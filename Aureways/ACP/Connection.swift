import Foundation

struct ACPLaunch: Sendable {
    var command: String
    var arguments: [String]
    var cwd: String
    var environment: [String: String]
}

struct ACPHandlers: Sendable {
    var onUpdate: @Sendable (SessionNotification) async -> Void
    var onPermission: @Sendable (PermissionPrompt) async -> PermissionDecision
    var onLog: @Sendable (String) async -> Void
    var onFileOp: (@Sendable (String, String) async -> Void)? = nil
}

actor ACPConnection {
    private let process: Process
    private let stdinHandle: FileHandle
    private let handlers: ACPHandlers
    private let fileOps: FileOps
    private let terminals: TerminalHost
    private var nextID: Int64 = 1
    private var pending: [JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private var closed = false
    private var stdoutFinished = false
    private var pendingExitCode: Int32?

    nonisolated static func launch(_ launch: ACPLaunch, handlers: ACPHandlers) throws -> ACPConnection {
        guard let resolved = HostEnvironment.resolveExecutable(launch.command, environment: launch.environment) else {
            throw ACPError.launch("Command not found: \(launch.command)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = URL(fileURLWithPath: launch.cwd)
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        return ACPConnection(
            process: process,
            stdinHandle: stdin.fileHandleForWriting,
            stdout: stdout,
            stderr: stderr,
            handlers: handlers,
            environment: launch.environment,
            workspace: launch.cwd
        )
    }

    private init(
        process: Process,
        stdinHandle: FileHandle,
        stdout: Pipe,
        stderr: Pipe,
        handlers: ACPHandlers,
        environment: [String: String],
        workspace: String
    ) {
        self.process = process
        self.stdinHandle = stdinHandle
        self.handlers = handlers
        self.fileOps = FileOps(workspace: workspace)
        self.terminals = TerminalHost(environment: environment)
        Task { await self.readLines(from: stdout.fileHandleForReading, asLog: false) }
        Task { await self.readLines(from: stderr.fileHandleForReading, asLog: true) }
        process.terminationHandler = { [weak self] proc in
            Task { await self?.handleExit(code: proc.terminationStatus) }
        }
    }

    func initialize() async throws -> InitializeResponse {
        let result = try await request("initialize", params: encodeJSON(InitializeRequest()))
        let data = try result.encode()
        return try JSONDecoder.acp.decode(InitializeResponse.self, from: data)
    }

    func newSession(cwd: String, yolo: Bool) async throws -> NewSessionResponse {
        var requestBody = NewSessionRequest(cwd: cwd)
        if yolo {
            requestBody.meta = ["yoloMode": .bool(true)]
        }
        let result = try await request("session/new", params: encodeJSON(requestBody))
        let data = try result.encode()
        return try JSONDecoder.acp.decode(NewSessionResponse.self, from: data)
    }

    func prompt(sessionId: String, text: String) async throws -> PromptResponse {
        let body = PromptRequest(sessionId: sessionId, prompt: [.text(text)])
        let result = try await request("session/prompt", params: encodeJSON(body))
        let data = try result.encode()
        return try JSONDecoder.acp.decode(PromptResponse.self, from: data)
    }

    func cancel(sessionId: String) async {
        try? await notify("session/cancel", params: encodeJSON(CancelNotification(sessionId: sessionId)))
    }

    func authenticate(methodId: String) async throws {
        _ = try await request(
            "authenticate",
            params: .object(["methodId": .string(methodId)])
        )
    }

    func shutdown() async {
        closed = true
        await terminals.shutdown()
        failPending(ACPError.transportClosed("connection closed"))
        if process.isRunning {
            process.terminate()
        }
        try? stdinHandle.close()
    }

    private func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        let id = JSONRPCID.number(nextID)
        nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                pending[id] = continuation
                Task {
                    do {
                        try await self.write(.request(id: id, method: method, params: params))
                    } catch {
                        await self.finishPending(id: id, .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { await self.finishPending(id: id, .failure(CancellationError())) }
        }
    }

    private func notify(_ method: String, params: JSONValue?) async throws {
        try await write(.notification(method: method, params: params))
    }

    private func write(_ message: JSONRPCMessage) async throws {
        if closed {
            throw ACPError.transportClosed("agent process is not running")
        }
        let line = try message.line() + "\n"
        guard let data = line.data(using: .utf8) else {
            throw ACPError.invalidJSON("utf-8 encode failed")
        }
        try stdinHandle.write(contentsOf: data)
    }

    private func readLines(from handle: FileHandle, asLog: Bool) async {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    if !buffer.isEmpty {
                        let line = String(data: buffer, encoding: .utf8) ?? String(decoding: buffer, as: UTF8.self)
                        continuation.yield(line)
                    }
                    break
                }
                buffer.append(chunk)
                while let range = buffer.range(of: Data("\n".utf8)) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                    buffer.removeSubrange(..<range.upperBound)
                    let line = String(data: lineData, encoding: .utf8) ?? String(decoding: lineData, as: UTF8.self)
                    continuation.yield(line)
                }
            }
            continuation.finish()
        }
        for await line in stream {
            if asLog {
                await handlers.onLog(line)
            } else {
                await dispatch(line)
            }
        }
        if !asLog {
            stdoutFinished = true
            await handleExit(code: pendingExitCode ?? process.terminationStatus)
        }
    }

    private func dispatch(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let message = try JSONRPCMessage.parse(line: trimmed)
            switch message {
            case .response(let id, let result):
                finishPending(id: id, .success(result))
            case .error(let id, let code, let message, _):
                if let id {
                    finishPending(id: id, .failure(ACPError.agent(code, message)))
                } else {
                    await handlers.onLog("agent error \(code): \(message)")
                }
            case .notification(let method, let params):
                await handleNotification(method, params: params)
            case .request(let id, let method, let params):
                Task { await self.handleRequest(id: id, method: method, params: params) }
            }
        } catch {
            await handlers.onLog("skip line: \(error.localizedDescription) — \(trimmed.prefix(180))")
        }
    }

    private func handleNotification(_ method: String, params: JSONValue?) async {
        guard method == "session/update", let params, let notification = SessionNotification(json: params) else {
            if let method = Optional(method), method.hasPrefix("x.ai/") {
                await handlers.onLog(method)
            }
            return
        }
        await handlers.onUpdate(notification)
    }

    private func handleRequest(id: JSONRPCID, method: String, params: JSONValue?) async {
        do {
            let result = try await perform(method: method, params: params ?? .object([:]))
            try await write(.response(id: id, result: result))
        } catch {
            let message = error.localizedDescription
            try? await write(.error(id: id, code: -32000, message: message, data: nil))
        }
    }

    private func perform(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "session/request_permission":
            guard let prompt = PermissionPrompt(json: params) else {
                throw ACPError.invalidJSON("malformed permission request")
            }
            let decision = await handlers.onPermission(prompt)
            return decision.json
        case "fs/read_text_file":
            guard let path = params["path"]?.stringValue else {
                throw ACPError.invalidJSON("missing path")
            }
            let line = params["line"]?.int64Value.map(Int.init)
            let limit = params["limit"]?.int64Value.map(Int.init)
            let content = try await fileOps.readText(path: path, line: line, limit: limit)
            await handlers.onFileOp?("read", path)
            return .object(["content": .string(content)])
        case "fs/write_text_file":
            guard let path = params["path"]?.stringValue, let content = params["content"]?.stringValue else {
                throw ACPError.invalidJSON("missing path or content")
            }
            try await fileOps.writeText(path: path, content: content)
            await handlers.onFileOp?("write", path)
            return .object([:])
        case "terminal/create":
            return try await terminals.create(params: params)
        case "terminal/output":
            guard let id = params["terminalId"]?.stringValue else {
                throw ACPError.invalidJSON("missing terminalId")
            }
            return try await terminals.output(id: id)
        case "terminal/wait_for_exit":
            guard let id = params["terminalId"]?.stringValue else {
                throw ACPError.invalidJSON("missing terminalId")
            }
            return try await terminals.wait(id: id)
        case "terminal/kill":
            guard let id = params["terminalId"]?.stringValue else {
                throw ACPError.invalidJSON("missing terminalId")
            }
            return await terminals.kill(id: id)
        case "terminal/release":
            guard let id = params["terminalId"]?.stringValue else {
                throw ACPError.invalidJSON("missing terminalId")
            }
            return await terminals.release(id: id)
        default:
            throw ACPError.agent(-32601, "Method not found: \(method)")
        }
    }

    private func handleExit(code: Int32) async {
        if !stdoutFinished {
            pendingExitCode = code
            return
        }
        guard !closed else { return }
        closed = true
        await terminals.shutdown()
        failPending(ACPError.transportClosed("agent exited (\(code))"))
        await handlers.onLog("agent exited with status \(code)")
    }

    private func finishPending(id: JSONRPCID, _ result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func failPending(_ error: Error) {
        let continuations = pending
        pending.removeAll()
        continuations.values.forEach { $0.resume(throwing: error) }
    }
}
