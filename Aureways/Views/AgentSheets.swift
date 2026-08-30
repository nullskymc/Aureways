import SwiftUI

// MARK: - Custom Agent Sheet

struct CustomAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("添加自定义 ACP Agent")
                .font(.title3.weight(.semibold))
            Text("支持任意遵循 stdio ACP 协议的 CLI 工具。例如：grok agent stdio")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("名称 (如: My Custom Agent)", text: $model.customTitle)
                .textFieldStyle(.roundedBorder)

            TextField("启动命令 (如: /opt/homebrew/bin/opencode acp)", text: $model.customCommand)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") {
                    model.addCustomAgent()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.customCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

