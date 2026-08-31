import SwiftUI

struct SidebarView: View {
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                WorkspaceSessionTree()
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
            }
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)

            // 3. User Profile Footer — floating glass card
            UserProfileFooter()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .liquidGlassCard(cornerRadius: 12)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
    }
}

// MARK: - User Profile Footer

struct UserProfileFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 9) {
            // User Avatar
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.8), Color.indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 26, height: 26)
                Text(String(model.userName.prefix(2)).lowercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(model.userName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text("ACP 客户端已就绪")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("设置与偏好 (⌘,)")
        }
    }
}
