import Foundation
import AVFoundation
import CoreImage
import Metal
import os
import UIKit

/// Owns the live-recording pipeline: receives sample buffers from
/// AVCapture, composites the overlay onto each video frame via Core
/// Image, writes through a per-segment `DashcamWriter`, and rotates
/// to a new writer when the segment duration is reached. All on a
/// dedicated sample-buffer queue — no MainActor hops in the hot path
/// (the overlay state is snapshotted via a lock that the MainActor
/// updates a few times per second).
///
/// `nonisolated` because the AVCapture delegate callbacks happen on
/// the sample-buffer queue. State that crosses with the MainActor
/// (overlay snapshot, rotation requests) is gated by a lock.
final class DashcamRecordingPipeline: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    /// Snapshot of overlay data used by the renderer. Updated by
    /// the MainActor at ~4 Hz; read by the pipeline per frame.
    private let stateLock = OSAllocatedUnfairLock<DashcamOverlayRenderer.State>(
        initialState: .empty
    )

    /// Active recording configuration — segment length + the
    /// directory to write into. Updated under stateLock so the
    /// sample-buffer queue and the MainActor agree.
    private let configLock = OSAllocatedUnfairLock<RecordingConfig>(
        initialState: RecordingConfig(segmentSeconds: 60,
                                      segmentsDir: nil,
                                      enabled: false)
    )

    struct RecordingConfig {
        var segmentSeconds: Int
        var segmentsDir: URL?
        var enabled: Bool
        /// Region-of-interest as a normalized rect in source-frame
        /// unit space (top-left origin). Default = full frame.
        /// Changes take effect on the next segment rotation since
        /// AVAssetWriter dimensions are fixed at writer-create.
        var normalizedROI: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// Called from the pipeline (on sample-buffer queue) when a
    /// segment finishes writing — gives the service a chance to
    /// run loop-cleanup, lock-handling, segment-list refresh.
    var onSegmentFinished: ((URL) -> Void)?

    // Per-frame state (only touched on sample-buffer queue).
    private let ciContext: CIContext
    private var overlayRenderer: DashcamOverlayRenderer?
    private var currentWriter: DashcamWriter?
    private var currentSegmentStartedAt: CMTime?
    private var videoSize: CGSize?

    /// Pixel-format-converted buffers we hand to the writer — kept
    /// re-allocated per frame for simplicity (could be pooled later).
    private let bufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]

    override init() {
        // Metal-backed Core Image context — gives us GPU compositing
        // for the per-frame overlay blit. Falls back to a software
        // context if Metal is unavailable (simulator, etc.).
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device,
                                       options: [.workingColorSpace: NSNull()])
        } else {
            self.ciContext = CIContext(options: [.workingColorSpace: NSNull()])
        }
        super.init()
    }

    // MARK: - Configuration

    func setOverlayState(_ state: DashcamOverlayRenderer.State) {
        stateLock.withLock { $0 = state }
    }

    func updateConfig(_ block: (inout RecordingConfig) -> Void) {
        configLock.withLock { block(&$0) }
    }

    func currentConfig() -> RecordingConfig {
        configLock.withLock { $0 }
    }

    /// Force the current writer to close at the next opportunity.
    /// The sample-buffer queue will start a new one on the next
    /// video frame.
    func forceRotation() {
        rotationRequested = true
    }

    private var rotationRequested = false

    // MARK: - Sample-buffer delegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let config = currentConfig()
        guard config.enabled, let segmentsDir = config.segmentsDir else { return }

        if output is AVCaptureAudioDataOutput {
            processAudio(sampleBuffer)
            return
        }
        processVideo(sampleBuffer, segmentsDir: segmentsDir,
                     segmentSeconds: config.segmentSeconds)
    }

    private func processVideo(_ sampleBuffer: CMSampleBuffer,
                              segmentsDir: URL,
                              segmentSeconds: Int) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let sourceSize = CGSize(width: sourceWidth, height: sourceHeight)

        // ROI in pixel space (CIImage uses bottom-left origin so
        // the Y coord is flipped from the unit-space top-left we
        // store in RecordingConfig).
        let roiUnit = currentConfig().normalizedROI
        let cropRect = CGRect(
            x: roiUnit.minX * sourceSize.width,
            y: (1 - roiUnit.maxY) * sourceSize.height,
            width: roiUnit.width * sourceSize.width,
            height: roiUnit.height * sourceSize.height
        ).integral
        let outputSize = cropRect.size

        // First frame at this output size — refresh the overlay
        // renderer + force a writer rotation so the new writer is
        // sized to match the cropped output.
        if videoSize != outputSize {
            videoSize = outputSize
            overlayRenderer = DashcamOverlayRenderer(size: outputSize)
            // Drop the existing writer — its video dimensions are
            // locked at create time and don't match the new crop.
            // Detached finish keeps the sample queue moving.
            if let outgoing = currentWriter {
                currentWriter = nil
                Task.detached { [outgoing, onSegmentFinished] in
                    await outgoing.finish()
                    onSegmentFinished?(outgoing.url)
                }
            }
        }

        // Rotation check — if we've crossed segmentSeconds since the
        // current writer started, OR the writer is missing, OR a
        // forced rotation was requested, swap in a new writer.
        let elapsedSeconds: Double = currentSegmentStartedAt.flatMap {
            CMTimeGetSeconds(pts - $0)
        } ?? .greatestFiniteMagnitude
        let needRotation = currentWriter == nil
            || elapsedSeconds >= Double(segmentSeconds)
            || rotationRequested

        if needRotation {
            rotateWriter(segmentsDir: segmentsDir,
                         videoSize: outputSize,
                         startAt: pts)
            rotationRequested = false
        }

        guard let writer = currentWriter else { return }
        writer.startSessionIfNeeded(at: pts)

        // Crop the source frame, then composite overlay.
        let sourceCI = CIImage(cvPixelBuffer: pixelBuffer)
        // CIImage cropped(to:) clips the visible region but keeps
        // the original extent's origin — translate so the cropped
        // image's origin lands at (0,0) for the output buffer.
        let croppedCI = sourceCI
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX,
                                               y: -cropRect.minY))

        let state = stateLock.withLock { $0 }
        let composited: CIImage
        if let renderer = overlayRenderer,
           let overlay = renderer.image(for: state) {
            // Overlay was rendered with origin top-left at output
            // size (UIGraphicsImageRenderer convention). CIImage
            // converts it to bottom-left origin automatically.
            let overlayCI = CIImage(cgImage: overlay)
            composited = overlayCI.composited(over: croppedCI)
        } else {
            composited = croppedCI
        }

        // Render the composite into an output pixel buffer at the
        // cropped dimensions. Allocate per-frame (pool optimisation
        // possible later).
        var outBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(outputSize.width),
                                         Int(outputSize.height),
                                         kCVPixelFormatType_32BGRA,
                                         bufferAttributes as CFDictionary,
                                         &outBuffer)
        guard status == kCVReturnSuccess, let outBuffer else { return }

        ciContext.render(composited,
                         to: outBuffer,
                         bounds: CGRect(origin: .zero, size: outputSize),
                         colorSpace: CGColorSpaceCreateDeviceRGB())

        writer.append(pixelBuffer: outBuffer, at: pts)
    }

    private func processAudio(_ sampleBuffer: CMSampleBuffer) {
        // Audio passes through untouched. We can't append until the
        // writer has been started by the first video frame.
        guard let writer = currentWriter, writer.startedAt != nil else { return }
        writer.append(audioSample: sampleBuffer)
    }

    // MARK: - Rotation

    private func rotateWriter(segmentsDir: URL,
                              videoSize: CGSize,
                              startAt pts: CMTime) {
        // Close the outgoing writer first (async, doesn't block the
        // new writer's startWriting). The completion handler fires
        // the onSegmentFinished callback once the file is sealed.
        if let outgoing = currentWriter {
            Task.detached { [outgoing, onSegmentFinished] in
                await outgoing.finish()
                onSegmentFinished?(outgoing.url)
            }
        }

        let url = segmentsDir.appendingPathComponent("\(Self.timestamp()).mp4")
        do {
            let writer = try DashcamWriter(url: url, videoSize: videoSize)
            currentWriter = writer
            currentSegmentStartedAt = pts
        } catch {
            // Log + leave currentWriter nil; next frame will retry.
            print("[AudiPad/Dashcam] writer create failed: \(error)")
            currentWriter = nil
            currentSegmentStartedAt = nil
        }
    }

    /// Finalize the currently-recording segment (e.g. on disable).
    /// Idempotent. Returns the closed segment's URL.
    func finishCurrentSegment() async -> URL? {
        guard let writer = currentWriter else { return nil }
        currentWriter = nil
        currentSegmentStartedAt = nil
        await writer.finish()
        onSegmentFinished?(writer.url)
        return writer.url
    }

    // MARK: - Path helpers

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }
}
