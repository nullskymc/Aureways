import AppKit
import SwiftUI

/// Single appearance policy for in-app chrome.
///
/// Minimum system is macOS 26 and the app always follows the system's
/// Liquid Glass look. Window chrome (titlebar, toolbar, sidebar material)
/// is entirely system-native; we only push the user's light/dark choice
/// onto NSWindow so AppKit materials resolve consistently.
/// Do not wrap `NavigationSplitView` in an extra `glassEffect`.
///
/// Large cards use untinted `Glass.regular` as a decorative background
/// (`allowsHitTesting(false)`), never `.interactive()`. Chips use
/// `Glass.regular.interactive()` with optional semantic tint.
enum Chrome {
    static let cardRadius: CGFloat = 14
    static let composerMaxWidth: CGFloat = 780
}

/// 主操作玻璃按钮：整行卡片、品牌色加号、悬停反馈（侧栏新建对话、设置页添加入口）。
struct GlassPrimaryButton: View {
    let title: String
    var systemImage: String = "plus"
    var help: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .liquidGlassCard(cornerRadius: 10)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? Palette.cardHover.opacity(0.45) : .clear)
                .allowsHitTesting(false)
        }
        .onHover { isHovered = $0 }
        .help(help ?? title)
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

    func glassRowHighlight(isSelected: Bool, isHovered: Bool, cornerRadius: CGFloat = 8) -> some View {
        modifier(ChromeRowHighlightModifier(
            isSelected: isSelected,
            isHovered: isHovered,
            cornerRadius: cornerRadius
        ))
    }

    /// Push the user's light/dark preference onto the hosting NSWindow.
    /// AppKit 材质（侧栏、标题栏）不读 SwiftUI 的 preferredColorScheme，
    /// 不在这里设置会出现深浅混色。窗口本身完全交由系统原生渲染。
    func liquidGlassWindow(appearance: ColorScheme? = nil) -> some View {
        modifier(LiquidGlassWindowModifier(appearance: appearance))
    }
}

private struct ChromeCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    var veil: Double

    private var shape: ConcentricRectangle {
        // macOS 27 SDK：concentric(minimum:) 收 Edge.Corner.Style?，
        // 数值圆角要包一层 .fixed(CGFloat)。
        ConcentricRectangle(
            corners: .concentric(minimum: .fixed(cornerRadius)),
            isUniform: true
        )
    }

    func body(content: Content) -> some View {
        content.background {
            // 一层 ink 薄纱垫在玻璃后面，防止亮色壁纸把卡片洗白。
            // 同心圆角：贴近窗口圆角的卡片自动跟随系统曲率，远离处退到 minimum。
            ZStack {
                shape.fill(Palette.ink.opacity(veil))
                Color.clear
                    .glassEffect(.regular, in: shape)
            }
            .allowsHitTesting(false)
        }
    }
}

private struct ChromeCapsuleModifier: ViewModifier {
    var interactive: Bool
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = Capsule()
        content.background {
            ZStack {
                shape.fill(Palette.ink.opacity(0.30))
                Color.clear
                    .glassEffect(glass, in: shape)
            }
            .allowsHitTesting(false)
        }
        .contentShape(shape)
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

/// Makes the hosting `NSWindow` a liquid-glass window.
/// The probe view never participates in hit-testing.
struct LiquidGlassWindowConfigurator: NSViewRepresentable {
    var appearance: ColorScheme?

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.appearanceOverride = appearance
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        nsView.appearanceOverride = appearance
        nsView.apply()
    }
}

final class WindowProbeView: NSView {
    var appearanceOverride: ColorScheme?

    override var intrinsicContentSize: NSSize { .zero }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func apply() {
        let appearance = appearanceOverride
        guard window != nil else { return }
        configure(window, appearance: appearance)
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            self?.configure(window, appearance: appearance)
        }
    }

    private func configure(_ window: NSWindow?, appearance: ColorScheme?) {
        guard let window else { return }
        window.appearance = appearance.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
    }
}

private struct LiquidGlassWindowModifier: ViewModifier {
    var appearance: ColorScheme?

    func body(content: Content) -> some View {
        content
            .background {
                LiquidGlassWindowConfigurator(appearance: appearance)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
    }
}
