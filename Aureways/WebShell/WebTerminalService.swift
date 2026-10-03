import Foundation
import SwiftTerm

/// PTY-backed shells for the web inspector's terminal tabs. SwiftTerm is used
/// headless (`LocalProcess` only); xterm.js renders in the web view. Output is
/// coalesced (~8 ms) and sent as base64 so arbitrary bytes survive JSON.
@MainActor
final class WebTerminalService {
    @MainActor
    final class Session: LocalProcessDelegate {
        let id: String
        let cwd: String
        var process: LocalProcess!
        /// Read by LocalProcess from its own queue; written on main before resize ioctl.
        nonisolated(unsafe) var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        weak var owner: WebTerminalService?
        private var pending = Data()
        private var flushScheduled = false

        init(id: String, cwd: String) {
            self.id = id
            self.cwd = cwd
        }

        nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.flush()
                    self.owner?.terminated(self, code: exitCode)
                }
            }
        }

        nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
            let chunk = Data(slice)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.enqueue(chunk) }
            }
        }

        nonisolated func getWindowSize() -> winsize { size }

        private func enqueue(_ chunk: Data) {
            pending.append(chunk)
            guard !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
                MainActor.assumeIsolated { self?.flush() }
            }
        }

        func flush() {
            flushScheduled = false
            guard !pending.isEmpty else { return }
            let data = pending
            pending = Data()
            owner?.emit(["type": "termData", "id": id, "data": data.base64EncodedString()])
        }
    }

    private var sessions: [String: Session] = [:]
    private var counter = 0
    var onEmit: ([String: Any]) -> Void = { _ in }

    fileprivate func emit(_ payload: [String: Any]) { onEmit(payload) }

    func open(cwd: String, cols: Int, rows: Int) -> [String: Any] {
        counter += 1
        let id = UUID().uuidString
        let session = Session(id: id, cwd: cwd)
        session.owner = self
        session.size = winsize(ws_row: UInt16(clamping: max(rows, 2)), ws_col: UInt16(clamping: max(cols, 10)), ws_xpixel: 0, ws_ypixel: 0)
        session.process = LocalProcess(delegate: session)
        sessions[id] = session

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = HostEnvironment.augmented()
        env["TERM"] = "xterm-256color"
        if env["COLORTERM"]?.isEmpty != false { env["COLORTERM"] = "truecolor" }
        // GUI launches often lack LANG; zsh/p10k then fall back to ASCII.
        if env["LANG"]?.isEmpty != false { env["LANG"] = "en_US.UTF-8" }
        if env["LC_CTYPE"]?.isEmpty != false { env["LC_CTYPE"] = env["LANG"] ?? "en_US.UTF-8" }
        env["TERM_PROGRAM"] = "Aureways"
        let environment = env.map { "\($0.key)=\($0.value)" }
        // A leading "-" in argv[0] makes it a login shell (reads .zprofile).
        let execName = "-" + URL(fileURLWithPath: shell).lastPathComponent
        session.process.startProcess(executable: shell, environment: environment, execName: execName, currentDirectory: cwd)
        return ["id": id, "index": counter, "shell": URL(fileURLWithPath: shell).lastPathComponent]
    }

    func input(id: String, data: String) {
        guard let session = sessions[id] else { return }
        let bytes = Array(data.utf8)
        session.process.send(data: bytes[...])
    }

    func resize(id: String, cols: Int, rows: Int) {
        guard let session = sessions[id], cols > 0, rows > 0 else { return }
        session.size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        let fd = session.process.childfd
        guard fd >= 0 else { return }
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: fd, windowSize: &session.size)
    }

    func close(id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        if session.process.running { session.process.terminate() }
    }

    func closeAll() {
        for id in Array(sessions.keys) { close(id: id) }
    }

    fileprivate func terminated(_ session: Session, code: Int32?) {
        guard sessions[session.id] != nil else { return }
        sessions[session.id] = nil
        emit(["type": "termExit", "id": session.id, "code": code.map { Int($0) } ?? NSNull()])
    }
}
