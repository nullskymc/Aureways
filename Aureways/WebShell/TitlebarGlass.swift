import AppKit

/// Liquid Glass in the title bar row, system standard only (`NSGlassEffectView`
/// with its default style: no tint, no custom material), so it follows the
/// system Clear / Tinted setting and Reduce Transparency by itself.
///
/// - `TitlebarButtons`: the sidebar toggle (one circle next to the traffic
///   lights) and the file tree + inspector toggles (one two-button capsule at
///   the right edge). Fully native and laid out from the window edges, so live
///   resize and sidebar toggles never wait for the page.
/// - `TabCapsuleLayer`: one capsule under each column's tab strip (tabs and
///   its "+"), with the active tab as a brighter inner platter in the glass's
///   content (a system fill, like a selected segment). The page draws
///   the tabs transparently on top and reports each strip's geometry in a
///   resize-invariant form (see `TabCapsule`), coalesced to one message per
///   frame and only when it changes.
enum TitlebarMetrics {
    /// Circle diameter / capsule height for every title bar glass control.
    static let control: CGFloat = 30
    /// Gap between the zoom button and the sidebar circle.
    static let afterLights: CGFloat = 12
    /// Sidebar circle x when the traffic lights are hidden (full screen).
    static let fullscreenLeading: CGFloat = 12
    /// Right capsule distance from the window's right edge.
    static let trailing: CGFloat = 12
    /// Width of one button inside the right capsule.
    static let segment: CGFloat = 32
    /// Inset of the buttons inside the right capsule.
    static let capsulePadding: CGFloat = 2
    /// Space the page keeps clear after the sidebar circle / before the capsule.
    static let clearance: CGFloat = 8

    static var rightCapsuleWidth: CGFloat { segment * 2 + capsulePadding * 2 }

    /// Sidebar circle frame (host coordinates, flipped) for a header row.
    static func sidebarFrame(lights: CGRect, fullscreen: Bool, headerHeight: CGFloat) -> CGRect {
        let x = fullscreen || lights.isEmpty ? fullscreenLeading : lights.maxX + afterLights
        let y = lights.isEmpty || fullscreen ? (headerHeight - control) / 2 : lights.midY - control / 2
        return CGRect(x: x.rounded(), y: y.rounded(), width: control, height: control)
    }

    /// Right capsule frame for a host width.
    static func rightFrame(width: CGFloat, centerY: CGFloat) -> CGRect {
        CGRect(x: (width - trailing - rightCapsuleWidth).rounded(), y: (centerY - control / 2).rounded(),
               width: rightCapsuleWidth, height: control)
    }

    /// Insets the page keeps clear for the native controls (published in `chrome`).
    static func insets(sidebar: CGRect, width: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        (sidebar.maxX + clearance, trailing + rightCapsuleWidth + clearance)
    }
}

/// One column's tab capsule as reported by the page. Columns share the free
/// width in fixed proportions, so a strip's left edge moves linearly with the
/// window width: `x = base + share * width`. Reporting `base`/`share` instead
/// of `x` keeps the report unchanged during live resize; the native layer
/// recomputes `x` in the same layout pass as the window.
struct TabCapsule: Equatable {
    var base: CGFloat
    var share: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    /// Active tab, relative to the capsule's left edge (nil: no active tab here).
    var activeX: CGFloat?
    var activeWidth: CGFloat?

