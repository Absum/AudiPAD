import SwiftUI
import AVFoundation
import UIKit

/// SwiftUI wrapper around `AVCaptureVideoPreviewLayer` for the
/// dashcam's live feed in Settings. Supports a region-of-interest
/// (ROI) crop applied to the live preview so the user can see
/// what'll be in the recorded file before the recorder rolls.
///
/// AVCaptureVideoPreviewLayer renders the captured video stream
/// directly and **does not honour `CALayer.contentsRect`** — so
/// our crop has to be done by resizing the layer itself within a
/// clipping superview. PreviewContainer wraps the layer as a
/// sublayer of a regular UIView with `clipsToBounds = true`.
struct DashcamPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Normalized ROI rect in top-left unit space — same convention
    /// as `DashcamService.normalizedROI()`. Identity = full frame.
    var roi: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    func makeUIView(context: Context) -> PreviewContainer {
        let v = PreviewContainer()
        v.backgroundColor = .black
        v.attach(session: session)
        v.applyROI(roi)
        applyOrientation(to: v.previewLayer)
        return v
    }

    func updateUIView(_ uiView: PreviewContainer, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.attach(session: session)
        }
        uiView.applyROI(roi)
        applyOrientation(to: uiView.previewLayer)
    }

    private func applyOrientation(to layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection,
              connection.isVideoOrientationSupported
        else { return }
        let target = DashcamOrientation.currentVideoOrientation
        if connection.videoOrientation != target {
            connection.videoOrientation = target
        }
    }

    /// Regular UIView (NOT layerClass-overridden) so we get a normal
    /// CALayer with `masksToBounds = true`; the AVCaptureVideoPreviewLayer
    /// is added as a sublayer whose frame we control. Sizing the
    /// sublayer larger than the parent bounds is what produces the
    /// ROI crop effect — the parent clips, only the ROI region shows.
    final class PreviewContainer: UIView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        private var roi: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            layer.masksToBounds = true
            // resizeAspectFill so the captured frame fills the
            // (potentially-larger-than-parent) sublayer area — when
            // we scale up to crop, we don't want letterbox bars
            // appearing inside the layer.
            previewLayer.videoGravity = .resizeAspectFill
            layer.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:)") }

        func attach(session: AVCaptureSession) {
            previewLayer.session = session
        }

        func applyROI(_ roi: CGRect) {
            self.roi = roi
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // ROI math: the cropped region (roi in unit space)
            // should fill `bounds`. Compute the enlarged sublayer
            // frame such that the roi sub-region maps to bounds.
            //
            //   scaledLayerWidth  = bounds.width  / roi.width
            //   scaledLayerHeight = bounds.height / roi.height
            //   layer.origin      = (-roi.minX * scaledW, -roi.minY * scaledH)
            //
            // Guard against degenerate zero-size ROI (shouldn't happen
            // — DashcamService clamps — but cheap to check).
            let w = roi.width  > 0 ? bounds.width  / roi.width  : bounds.width
            let h = roi.height > 0 ? bounds.height / roi.height : bounds.height
            previewLayer.frame = CGRect(
                x: -roi.minX * w,
                y: -roi.minY * h,
                width: w,
                height: h
            )
            CATransaction.commit()
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
