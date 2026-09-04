import SwiftUI

// MARK: - Empty Workspace Landing

struct EmptyWorkspaceLanding: View {
    @Environment(AppModel.self) private var model
    @State private var isHoveringWorkspace = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                BrandMark(size: 96, glow: true)

                HStack(spacing: 4) {
                    Text("在")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.primary)

                    Button(action: model.pickWorkspace) {
                        Text(model.currentWorkspaceName)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.primary)
                            .underline(true, color: Color.primary.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringWorkspace = $0 }
                    .help("点击切换工作区（当前：\(model.workspacePath)）")

                    Text("做什么？")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .composerBar(session: nil)
    }
}
