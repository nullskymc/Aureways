import AppKit

/// Liquid Glass in the title bar row, system standard only (`NSGlassEffectView`
/// with its default style: no tint, no custom material), so it follows the
/// system Clear / Tinted setting and Reduce Transparency by itself.
///
/// - `TitlebarButtons`: the sidebar toggle (one circle next to the traffic
///   lights) and, with the sidebar closed, New chat (a second circle in the
///   same group); the new-tab "+" (a circle) and the file tree + inspector
///   toggles (one two-button capsule at the right edge). Fully native and laid
///   out from the window edges, so live resize and sidebar toggles never wait
///   for the page.
/// - `TabCapsuleLayer`: one slim strip under each workbench column's tabs,
///   Safari style: full column width, equal-width tabs, the active tab as a
///   subtle platter in the glass's content (a system fill), plus the column's
///   Split right circle just after the strip. The page draws the tabs (and a
///   transparent Split right hit target) on top and reports each strip's
///   geometry in a resize-invariant form (see `TabCapsule`), coalesced to one
///   message per frame and only when it changes.
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
    /// Gap between the "+" circle and the toggle capsule (one glass group).
    static let groupGap: CGFloat = 8

    static var rightCapsuleWidth: CGFloat { segment * 2 + capsulePadding * 2 }

    /// Sidebar circle frame (host coordinates, flipped) for a header row.
    static func sidebarFrame(lights: CGRect, fullscreen: Bool, headerHeight: CGFloat) -> CGRect {
        let x = fullscreen || lights.isEmpty ? fullscreenLeading : lights.maxX + afterLights
        let y = lights.isEmpty || fullscreen ? (headerHeight - control) / 2 : lights.midY - control / 2
        return CGRect(x: x.rounded(), y: y.rounded(), width: control, height: control)
    }

    /// New chat circle: right after the sidebar circle, in the same glass group.
    static func newChatFrame(sidebar: CGRect) -> CGRect {
        sidebar.offsetBy(dx: control + groupGap, dy: 0)
    }

    /// Right group frame for a host width: the two-button capsule, or (`compact`,
    /// workbench closed) a single circle holding just the inspector toggle.
    static func rightFrame(width: CGFloat, centerY: CGFloat, compact: Bool = false) -> CGRect {
        let w = compact ? control : rightCapsuleWidth
        return CGRect(x: (width - trailing - w).rounded(), y: (centerY - control / 2).rounded(), width: w, height: control)
    }

    /// Buttons inside the right group: [pad | file tree | inspector | pad], or
    /// (`compact`) the inspector toggle centred in one circle.
    static func rightButtonFrames(width: CGFloat, compact: Bool) -> (fileTree: CGRect, inspector: CGRect) {
        let inspectorX = compact ? width - control + (control - segment) / 2 : width - capsulePadding - segment
        return (CGRect(x: inspectorX - segment, y: 0, width: segment, height: control),
                CGRect(x: inspectorX, y: 0, width: segment, height: control))
    }

    /// "+" circle: left of the toggle capsule, or at the right edge when the
    /// capsule is hidden (Documents).
    static func addFrame(width: CGFloat, centerY: CGFloat, besideToggles: Bool) -> CGRect {
        let right = besideToggles ? width - trailing - rightCapsuleWidth - groupGap : width - trailing
        return CGRect(x: (right - control).rounded(), y: (centerY - control / 2).rounded(), width: control, height: control)
    }

    /// Insets the page keeps clear for the native controls (published in `chrome`):
    /// `leading` after the sidebar circle, `newChat` after the New chat circle
    /// (sidebar closed), `trailing` with the toggles and "+", `addOnly` with one
    /// circle at the edge (just "+" in Documents, or just the inspector toggle
    /// with the workbench closed).
    static func insets(sidebar: CGRect, width: CGFloat) -> (leading: CGFloat, newChat: CGFloat, trailing: CGFloat, addOnly: CGFloat) {
        (sidebar.maxX + clearance, newChatFrame(sidebar: sidebar).maxX + clearance,
         trailing + rightCapsuleWidth + groupGap + control + clearance, trailing + control + clearance)
    }
}