    func frame(hostWidth: CGFloat, scale: CGFloat = 2) -> CGRect {
        let step = max(scale, 1)
        let x = ((base + share * hostWidth) * step).rounded() / step
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Inner (active tab) frame in capsule coordinates, clipped to the capsule.
    func activeFrame(inset: CGFloat = 2) -> CGRect? {
        guard let activeX, let activeWidth, activeWidth > 0 else { return nil }
        let inner = CGRect(x: activeX, y: inset, width: activeWidth, height: height - inset * 2)
        let clipped = inner.intersection(CGRect(x: inset, y: 0, width: max(0, width - inset * 2), height: height))
        return clipped.isNull || clipped.width < 1 ? nil : clipped
    }

    /// Same tabs, possibly elsewhere: what a sidebar toggle changes.
    func sameShape(as other: TabCapsule) -> Bool {
        abs(width - other.width) < 1 && abs((activeWidth ?? 0) - (other.activeWidth ?? 0)) < 1
            && abs((activeX ?? 0) - (other.activeX ?? 0)) < 1 && abs(height - other.height) < 1
    }
}

/// Glass under the page's tab strips (below the transparent `WKWebView`).
@MainActor
final class TabCapsuleLayer: NSView {
    private let container = NSGlassEffectContainerView()
    private let content = PassthroughFlippedView()
    private var capsules: [NSGlassEffectView] = []
    private var inners: [SelectionPlatter] = []
    private(set) var strips: [TabCapsule] = []
    /// Last layout seen with the sidebar open / closed, for native toggles.
    private var remembered: [Bool: [TabCapsule]] = [:]

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        container.frame = bounds
        container.autoresizingMask = [.width, .height]
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.contentView = content
        addSubview(container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A report from the page (`sidebarOpen`: the page's state when measured).
    func apply(_ next: [TabCapsule], sidebarOpen: Bool) {
        remembered[sidebarOpen] = next
        guard next != strips else { return }
        strips = next
        rebuild()
    }

    /// The sidebar is about to toggle natively: jump to the layout last seen in
    /// that state if the tabs are unchanged, without waiting for the page.
    /// The page's next report confirms or corrects it.
    func sidebarWillToggle(to open: Bool) {
        guard let cached = remembered[open], cached.count == strips.count,
              zip(cached, strips).allSatisfy({ $0.sameShape(as: $1) }), cached != strips else { return }
        strips = cached
        rebuild()
    }

    private func rebuild() {
        while capsules.count < strips.count {
            let capsule = NSGlassEffectView()
            let holder = PassthroughFlippedView()
            holder.autoresizingMask = [.width, .height]
            capsule.contentView = holder
            let inner = SelectionPlatter()
            holder.addSubview(inner)
            content.addSubview(capsule)
            capsules.append(capsule)
            inners.append(inner)
        }
        while capsules.count > strips.count {
            capsules.removeLast().removeFromSuperview()
            inners.removeLast()
        }
        relayout()
    }

    private func relayout() {
        let scale = window?.backingScaleFactor ?? 2
        for (index, strip) in strips.enumerated() {
            let capsule = capsules[index]
            let frame = strip.frame(hostWidth: bounds.width, scale: scale)
            if capsule.frame != frame { capsule.frame = frame }
            if let holder = capsule.contentView, holder.frame != capsule.bounds { holder.frame = capsule.bounds }
            let radius = frame.height / 2
            if capsule.cornerRadius != radius { capsule.cornerRadius = radius }
            let inner = inners[index]
            if let active = strip.activeFrame() {
                if inner.frame != active {
                    inner.frame = active
                    inner.layer?.cornerRadius = active.height / 2
                }
                if inner.isHidden { inner.isHidden = false }
            } else if !inner.isHidden {
                inner.isHidden = true
            }
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        // Same pass as the window resize: strips follow without a page report.
        if oldSize.width != bounds.width { relayout() }
    }
}

/// Native glass buttons in the title bar row (topmost; only the buttons take clicks).
@MainActor
final class TitlebarButtons: NSView {
    enum Action { case sidebar, fileTree, inspector }
    var onAction: ((Action) -> Void)?

    private let container = NSGlassEffectContainerView()
    private let content = PassthroughFlippedView()
    let sidebarGlass = NSGlassEffectView()
    let rightGlass = NSGlassEffectView()
    private let sidebarButton: NSButton
    private let fileTreeButton: NSButton
    private let inspectorButton: NSButton

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        sidebarButton = Self.button(symbol: "sidebar.left", label: "切换侧边栏".localized)
        fileTreeButton = Self.button(symbol: "folder", label: "切换文件树".localized)
        inspectorButton = Self.button(symbol: "sidebar.right", label: "切换右侧标签区".localized)
        super.init(frame: frameRect)
        container.frame = bounds
        container.autoresizingMask = [.width, .height]
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.contentView = content
        addSubview(container)

        let side = NSView(frame: CGRect(x: 0, y: 0, width: TitlebarMetrics.control, height: TitlebarMetrics.control))
        sidebarButton.frame = side.bounds
        sidebarButton.autoresizingMask = [.width, .height]
        side.addSubview(sidebarButton)
        sidebarGlass.contentView = side
        sidebarGlass.cornerRadius = TitlebarMetrics.control / 2
        content.addSubview(sidebarGlass)

        let pair = NSView(frame: CGRect(x: 0, y: 0, width: TitlebarMetrics.rightCapsuleWidth, height: TitlebarMetrics.control))
        let pad = TitlebarMetrics.capsulePadding
        fileTreeButton.frame = CGRect(x: pad, y: 0, width: TitlebarMetrics.segment, height: TitlebarMetrics.control)
        inspectorButton.frame = CGRect(x: pad + TitlebarMetrics.segment, y: 0, width: TitlebarMetrics.segment, height: TitlebarMetrics.control)
        pair.addSubview(fileTreeButton)
        pair.addSubview(inspectorButton)
        rightGlass.contentView = pair
        rightGlass.cornerRadius = TitlebarMetrics.control / 2
        rightGlass.autoresizingMask = [.minXMargin]
        rightGlass.isHidden = true
        content.addSubview(rightGlass)

        for button in [sidebarButton, fileTreeButton, inspectorButton] {
            button.target = self
            button.action = #selector(clicked(_:))
        }
        setState(fileTree: false, inspector: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func button(symbol: String, label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.refusesFirstResponder = true
        return button
    }

    @objc private func clicked(_ sender: NSButton) {
        switch sender {
        case sidebarButton: onAction?(.sidebar)
        case fileTreeButton: onAction?(.fileTree)
        default: onAction?(.inspector)
        }
    }

    /// Native geometry from the traffic lights; the right capsule follows the
    /// right edge through its autoresizing mask.
    func layout(lights: CGRect, fullscreen: Bool, headerHeight: CGFloat) {
        let side = TitlebarMetrics.sidebarFrame(lights: lights, fullscreen: fullscreen, headerHeight: headerHeight)
        if sidebarGlass.frame != side { sidebarGlass.frame = side }
        let right = TitlebarMetrics.rightFrame(width: bounds.width, centerY: side.midY)
        if rightGlass.frame != right { rightGlass.frame = right }
    }

    func setRightVisible(_ visible: Bool) {
        if rightGlass.isHidden == visible { rightGlass.isHidden = !visible }
    }

    func setState(fileTree: Bool, inspector: Bool) {
        for (button, on) in [(fileTreeButton, fileTree), (inspectorButton, inspector)] {
            button.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
            button.setAccessibilityValue(on ? "1" : "0")
        }
        sidebarButton.contentTintColor = .secondaryLabelColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let visible = [(sidebarGlass, [sidebarButton]), (rightGlass, [fileTreeButton, inspectorButton])]
        for (glass, buttons) in visible where !glass.isHidden && glass.frame.contains(local) {
            return buttons.first { $0.bounds.contains($0.convert(local, from: self)) }
        }
        return nil
    }
}

/// The selected tab inside a capsule: a system fill (no custom color or
/// material) drawn as glass content, so it adapts to appearance, Clear /
/// Tinted glass and Reduce Transparency with the capsule.
private final class SelectionPlatter: NSView {
    override var wantsUpdateLayer: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        var color = NSColor.tertiarySystemFill.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.tertiarySystemFill.cgColor }
        layer?.backgroundColor = color
        layer?.cornerRadius = bounds.height / 2
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PassthroughFlippedView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
