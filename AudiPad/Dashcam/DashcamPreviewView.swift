import SwiftUI
import AVFoundation
import UIKit

/// SwiftUI wrapper around `AVCaptureVideoPreviewLayer` so the
/// dashcam's live feed can render inside Settings → Dashcam.
/// Caller decides the frame; the layer fills it with aspect-fit
/// gravity (letterboxed where needed so nothing's cropped — the
/// user wants to verify framing).
struct DashcamPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainer {
        let v = PreviewContainer()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        applyOrientation(to: v.previewLayer)
        return v
    }

    func updateUIView(_ uiView: PreviewContainer, context: Context) {
        // Session reference can change if the service re-creates it
        // (currently it doesn't, but keep the update path correct).
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        // Re-apply on every update so a device-rotation between
        // LandscapeLeft and LandscapeRight is picked up immediately.
        applyOrientation(to: uiView.previewLayer)
    }

    /// Sync the preview-layer connection to the active scene's
    /// interface orientation. Without this the layer renders in
    /// the camera's native portrait, which on a landscape-locked
    /// iPad shows the world rotated 90° from the windshield view.
    private func applyOrientation(to layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection,
              connection.isVideoOrientationSupported
        else { return }
        let target = DashcamOrientation.currentVideoOrientation
        if connection.videoOrientation != target {
            connection.videoOrientation = target
        }
    }

    /// Custom UIView whose backing layer is an
    /// `AVCaptureVideoPreviewLayer`. Using a backing layer (rather
    /// than addSublayer) means the layer auto-resizes with the
    /// view's bounds, so we don't need a layoutSubviews override.
    final class PreviewContainer: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

/// Shared helper that maps the active UIWindowScene's
/// interfaceOrientation to AVCaptureVideoOrientation. Used by both
/// the preview layer (so the live feed matches the windshield view)
/// AND the movie-output connection (so recorded segments save in
/// landscape — otherwise they're unwatchable for incident review).
enum DashcamOrientation {
    static var currentVideoOrientation: AVCaptureVideoOrientation {
        let ui: UIInterfaceOrientation
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first {
            ui = scene.interfaceOrientation
        } else {
            ui = .landscapeRight
        }
        switch ui {
        case .portrait:           return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft:      return .landscapeLeft
        case .landscapeRight:     return .landscapeRight
        case .unknown:            return .landscapeRight
        @unknown default:         return .landscapeRight
        }
    }
}