/// One workbench column's tab strip as reported by the page. Columns share
/// the free width in fixed proportions, so a strip's left edge and its width
/// both move linearly with the window width: `x = base + share * width`,
/// `w = widthBase + widthShare * width`. Reporting those instead of pixels
/// keeps the report unchanged during live resize; the native layer
/// recomputes the frame in the same layout pass as the window.
///
/// The active tab is reported as `activeIndex` of `count` equal-width tabs
/// while they all fit (Safari style, so it also follows resize natively), or
/// as a pixel offset once the strip scrolls.
struct TabCapsule: Equatable {
    var base: CGFloat
    var share: CGFloat
    var y: CGFloat
    var widthBase: CGFloat
    var widthShare: CGFloat = 0
    var height: CGFloat
    var activeIndex: Int?
    var count: Int?
    /// Scrolled strip: active tab relative to the strip's left edge.
    var activeX: CGFloat?
    var activeWidth: CGFloat?
    /// The column's Split right circle after the strip.
    var split: Split?

    /// Split right circle: `offset` from the strip's right edge to the circle,
    /// `size` its diameter (vertically centred on the strip). Fixed page
    /// metrics, so it follows the strip through live resize natively.
    struct Split: Equatable {
        var offset: CGFloat
        var size: CGFloat
        var enabled: Bool
    }

    /// Inset of the tabs inside the strip (the page's strip padding).
    static let padding: CGFloat = 2

    func width(hostWidth: CGFloat) -> CGFloat { max(0, widthBase + widthShare * hostWidth) }

    func frame(hostWidth: CGFloat, scale: CGFloat = 2) -> CGRect {
        let step = max(scale, 1)
        let x = ((base + share * hostWidth) * step).rounded() / step
        let w = (width(hostWidth: hostWidth) * step).rounded() / step
        return CGRect(x: x, y: y, width: w, height: height)
    }

    /// Active tab platter in strip coordinates, clipped to the strip.
    /// Split right circle in host coordinates.
    func splitFrame(hostWidth: CGFloat, scale: CGFloat = 2) -> CGRect? {
        guard let split, split.size > 0 else { return nil }
        let strip = frame(hostWidth: hostWidth, scale: scale)
        return CGRect(x: strip.maxX + split.offset, y: (y + (height - split.size) / 2).rounded(), width: split.size, height: split.size)
    }

    func activeFrame(hostWidth: CGFloat, inset: CGFloat = TabCapsule.padding) -> CGRect? {
        let width = width(hostWidth: hostWidth)
        let inner: CGRect
        if let activeIndex, let count, count > 1, activeIndex >= 0, activeIndex < count {
            let tab = (width - Self.padding * 2) / CGFloat(count)
            inner = CGRect(x: Self.padding + CGFloat(activeIndex) * tab, y: inset, width: tab, height: height - inset * 2)
        } else if let activeX, let activeWidth, activeWidth > 0 {
            inner = CGRect(x: activeX, y: inset, width: activeWidth, height: height - inset * 2)
        } else {
            return nil
        }
        let clipped = inner.intersection(CGRect(x: Self.padding, y: 0, width: max(0, width - Self.padding * 2), height: height))
        return clipped.isNull || clipped.width < 1 ? nil : clipped
    }

    /// Same tabs, possibly elsewhere or wider: what a sidebar toggle changes.
    func sameShape(as other: TabCapsule) -> Bool {
        activeIndex == other.activeIndex && count == other.count && split == other.split && abs(height - other.height) < 1
            && abs((activeX ?? 0) - (other.activeX ?? 0)) < 1 && abs((activeWidth ?? 0) - (other.activeWidth ?? 0)) < 1
    }
}

