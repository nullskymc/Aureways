import AppKit
import SwiftUI

// MARK: - Agent Quota Indicator View

struct HarnessQuotaChip: View {
    let agentId: String
    @Binding var isShowingCard: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        if let agent = model.agents.first(where: { $0.id == agentId }) ?? (model.selectedAgent.id == agentId ? model.selectedAgent : nil) {
            HarnessQuotaIndicatorView(agent: agent, isShowingCard: $isShowingCard)
        }
    }
}

struct HarnessQuotaIndicatorView: View {
    let agent: AgentProfile?
    @Binding var isShowingCard: Bool
    @Environment(AppModel.self) private var model

    private var snapshot: HarnessQuotaSnapshot? {
        guard let agent = agent else { return nil }
        return model.quotaService.snapshot(for: agent.id)
    }

    private var isRefreshing: Bool {
        guard let agent = agent else { return false }
        return model.quotaService.isRefreshing[agent.id] == true
    }

    var body: some View {
        if let agent = agent, HarnessQuotaFetcher.supportsQuota(for: agent.id) {
            Button {
                isShowingCard.toggle()
                if snapshot == nil {
                    Task {
                        await model.quotaService.refreshQuota(for: agent, force: true)
                    }
                }
            } label: {
                contentLabel(agent: agent)
            }
            .buttonStyle(.glass)
            .fixedSize()
            .help(tooltipText)
            .background { QuotaChromeAnchorView() }
            .background {
                QuotaOutsideDismiss(isActive: isShowingCard) {
                    isShowingCard = false
                }
            }
        }
    }

    @ViewBuilder
    private func contentLabel(agent: AgentProfile) -> some View {
        HStack(spacing: 5) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                statusIcon
            }

            if let snapshot = snapshot {
                Text(snapshot.shortSummary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(severityColor(snapshot.overallSeverity))
            } else {
                Text("配额")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        let severity = snapshot?.overallSeverity ?? .unknown
        switch severity {
        case .critical:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.red)
        case .warning:
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.orange)
        case .healthy:
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.moss)
        case .unknown:
            Image(systemName: "chart.bar")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func severityColor(_ severity: HarnessQuotaSeverity) -> Color {
        switch severity {
        case .critical: return Color.red
        case .warning: return Color.orange
        case .healthy: return .primary
        case .unknown: return .secondary
        }
    }

    private var tooltipText: String {
        if let snapshot = snapshot {
            var lines = ["%@ 配额情况".localized(snapshot.providerTitle)]
            if let email = snapshot.accountEmail {
                lines.append("账号: %@".localized(email))
            }
            if let urgent = snapshot.mostUrgentWindow {
                lines.append("%1$@: 剩余 %2$lld%% (已用 %3$lld%%)".localized(urgent.title, Int(round(urgent.remainingPercent)), Int(round(urgent.usedPercent))))
                if let reset = urgent.countdownDescription {
                    lines.append(reset)
                }
            }
            lines.append("点击查看完整配额详情".localized)
            return lines.joined(separator: "\n")
        }
        return "点击查看并刷新 %@ 配额".localized(agent?.title ?? "Agent")
    }
}

/// 配额详情卡。必须挂在 ComposerCard 的 overlay 上，不能放进 chip：
/// chip 在玻璃卡片内部，溢出部分会被裁掉，检查器会从裁切处透出来。
struct HarnessQuotaFloatingCard: View {
    let agent: AgentProfile
    @Environment(AppModel.self) private var model

    private var snapshot: HarnessQuotaSnapshot? {
        model.quotaService.snapshot(for: agent.id)
    }

    private var isRefreshing: Bool {
        model.quotaService.isRefreshing[agent.id] == true
    }

    var body: some View {
        Group {
            if let snapshot {
                HarnessQuotaPopoverView(snapshot: snapshot, isRefreshing: isRefreshing) {
                    Task {
                        await model.quotaService.refreshQuota(for: agent, force: true)
                    }
                }
            } else {
                loadingView
            }
        }
        .background { QuotaChromeAnchorView() }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("正在查询 \(agent.title) 配额...")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 240)
        .liquidGlassCard(cornerRadius: 14, veil: 0.65)
        .task {
            await model.quotaService.refreshQuota(for: agent, force: true)
        }
    }
}

// MARK: - Quota Popover View

