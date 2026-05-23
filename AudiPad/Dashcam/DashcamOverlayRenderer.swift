import Foundation
import UIKit
import CoreLocation

/// Renders the per-frame overlay that gets burned into dashcam
/// recordings. State snapshot in → cached CGImage out. The image
/// is re-rendered on a coarse cadence (every ~250 ms or when state
/// changes meaningfully) and reused across all frames in between,
/// so per-frame composite is just a single CISourceOverCompositing
/// blit — cheap enough for 30 fps on the A9X.
///
/// Layout:
///   Top strip (height ~h*0.07): SQ5 logo (left) + date · clock (right)
///   Bottom strip (height ~h*0.12):
///     Speed (large, left)
///     Road name + ref (middle-left)
///     G-force magnitude (middle-right)
///     GPS lat/lon (right)
///   Both strips have a dark-translucent background for legibility
///   against any road scene (snow, asphalt, foliage).
final class DashcamOverlayRenderer {

    /// Snapshot of every field the overlay can show. Built on the
    /// MainActor from the observed services; passed into render()
    /// from any thread.
    struct State: Equatable {
        let date: Date
        let speedKph: Double?
        let roadName: String?
        let roadRef: String?
        let lateralG: Double?
        let longitudinalG: Double?
        let coordinate: CLLocationCoordinate2D?

        static let empty = State(date: Date(), speedKph: nil, roadName: nil,
                                 roadRef: nil, lateralG: nil,
                                 longitudinalG: nil, coordinate: nil)

        static func == (lhs: State, rhs: State) -> Bool {
            lhs.date == rhs.date &&
            lhs.speedKph == rhs.speedKph &&
            lhs.roadName == rhs.roadName &&
            lhs.roadRef == rhs.roadRef &&
            lhs.lateralG == rhs.lateralG &&
            lhs.longitudinalG == rhs.longitudinalG &&
            lhs.coordinate?.latitude == rhs.coordinate?.latitude &&
            lhs.coordinate?.longitude == rhs.coordinate?.longitude
        }
    }

    private let size: CGSize
    private var cache: (state: State, image: CGImage)?

    /// Render at the same resolution as the video frame so the
    /// overlay never gets upscaled (would smear text). Pass the
    /// actual frame dimensions discovered from the first sample
    /// buffer.
    init(size: CGSize) {
        self.size = size
    }

    /// Cached render: returns the same CGImage when state hasn't
    /// changed (frame timestamp clamped to a 250 ms quantum so the
    /// clock seconds don't churn the cache). Cheap on cache hit.
    func image(for state: State) -> CGImage? {
        let quantized = State(
            date: Self.quantize(state.date, to: 1.0),
            speedKph: state.speedKph,
            roadName: state.roadName,
            roadRef: state.roadRef,
            lateralG: state.lateralG,
            longitudinalG: state.longitudinalG,
            coordinate: state.coordinate
        )
        if let cache, cache.state == quantized { return cache.image }
        let img = render(state: quantized)
        if let img { cache = (quantized, img) }
        return img
    }

    // MARK: - Render

