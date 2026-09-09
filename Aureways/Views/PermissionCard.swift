import SwiftUI

/// 内联审批卡：悬浮在输入框上方，不再是模态弹窗。
/// 选项完全按 harness 经 ACP 下发的 PermissionOption 动态渲染——
/// 各家允许/拒绝的档位数与命名不同，客户端不硬编码。
/// 选项纵向铺开、全文换行，避免横排胶囊把长文案截断。
struct PermissionCard: View {
    let session: ChatSession
    let prompt: PermissionPrompt
    var showsSessionBadge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            details
            optionList
            footer
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 12, veil: 0.65)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.gold)
                .padding(.top, 1)
            Text(prompt.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsSessionBadge {
                Text(session.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .liquidGlassCapsule(interactive: false)
                    .help("该请求来自另一个会话")
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        if let toolCall = prompt.toolCall {
            ToolCallDetail(call: toolCall, lineLimit: 6)
        }
    }

    @ViewBuilder
    private var optionList: some View {
        let rows = VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(prompt.options.enumerated()), id: \.element.id) { index, option in
                optionRow(option, isDefault: index == firstAllowIndex)
            }
        }
        if prompt.options.count > 5 {
            ScrollView {
                rows
            }
            .frame(maxHeight: 220)
        } else {
            rows
        }
    }

    private func optionRow(_ option: PermissionOption, isDefault: Bool) -> some View {
        Button {
            session.resumePermission(.selected(option.optionId))
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: option.isAllow ? "checkmark.circle" : "xmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(option.isAllow ? Palette.moss : Color.red.opacity(0.85))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = option.description {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.badgeBg)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(isDefault ? .defaultAction : nil)
    }

    private var footer: some View {
        HStack {
            Button("取消") {
                session.resumePermission(.cancelled)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
            .help("拒绝本次请求 (Esc)")
            Spacer()
        }
    }

    private var firstAllowIndex: Int? {
        prompt.options.firstIndex(where: \.isAllow)
    }

}
