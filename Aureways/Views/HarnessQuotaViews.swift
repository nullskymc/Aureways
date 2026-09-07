import SwiftUI

// MARK: - Harness Quota Chip (for Composer)

struct HarnessQuotaChip: View {
    @Environment(AppModel.self) private var model
    let agentId: String

    @State private var showPopover = false
    @State private var isHovered = false

    private var agent: AgentProfile? {
        model.agents.first(where: { $0.id == agentId })
    }

    private var snapshot: HarnessQuotaSnapshot? {
        model.quotaService.snapshot(for: agentId)
    }

    private var isRefreshing: Bool {
        model.quotaService.isRefreshing[agentId] == true
    }

    var body: some View {
        if let agent = agent {
            Button {
                showPopover.toggle()
            } label: {
                contentLabel(agent: agent)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                if let snapshot = snapshot {
                    HarnessQuotaPopoverView(snapshot: snapshot) {
                        Task {
                            await model.quotaService.refreshQuota(for: agent, force: true)
                        }
                    }
                } else {
                    quotaLoadingView(agent: agent)
                }
            }
            .onHover { isHovered = $0 }
            .task(id: agentId) {
                await model.quotaService.refreshQuota(for: agent)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .liquidGlassCapsule(interactive: true)
        .help(tooltipText)
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
            var lines = ["\(snapshot.providerTitle) 配额使用情况"]
            if let email = snapshot.accountEmail {
                lines.append("账号: \(email)")
            }
            if let urgent = snapshot.mostUrgentWindow {
                lines.append("\(urgent.title): \(Int(round(urgent.usedPercent)))% 已使用")
                if let reset = urgent.countdownDescription {
                    lines.append(reset)
                }
            }
            lines.append("点击查看完整配额详情")
            return lines.joined(separator: "\n")
        }
        return "点击查看并刷新 \(agent?.title ?? "Agent") 配额"
    }

    @ViewBuilder
    private func quotaLoadingView(agent: AgentProfile) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("正在查询 \(agent.title) 配额...")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 240)
        .task {
            await model.quotaService.refreshQuota(for: agent, force: true)
        }
    }
}

// MARK: - Quota Popover View

struct HarnessQuotaPopoverView: View {
    let snapshot: HarnessQuotaSnapshot
    let onRefresh: () -> Void

    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: Monogram, Title, Plan Badge, Email
            headerView

            Divider().opacity(0.3)

            // Primary rate window
            if let primary = snapshot.primaryWindow {
                windowRow(window: primary, isPrimary: true)
            }

            // Secondary rate window
            if let secondary = snapshot.secondaryWindow {
                windowRow(window: secondary, isPrimary: false)
            }

            // Extra rate windows (e.g. Gemini 5h, Weekly, 3p 5h, 3p Weekly)
            if !snapshot.extraWindows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("模型细分限额")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    ForEach(snapshot.extraWindows) { extra in
                        extraWindowRow(extra)
                    }
                }
            }

            // Credits and Perks
            if snapshot.creditsRemaining != nil || (snapshot.resetCreditsAvailable ?? 0) > 0 {
                Divider().opacity(0.3)
                perksView
            }

            // Error notice if any
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

            Divider().opacity(0.3)

            // Footer: Updated at & Refresh button
            footerView
        }
        .padding(14)
        .frame(width: 290)
        .background(.ultraThinMaterial)
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
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.title)
                    .font(.system(size: 11.5, weight: isPrimary ? .medium : .regular))
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(Int(round(window.usedPercent)))%")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(progressBarColor(for: window.usedPercent))
            }

            quotaProgressBar(usedPercent: window.usedPercent)

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

    @ViewBuilder
    private func extraWindowRow(_ window: HarnessQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(Int(round(window.usedPercent)))%")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(progressBarColor(for: window.usedPercent))
            }

            quotaProgressBar(usedPercent: window.usedPercent, height: 3.5)

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
                isRefreshing = true
                onRefresh()
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    isRefreshing = false
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                    Text("刷新")
                        .font(.system(size: 10.5))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func quotaProgressBar(usedPercent: Double, height: CGFloat = 4.5) -> some View {
        GeometryReader { geo in
            let clamped = max(0.0, min(100.0, usedPercent))
            let fillWidth = geo.size.width * (clamped / 100.0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: height)

                Capsule()
                    .fill(progressBarColor(for: clamped))
                    .frame(width: fillWidth, height: height)
            }
        }
        .frame(height: height)
    }

    private func progressBarColor(for usedPercent: Double) -> Color {
        if usedPercent >= 95.0 {
            return Color.red
        } else if usedPercent >= 80.0 {
            return Color.orange
        } else {
            return Palette.moss
        }
    }

    private var updatedTimeString: String {
        let interval = Date().timeIntervalSince(snapshot.updatedAt)
        if interval < 60 {
            return "刚刚更新"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins) 分钟前更新"
        } else {
            let hours = Int(interval / 3600)
            return "\(hours) 小时前更新"
        }
    }
}

// MARK: - Quota Critical Alert Banner (for Composer top)

struct HarnessQuotaCriticalBanner: View {
    @Environment(AppModel.self) private var model
    let agentId: String

    @State private var showPopover = false

    private var snapshot: HarnessQuotaSnapshot? {
        model.quotaService.snapshot(for: agentId)
    }

    var body: some View {
        if let snapshot = snapshot, snapshot.overallSeverity == .critical, let urgent = snapshot.mostUrgentWindow {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.red)

                Text("\(snapshot.providerTitle) 配额即将耗尽（\(Int(round(urgent.usedPercent)))% 已使用）\(urgent.countdownDescription != nil ? " · \(urgent.countdownDescription!)" : "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Button("查看详情") {
                    showPopover = true
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.accent)
                .buttonStyle(.plain)
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    HarnessQuotaPopoverView(snapshot: snapshot) {
                        if let agent = model.agents.first(where: { $0.id == agentId }) {
                            Task {
                                await model.quotaService.refreshQuota(for: agent, force: true)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.09))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.red.opacity(0.2), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
            .padding(.top, 4)
        }
    }
}

// MARK: - Quota Summary Badge (for SettingsView AgentRow)

struct HarnessQuotaSummaryBadge: View {
    @Environment(AppModel.self) private var model
    let agentId: String

    @State private var showPopover = false

    private var agent: AgentProfile? {
        model.agents.first(where: { $0.id == agentId })
    }

    private var snapshot: HarnessQuotaSnapshot? {
        model.quotaService.snapshot(for: agentId)
    }

    var body: some View {
        if let snapshot = snapshot, let agent = agent {
            Button {
                showPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(badgeColor(snapshot.overallSeverity))
                        .frame(width: 5.5, height: 5.5)

                    Text(snapshot.shortSummary)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPopover, arrowEdge: .leading) {
                HarnessQuotaPopoverView(snapshot: snapshot) {
                    Task {
                        await model.quotaService.refreshQuota(for: agent, force: true)
                    }
                }
            }
        }
    }

    private func badgeColor(_ severity: HarnessQuotaSeverity) -> Color {
        switch severity {
        case .critical: return Color.red
        case .warning: return Color.orange
        case .healthy: return Palette.moss
        case .unknown: return Color.secondary.opacity(0.4)
        }
    }
}
