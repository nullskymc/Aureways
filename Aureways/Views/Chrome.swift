import AppKit
import SwiftUI

/// Single appearance policy for in-app chrome.
///
/// Minimum system is macOS 26. The window is non-opaque so Liquid Glass
/// can sample the desktop, with a `.ultraThinMaterial` window container background.
/// Columns sample that fill via `liquidGlassBackdrop`.
/// Do not wrap `NavigationSplitView` in an extra `glassEffect`.
///
/// Large cards use untinted `Glass.regular` as a decorative background
/// (`allowsHitTesting(false)`), never `.interactive()`. Chips use
/// `Glass.regular.interactive()` with optional semantic tint.
enum Chrome {
    static let cardRadius: CGFloat = 14
    static let composerMaxWidth: CGFloat = 780
}

private struct LiquidGlassKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var liquidGlass: Bool {
        get { self[LiquidGlassKey.self] }
        set { self[LiquidGlassKey.self] = newValue }
    }
}

extension View {
    /// `veil` 抬高玻璃后的 ink 纱：浮在滚动内容上的卡片（输入框）需要更厚
    /// 的一层，否则正文透过玻璃和前景文字叠在一起没法读。
    func liquidGlassCard(cornerRadius: CGFloat = Chrome.cardRadius, veil: Double = 0.30) -> some View {
        modifier(ChromeCardModifier(cornerRadius: cornerRadius, veil: veil))
    }

    /// Capsule glass for composer chips. Interaction stays on the button;
    /// the effect layer does not cover it.
    func liquidGlassCapsule(interactive: Bool = true, tint: Color? = nil) -> some View {
        modifier(ChromeCapsuleModifier(interactive: interactive, tint: tint))
    }

    func liquidGlassBackdrop() -> some View {
        modifier(ChromeBackdropModifier())
    }

    func glassRowHighlight(isSelected: Bool, isHovered: Bool, cornerRadius: CGFloat = 8) -> some View {
        modifier(ChromeRowHighlightModifier(
            isSelected: isSelected,
            isHovered: isHovered,
            cornerRadius: cornerRadius
        ))
    }

    /// Clear window container + NSWindow glass chrome. Call from each scene root.
    /// `appearance` 把用户选择的深浅色同时写到 NSWindow 上，否则侧栏/标题栏等
    /// AppKit 材质仍按系统外观解析，出现深浅混色。
    func liquidGlassWindow(_ enabled: Bool, opaqueFill: Color, appearance: ColorScheme? = nil) -> some View {
        modifier(LiquidGlassWindowModifier(enabled: enabled, opaqueFill: opaqueFill, appearance: appearance))
    }
}

private struct ChromeCardModifier: ViewModifier {
    @Environment(\.liquidGlass) private var enabled
    var cornerRadius: CGFloat
    var veil: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if enabled {
            content.background {
                // 一层 ink 薄纱垫在玻璃后面，防止亮色壁纸把卡片洗白。
                ZStack {
                    shape.fill(Palette.ink.opacity(veil))
                    Color.clear
                        .glassEffect(.regular, in: shape)
                }
                .allowsHitTesting(false)
            }
        } else {
            content.background(shape.fill(Palette.card))
        }
    }
}

private struct ChromeCapsuleModifier: ViewModifier {
    @Environment(\.liquidGlass) private var enabled
    var interactive: Bool
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = Capsule()
        if enabled {
            content.background {
                ZStack {
                    shape.fill(Palette.ink.opacity(0.30))
                    Color.clear
                        .glassEffect(glass, in: shape)
                }
                .allowsHitTesting(false)
            }
            .contentShape(shape)
        } else if let tint {
            content.background(shape.fill(tint.opacity(0.22)))
        } else {
            content.background(shape.fill(Palette.card))
        }
    }

    private var glass: Glass {
        var value = Glass.regular
        if let tint {
            value = value.tint(tint)
        }
        if interactive {
            value = value.interactive()
        }
        return value
    }
}

private struct ChromeBackdropModifier: ViewModifier {
    @Environment(\.liquidGlass) private var enabled

    func body(content: Content) -> some View {
        content.background {
            Group {
                if enabled {
                    Color.clear
                } else {
                    Palette.panel
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private struct ChromeRowHighlightModifier: ViewModifier {
    var isSelected: Bool
    var isHovered: Bool
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.background {
            if isSelected {
                shape.fill(Palette.selection)
            } else if isHovered {
                shape.fill(Palette.selection.opacity(0.55))
            }
        }
    }
}

/// Makes the hosting `NSWindow` a liquid-glass window (or restores opaque chrome).
/// The probe view never participates in hit-testing.
struct LiquidGlassWindowConfigurator: NSViewRepresentable {
    var enabled: Bool
    var appearance: ColorScheme?

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.glassEnabled = enabled
        view.appearanceOverride = appearance
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        nsView.glassEnabled = enabled
        nsView.appearanceOverride = appearance
        nsView.apply()
    }
}

final class WindowProbeView: NSView {
    var glassEnabled = true
    var appearanceOverride: ColorScheme?

    override var intrinsicContentSize: NSSize { .zero }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func apply() {
        let enabled = glassEnabled
        let appearance = appearanceOverride
        guard window != nil else { return }
        configure(window, enabled: enabled, appearance: appearance)
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            self?.configure(window, enabled: enabled, appearance: appearance)
        }
    }

    private func configure(_ window: NSWindow?, enabled: Bool, appearance: ColorScheme?) {
        guard let window else { return }
        window.appearance = appearance.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
        if enabled {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.titlebarAppearsTransparent = false
        }
    }
}

private struct LiquidGlassWindowModifier: ViewModifier {
    var enabled: Bool
    var opaqueFill: Color
    var appearance: ColorScheme?

    func body(content: Content) -> some View {
        content
            .containerBackground(for: .window) {
                if enabled {
                    Color.clear
                        .background(.ultraThinMaterial)
                        // 半透明 ink 压住壁纸亮斑，保证前景文字对比度。
                        .overlay(opaqueFill.opacity(0.45))
                } else {
                    opaqueFill
                }
            }
            .background {
                LiquidGlassWindowConfigurator(enabled: enabled, appearance: appearance)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
    }
}
