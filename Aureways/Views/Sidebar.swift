import SwiftUI

struct SidebarView: View {
    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader()
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

            ScrollView {
                WorkspaceSessionTree()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)

            Divider()

            // 3. User Profile Footer
            UserProfileFooter()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }
}

// MARK: - Sidebar Header

struct SidebarHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack {
            Menu {
                Text("Aureways v\(AppInfo.version) (ACP v1)")
                Divider()
                Button("添加工作区...") { model.addWorkspace() }
                Button("在 Finder 中打开当前工作区") { model.openWorkspaceInFinder() }
                Divider()
                Button("偏好设置...") {
                    openSettings()
                }
            } label: {
                HStack(spacing: 5) {
                    Text("会话")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Button {
                model.startNewSession()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("新对话 (⌘N)")
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
