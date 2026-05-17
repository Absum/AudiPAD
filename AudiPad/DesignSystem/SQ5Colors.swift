import SwiftUI

enum SQ5Colors {
    static let background = Color(hex: 0x000000)
    static let surface = Color(hex: 0x1A1A1C)
    static let surfaceElevated = Color(hex: 0x25252A)
    static let border = Color(hex: 0x2A2A2C)

    static let textPrimary = Color(hex: 0xFFFFFF)
    static let textSecondary = Color(hex: 0xB0B0B5)
    static let textTertiary = Color(hex: 0x6E6E73)

    static let accent = Color(hex: 0xBB0A30)
    static let aluminum = Color(hex: 0xC5C7CC)

    static let success = Color(hex: 0x00C853)
    static let warning = Color(hex: 0xFFA000)
    static let danger = Color(hex: 0xE53935)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
