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
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let pipeline = DashcamRecordingPipeline()
    private var overlayStateTask: Task<Void, Never>?

    /// Serial queue for AVCaptureSession config — mandated by AVF.
    private let sessionQueue = DispatchQueue(label: "audipad.dashcam.session")

    /// Dedicated sample-buffer queue — keeps the AVCapture pipeline
    /// off the session-config queue so config + sample handling
    /// don't block each other.
    private let sampleQueue = DispatchQueue(label: "audipad.dashcam.samples",
                                            qos: .userInitiated)

    // MARK: - Overlay data sources
    //
    // Weak refs so DashcamService can ask LocationService /
    // RoadSpeedLimitService / MotionService for current values when
    // refreshing the overlay state. Configured by ContentView at
    // startup; nil-tolerant so the dashcam still works if any
    // service is unavailable.
    weak var location: LocationService?
    weak var roadLimits: RoadSpeedLimitService?
    weak var motion: MotionService?

    func configure(location: LocationService,
                   roadLimits: RoadSpeedLimitService,
                   motion: MotionService) {
        self.location = location
        self.roadLimits = roadLimits
        self.motion = motion
        pipeline.onSegmentFinished = { [weak self] url in
            Task { @MainActor in self?.handleSegmentFinished(url: url) }
        }
    }

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
        overlayStateTask?.cancel()
        overlayStateTask = nil
        // Mark the pipeline disabled — next sample buffer will be
        // dropped. Then finalize the in-flight writer so the segment
        // file isn't left half-written.
        pipeline.updateConfig { $0.enabled = false }
        Task.detached { [pipeline] in
            _ = await pipeline.finishCurrentSegment()
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
    /// Set alongside `lockRequestedForCurrent` when the user pressed
    /// SAVE in the TopBar — the just-finished segment should also be
    /// exported to Photos so iCloud syncs it to the user's other
    /// devices. Lock alone (from the Settings list) doesn't trigger
    /// Photos export.
    private var photosSaveRequestedForCurrent = false
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
        var exportedURLs: [URL] = []
        for seg in candidates {
            let dest = Self.lockedDir.appendingPathComponent(seg.url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: seg.url, to: dest)
                exportedURLs.append(dest)
            } catch {
                // Already moved or filesystem race — best effort,
                // skip the export for this one.
            }
        }
        // Photos export — fire-and-forget. iCloud Photos picks them
        // up and replicates to iPhone / Mac / other iPads.
        for dest in exportedURLs {
            Task { await DashcamPhotosExporter.export(dest) }
        }
        // Also lock + Photos-export the in-flight segment — it's
        // the one currently covering the most-recent moment of the
        // save window. The actual export happens in
        // handleSegmentFinished when the writer finalises this seg.
        lockRequestedForCurrent = true
        photosSaveRequestedForCurrent = true
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
        // Snapshot orientation here on MainActor — UIWindowScene
        // reads are main-thread-only, and the sessionQueue block
        // below needs to apply it to the movie-output connection.
        let videoOrientation = DashcamOrientation.currentVideoOrientation
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

            // Video + audio DATA outputs — we own the sample buffers,
            // composite the overlay onto each frame in the pipeline,
            // and write through AVAssetWriter. (Replaces the previous
            // AVCaptureMovieFileOutput.)
            self.videoDataOutput.setSampleBufferDelegate(self.pipeline,
                                                         queue: self.sampleQueue)
            self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
            self.videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            if self.session.canAddOutput(self.videoDataOutput) {
                self.session.addOutput(self.videoDataOutput)
                if let conn = self.videoDataOutput.connection(with: .video) {
                    if conn.isVideoStabilizationSupported {
                        conn.preferredVideoStabilizationMode = .auto
                    }
                    if conn.isVideoOrientationSupported {
                        conn.videoOrientation = videoOrientation
                    }
                }
            } else {
                Task { @MainActor in
                    self.state = .error("Couldn't add video data output to session.")
                }
                self.session.commitConfiguration()
                return
            }

            self.audioDataOutput.setSampleBufferDelegate(self.pipeline,
                                                         queue: self.sampleQueue)
            if self.session.canAddOutput(self.audioDataOutput) {
                self.session.addOutput(self.audioDataOutput)
            }

            self.session.commitConfiguration()
            self.session.startRunning()

            Task { @MainActor in
                self.beginRecording()
                self.state = .active
            }
        }
    }

    // MARK: - Recording lifecycle

    private func beginRecording() {
        try? FileManager.default.createDirectory(at: Self.segmentsDir,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.lockedDir,
                                                 withIntermediateDirectories: true)
        pipeline.updateConfig {
            $0.enabled = true
            $0.segmentsDir = Self.segmentsDir
            $0.segmentSeconds = self.segmentSecondsPref
        }
        startOverlayStateLoop()
    }

    /// Pushes overlay data into the pipeline a few times per second.
    /// Cheap — just reads the current values from each service and
    /// hands them to the pipeline (which the sample queue then reads
    /// per frame). Stops on cancel.
    private func startOverlayStateLoop() {
        overlayStateTask?.cancel()
        overlayStateTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pushOverlayState()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        // Push immediately so the first frame already has data.
        pushOverlayState()
    }

    private func pushOverlayState() {
        let loc = location?.location
        let road = roadLimits?.currentRoad
        let state = DashcamOverlayRenderer.State(
            date: Date(),
            speedKph: loc.flatMap { $0.speed >= 0 ? $0.speed * 3.6 : nil },
            roadName: road?.name,
            roadRef: road?.ref,
            lateralG: motion?.currentLateralG,
            longitudinalG: motion?.currentLongitudinalG,
            coordinate: loc?.coordinate
        )
        pipeline.setOverlayState(state)
        // Also keep the pipeline's segment-seconds preference in sync
        // in case the user changed it in Settings.
        pipeline.updateConfig { $0.segmentSeconds = self.segmentSecondsPref }
    }

    private func handleSegmentFinished(url: URL) {
        // Sealed segment file — exclude from iCloud backup, run the
        // cleanup routine, refresh the published segments list.
        var u = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? u.setResourceValues(resourceValues)

        var finalURL = url
        if lockRequestedForCurrent {
            let dest = Self.lockedDir.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: url, to: dest)
                finalURL = dest
            } catch {
                // Already moved or filesystem race — keep finalURL
                // pointing at the original location for the Photos
                // export below.
            }
            lockRequestedForCurrent = false
        }

        if photosSaveRequestedForCurrent {
            photosSaveRequestedForCurrent = false
            Task { await DashcamPhotosExporter.export(finalURL) }
        }

        enforceCap()
        refreshSegments()
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

// Segment-finished handling lives in
// `DashcamService.handleSegmentFinished(url:)` now — driven by the
// DashcamRecordingPipeline's onSegmentFinished callback. The old
// AVCaptureFileOutputRecordingDelegate path is gone with the
// AVCaptureMovieFileOutput it served.
