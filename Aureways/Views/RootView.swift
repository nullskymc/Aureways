import SwiftUI
import AppKit

extension Color {
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? NSColor(dark) : NSColor(light)
        }))
    }
}

enum Palette {
    static let ink = Color.adaptive(
        light: Color(red: 0.98, green: 0.98, blue: 0.99),
        dark: Color(red: 0.09, green: 0.09, blue: 0.10)
    )
    static let panel = Color.adaptive(
        light: Color(red: 0.94, green: 0.94, blue: 0.96),
        dark: Color(red: 0.13, green: 0.13, blue: 0.14)
    )
    static let card = Color.adaptive(
        light: Color(red: 1.0, green: 1.0, blue: 1.0),
        dark: Color(red: 0.17, green: 0.17, blue: 0.19)
    )
    static let cardHover = Color.adaptive(
        light: Color(red: 0.92, green: 0.92, blue: 0.95),
        dark: Color(red: 0.22, green: 0.22, blue: 0.25)
    )
    static let border = Color.adaptive(
        light: Color(white: 0.0, opacity: 0.09),
        dark: Color(white: 1.0, opacity: 0.12)
    )
    static let subtleBorder = Color.adaptive(
        light: Color(white: 0.0, opacity: 0.05),
        dark: Color(white: 1.0, opacity: 0.07)
    )

    static let gold = Color.adaptive(
        light: Color(red: 0.72, green: 0.52, blue: 0.18),
        dark: Color(red: 0.85, green: 0.70, blue: 0.40)
    )
    static let accent = Color.adaptive(
        light: Color(red: 0.75, green: 0.55, blue: 0.20),
        dark: Color(red: 0.90, green: 0.75, blue: 0.45)
    )
    static let mist = Color.adaptive(
        light: Color(red: 0.20, green: 0.20, blue: 0.22),
        dark: Color(red: 0.88, green: 0.88, blue: 0.90)
    )
    static let moss = Color.adaptive(
        light: Color(red: 0.10, green: 0.60, blue: 0.35),
        dark: Color(red: 0.35, green: 0.78, blue: 0.55)
    )
    static let sky = Color.adaptive(
        light: Color(red: 0.15, green: 0.45, blue: 0.85),
        dark: Color(red: 0.40, green: 0.65, blue: 0.95)
    )
    static let badgeBg = Color.adaptive(
        light: Color(white: 0.0, opacity: 0.06),
        dark: Color(white: 1.0, opacity: 0.08)
    )
}

// MARK: - Native Liquid Glass Visual Effect Support

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

extension View {
    @ViewBuilder
    func liquidGlassCard(cornerRadius: CGFloat = 16, isFocused: Bool = false, enabled: Bool = true) -> some View {
        if enabled {
            self
                .background(
                    ZStack {
                        // 1. Ultra thin frosted material base
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.ultraThinMaterial)

                        // 2. Translucent glass tint layer
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(
                                Color.adaptive(
                                    light: Color.white.opacity(0.55),
                                    dark: Color.white.opacity(0.06)
                                )
                            )

                        // 3. Specular diagonal glass sheen
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: Color.white.opacity(0.30), location: 0),
                                        .init(color: Color.white.opacity(0.05), location: 0.35),
                                        .init(color: Color.clear, location: 0.6),
                                        .init(color: Color.black.opacity(0.04), location: 1.0)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                )
                .overlay(
                    // Specular light edge refraction
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            LinearGradient(
                                stops: [
                                    .init(color: isFocused ? Palette.accent.opacity(0.9) : Color.white.opacity(0.65), location: 0),
                                    .init(color: isFocused ? Palette.accent.opacity(0.5) : Color.white.opacity(0.20), location: 0.35),
                                    .init(color: isFocused ? Palette.accent.opacity(0.3) : Palette.border, location: 1.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
                .shadow(color: Color.black.opacity(0.15), radius: 24, x: 0, y: 10)
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Palette.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(isFocused ? Palette.accent.opacity(0.6) : Palette.border, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } detail: {
            MainWorkspaceView()
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                WorkspaceButton()
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    model.autoApprove.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.autoApprove ? "checkmark.shield.fill" : "shield")
                            .foregroundStyle(model.autoApprove ? Palette.moss : .secondary)
                        Text("Auto-approve")
                            .font(.caption)
                    }
                }
                .help(model.autoApprove ? "自动批准权限已开启" : "自动批准权限已关闭")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    model.inspectorOpen.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(model.inspectorOpen ? Palette.accent : .secondary)
                }
                .help("检查器 (⌘B / ⌥⌘I)")
                .keyboardShortcut("b", modifiers: [.command])
            }
        }
        .background(Palette.ink)
        .alert("Agent error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .background {
            // Hidden keyboard shortcut buttons for ⌘1 ~ ⌘9
            ForEach(0..<9, id: \.self) { idx in
                Button("") {
                    model.selectSessionByIndex(idx)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: [.command])
                .opacity(0)
            }
            Button("") {
                model.inspectorOpen.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .opacity(0)
        }
    }
}

struct MainWorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if let session = model.selectedSession {
                    SessionStatusBar(session: session)
                    TranscriptView(session: session)
                    ComposerCard(session: session)
                } else {
                    EmptyWorkspaceLanding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.inspectorOpen {
                InspectorPaneView()
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 450)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.sessions.contains { $0.pendingPermission != nil } },
            set: { if !$0 { model.resolvePermission(.cancelled) } }
        )) {
            if let prompt = model.sessions.first(where: { $0.pendingPermission != nil })?.pendingPermission {
                PermissionSheet(prompt: prompt) { decision in
                    model.resolvePermission(decision)
                }
            }
        }
        .background(Palette.ink)
    }
}

struct WorkspaceButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Section("当前工作区") {
                Text(model.workspacePath)
            }
            Divider()
            Button("切换工作区...") { model.pickWorkspace() }
            Button("在 Finder 中打开") { model.openWorkspaceInFinder() }
            if let branch = model.workspaceBranch {
                Divider()
                Text("Git 分支: \(branch)")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.accent)
                Text(model.currentWorkspaceName)
                    .font(.system(size: 12.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("当前工作区：\(model.workspacePath)")
    }
}