/// Glass under the page's workbench tab strips (below the transparent `WKWebView`).
@MainActor
final class TabCapsuleLayer: NSView {
    private let container = NSGlassEffectContainerView()
    private let content = PassthroughFlippedView()
    private var capsules: [NSGlassEffectView] = []
    private var inners: [SelectionPlatter] = []
    /// Split right circles (the page's button on top is a transparent hit target).
    private var splits: [NSGlassEffectView] = []
    private var splitIcons: [NSImageView] = []
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

            let split = NSGlassEffectView()
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
            icon.imageScaling = .scaleNone
            icon.autoresizingMask = [.width, .height]
            // The page's button carries the label, tooltip and click.
            icon.setAccessibilityElement(false)
            split.contentView = icon
            split.isHidden = true
            content.addSubview(split)
            splits.append(split)
            splitIcons.append(icon)
        }
        while capsules.count > strips.count {
            capsules.removeLast().removeFromSuperview()
            inners.removeLast()
            splits.removeLast().removeFromSuperview()
            splitIcons.removeLast()
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
            if let active = strip.activeFrame(hostWidth: bounds.width) {
                if inner.frame != active {
                    inner.frame = active
                    inner.layer?.cornerRadius = active.height / 2
                }
                if inner.isHidden { inner.isHidden = false }
            } else if !inner.isHidden {
                inner.isHidden = true
            }
            let split = splits[index]
            if let circle = strip.splitFrame(hostWidth: bounds.width, scale: scale), let info = strip.split {
                if split.frame != circle { split.frame = circle }
                if split.cornerRadius != circle.height / 2 { split.cornerRadius = circle.height / 2 }
                let iconFrame = CGRect(origin: .zero, size: circle.size)
                if splitIcons[index].frame != iconFrame { splitIcons[index].frame = iconFrame }
                let tint: NSColor = info.enabled ? .secondaryLabelColor : .tertiaryLabelColor
                if splitIcons[index].contentTintColor != tint { splitIcons[index].contentTintColor = tint }
                if split.isHidden { split.isHidden = false }
            } else if !split.isHidden {
                split.isHidden = true
            }
        }
    }

    /// Visible Split right circles, per strip (tests).
    var splitFrames: [CGRect?] { splits.prefix(strips.count).map { $0.isHidden ? nil : $0.frame } }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        // Same pass as the window resize: strips follow without a page report.
        if oldSize.width != bounds.width { relayout() }
    }
}

/// Native glass buttons in the title bar row (topmost; only the buttons take clicks).
@MainActor
final class TitlebarButtons: NSView {
    enum Action { case sidebar, newChat, addTab, fileTree, inspector }
    var onAction: ((Action) -> Void)?

    private let container = NSGlassEffectContainerView()
    private let content = PassthroughFlippedView()
    let sidebarGlass = NSGlassEffectView()
    let newChatGlass = NSGlassEffectView()
    let rightGlass = NSGlassEffectView()
    let addGlass = NSGlassEffectView()
    private let sidebarButton: NSButton
    private let newChatButton: NSButton
    private let addButton: NSButton
    private let fileTreeButton: NSButton
    private let inspectorButton: NSButton

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        sidebarButton = Self.button(symbol: "sidebar.left", label: "切换侧边栏".localized)
        newChatButton = Self.button(symbol: "square.and.pencil", label: "新对话".localized)
        addButton = Self.button(symbol: "plus", label: "新建标签页".localized)
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

        let compose = NSView(frame: side.bounds)
        newChatButton.frame = compose.bounds
        newChatButton.autoresizingMask = [.width, .height]
        compose.addSubview(newChatButton)
        newChatGlass.contentView = compose
        newChatGlass.cornerRadius = TitlebarMetrics.control / 2
        newChatGlass.isHidden = true
        // Below the sidebar circle: it slides out from under it.
        content.addSubview(newChatGlass, positioned: .below, relativeTo: sidebarGlass)