struct HarnessQuotaPopoverView: View {
    let snapshot: HarnessQuotaSnapshot
    var isRefreshing = false
    var showsChrome = true
    var showsProviderHeader = true
    let onRefresh: () -> Void

    var body: some View {
        if showsChrome {
            detail
                .padding(14)
                .frame(width: 300)
                .liquidGlassCard(cornerRadius: 14, veil: 0.65)
        } else {
            detail
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsProviderHeader {
                headerView
                Divider().opacity(0.3)
            } else {
                compactAccount
            }

            if let primary = snapshot.primaryWindow {
                windowRow(window: primary, isPrimary: true)
            }

            if let secondary = snapshot.secondaryWindow {
                windowRow(window: secondary, isPrimary: false)
            }

            if !snapshot.extraWindows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("其他模型限额")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    ForEach(snapshot.extraWindows) { extra in
                        extraWindowRow(extra)
                    }
                }
            }

            if snapshot.creditsRemaining != nil || (snapshot.resetCreditsAvailable ?? 0) > 0 {
                Divider().opacity(0.3)
                perksView
            }

            if let error = snapshot.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red)
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            footerView
        }
    }

    @ViewBuilder
    private var compactAccount: some View {
        if let plan = snapshot.planType, !plan.isEmpty {
            HStack(spacing: 6) {
                Text(plan)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Palette.badgeBg, in: Capsule())
                if let email = snapshot.accountEmail, !email.isEmpty {
                    Text(email)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        } else if let email = snapshot.accountEmail, !email.isEmpty {
            Text(email)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var headerView: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Palette.badgeBg)
                    .frame(width: 32, height: 32)
                Text(String(snapshot.providerTitle.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snapshot.providerTitle)
                        .font(.system(size: 13, weight: .semibold))

                    if let plan = snapshot.planType, !plan.isEmpty {
                        Text(plan)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Palette.badgeBg, in: Capsule())
                    }
                }

                if let email = snapshot.accountEmail, !email.isEmpty {
                    Text(email)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func windowRow(window: HarnessQuotaWindow, isPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.title)
                    .font(.system(size: 11.5, weight: isPrimary ? .medium : .regular))
                    .foregroundStyle(.primary)

                Spacer()

                Text("剩余 \(Int(round(window.remainingPercent)))%")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(progressBarColor(forRemaining: window.remainingPercent))
            }

            if isPrimary && !snapshot.usageBreakdown.isEmpty {
                segmentedProgressBar(breakdown: snapshot.usageBreakdown)

                if let countdown = window.countdownDescription {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(countdown)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(snapshot.usageBreakdown.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(breakdownColor(for: index))
                                .frame(width: 6, height: 6)

                            Text(item.title)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)

                            Spacer()

                            Text("已用 \(Int(round(item.usedPercent)))%")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            } else {
                quotaProgressBar(remainingPercent: window.remainingPercent)

                if let countdown = window.countdownDescription {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(countdown)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func extraWindowRow(_ window: HarnessQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.primary)

                Spacer()

                Text("剩余 \(Int(round(window.remainingPercent)))%")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(progressBarColor(forRemaining: window.remainingPercent))
            }

            quotaProgressBar(remainingPercent: window.remainingPercent, height: 3.5)

            if let countdown = window.countdownDescription {
                Text(countdown)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var perksView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let credits = snapshot.creditsRemaining {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.accent)
                    Text("剩余点数:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(String(format: "%.2f", credits)) \(snapshot.creditsUnit ?? "Credits")")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
            }

            if let resetCredits = snapshot.resetCreditsAvailable, resetCredits > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "gift.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.moss)
                    Text("免费重置额度:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(resetCredits) 次可用")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.moss)
                }
            }
        }
    }

    private var footerView: some View {
        HStack {
            Text(updatedTimeString)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                onRefresh()
            } label: {
                HStack(spacing: 4) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    Text("刷新")
                        .font(.system(size: 10.5))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
        }
    }

    private func quotaProgressBar(remainingPercent: Double, height: CGFloat = 4.5) -> some View {
        GeometryReader { geo in
            let clamped = max(0.0, min(100.0, remainingPercent))
            let fillWidth = geo.size.width * (clamped / 100.0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: height)

                Capsule()
                    .fill(progressBarColor(forRemaining: clamped))
                    .frame(width: fillWidth, height: height)
            }
        }
        .frame(height: height)
    }

    private func segmentedProgressBar(breakdown: [HarnessQuotaBreakdownItem], height: CGFloat = 6.0) -> some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            HStack(spacing: 1.5) {
                ForEach(Array(breakdown.enumerated()), id: \.element.id) { index, item in
                    let pct = max(0.0, min(100.0, item.usedPercent))
                    let segWidth = totalWidth * CGFloat(pct / 100.0)
                    if segWidth > 1.0 {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(breakdownColor(for: index))
                            .frame(width: max(2.5, segWidth - 1.5))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: height)
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .frame(height: height)
    }

    private func breakdownColor(for index: Int) -> Color {
        let colors: [Color] = [
            Color(nsColor: .systemBlue),
            Color(nsColor: .systemPurple),
            Color(nsColor: .systemOrange),
            Color(nsColor: .systemTeal),
            Color(nsColor: .systemPink),
            Color(nsColor: .systemIndigo),
            Color(nsColor: .systemMint)
        ]
        return colors[index % colors.count]
    }

    private func progressBarColor(forRemaining remainingPercent: Double) -> Color {
        if remainingPercent <= 5.0 {
            return Color.red
        } else if remainingPercent <= 20.0 {
            return Color.orange
        } else {
            return Palette.moss
        }
    }

    private var updatedTimeString: String {
        let interval = Date().timeIntervalSince(snapshot.updatedAt)
        if interval < 60 {
            return "刚刚更新".localized
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "%lld 分钟前更新".localized(mins)
        } else {
            let hours = Int(interval / 3600)
            return "%lld 小时前更新".localized(hours)
        }
    }
}

