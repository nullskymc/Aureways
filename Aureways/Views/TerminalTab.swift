import AppKit
import SwiftUI
import SwiftTerm

// MARK: - Interactive Terminal (PTY-backed, user-facing)

@MainActor
final class InteractiveTerminal: NSObject {
    let id = UUID()
    let index: Int
    let cwd: String
    let view: LocalProcessTerminalView

    private(set) var exited = false
    private(set) var exitCode: Int32?
    private var appliedDark: Bool?
    var onExited: ((Int32?) -> Void)?

    var title: String {
        guard exited else { return "终端 \(index)" }
        if let code = exitCode {
            return "终端 \(index)（已退出 \(code)）"
        }
        return "终端 \(index)（已退出）"
    }

    init(index: Int, cwd: String) {
        self.index = index
        self.cwd = cwd
        self.view = LocalProcessTerminalView(frame: .zero)
        super.init()
        view.processDelegate = self
        view.font = TerminalTypeface.resolve()
    }

    func start() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = HostEnvironment.augmented()
        env["TERM"] = "xterm-256color"
        if env["COLORTERM"] == nil || env["COLORTERM"]?.isEmpty == true {
            env["COLORTERM"] = "truecolor"
        }
        // Finder 启动的 GUI 进程经常没有 LANG，zsh/p10k 会退回 ASCII 并用替换符画图标。
        if env["LANG"] == nil || env["LANG"]?.isEmpty == true {
            env["LANG"] = "en_US.UTF-8"
        }
        if env["LC_CTYPE"] == nil || env["LC_CTYPE"]?.isEmpty == true {
            env["LC_CTYPE"] = env["LANG"] ?? "en_US.UTF-8"
        }
        let environment = env.map { "\($0.key)=\($0.value)" }
        // argv[0] 以 "-" 开头，shell 按登录 shell 启动（读取 .zprofile 等）。
        let execName = "-" + URL(fileURLWithPath: shell).lastPathComponent
        view.startProcess(executable: shell, environment: environment, execName: execName, currentDirectory: cwd)
    }

    func terminate() {
        guard view.process.running else { return }
        view.terminate()
    }

    func applyAppearance(dark: Bool) {
        guard appliedDark != dark else { return }
        appliedDark = dark
        view.nativeBackgroundColor = dark
            ? NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)
            : NSColor.white
        view.nativeForegroundColor = dark
            ? NSColor(calibratedWhite: 0.92, alpha: 1)
            : NSColor.black
    }

    fileprivate func markExited(_ code: Int32?) {
        guard !exited else { return }
        exited = true
        exitCode = code
        onExited?(code)
    }
}

extension InteractiveTerminal: LocalProcessTerminalViewDelegate {
    // 回调由 SwiftTerm 在主队列投递；协议签名是 nonisolated，这里回到 MainActor。
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            markExited(exitCode)
        }
    }
}

// MARK: - Terminal Tab View

struct TerminalTabView: View {
    @Environment(\.colorScheme) private var colorScheme
    let terminal: InteractiveTerminal
    var isActive: Bool = true

    var body: some View {
        TerminalViewRepresentable(terminal: terminal, isDark: colorScheme == .dark, isActive: isActive)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TerminalViewRepresentable: NSViewRepresentable {
    let terminal: InteractiveTerminal
    let isDark: Bool
    var isActive: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // 进程在 AppModel.openTerminalTab() 中创建；这里只挂接既有视图，
    // 避免 representable 重建导致重复启动。
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        terminal.view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        terminal.applyAppearance(dark: isDark)
        guard let window = nsView.window else { return }
        let coordinator = context.coordinator
        if !coordinator.didApplyActiveState {
            coordinator.didApplyActiveState = true
            coordinator.wasActive = isActive
            if !isActive, window.firstResponder === nsView {
                window.makeFirstResponder(nil)
            }
            return
        }
        let becameActive = isActive && !coordinator.wasActive
        coordinator.wasActive = isActive
        if !isActive {
            if window.firstResponder === nsView {
                window.makeFirstResponder(nil)
            }
            return
        }
        if becameActive, window.firstResponder == nil {
            window.makeFirstResponder(nsView)
        }
    }

    final class Coordinator {
        var wasActive = false
        var didApplyActiveState = false
    }
}

/// SwiftTerm 用单一 NSFont 画格子，缺字形就是 □/?，不会走系统级联。
/// p10k / starship 的分段图标在 Nerd Font 私用区，SF Mono 没有。
private enum TerminalTypeface {
    private static let size: CGFloat = 12

    /// PostScript 名或族名，MesloLGS NF 是 p10k 官方字体。
    private static let preferredNames = [
        "MesloLGS NF",
        "MesloLGS-NF-Regular",
        "JetBrainsMono Nerd Font Mono",
        "JetBrainsMonoNFM-Regular",
        "JetBrainsMonoNL Nerd Font Mono",
        "JetBrainsMonoNLNFM-Regular",
        "Hack Nerd Font Mono",
        "FiraCode Nerd Font Mono",
        "CaskaydiaCove Nerd Font Mono",
        "SauceCodePro Nerd Font Mono",
        "JetBrainsMono Nerd Font",
        "JetBrainsMonoNF-Regular",
        "Menlo",
    ]

    static func resolve(size: CGFloat = size) -> NSFont {
        for name in preferredNames {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        if let family = firstInstalledFamily(matching: { $0.localizedCaseInsensitiveContains("Nerd Font Mono") }),
           let font = font(inFamily: family, size: size) {
            return font
        }
        if let family = firstInstalledFamily(matching: { family in
            let lower = family.lowercased()
            return lower.contains("nerd font") || lower.hasSuffix(" nf")
        }), let font = font(inFamily: family, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func firstInstalledFamily(matching predicate: (String) -> Bool) -> String? {
        NSFontManager.shared.availableFontFamilies.first(where: predicate)
    }

    private static func font(inFamily family: String, size: CGFloat) -> NSFont? {
        NSFontManager.shared.font(withFamily: family, traits: .fixedPitchFontMask, weight: 5, size: size)
            ?? NSFont(name: family, size: size)
    }
}
