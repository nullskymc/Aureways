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
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    func start() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = HostEnvironment.augmented()
        env["TERM"] = "xterm-256color"
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

    var body: some View {
        TerminalViewRepresentable(terminal: terminal, isDark: colorScheme == .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TerminalViewRepresentable: NSViewRepresentable {
    let terminal: InteractiveTerminal
    let isDark: Bool

    // 进程在 AppModel.openTerminalTab() 中创建；这里只挂接既有视图，
    // 避免 representable 重建导致重复启动。
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        terminal.view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        terminal.applyAppearance(dark: isDark)
    }
}
