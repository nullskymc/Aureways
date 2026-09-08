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

/// 右侧菜单栏点开后的面板。玻璃由 `MenuBarExtra` 的 `.window` 样式提供，
/// 与控制中心等系统卡片同一套，不要再叠一层 `liquidGlassCard`。
struct StatusMenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            harnessSection

            if let session = model.selectedSession {
                Divider()
                currentSessionRow(session)
            }

            if !recentSessions.isEmpty {
                Divider()
                recentSection
            }

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 320)
        .task {
            model.refreshAvailability()
        }
    }

    private var recentSessions: [ChatSession] {
        model.sessions.filter { $0.id != model.selectedSessionID }.prefix(5).map { $0 }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Aureways")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.currentWorkspaceName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("打开窗口") {
                revealMainWindow()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }

    private var harnessSection: some View {
        let agents = model.selectableAgents
        return VStack(alignment: .leading, spacing: 4) {
            Text("新对话")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            if agents.isEmpty {
                Text("没有可用的 Agent")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            } else {
                let row: CGFloat = 40
                let height = min(CGFloat(agents.count), 7) * row
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(agents) { agent in
                            HarnessMenuRow(agent: agent) {
                                model.startNewSession(agent: agent)
                                revealMainWindow()
                            }
                        }
                    }
                }
                .frame(height: height)
            }
        }
    }

    private func currentSessionRow(_ session: ChatSession) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(session.agent.title) · \(sessionStatus(session))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if session.isStreaming {
                Button("停止") {
                    model.cancel()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .tint(.red)
            } else {
                Button("打开") {
                    model.select(session)
                    revealMainWindow()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("最近会话")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            ForEach(recentSessions) { session in
                Button {
                    model.select(session)
                    revealMainWindow()
                } label: {
                    HStack(spacing: 8) {
                        Text(session.title)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(session.agent.title)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("偏好设置…") {
                openSettings()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 12))

            Spacer()

            Button("关闭窗口") {
                AppActivation.resignToMenuBar()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 12))

            Button("退出") {
                AppActivation.terminate()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 12))
        }
        .padding(.horizontal, 4)
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
}

private struct HarnessMenuRow: View {
    @Environment(AppModel.self) private var model
    let agent: AgentProfile
    let action: () -> Void
    @State private var isHovered = false

    private var isAvailable: Bool {
        model.availability[agent.id] == true
    }

    private var snapshot: HarnessQuotaSnapshot? {
        model.quotaService.snapshot(for: agent.id)
    }

    private var isRefreshing: Bool {
        model.quotaService.isRefreshing[agent.id] == true
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(String(agent.title.prefix(1)))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.accent.opacity(isAvailable ? 1 : 0.35)))

                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isAvailable ? .primary : .secondary)
                    if let detail = quotaDetail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if !isAvailable {
                        Text("未安装")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 6)

                trailing
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .help(helpText)
        .glassRowHighlight(isSelected: false, isHovered: isHovered, cornerRadius: 8)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var trailing: some View {
        if isRefreshing && snapshot == nil {
            ProgressView()
                .controlSize(.mini)
        } else if let snapshot, HarnessQuotaFetcher.supportsQuota(for: agent.id) {
            Text(snapshot.shortSummary)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(severityColor(snapshot.overallSeverity))
                .monospacedDigit()
        } else if isAvailable {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var quotaDetail: String? {
        guard let snapshot, HarnessQuotaFetcher.supportsQuota(for: agent.id) else { return nil }
        guard let window = snapshot.mostUrgentWindow else { return nil }
        if let countdown = window.countdownDescription {
            return "\(window.title) · \(countdown)"
        }
        return window.title
    }

    private var helpText: String {
        if !isAvailable {
            return "\(agent.title) 未安装"
        }
        if let snapshot, let window = snapshot.mostUrgentWindow {
            var lines = ["用 \(agent.title) 开始新对话"]
            lines.append("\(window.title) 剩余 \(Int(round(window.remainingPercent)))%")
            if let countdown = window.countdownDescription {
                lines.append(countdown)
            }
            return lines.joined(separator: "\n")
        }
        return "用 \(agent.title) 开始新对话"
    }

    private func severityColor(_ severity: HarnessQuotaSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .healthy: return Palette.moss
        case .unknown: return .secondary
        }
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