        let pair = NSView(frame: CGRect(x: 0, y: 0, width: TitlebarMetrics.rightCapsuleWidth, height: TitlebarMetrics.control))
        pair.autoresizingMask = [.width, .height]
        // Pinned to the capsule's right edge, so collapsing to one circle keeps
        // the inspector toggle in place while the file tree button fades out.
        fileTreeButton.autoresizingMask = [.minXMargin]
        inspectorButton.autoresizingMask = [.minXMargin]
        Self.placeRightButtons(fileTree: fileTreeButton, inspector: inspectorButton, in: pair.bounds.width, compact: false)
        pair.addSubview(fileTreeButton)
        pair.addSubview(inspectorButton)
        rightGlass.contentView = pair
        rightGlass.cornerRadius = TitlebarMetrics.control / 2
        rightGlass.autoresizingMask = [.minXMargin]
        rightGlass.isHidden = true
        content.addSubview(rightGlass)

        let plus = NSView(frame: CGRect(x: 0, y: 0, width: TitlebarMetrics.control, height: TitlebarMetrics.control))
        addButton.frame = plus.bounds
        addButton.autoresizingMask = [.width, .height]
        plus.addSubview(addButton)
        addGlass.contentView = plus
        addGlass.cornerRadius = TitlebarMetrics.control / 2
        addGlass.autoresizingMask = [.minXMargin]
        addGlass.isHidden = true
        content.addSubview(addGlass)

