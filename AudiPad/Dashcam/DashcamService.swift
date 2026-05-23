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

    /// Timestamp + duration of the most-recent SAVE-LAST-N press, so
    /// the TopBar can flash a "SAVED Xs" pill briefly after. Nil
    /// when no save has happened yet (or the pill has expired).
    @Published private(set) var lastSaveAcknowledged: (at: Date, seconds: Int)?

    /// User preferences (mirrored via @AppStorage in the UI).
    static let enabledKey            = "audipad.dashcam.enabled"
    static let segmentSecondsKey     = "audipad.dashcam.segmentSeconds"
    static let loopMinutesKey        = "audipad.dashcam.loopMinutes"
    static let audioEnabledKey       = "audipad.dashcam.audioEnabled"
    static let saveDurationSecondsKey = "audipad.dashcam.saveDurationSeconds"

    static let defaultEnabled              = false
    static let defaultSegmentSeconds       = 60
    static let defaultLoopMinutes          = 30
    static let defaultAudioEnabled         = true
    static let defaultSaveDurationSeconds  = 30

    static let allowedSegmentSeconds      = [30, 60, 120]
    static let allowedSaveDurationSeconds = [15, 30, 60, 120]

    /// Loop-length bounds for the Settings Stepper. 5 min is the
    /// shortest sensible cap (loses incidents quickly); 240 min is
    /// generous (~12 GB at 60 s/segment, more than enough for any
    /// drive).
    static let loopMinutesRange: ClosedRange<Int> = 5...240
    static let loopMinutesStep: Int = 5

    var isRecording: Bool {
        if case .active = state { return true }
        return false
    }

    /// `true` while a preview-only session is running OR while
    /// recording is active (both share the same underlying session,
    /// which the preview layer can hook into). The Settings preview
    /// view binds to this to decide whether to render the layer.
    @Published private(set) var isShowingPreview: Bool = false

    /// Public-readable AVCaptureSession so a SwiftUI
    /// `UIViewRepresentable` can attach an `AVCaptureVideoPreviewLayer`
    /// to it. Don't mutate from outside the service — all session
    /// reconfig has to go through sessionQueue for thread safety.
    let session = AVCaptureSession()

    // MARK: - Internal
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
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            // If a preview observer is still around, leave the
            // session inputs in place so a follow-up startPreview()
            // can resume without re-asking the user for permissions.
            // Inputs only get torn down on stopPreview when neither
            // mode wants the camera any more.
        }
        // Preserve isShowingPreview if a Settings preview is mounted
        // alongside an active recording that just stopped — the view
        // will call stopPreview() on its own lifecycle.
        state = .disabled
    }

    // MARK: - Preview-only mode

    /// `true` while a preview-only session is keeping the camera
    /// alive without any recording. Used to decide whether
    /// `stopPreview()` should actually shut the session down.
    private var inPreviewMode = false

    /// Begin (or resume) a live camera preview. If recording is on,
    /// the session is already running and this is just a flag flip —
    /// the same preview layer renders against the recording session.
    /// If recording is off, configures the session for input-only
    /// capture (no movie output, no rotation) so the user can verify
    /// mount alignment without committing to disk.
    func startPreview() {
        // Session already running for recording → just light up the
        // preview flag so the SwiftUI view renders the layer.
        if isRecording {
            if !isShowingPreview { isShowingPreview = true }
            return
        }
        // Already in preview-only mode → idempotent.
        if inPreviewMode {
            if !isShowingPreview { isShowingPreview = true }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let videoOK = await Self.requestVideo()
            guard videoOK else {
                self.state = .permissionDenied("Camera access denied. Enable in iOS Settings → AudiPad.")
                return
            }
            self.inPreviewMode = true
            self.isShowingPreview = true
            self.startSessionForPreview()
        }
    }

    /// Tear down a preview-only session. No-op if recording is on
    /// (the recording session owns the camera until disable() is
    /// called). The Settings view typically calls this on its
    /// .onDisappear.
    func stopPreview() {
        isShowingPreview = false
        if isRecording { return }      // recording still wants the camera
        guard inPreviewMode else { return }
        inPreviewMode = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.session.beginConfiguration()
            for input in self.session.inputs {
                self.session.removeInput(input)
            }
            for output in self.session.outputs {
                self.session.removeOutput(output)
            }
            self.session.commitConfiguration()
            self.videoInput = nil
            self.audioInput = nil
        }
    }

    private func startSessionForPreview() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            // Video input — back camera, fall back to any video device.
            let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                      for: .video,
                                                      position: .back)
                ?? AVCaptureDevice.default(for: .video)
            if let videoDevice,
               let videoIn = try? AVCaptureDeviceInput(device: videoDevice),
               self.session.canAddInput(videoIn) {
                self.session.addInput(videoIn)
                self.videoInput = videoIn
            } else {
                Task { @MainActor in
                    self.inPreviewMode = false
                    self.isShowingPreview = false
                    self.state = .error("No camera available on this device.")
                }
                self.session.commitConfiguration()
                return
            }
            // Preview deliberately skips the audio input + movie
            // output — we only need frames in the preview layer.
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    /// Lock the current segment so the loop-deletion skips it.
    /// Returns immediately; the actual move happens when the segment
    /// finalises (didFinishRecordingTo) so we can preserve the
    /// in-flight file properly.
    private var lockRequestedForCurrent = false
    func lockCurrentSegment() {
        lockRequestedForCurrent = true
    }

    /// Panic-save the last `seconds` of footage. Walks segments/ for
    /// files whose recordedAt falls inside (now − seconds − segLen,
    /// now], moves them to segments/locked/, AND flags the currently
    /// in-flight segment to be locked on its next rotation — so any
    /// part of the save window that's still being written is also
    /// preserved.
    ///
    /// The `+ segLen` slack on the lower bound captures any segment
    /// that *started* before the window but is still actively
    /// covering part of it (e.g. a 60 s segment started 50 s ago is
    /// 10 s old; saving "last 30 s" must include it because the
    /// first 20 s of the save window are inside that segment).
    func saveLastSeconds(_ seconds: Int) {
        let now = Date()
        let segLen = Double(segmentSecondsPref)
        let cutoff = now.addingTimeInterval(-Double(seconds) - segLen)

        let candidates = enumerateActiveSegments().filter {
            $0.recordedAt >= cutoff
        }
        for seg in candidates {
            let dest = Self.lockedDir.appendingPathComponent(seg.url.lastPathComponent)
            try? FileManager.default.moveItem(at: seg.url, to: dest)
        }
        // Also lock the in-flight segment — it's the one currently
        // covering the most-recent moment of the save window.
        lockRequestedForCurrent = true
        refreshSegments()
        lastSaveAcknowledged = (now, seconds)

        // Auto-clear the ack after 2.5 s so the TopBar pill fades.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run {
                guard let self else { return }
                if let ack = self.lastSaveAcknowledged,
                   ack.at == now {
                    self.lastSaveAcknowledged = nil
                }
            }
        }
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
        // Preview, if any, is being upgraded to a recording session;
        // mark that the preview-only mode no longer owns the camera.
        let wasInPreview = inPreviewMode
        inPreviewMode = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            // Wipe whatever the preview mode (or a previous run) put
            // in — gives us a clean slate so addInput / addOutput
            // never fail with "already added".
            for input in self.session.inputs {
                self.session.removeInput(input)
            }
            for output in self.session.outputs {
                self.session.removeOutput(output)
            }
            self.videoInput = nil
            self.audioInput = nil
            _ = wasInPreview // future: could log/telemetry the transition

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
    private var loopMinutesPref: Int {
        let raw = UserDefaults.standard.object(forKey: Self.loopMinutesKey) as? Int
            ?? Self.defaultLoopMinutes
        return min(max(raw, Self.loopMinutesRange.lowerBound),
                   Self.loopMinutesRange.upperBound)
    }
    /// Derived cap — ceil(loopMinutes × 60 / segmentSeconds) so the
    /// loop's actual on-disk duration matches the user's chosen
    /// minutes regardless of segment length. Always at least 1.
    private var maxSegmentsPref: Int {
        let totalSeconds = loopMinutesPref * 60
        let segs = (totalSeconds + segmentSecondsPref - 1) / segmentSecondsPref
        return max(1, segs)
    }
    var saveDurationPref: Int {
        let raw = UserDefaults.standard.object(forKey: Self.saveDurationSecondsKey) as? Int
            ?? Self.defaultSaveDurationSeconds
        return Self.allowedSaveDurationSeconds.contains(raw)
            ? raw : Self.defaultSaveDurationSeconds
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
