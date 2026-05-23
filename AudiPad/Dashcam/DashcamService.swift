import Foundation
import AVFoundation
import UIKit
import Combine

/// Loop-recording dashcam built on AVCaptureSession + a rotating
/// AVCaptureMovieFileOutput. Records the back camera (+ mic when
/// enabled) into Documents/dashcam/segments/<timestamp>.mp4 in
/// N-second segments; once the segment count exceeds the cap, the
/// oldest non-locked segment is deleted. The user can lock the
/// current segment to move it to segments/locked/, where the
/// cleanup routine ignores it.
///
/// Segment rotation via stop/start of the movie file output rather
/// than AVAssetWriter HLS segmenting: simpler API, brief gap (a
/// frame or two) at boundaries. Acceptable trade-off for dashcam
/// use, where the question is "was the event captured?" not "is
/// the file frame-perfectly continuous?".
@MainActor
final class DashcamService: NSObject, ObservableObject {

    enum State: Equatable {
        case disabled                  // user toggle is off
        case awaitingPermission        // requesting camera / mic access
        case permissionDenied(String)  // user said no — surface in Settings
        case starting                  // session being configured
        case active                    // recording, segments rotating
        case error(String)             // session failed; user can retry
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var segments: [DashcamSegment] = []
    @Published private(set) var totalStorageBytes: Int64 = 0

    /// User preferences (mirrored via @AppStorage in the UI).
    static let enabledKey       = "audipad.dashcam.enabled"
    static let segmentSecondsKey = "audipad.dashcam.segmentSeconds"
    static let maxSegmentsKey   = "audipad.dashcam.maxSegments"
    static let audioEnabledKey  = "audipad.dashcam.audioEnabled"

    static let defaultEnabled        = false
    static let defaultSegmentSeconds = 60
    static let defaultMaxSegments    = 30
    static let defaultAudioEnabled   = true

    static let allowedSegmentSeconds = [30, 60, 120]
    static let allowedMaxSegments    = [10, 30, 60, 120]

    var isRecording: Bool {
        if case .active = state { return true }
        return false
    }

    // MARK: - Internal

    private let session = AVCaptureSession()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let movieOutput = AVCaptureMovieFileOutput()
    private var rotationTask: Task<Void, Never>?
    private var currentSegmentURL: URL?

    /// Serial queue for AVCaptureSession config — mandated by AVF.
    private let sessionQueue = DispatchQueue(label: "audipad.dashcam.session")

    // MARK: - Public API

    /// Begin (or restart) recording if the user toggle is on. Idempotent.
    func enable() {
        guard state != .active, state != .starting else {
            refreshSegments()
            return
        }
        state = .awaitingPermission

        Task { [weak self] in
            guard let self else { return }
            let videoOK = await Self.requestVideo()
            let audioOK = self.audioPref ? await Self.requestAudio() : true
            guard videoOK else {
                self.state = .permissionDenied("Camera access denied. Enable in iOS Settings → AudiPad.")
                return
            }
            if self.audioPref && !audioOK {
                self.state = .permissionDenied("Microphone access denied. Disable Audio in Dashcam settings or grant access in iOS Settings → AudiPad.")
                return
            }
            self.startSession()
        }
    }

    /// Stop everything cleanly. Active segment is finalized.
    func disable() {
        rotationTask?.cancel()
        rotationTask = nil
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
        sessionQueue.async { [session] in
            session.stopRunning()
        }
        state = .disabled
    }

    /// Lock the current segment so the loop-deletion skips it.
    /// Returns immediately; the actual move happens when the segment
    /// finalises (didFinishRecordingTo) so we can preserve the
    /// in-flight file properly.
    private var lockRequestedForCurrent = false
    func lockCurrentSegment() {
        lockRequestedForCurrent = true
    }

    /// Force a fresh enumeration of disk segments — used after
    /// destructive actions in the Settings UI (delete, unlock).
    func refreshSegments() {
        segments = enumerateSegments()
        totalStorageBytes = segments.reduce(0) { $0 + $1.fileSizeBytes }
    }

    /// Permanently delete a segment (locked or not).
    func deleteSegment(_ segment: DashcamSegment) {
        try? FileManager.default.removeItem(at: segment.url)
        refreshSegments()
    }

    /// Move a locked segment back into the active loop (where the
    /// cleanup routine may later delete it).
    func unlockSegment(_ segment: DashcamSegment) {
        guard segment.isLocked else { return }
        let dest = Self.segmentsDir.appendingPathComponent(segment.url.lastPathComponent)
        try? FileManager.default.moveItem(at: segment.url, to: dest)
        refreshSegments()
    }

    // MARK: - Setup

    private func startSession() {
        state = .starting
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            // Video input — back camera, fall back to any video device.
            let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                      for: .video,
                                                      position: .back)
                ?? AVCaptureDevice.default(for: .video)
            guard let videoDevice,
                  let videoIn = try? AVCaptureDeviceInput(device: videoDevice),
                  self.session.canAddInput(videoIn)
            else {
                Task { @MainActor in
                    self.state = .error("No camera available on this device.")
                }
                self.session.commitConfiguration()
                return
            }
            self.session.addInput(videoIn)
            self.videoInput = videoIn

            // Audio input — optional based on the user pref.
            let wantAudio = UserDefaults.standard.object(forKey: Self.audioEnabledKey) as? Bool
                ?? Self.defaultAudioEnabled
            if wantAudio,
               let mic = AVCaptureDevice.default(for: .audio),
               let micIn = try? AVCaptureDeviceInput(device: mic),
               self.session.canAddInput(micIn) {
                self.session.addInput(micIn)
                self.audioInput = micIn
            }

