import Foundation
import Photos

/// Thin wrapper around `PHPhotoLibrary` for exporting saved dashcam
/// segments to the user's iOS Photos library. From there iCloud
/// Photos syncs the clip to the user's iPhone / Mac / other iPads,
/// so an incident captured on the car iPad is one tap away on every
/// signed-in device.
///
/// Photos export is treated as a nice-to-have, not the source of
/// truth — the locked segment lives in `Documents/dashcam/
/// segments/locked/` regardless. Failures are logged and dropped;
/// the segment file on disk is untouched.
enum DashcamPhotosExporter {

    /// Export a video file to Photos. Requests `.addOnly` access on
    /// first use; on subsequent calls returns immediately if the
    /// authorization is already granted. No-op if denied.
    static func export(_ url: URL) async {
        let status = await ensureAuthorized()
        switch status {
        case .authorized, .limited:
            await performExport(url)
        case .denied, .restricted:
            print("[AudiPad/Dashcam] Photos export skipped — \(status.rawValue) (open iOS Settings → AudiPad → Photos to grant access)")
        case .notDetermined:
            // ensureAuthorized only returns .notDetermined if the
            // system never resolved the request; treat as denial.
            print("[AudiPad/Dashcam] Photos export skipped — authorization not determined")
        @unknown default:
            print("[AudiPad/Dashcam] Photos export skipped — unknown auth status")
        }
    }

    // MARK: - Internal

    private static func ensureAuthorized() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current != .notDetermined { return current }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                cont.resume(returning: status)
            }
        }
    }

    private static func performExport(_ url: URL) async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                // Don't have Photos move/copy the file — it'll read
                // from our Documents/ path. shouldMoveFile=false is
                // the default but spell it out for clarity.
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: url, options: options)
            }
            print("[AudiPad/Dashcam] Photos export OK: \(url.lastPathComponent)")
        } catch {
            print("[AudiPad/Dashcam] Photos export failed for \(url.lastPathComponent): \(error)")
        }
    }
}
