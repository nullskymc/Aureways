import SwiftUI

/// Grok `x.ai/exit_plan_mode` — inline plan preview above the composer.
struct PlanApprovalCard: View {
    let session: ChatSession
    let prompt: PlanApprovalPrompt
    var showsSessionBadge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            bodyPreview
            actions
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 12, veil: 0.65)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "list.clipboard.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.gold)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("批准计划")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                if let path = prompt.filePath {
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsSessionBadge {
                Text(session.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .liquidGlassCapsule(interactive: false)
            }
        }
    }

    @ViewBuilder
    private var bodyPreview: some View {
        if prompt.isEmpty {
            Text("尚未写入计划。仍可批准并开始实现，或请 agent 继续规划。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView {
                MarkdownBody(source: prompt.content, isStreaming: false)
            }
            .frame(maxHeight: 280)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("放弃") {
                session.resumePlanApproval(.quit)
            }
            .buttonStyle(.glass)
            .help("放弃计划并退出计划模式")
            Button("要修改") {
                session.resumePlanApproval(.requestChanges)
            }
            .buttonStyle(.glass)
            .help("留在计划模式，在输入框里说明要改什么")
            Spacer()
            Button("批准") {
                session.resumePlanApproval(.approved(feedback: ""))
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.defaultAction)
            .help("批准计划并开始实现 (Return)")
        }
    }
}

/// Grok `x.ai/ask_user_question` — option list, same slot as PermissionCard.
struct UserQuestionCard: View {
    let session: ChatSession
    let prompt: UserQuestionPrompt
    var showsSessionBadge = false

    @State private var selections: [UUID: Set<String>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(prompt.questions) { question in
                questionBlock(question)
            }
            actions
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 12, veil: 0.65)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.gold)
                .padding(.top, 1)
            Text(prompt.questions.count == 1 ? "请选择" : "请回答 \(prompt.questions.count) 个问题")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsSessionBadge {
                Text(session.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .liquidGlassCapsule(interactive: false)
            }
        }
    }

    private func questionBlock(_ question: UserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(question.options) { option in
                optionRow(question: question, option: option)
            }
        }
    }

    private func optionRow(question: UserQuestion, option: UserQuestionOption) -> some View {
        let selected = selections[question.id, default: []].contains(option.label)
        return Button {
            toggle(question: question, option: option)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected
                      ? (question.multiSelect ? "checkmark.square.fill" : "checkmark.circle.fill")
                      : (question.multiSelect ? "square" : "circle"))
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Palette.moss : .secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
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
                    if let preview = option.preview {
                        Text(preview)
                            .font(.system(size: 11).monospaced())
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
                    .fill(selected ? Palette.moss.opacity(0.12) : Palette.badgeBg)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var actions: some View {
        HStack {
            Button("跳过") {
                session.resumeUserQuestion(.skipInterview)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button("确认") {
                var mapped: [UUID: [String]] = [:]
                for question in prompt.questions {
                    mapped[question.id] = Array(selections[question.id] ?? [])
                }
                session.resumeUserQuestion(.accepted(mapped))
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
        }
    }

    private var canSubmit: Bool {
        prompt.questions.allSatisfy { question in
            question.options.isEmpty || !(selections[question.id] ?? []).isEmpty
        }
    }

    private func toggle(question: UserQuestion, option: UserQuestionOption) {
        var current = selections[question.id] ?? []
        if question.multiSelect {
            if current.contains(option.label) {
                current.remove(option.label)
            } else {
                current.insert(option.label)
            }
        } else {
            current = [option.label]
        }
        selections[question.id] = current
    }
}