        for button in [sidebarButton, newChatButton, addButton, fileTreeButton, inspectorButton] {
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
        case newChatButton: onAction?(.newChat)
        case addButton: onAction?(.addTab)
        case fileTreeButton: onAction?(.fileTree)
        default: onAction?(.inspector)
        }
    }

    private static func placeRightButtons(fileTree: NSButton, inspector: NSButton, in width: CGFloat, compact: Bool) {
        let frames = TitlebarMetrics.rightButtonFrames(width: width, compact: compact)
        if fileTree.frame != frames.fileTree { fileTree.frame = frames.fileTree }
        if inspector.frame != frames.inspector { inspector.frame = frames.inspector }
    }

    /// Workbench closed: the right group is one circle (inspector toggle only)
    /// and "+" / file tree have nothing to act on, so they are hidden.
    private(set) var compact = false
    private var addShown = false

    /// Native geometry from the traffic lights; the right group follows the
    /// right edge through its autoresizing mask.
    func layout(lights: CGRect, fullscreen: Bool, headerHeight: CGFloat) {
        let side = TitlebarMetrics.sidebarFrame(lights: lights, fullscreen: fullscreen, headerHeight: headerHeight)
        if sidebarGlass.frame != side { sidebarGlass.frame = side }
        placeNewChat()
        placeRight()
    }

    private var newChatShown = false

    /// Shown, New chat sits right of the sidebar circle; hidden, under it.
    private func placeNewChat() {
        let frame = newChatShown ? TitlebarMetrics.newChatFrame(sidebar: sidebarGlass.frame) : sidebarGlass.frame
        if newChatGlass.frame != frame { newChatGlass.frame = frame }
    }

    /// New chat shows while the sidebar (with its own New chat row) is closed.
    /// It slides out from under the sidebar circle natively.
    func setNewChatVisible(_ visible: Bool) {
        guard visible != newChatShown else { return }
        newChatShown = visible
        let animate = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if visible, newChatGlass.isHidden {
            newChatGlass.frame = sidebarGlass.frame
            newChatGlass.alphaValue = animate ? 0 : 1
            newChatGlass.isHidden = false
        }
        guard animate else {
            newChatGlass.alphaValue = 1
            settleNewChat()
            return
        }
        let target = visible ? TitlebarMetrics.newChatFrame(sidebar: sidebarGlass.frame) : sidebarGlass.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            newChatGlass.animator().frame = target
            newChatGlass.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.settleNewChat() }
        })
    }

    private func settleNewChat() {
        placeNewChat()
        if !newChatShown { newChatGlass.isHidden = true }
    }

    var isNewChatVisible: Bool { !newChatGlass.isHidden }
    var newChatFrame: CGRect { newChatGlass.frame }

    private func placeRight() {
        let midY = sidebarGlass.frame.midY
        let right = TitlebarMetrics.rightFrame(width: bounds.width, centerY: midY, compact: compact)
        if rightGlass.frame != right { rightGlass.frame = right }
        if let pair = rightGlass.contentView, pair.frame != rightGlass.bounds { pair.frame = rightGlass.bounds }
        Self.placeRightButtons(fileTree: fileTreeButton, inspector: inspectorButton, in: right.width, compact: compact)
        let plus = TitlebarMetrics.addFrame(width: bounds.width, centerY: midY, besideToggles: !rightGlass.isHidden && !compact)
        if addGlass.frame != plus { addGlass.frame = plus }
    }

    /// Page state (only sent when it changes). `compact`: the workbench is
    /// closed. The change animates natively; nothing is sent per frame.
    func setRightVisible(_ visible: Bool, add: Bool, compact nextCompact: Bool = false) {
        let wasShown = !rightGlass.isHidden
        if rightGlass.isHidden == visible { rightGlass.isHidden = !visible }
        let animate = window != nil && wasShown && visible && (nextCompact != compact || add != addShown)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        compact = nextCompact
        addShown = add
        if add, addGlass.isHidden { addGlass.alphaValue = animate ? 0 : 1; addGlass.isHidden = false }
        if !compact, fileTreeButton.isHidden { fileTreeButton.alphaValue = animate ? 0 : 1; fileTreeButton.isHidden = false }
        guard animate else {
            addGlass.alphaValue = 1
            fileTreeButton.alphaValue = 1
            settleRight()
            return
        }
        let midY = sidebarGlass.frame.midY
        let right = TitlebarMetrics.rightFrame(width: bounds.width, centerY: midY, compact: compact)
        let buttons = TitlebarMetrics.rightButtonFrames(width: right.width, compact: compact)
        let plus = TitlebarMetrics.addFrame(width: bounds.width, centerY: midY, besideToggles: !compact)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            rightGlass.animator().frame = right
            rightGlass.contentView?.animator().frame = CGRect(origin: .zero, size: right.size)
            inspectorButton.animator().frame = buttons.inspector
            fileTreeButton.animator().frame = buttons.fileTree
            fileTreeButton.animator().alphaValue = compact ? 0 : 1
            addGlass.animator().frame = plus
            addGlass.animator().alphaValue = add ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.settleRight() }
        })
    }

    /// Final state after a change (also after an animation; a newer state wins).
    private func settleRight() {
        placeRight()
        if !addShown { addGlass.isHidden = true }
        if compact { fileTreeButton.isHidden = true }
    }

    var isAddVisible: Bool { !addGlass.isHidden }
    var isFileTreeVisible: Bool { !rightGlass.isHidden && !fileTreeButton.isHidden }

    /// Where the "+" menu opens (host coordinates).
    var addButtonFrame: CGRect { addGlass.frame }

    func setState(fileTree: Bool, inspector: Bool) {
        for (button, on) in [(fileTreeButton, fileTree), (inspectorButton, inspector)] {
            button.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
            button.setAccessibilityValue(on ? "1" : "0")
        }
        sidebarButton.contentTintColor = .secondaryLabelColor
        newChatButton.contentTintColor = .secondaryLabelColor
        addButton.contentTintColor = .secondaryLabelColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let visible = [(sidebarGlass, [sidebarButton]), (newChatGlass, [newChatButton]), (addGlass, [addButton]), (rightGlass, [fileTreeButton, inspectorButton])]
        for (glass, buttons) in visible where !glass.isHidden && glass.alphaValue > 0.5 && glass.frame.contains(local) {
            return buttons.first { !$0.isHidden && $0.alphaValue > 0.5 && $0.bounds.contains($0.convert(local, from: self)) }
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
