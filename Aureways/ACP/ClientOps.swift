import Foundation

actor FileOps {
    private let workspace: URL

    init(workspace: String) {
        self.workspace = URL(fileURLWithPath: workspace, isDirectory: true).standardizedFileURL
    }

    func readText(path: String, line: Int?, limit: Int?) throws -> String {
        let url = try resolve(path)
        var text = try String(contentsOf: url, encoding: .utf8)
        if let line, line > 1 {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let start = min(max(line - 1, 0), lines.count)
            text = lines.dropFirst(start).joined(separator: "\n")
        }
        if let limit, limit >= 0 {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            text = lines.prefix(limit).joined(separator: "\n")
        }
        return text
    }

    func writeText(path: String, content: String) throws {
        let url = try resolve(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func resolve(_ path: String) throws -> URL {
        let url: URL
        if (path as NSString).isAbsolutePath {
            url = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            url = URL(fileURLWithPath: path, relativeTo: workspace).standardizedFileURL
        }
        let root = workspace.path
        let candidate = url.path
        if candidate == root { return url }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard candidate.hasPrefix(prefix) else {
            throw ACPError.agent(-32602, "path is outside the workspace")
        }
        return url
    }
}

final class AgentTerminal: @unchecked Sendable {
    let id: String
    let process: Process
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var truncated = false
    private var byteLimit: Int
    private var exitCode: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(id: String, command: String, arguments: [String], cwd: String?, env: [String: String], byteLimit: Int) throws {
        self.id = id
        self.byteLimit = max(byteLimit, 1024)
        process = Process()
        let resolved = HostEnvironment.resolveExecutable(command, environment: env) ?? command
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = arguments
        process.environment = env
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let state = self
        stdout.fileHandleForReading.readabilityHandler = { reader in
            let data = reader.availableData
            if data.isEmpty {
                reader.readabilityHandler = nil
                return
            }
            state.append(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { reader in
            let data = reader.availableData
            if data.isEmpty {
                reader.readabilityHandler = nil
                return
            }
            state.append(data)
        }

        process.terminationHandler = { proc in
            state.didExit(proc.terminationStatus)
        }
        try process.run()
    }

    private func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > byteLimit {
            buffer = buffer.suffix(byteLimit)
            truncated = true
        }
    }

    private func didExit(_ code: Int32) {
        lock.lock()
        exitCode = code
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: code) }
    }

    func snapshot() -> (output: String, truncated: Bool, exitCode: Int32?) {
        lock.lock()
        defer { lock.unlock() }
        let output = String(data: buffer, encoding: .utf8) ?? String(decoding: buffer, as: UTF8.self)
        return (output, truncated, exitCode)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            enqueueWaiter(continuation)
        }
    }

    private func enqueueWaiter(_ continuation: CheckedContinuation<Int32, Never>) {
        lock.lock()
        if let exitCode {
            lock.unlock()
            continuation.resume(returning: exitCode)
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }

    func kill() {
        if process.isRunning {
            process.terminate()
        }
    }
}

actor TerminalHost {
    private var terminals: [String: AgentTerminal] = [:]
    private let environment: [String: String]

    init(environment: [String: String]) {
        self.environment = environment
    }

    func create(params: JSONValue) throws -> JSONValue {
        let command = params["command"]?.stringValue ?? "/bin/zsh"
        let args = params["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let cwd = params["cwd"]?.stringValue
        let limit = params["outputByteLimit"]?.int64Value.map(Int.init) ?? 1024 * 1024
        var env = environment
        if let extra = params["env"]?.arrayValue {
            for item in extra {
                if let name = item["name"]?.stringValue, let value = item["value"]?.stringValue {
                    env[name] = value
                }
            }
        }
        let id = UUID().uuidString
        let terminal = try AgentTerminal(id: id, command: command, arguments: args, cwd: cwd, env: env, byteLimit: limit)
        terminals[id] = terminal
        return .object(["terminalId": .string(id)])
    }

    func output(id: String) throws -> JSONValue {
        guard let terminal = terminals[id] else {
            throw ACPError.agent(-32602, "unknown terminal")
        }
        let snap = terminal.snapshot()
        var object: [String: JSONValue] = [
            "output": .string(snap.output),
            "truncated": .bool(snap.truncated),
        ]
        if let code = snap.exitCode {
            object["exitStatus"] = .object(["exitCode": .number(Double(code))])
        }
        return .object(object)
    }

    func wait(id: String) async throws -> JSONValue {
        guard let terminal = terminals[id] else {
            throw ACPError.agent(-32602, "unknown terminal")
        }
        let code = await terminal.wait()
        return .object(["exitCode": .number(Double(code))])
    }

    func kill(id: String) -> JSONValue {
        terminals[id]?.kill()
        return .object([:])
    }

    func release(id: String) -> JSONValue {
        terminals[id]?.kill()
        terminals[id] = nil
        return .object([:])
    }

    func shutdown() {
        for terminal in terminals.values {
            terminal.kill()
        }
        terminals.removeAll()
    }
}
