import AppKit
import SwiftUI

/// 菜单栏 Extra 的系统模板图标。尺寸锁在 16 pt，避免被状态栏按钮拉扁。
struct MenuBarExtraLabel: View {
    var body: some View {
        Image(nsImage: Self.templateImage)
            .renderingMode(.template)
            .accessibilityLabel("Aureways")
    }

    private static let templateImage: NSImage = {
        let canvas = NSImage(size: NSSize(width: 16, height: 16))
        canvas.isTemplate = true
        if let named = NSImage(named: "MenuBarIcon") {
            named.isTemplate = true
            canvas.lockFocus()
            named.draw(
                in: NSRect(x: 0, y: 0, width: 16, height: 16),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            canvas.unlockFocus()
        }
        return canvas
    }()
}

private enum StatusMenuFocus {
    static let overview = "overview"

    static func shortTitle(_ agent: AgentProfile) -> String {
        switch agent.id {
        case GrokBuildHarness.id: return "Grok"
        case CopilotHarness.id: return "Copilot"
        case ClaudeCodeHarness.id: return "Claude"
        case OhMyPiHarness.id: return "Pi"
        case CursorHarness.id: return "Cursor"
        default:
            return agent.title.split(separator: " ").first.map(String.init) ?? agent.title
        }
    }
}

private enum StatusMenuType {
    static let title = Font.system(size: 12, weight: .semibold)
    static let body = Font.system(size: 11)
    static let bodyMedium = Font.system(size: 11, weight: .medium)
    static let meta = Font.system(size: 10)
    static let metaMedium = Font.system(size: 10, weight: .medium)
    static let tab = Font.system(size: 10, weight: .medium)
    static let number = Font.system(size: 11, weight: .semibold, design: .rounded)
}

private enum StatusMenuLayout {
    static let width: CGFloat = 268
    static let tabInset: CGFloat = 4
    static let tabSpacing: CGFloat = 2
    static let tabCornerRadius: CGFloat = 8
    static let tabVerticalPadding: CGFloat = 8
    static let visibleSlots = 5
    static var tabWidth: CGFloat {
        let inner = width - tabInset * 2
        return (inner - tabSpacing * CGFloat(visibleSlots - 1)) / CGFloat(visibleSlots)
    }
}

/// 菜单栏 Extra 里 `Button` 套在横向 `ScrollView` 中会先等系统区分点击和拖拽，
/// 命中区又只包住图标文字，切换会发飘。这里整格可点，位移很小才当点击。
private struct StatusMenuTapStyle: PrimitiveButtonStyle {
    var slop: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        if hypot(value.translation.width, value.translation.height) < slop {
                            configuration.trigger()
                        }
                    }
            )
    }
}

private struct StatusMenuHoverChrome: ViewModifier {
    var isSelected: Bool
    var selectedFill: Color
    var cornerRadius: CGFloat
    var showsPointer: Bool = true
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .contentShape(shape)
            .background {
                shape
                    .fill(fill)
                    .shadow(
                        color: .black.opacity(isHovered ? 0.22 : 0),
                        radius: isHovered ? 8 : 0,
                        y: isHovered ? 2 : 0
                    )
                    .allowsHitTesting(false)
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
                guard showsPointer else { return }
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .onDisappear {
                if isHovered { NSCursor.arrow.set() }
            }
    }

    private var fill: Color {
        if isSelected { return selectedFill }
        if isHovered { return Color.primary.opacity(0.08) }
        return .clear
    }
}

private struct StatusMenuMark: View {
    let agentId: String

    var body: some View {
        HarnessIcon(agentId: agentId)
    }
}

