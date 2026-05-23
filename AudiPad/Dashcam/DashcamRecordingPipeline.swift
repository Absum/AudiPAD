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
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let size = CGSize(width: width, height: height)

        // First frame — lock in video size and create the overlay
        // renderer to match. Subsequent size changes (orientation
        // flip mid-recording) will cause the renderer to draw at
        // wrong coords; rotation handling above + matching the
        // session's video connection orientation prevents that.
        if videoSize != size {
            videoSize = size
            overlayRenderer = DashcamOverlayRenderer(size: size)
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
                         videoSize: size,
                         startAt: pts)
            rotationRequested = false
        }

        guard let writer = currentWriter else { return }
        writer.startSessionIfNeeded(at: pts)

        // Composite overlay onto frame.
        let sourceCI = CIImage(cvPixelBuffer: pixelBuffer)
        let state = stateLock.withLock { $0 }
        let composited: CIImage
        if let renderer = overlayRenderer,
           let overlay = renderer.image(for: state) {
            let overlayCI = CIImage(cgImage: overlay)
            composited = overlayCI.composited(over: sourceCI)
        } else {
            composited = sourceCI
        }

        // Render the composite into an output pixel buffer. Allocate
        // per-frame for now (pool optimisation possible later).
        var outBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width, height,
                                         kCVPixelFormatType_32BGRA,
                                         bufferAttributes as CFDictionary,
                                         &outBuffer)
        guard status == kCVReturnSuccess, let outBuffer else { return }

        ciContext.render(composited,
                         to: outBuffer,
                         bounds: composited.extent,
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
