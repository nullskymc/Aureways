import SwiftUI

struct PermissionSheet: View {
    let prompt: PermissionPrompt
    let onDecide: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(Palette.gold)
                Text("需要权限确认")
                    .font(.title3.weight(.semibold))
            }

            Text(prompt.title)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let input = prompt.toolCall?.rawInput {
                VStack(alignment: .leading, spacing: 4) {
                    Text("调用参数：")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(stringify(input))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.badgeBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            HStack {
                Button("取消") { onDecide(.cancelled) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                ForEach(prompt.options) { option in
                    Button(option.name) {
                        onDecide(.selected(option.optionId))
                    }
                    .keyboardShortcut(option.isAllow ? .defaultAction : nil)
                    .tint(option.isAllow ? Palette.moss : .red)
                }
            }
        }
        .padding(22)
        .frame(minWidth: 440)
    }

    private func stringify(_ json: JSONValue) -> String {
        (try? String(data: json.encode(), encoding: .utf8)) ?? ""
    }
}