// MARK: - Quota Summary Badge (for Settings Agent Row)

struct HarnessQuotaSummaryBadge: View {
    let agentId: String
    @Environment(AppModel.self) private var model

    private var snapshot: HarnessQuotaSnapshot? {
        model.quotaService.snapshot(for: agentId)
    }

    var body: some View {
        if HarnessQuotaFetcher.supportsQuota(for: agentId), let snapshot = snapshot {
            HStack(spacing: 4) {
                Circle()
                    .fill(badgeColor(snapshot.overallSeverity))
                    .frame(width: 6, height: 6)
                Text(snapshot.shortSummary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.04), in: Capsule())
        }
    }

    private func badgeColor(_ severity: HarnessQuotaSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .healthy: return Palette.moss
        case .unknown: return .secondary
        }
    }
}

private final class QuotaChromeAnchor: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { .zero }
}

private struct QuotaChromeAnchorView: NSViewRepresentable {
    func makeNSView(context: Context) -> QuotaChromeAnchor {
        QuotaChromeAnchor()
    }

    func updateNSView(_ nsView: QuotaChromeAnchor, context: Context) {}
}

private struct QuotaOutsideDismiss: NSViewRepresentable {
    var isActive: Bool
    var onDismiss: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityHidden(true)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        context.coordinator.setActive(isActive)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.setActive(false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: @unchecked Sendable {
        var onDismiss: @MainActor () -> Void = {}
        nonisolated(unsafe) private var monitor: Any?

        func setActive(_ active: Bool) {
            if active {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                    guard let self else { return event }
                    if event.type == .keyDown {
                        guard event.keyCode == 53 else { return event }
                        let dismiss = self.onDismiss
                        Task { @MainActor in dismiss() }
                        return nil
                    }
                    let windowNumber = event.windowNumber
                    let location = event.locationInWindow
                    let dismiss = self.onDismiss
                    Task { @MainActor in
                        if Self.hitQuotaChrome(windowNumber: windowNumber, location: location) {
                            return
                        }
                        dismiss()
                    }
                    return event
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        @MainActor
        private static func hitQuotaChrome(windowNumber: Int, location: NSPoint) -> Bool {
            guard let window = NSApp.window(withWindowNumber: windowNumber),
                  let hit = window.contentView?.hitTest(location)
            else {
                return false
            }
            var current: NSView? = hit
            while let view = current {
                if view is QuotaChromeAnchor { return true }
                if view.subviews.contains(where: { $0 is QuotaChromeAnchor }) { return true }
                current = view.superview
            }
            return false
        }
    }
}
