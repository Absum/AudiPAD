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
        let stripHeight = size.height * 0.07
        let rect = CGRect(x: 0, y: 0, width: size.width, height: stripHeight)
        UIColor.black.withAlphaComponent(0.55).setFill()
        ctx.fill(rect)

        // SQ5 mark on the left — text-only fallback if the asset
        // isn't bundled. Kept small so it doesn't dominate.
        let logoText = "AUDI · SQ5"
        let logoFont = UIFont.systemFont(ofSize: stripHeight * 0.55, weight: .heavy)
        let logoAttrs: [NSAttributedString.Key: Any] = [
            .font: logoFont,
            .foregroundColor: UIColor.white,
            .kern: 2.0,
        ]
        let logoSize = (logoText as NSString).size(withAttributes: logoAttrs)
        (logoText as NSString).draw(
            at: CGPoint(x: stripHeight * 0.5,
                        y: (stripHeight - logoSize.height) / 2),
            withAttributes: logoAttrs
        )

        // Date · clock on the right.
        let clockText = Self.clockFormatter.string(from: state.date)
        let clockFont = UIFont.monospacedDigitSystemFont(ofSize: stripHeight * 0.55, weight: .semibold)
        let clockAttrs: [NSAttributedString.Key: Any] = [
            .font: clockFont,
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
        let stripHeight = size.height * 0.12
        let rect = CGRect(x: 0,
                          y: size.height - stripHeight,
                          width: size.width,
                          height: stripHeight)
        UIColor.black.withAlphaComponent(0.55).setFill()
        ctx.fill(rect)

        let pad = stripHeight * 0.25
        let topPad = stripHeight * 0.18
        let labelFont = UIFont.systemFont(ofSize: stripHeight * 0.16, weight: .heavy)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: UIColor.white.withAlphaComponent(0.7),
            .kern: 1.4,
        ]
        let valueFont = UIFont.monospacedDigitSystemFont(ofSize: stripHeight * 0.42, weight: .semibold)
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: UIColor.white,
        ]

        // Four columns, evenly spaced.
        let colWidth = (size.width - pad * 2) / 4
        let columns: [(String, String)] = [
            ("SPEED",   state.speedKph.map { String(format: "%.0f km/h", $0) } ?? "—"),
            ("ROAD",    Self.roadDisplay(state: state)),
            ("G-FORCE", Self.gforceDisplay(state: state)),
            ("GPS",     Self.gpsDisplay(state: state)),
        ]
        for (i, (label, value)) in columns.enumerated() {
            let x = pad + colWidth * CGFloat(i)
            (label as NSString).draw(
                at: CGPoint(x: x, y: rect.minY + topPad),
                withAttributes: labelAttrs
            )
            (value as NSString).draw(
                at: CGPoint(x: x, y: rect.minY + topPad + labelFont.lineHeight + 2),
                withAttributes: valueAttrs
            )
        }
    }

    // MARK: - Formatters

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd  HH:mm:ss"
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
