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
    /// Orbit Blue `#003DA5` — brand mark, system accent, primary controls.
    static let orbit = Color(red: 0, green: 61 / 255, blue: 165 / 255)
    /// Deep Navy `#002B73` — dark colourway, avatar gradient.
    static let deepNavy = Color(red: 0, green: 43 / 255, blue: 115 / 255)

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

    /// Semantic: thinking / connecting / warning. Not the brand color.
    static let gold = Color.adaptive(
        light: Color(red: 0.72, green: 0.52, blue: 0.18),
        dark: Color(red: 0.85, green: 0.70, blue: 0.40)
    )
    static let accent = Color.adaptive(
        light: orbit,
        dark: Color(red: 0.45, green: 0.62, blue: 0.98)
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

    /// macOS unemphasized list selection — gray, not the brand accent.
    static let selection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)

    /// Background for inspector / sidebar panels (subtle contrast against pure white chat canvas).
    static let inspectorBg = Color.adaptive(
        light: Color(red: 0.955, green: 0.958, blue: 0.965),
        dark: Color(red: 0.12, green: 0.12, blue: 0.13)
    )

    /// Same canvas as `inspectorBg`, for AppKit editor + gutter so they don't band.
    static let editorCanvasNS = NSColor(name: nil) { appearance in
        resolvedEditorCanvas(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    /// SwiftTerm snapshots `NSColor` at assignment time, so the terminal
    /// needs an already-resolved color rather than a dynamic provider.
    static func resolvedEditorCanvas(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
            : NSColor(srgbRed: 0.955, green: 0.958, blue: 0.965, alpha: 1)
    }

    static func resolvedTerminalInk(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1)
            : NSColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 1)
    }

    /// Crisp physical 1px split divider separating workspace columns.
    static let splitDivider = Color.adaptive(
        light: Color(white: 0.0, opacity: 0.12),
        dark: Color(white: 1.0, opacity: 0.14)
    )
}

/// Planar A-orbit mark. Light = blue on transparent, dark = white on transparent.
/// The squircle Dock icon is `AppIconImage`, not this.
struct BrandMark: View {
    var size: CGFloat = 72
    var glow = false

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .background {
                if glow {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Palette.accent.opacity(0.42),
                                    Palette.accent.opacity(0.12),
                                    .clear
                                ],
                                center: .center,
                                startRadius: size * 0.04,
                                endRadius: size * 1.4
                            )
                        )
                        .frame(width: size * 2.8, height: size * 2.8)
                        .blur(radius: 32)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Aureways")
    }
}

/// System-composited app icon (Liquid Glass squircle). Use in Settings / About.
struct AppIconImage: View {
    var size: CGFloat = 64

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
