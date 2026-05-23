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
        return v
    }

    func updateUIView(_ uiView: PreviewContainer, context: Context) {
        // Session reference can change if the service re-creates it
        // (currently it doesn't, but keep the update path correct).
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
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