            // Movie file output — one per segment, recycled.
            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
                if let conn = self.movieOutput.connection(with: .video) {
                    if conn.isVideoStabilizationSupported {
                        conn.preferredVideoStabilizationMode = .auto
                    }
                }
            } else {
                Task { @MainActor in
                    self.state = .error("Couldn't add movie output to session.")
                }
                self.session.commitConfiguration()
                return
            }

            self.session.commitConfiguration()
            self.session.startRunning()

            Task { @MainActor in
                self.beginRotation()
                self.state = .active
            }
        }
    }

    // MARK: - Segment rotation

    private func beginRotation() {
        try? FileManager.default.createDirectory(at: Self.segmentsDir,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.lockedDir,
                                                 withIntermediateDirectories: true)
        startNewSegment()
        rotationTask?.cancel()
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = self?.segmentSecondsPref ?? Self.defaultSegmentSeconds
                try? await Task.sleep(for: .seconds(Double(seconds)))
                if Task.isCancelled { break }
                await self?.rotateSegment()
            }
        }
    }

    private func startNewSegment() {
        let url = Self.segmentsDir.appendingPathComponent("\(Self.timestamp()).mp4")
        currentSegmentURL = url
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    private func rotateSegment() {
        // Stopping triggers the delegate, which starts the next one.
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
    }

    // MARK: - Cleanup (loop cap enforcement)

    private func enforceCap() {
        let cap = maxSegmentsPref
        let active = enumerateActiveSegments().sorted { $0.recordedAt < $1.recordedAt }
        guard active.count > cap else { return }
        let toDelete = active.prefix(active.count - cap)
        for seg in toDelete {
            try? FileManager.default.removeItem(at: seg.url)
        }
    }

    // MARK: - Filesystem enumeration

    private func enumerateSegments() -> [DashcamSegment] {
        let unlocked = enumerateActiveSegments()
        let locked = enumerate(at: Self.lockedDir, locked: true)
        return (unlocked + locked).sorted { $0.recordedAt > $1.recordedAt }
    }

    private func enumerateActiveSegments() -> [DashcamSegment] {
        enumerate(at: Self.segmentsDir, locked: false)
    }

    private func enumerate(at dir: URL, locked: Bool) -> [DashcamSegment] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir,
                                                    includingPropertiesForKeys: [
                                                        .creationDateKey,
                                                        .fileSizeKey,
                                                    ])
        else { return [] }
        return urls.compactMap { url -> DashcamSegment? in
            guard url.pathExtension.lowercased() == "mp4" else { return nil }
            let attrs = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            let recordedAt = attrs?.creationDate
                ?? Self.parseTimestamp(from: url.lastPathComponent)
                ?? Date()
            let size = Int64(attrs?.fileSize ?? 0)
            // Duration probe is async + expensive; leave nil for now.
            // Settings UI can display it as "≈ N s" using the
            // configured segment length instead.
            return DashcamSegment(url: url,
                                  recordedAt: recordedAt,
                                  durationSeconds: nil,
                                  fileSizeBytes: size,
                                  isLocked: locked)
        }
    }

    // MARK: - Permissions

    private static func requestVideo() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private static func requestAudio() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - Preferences (read direct from UserDefaults — these can
    // change while the service is running and we read them per-segment)

    private var audioPref: Bool {
        UserDefaults.standard.object(forKey: Self.audioEnabledKey) as? Bool
            ?? Self.defaultAudioEnabled
    }
    private var segmentSecondsPref: Int {
        let raw = UserDefaults.standard.object(forKey: Self.segmentSecondsKey) as? Int
            ?? Self.defaultSegmentSeconds
        return Self.allowedSegmentSeconds.contains(raw) ? raw : Self.defaultSegmentSeconds
    }
    private var maxSegmentsPref: Int {
        let raw = UserDefaults.standard.object(forKey: Self.maxSegmentsKey) as? Int
            ?? Self.defaultMaxSegments
        return Self.allowedMaxSegments.contains(raw) ? raw : Self.defaultMaxSegments
    }

    // MARK: - Paths

    static let dashcamRoot: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("dashcam", isDirectory: true)
    }()

    static let segmentsDir: URL = dashcamRoot.appendingPathComponent("segments", isDirectory: true)
    static let lockedDir: URL = segmentsDir.appendingPathComponent("locked", isDirectory: true)

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }

    private static func parseTimestamp(from filename: String) -> Date? {
        let base = (filename as NSString).deletingPathExtension
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.date(from: base)
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension DashcamService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        // AVF calls this on a background queue. Hop to MainActor for
        // state mutations + filesystem bookkeeping.
        Task { @MainActor in
            // Flag the file as not-iCloud-backed so segments don't
            // sync to iCloud Drive (would be silly for ~30 min of
            // looping dashcam).
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableURL = outputFileURL
            try? mutableURL.setResourceValues(resourceValues)

            // Lock the just-finished segment if the user pressed Lock
            // during this segment's lifetime.
            if self.lockRequestedForCurrent {
                let dest = Self.lockedDir
                    .appendingPathComponent(outputFileURL.lastPathComponent)
                try? FileManager.default.moveItem(at: outputFileURL, to: dest)
                self.lockRequestedForCurrent = false
            }

            self.enforceCap()
            self.refreshSegments()

            // If we're still supposed to be recording, kick the
            // next segment immediately so the gap is sub-frame.
            if self.state == .active {
                self.startNewSegment()
            }
        }
    }
}
