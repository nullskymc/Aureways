import SwiftUI

/// 内联审批卡：悬浮在输入框上方，不再是模态弹窗。
/// 选项完全按 harness 经 ACP 下发的 PermissionOption 动态渲染——
/// 各家允许/拒绝的档位数与命名不同，客户端不硬编码。
struct PermissionCard: View {
    let session: ChatSession
    let prompt: PermissionPrompt
    var showsSessionBadge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.gold)
                Text(prompt.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
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

            if let input = prompt.toolCall?.rawInput {
                Text(stringify(input))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Palette.badgeBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 8) {
                Button("取消") {
                    session.resumePermission(.cancelled)
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                .help("拒绝本次请求 (Esc)")

                Spacer()

                ForEach(Array(prompt.options.enumerated()), id: \.element.id) { index, option in
                    Button(option.name) {
                        session.resumePermission(.selected(option.optionId))
                    }
                    .buttonStyle(.glass(.regular.tint(option.isAllow ? Palette.moss : Color.red)))
                    .keyboardShortcut(index == firstAllowIndex ? .defaultAction : nil)
                }
            }
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 12, veil: 0.65)
    }

    private var firstAllowIndex: Int? {
        prompt.options.firstIndex(where: \.isAllow)
    }

    private func stringify(_ json: JSONValue) -> String {
        (try? String(data: json.encode(), encoding: .utf8)) ?? ""
    }
}
