import AppKit
import SwiftUI

extension Color {
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? NSColor(dark) : NSColor(light)
        }))
    }
}

enum Palette {
    static let ink = Color.adaptive(
        light: Color(red: 0.98, green: 0.98, blue: 0.99),
        dark: Color(red: 0.09, green: 0.09, blue: 0.10)
    )
    static let cardHover = Color.adaptive(
        light: Color(red: 0.92, green: 0.92, blue: 0.95),
        dark: Color(red: 0.22, green: 0.22, blue: 0.25)
    )
    static let border = Color.adaptive(
        light: Color(white: 0.0, opacity: 0.09),
        dark: Color(white: 1.0, opacity: 0.12)
    )

    static let gold = Color.adaptive(
        light: Color(red: 0.72, green: 0.52, blue: 0.18),
        dark: Color(red: 0.85, green: 0.70, blue: 0.40)
    )
    static let accent = Color.adaptive(
        light: Color(red: 0.75, green: 0.55, blue: 0.20),
        dark: Color(red: 0.90, green: 0.75, blue: 0.45)
    )
    static let moss = Color.adaptive(
        light: Color(red: 0.10, green: 0.60, blue: 0.35),
        dark: Color(red: 0.35, green: 0.78, blue: 0.55)
    )
    static let sky = Color.adaptive(
        light: Color(red: 0.15, green: 0.45, blue: 0.85),
        dark: Color(red: 0.40, green: 0.65, blue: 0.95)
    )
    static let badgeBg = Color.adaptive(
        light: Color(white: 0.0, opacity: 0.06),
        dark: Color(white: 1.0, opacity: 0.08)
    )

    /// macOS unemphasized list selection — gray, not the gold brand accent.
    static let selection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
}