    private func render(state: State) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let uiImage = renderer.image { ctx in
            let cg = ctx.cgContext
            drawTopStrip(in: cg, state: state)
            drawBottomStrip(in: cg, state: state)
        }
        return uiImage.cgImage
    }

    private func drawTopStrip(in ctx: CGContext, state: State) {
        // Title-row font size derived from frame height — kept
        // small so the overlay reads as an info strip, not chrome
        // that competes with the road footage.
        let titleFont = UIFont.systemFont(ofSize: size.height * 0.025, weight: .semibold)
        let stripHeight = titleFont.lineHeight + size.height * 0.012
        let rect = CGRect(x: 0, y: 0, width: size.width, height: stripHeight)
        UIColor.black.withAlphaComponent(0.55).setFill()
        ctx.fill(rect)

        // Wordmark on the left — no separator dot (user feedback).
        let logoText = "AUDI SQ5"
        let logoAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: titleFont.pointSize, weight: .heavy),
            .foregroundColor: UIColor.white,
            .kern: 1.2,
        ]
        let logoSize = (logoText as NSString).size(withAttributes: logoAttrs)
        (logoText as NSString).draw(
            at: CGPoint(x: stripHeight * 0.5,
                        y: (stripHeight - logoSize.height) / 2),
            withAttributes: logoAttrs
        )

        // Finnish date + clock on the right (d.M.yyyy HH:mm:ss).
        let clockText = Self.clockFormatter.string(from: state.date)
        let clockAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: titleFont.pointSize, weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        let clockSize = (clockText as NSString).size(withAttributes: clockAttrs)
        (clockText as NSString).draw(
            at: CGPoint(x: size.width - clockSize.width - stripHeight * 0.5,
                        y: (stripHeight - clockSize.height) / 2),
            withAttributes: clockAttrs
        )
    }

    private func drawBottomStrip(in ctx: CGContext, state: State) {
        // Bottom-row font ≈ 2/3 of the top-row title (user feedback).
        let bodyFontSize = size.height * 0.017
        let bodyFont = UIFont.systemFont(ofSize: bodyFontSize, weight: .semibold)
        let stripHeight = bodyFont.lineHeight + size.height * 0.010
        let rect = CGRect(x: 0,
                          y: size.height - stripHeight,
                          width: size.width,
                          height: stripHeight)
        UIColor.black.withAlphaComponent(0.55).setFill()
        ctx.fill(rect)

        // Build the inline NSAttributedString:
        // "SPEED " (muted) "87 km/h" (white) "  ·  " (muted) …
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: bodyFontSize, weight: .heavy),
            .foregroundColor: UIColor.white.withAlphaComponent(0.6),
            .kern: 1.2,
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: bodyFontSize, weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        let separatorAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: UIColor.white.withAlphaComponent(0.35),
        ]

        let columns: [(String, String)] = [
            ("SPEED",   state.speedKph.map { String(format: "%.0f km/h", $0) } ?? "—"),
            ("ROAD",    Self.roadDisplay(state: state)),
            ("G-FORCE", Self.gforceDisplay(state: state)),
            ("GPS",     Self.gpsDisplay(state: state)),
        ]
        let line = NSMutableAttributedString()
        for (i, (label, value)) in columns.enumerated() {
            if i > 0 {
                line.append(NSAttributedString(string: "   ·   ", attributes: separatorAttrs))
            }
            line.append(NSAttributedString(string: "\(label) ", attributes: labelAttrs))
            line.append(NSAttributedString(string: value, attributes: valueAttrs))
        }
        let lineSize = line.size()
        line.draw(at: CGPoint(
            x: stripHeight * 0.5,
            y: rect.minY + (stripHeight - lineSize.height) / 2
        ))
    }

    // MARK: - Formatters

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fi_FI")
        f.dateFormat = "d.M.yyyy HH:mm:ss"
        return f
    }()

    private static func roadDisplay(state: State) -> String {
        if let name = state.roadName, !name.isEmpty {
            if let ref = state.roadRef, !ref.isEmpty {
                return "\(name) (\(ref))"
            }
            return name
        }
        if let ref = state.roadRef, !ref.isEmpty { return ref }
        return "—"
    }

    private static func gforceDisplay(state: State) -> String {
        guard let lat = state.lateralG, let lon = state.longitudinalG else { return "—" }
        let mag = sqrt(lat * lat + lon * lon)
        return String(format: "%.2f g", mag)
    }

    private static func gpsDisplay(state: State) -> String {
        guard let c = state.coordinate else { return "—" }
        return String(format: "%.4f, %.4f", c.latitude, c.longitude)
    }

    /// Quantize date to the given seconds-quantum so the cache hits
    /// for the duration of one quantum (clock seconds change only
    /// at second boundaries).
    private static func quantize(_ date: Date, to seconds: TimeInterval) -> Date {
        let t = floor(date.timeIntervalSince1970 / seconds) * seconds
        return Date(timeIntervalSince1970: t)
    }
}
