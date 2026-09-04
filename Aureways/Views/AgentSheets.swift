import SwiftUI

// MARK: - Custom Agent Sheet

struct CustomAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("添加自定义 Agent")
                .font(.title3.weight(.semibold))
            Text("用命令行启动任意 Agent。名称可选，命令与参数以空格分隔。")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("名称", text: $model.customTitle)
                .textFieldStyle(.roundedBorder)

            TextField("启动命令", text: $model.customCommand)
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