private struct StatusMenuQuotaBlock: View {
    let snapshot: HarnessQuotaSnapshot
    var isRefreshing = false
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let plan = snapshot.planType, !plan.isEmpty {
                HStack(spacing: 6) {
                    Text(plan)
                        .font(StatusMenuType.metaMedium)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Palette.badgeBg, in: Capsule())
                    if let email = snapshot.accountEmail, !email.isEmpty {
                        Text(email)
                            .font(StatusMenuType.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            } else if let email = snapshot.accountEmail, !email.isEmpty {
                Text(email)
                    .font(StatusMenuType.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let primary = snapshot.primaryWindow {
                windowRow(primary)
            }
            if let secondary = snapshot.secondaryWindow {
                windowRow(secondary)
            }
            ForEach(snapshot.extraWindows.prefix(3)) { extra in
                windowRow(extra)
            }

            if snapshot.creditsRemaining != nil || (snapshot.resetCreditsAvailable ?? 0) > 0 {
                if let credits = snapshot.creditsRemaining {
                    HStack {
                        Text("剩余点数")
                            .font(StatusMenuType.meta)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(String(format: "%.2f", credits)) \(snapshot.creditsUnit ?? "")")
                            .font(StatusMenuType.bodyMedium)
                    }
                }
                if let resets = snapshot.resetCreditsAvailable, resets > 0 {
                    HStack {
                        Text("免费重置")
                            .font(StatusMenuType.meta)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(resets) 次")
                            .font(StatusMenuType.bodyMedium)
                            .foregroundStyle(Palette.moss)
                    }
                }
            }

            HStack {
                Text(updatedLabel)
                    .font(StatusMenuType.meta)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onRefresh) {
                    if isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("刷新")
                            .font(StatusMenuType.meta)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
            }
        }
    }

    private func windowRow(_ window: HarnessQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.title)
                    .font(StatusMenuType.body)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(round(window.remainingPercent)))%")
                    .font(StatusMenuType.number)
                    .foregroundStyle(barColor(window.remainingPercent / 100))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(barColor(window.remainingPercent / 100))
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, window.remainingPercent / 100))))
                    }
            }
            .frame(height: 3)
            if let countdown = window.countdownDescription {
                Text(countdown)
                    .font(StatusMenuType.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func barColor(_ remaining: Double) -> Color {
        if remaining <= 0.05 { return .red }
        if remaining <= 0.20 { return .orange }
        return Palette.moss
    }

    private var updatedLabel: String {
        let interval = Date().timeIntervalSince(snapshot.updatedAt)
        if interval < 60 { return "刚刚更新" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前更新" }
        return "\(Int(interval / 3600)) 小时前更新"
    }
}

/// 右侧菜单栏点开后的面板。玻璃由 `MenuBarExtra` 的 `.window` 样式提供。
/// 顶部是「概览 + 各 harness」横向 Tab，配额条画在图标下面。
struct StatusMenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var focusedAgentId = StatusMenuFocus.overview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabBar
            Divider()
            Group {
                if isOverview {
                    overviewBody
                } else {
                    harnessBody
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .frame(width: StatusMenuLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            model.refreshAvailability()
            // 打开窗口刷一轮，但仍受 60 秒闸门管，反复开关不会连打请求。
            Task { await model.quotaService.refreshAll(agents: model.selectableAgents) }
        }
    }

    private var isOverview: Bool { focusedAgentId == StatusMenuFocus.overview }

    private var resolvedAgent: AgentProfile? {
        model.selectableAgents.first(where: { $0.id == focusedAgentId })
    }

    private var isAvailable: Bool {
        guard let agent = resolvedAgent else { return false }
        return model.availability[agent.id] == true
    }

    private var recentSessions: [ChatSession] {
        if isOverview {
            return Array(model.sessions.prefix(6))
        }
        guard let agent = resolvedAgent else { return [] }
        return model.sessions.filter { $0.agent.id == agent.id }.prefix(6).map { $0 }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: StatusMenuLayout.tabSpacing) {
                overviewTab
                ForEach(model.selectableAgents) { agent in
                    harnessTab(agent)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, StatusMenuLayout.tabInset, for: .scrollContent)
        .contentMargins(.vertical, 4, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .frame(width: StatusMenuLayout.width)
        .clipped()
        .fixedSize(horizontal: false, vertical: true)
    }

    private var overviewTab: some View {
        let selected = isOverview
        return Button {
            withAnimation(.snappy(duration: 0.16)) {
                focusedAgentId = StatusMenuFocus.overview
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 14)
                Text("概览")
                    .font(StatusMenuType.tab)
                    .lineLimit(1)
                Color.clear.frame(width: 22, height: 2.5)
            }
            .foregroundStyle(selected ? .white : .primary)
            .frame(width: StatusMenuLayout.tabWidth)
            .padding(.vertical, StatusMenuLayout.tabVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(StatusMenuTapStyle())
        .modifier(StatusMenuHoverChrome(
            isSelected: selected,
            selectedFill: Palette.accent,
            cornerRadius: StatusMenuLayout.tabCornerRadius
        ))
        .help("概览")
    }

    private func harnessTab(_ agent: AgentProfile) -> some View {
        let selected = focusedAgentId == agent.id
        return Button {
            withAnimation(.snappy(duration: 0.16)) {
                focusedAgentId = agent.id
            }
        } label: {
            VStack(spacing: 3) {
                StatusMenuMark(agentId: agent.id)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(selected ? Palette.accent : .primary)
                Text(StatusMenuFocus.shortTitle(agent))
                    .font(StatusMenuType.tab)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                tabQuotaBar(for: agent)
            }
            .frame(width: StatusMenuLayout.tabWidth)
            .padding(.vertical, StatusMenuLayout.tabVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(StatusMenuTapStyle())
        .modifier(StatusMenuHoverChrome(
            isSelected: selected,
            selectedFill: Color.primary.opacity(0.08),
            cornerRadius: StatusMenuLayout.tabCornerRadius
        ))
        .help(agent.title)
    }

    @ViewBuilder
    private func tabQuotaBar(for agent: AgentProfile) -> some View {
        let remaining = remainingFraction(for: agent)
        Capsule()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 22, height: 2.5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(barColor(remaining))
                    .frame(width: 22 * CGFloat(remaining ?? 0), height: 2.5)
            }
            .opacity(remaining == nil ? 0.35 : 1)
    }

    private func remainingFraction(for agent: AgentProfile) -> Double? {
        guard HarnessQuotaFetcher.supportsQuota(for: agent.id),
              let window = model.quotaService.snapshot(for: agent.id)?.mostUrgentWindow
        else { return nil }
        return max(0, min(1, window.remainingPercent / 100))
    }

    private func barColor(_ remaining: Double?) -> Color {
        guard let remaining else { return Color.primary.opacity(0.2) }
        if remaining <= 0.05 { return .red }
        if remaining <= 0.20 { return .orange }
        return Palette.moss
    }

    @ViewBuilder
    private var overviewBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.currentWorkspaceName)
                .font(StatusMenuType.meta)
                .foregroundStyle(.secondary)

            Text("配额")
                .font(StatusMenuType.metaMedium)
                .foregroundStyle(.secondary)

            ForEach(model.selectableAgents) { agent in
                overviewQuotaRow(agent)
            }

            recentSection
        }
    }

    private func overviewQuotaRow(_ agent: AgentProfile) -> some View {
        let remaining = remainingFraction(for: agent)
        let snapshot = model.quotaService.snapshot(for: agent.id)
        return Button {
            withAnimation(.snappy(duration: 0.16)) {
                focusedAgentId = agent.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    StatusMenuMark(agentId: agent.id)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(.primary)
                    Text(agent.title)
                        .font(StatusMenuType.bodyMedium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let remaining {
                        Text("\(Int(round(remaining * 100)))%")
                            .font(StatusMenuType.number)
                            .foregroundStyle(barColor(remaining))
                            .monospacedDigit()
                    } else if model.availability[agent.id] != true {
                        Text("未安装")
                            .font(StatusMenuType.meta)
                            .foregroundStyle(.secondary)
                    } else if !HarnessQuotaFetcher.supportsQuota(for: agent.id) {
                        Text("—")
                            .font(StatusMenuType.meta)
                            .foregroundStyle(.tertiary)
                    }
                }
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(barColor(remaining))
                                .frame(width: geo.size.width * CGFloat(remaining ?? 0))
                        }
                        .opacity(remaining == nil ? 0.2 : 1)
                }
                .frame(height: 3)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(StatusMenuHoverChrome(
            isSelected: false,
            selectedFill: .clear,
            cornerRadius: 8
        ))
        .help(snapshot.flatMap(\.mostUrgentWindow)?.title ?? agent.title)
    }

    private var harnessBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            quotaSection
            newConversationButton
            recentSection
        }
    }

    @ViewBuilder
    private var quotaSection: some View {
        if let agent = resolvedAgent {
            if let snapshot = model.quotaService.snapshot(for: agent.id) {
                StatusMenuQuotaBlock(
                    snapshot: snapshot,
                    isRefreshing: model.quotaService.isRefreshing[agent.id] == true
                ) {
                    Task { await refreshFocusedQuota(force: true) }
                }
            } else if HarnessQuotaFetcher.supportsQuota(for: agent.id) {
                Text(model.quotaService.isRefreshing[agent.id] == true
                     ? "正在更新配额…"
                     : "还没有配额缓存，稍后自动刷新")
                    .font(StatusMenuType.meta)
                    .foregroundStyle(.secondary)
            } else {
                Text("此 Agent 不提供配额查询")
                    .font(StatusMenuType.meta)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var newConversationButton: some View {
        Button {
            guard let agent = resolvedAgent else { return }
            model.startNewSession(agent: agent)
            revealMainWindow()
        } label: {
            Label("新对话", systemImage: "plus")
                .font(StatusMenuType.bodyMedium)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .disabled(!isAvailable)
        .help(isAvailable ? "用 \(resolvedAgent?.title ?? "Agent") 开始新对话" : "未安装")
    }

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("最近会话")
                .font(StatusMenuType.metaMedium)
                .foregroundStyle(.secondary)

            if recentSessions.isEmpty {
                Text("还没有会话")
                    .font(StatusMenuType.meta)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                ForEach(recentSessions) { session in
                    sessionRow(session, showAgent: isOverview)
                }
            }
        }
    }

    private func sessionRow(_ session: ChatSession, showAgent: Bool = false) -> some View {
        let isCurrent = session.id == model.selectedSessionID
        let subtitle = showAgent
            ? "\(session.agent.title) · \(sessionStatus(session))"
            : sessionStatus(session)
        return Button {
            model.select(session)
            revealMainWindow()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(isCurrent ? StatusMenuType.bodyMedium : StatusMenuType.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(StatusMenuType.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(StatusMenuHoverChrome(
            isSelected: isCurrent,
            selectedFill: Palette.selection,
            cornerRadius: 8
        ))
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help("设置")
            .modifier(StatusMenuHoverChrome(
                isSelected: false,
                selectedFill: .clear,
                cornerRadius: 7
            ))

            Spacer()

            Button {
                AppActivation.terminate()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help("退出")
            .modifier(StatusMenuHoverChrome(
                isSelected: false,
                selectedFill: .clear,
                cornerRadius: 7
            ))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func sessionStatus(_ session: ChatSession) -> String {
        if session.isStreaming { return "生成中" }
        if session.pendingPermission != nil { return "等待确认" }
        switch session.phase {
        case .connecting: return "连接中"
        case .ready: return "就绪"
        case .idle: return "已断开"
        case .failed: return "失败"
        }
    }

    private func revealMainWindow() {
        AppActivation.revealMainWindow(openIfNeeded: {
            openWindow(id: AppActivation.mainWindowID)
        })
    }

    private func refreshFocusedQuota(force: Bool = false) async {
        guard let agent = resolvedAgent,
              HarnessQuotaFetcher.supportsQuota(for: agent.id)
        else { return }
        await model.quotaService.refreshQuota(for: agent, force: force)
    }
}

extension Notification.Name {
    static let aurewaysRevealMainWindow = Notification.Name("ai.aureways.revealMainWindow")
}

enum AppActivation {
    static let mainWindowID = "main"
    @MainActor static var openMainWindow: (() -> Void)?
    @MainActor static var allowsTermination = false

    @MainActor
    static var mainWindows: [NSWindow] {
        NSApp.windows.filter { window in
            window.canBecomeMain
                && window.styleMask.contains(.titled)
                && window.styleMask.contains(.closable)
        }
    }

    /// 关掉主窗口和 Dock 图标，只留菜单栏。
    @MainActor
    static func resignToMenuBar() {
        for window in NSApp.windows where window.styleMask.contains(.titled) {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
    }

    /// 从菜单栏真正退出进程。
    @MainActor
    static func terminate() {
        allowsTermination = true
        NSApp.terminate(nil)
    }

    @MainActor
    static func hideDockIfNoMainWindow() {
        if mainWindows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @MainActor
    static func revealMainWindow(openIfNeeded: (() -> Void)? = nil) {
        let restoreDock = NSApp.activationPolicy() != .regular
        if restoreDock {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        let present = {
            if let window = mainWindows.first {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                return
            }
            (openIfNeeded ?? openMainWindow)?()
        }

        if restoreDock {
            DispatchQueue.main.async(execute: present)
        } else {
            present()
        }
    }
}
