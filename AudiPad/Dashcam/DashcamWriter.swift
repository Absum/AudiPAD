import Foundation
import AVFoundation

/// Per-segment AVAssetWriter wrapper. Wraps an mp4 writer with one
/// video input (H.264) + one audio input (AAC). The DashcamService
/// owns one of these at a time; rotation = finishWriting current +
/// startWriting next with a new URL.
final class DashcamWriter {

    let url: URL
    let videoSize: CGSize
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor

    private(set) var startedAt: CMTime?
    private(set) var hasFinished = false

    init(url: URL, videoSize: CGSize) throws {
        self.url = url
        self.videoSize = videoSize

        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false

        // Video — H.264, ~6 Mbit/s at 720p is a good legible-but-
        // not-bloated setting for dashcam.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoSize.width,
            AVVideoHeightKey: videoSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video,
                                            outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoSize.width,
            kCVPixelBufferHeightKey as String: videoSize.height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelAttrs
        )

        // Audio — AAC stereo, 64 kbit/s. Voice + ambient road noise
        // doesn't need high bitrate.
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 64_000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio,
                                            outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw NSError(domain: "DashcamWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add writer inputs."])
        }
        writer.add(videoInput)
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "DashcamWriter", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "startWriting failed."])
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.pixelBufferAdaptor = adaptor
    }

    /// First sample-buffer presentation timestamp seen — used to
    /// startSession so the writer's timeline aligns with capture.
    func startSessionIfNeeded(at pts: CMTime) {
        if startedAt == nil {
            writer.startSession(atSourceTime: pts)
            startedAt = pts
        }
    }

    /// Append a video pixel buffer at the given timestamp. Returns
    /// false if the writer wasn't ready (drop the frame).
    @discardableResult
    func append(pixelBuffer: CVPixelBuffer, at pts: CMTime) -> Bool {
        guard !hasFinished, videoInput.isReadyForMoreMediaData else { return false }
        return pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: pts)
    }

    /// Append an audio sample. Returns false if the writer wasn't
    /// ready (drop the sample).
    @discardableResult
    func append(audioSample: CMSampleBuffer) -> Bool {
        guard !hasFinished, audioInput.isReadyForMoreMediaData else { return false }
        return audioInput.append(audioSample)
    }

    /// Finalize the segment file. Idempotent — second call is a no-op.
    func finish() async {
        guard !hasFinished else { return }
        hasFinished = true
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await writer.finishWriting()
    }
}
