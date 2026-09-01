import Foundation

extension AppModel {
    func connectNew(_ session: ChatSession) async {
        session.phase = .connecting
        session.log("Launching \(session.agent.title)")
        do {
            let runtime = try await ensureRuntime(session.agent)
            session.agentInfo = runtime.agentInfo
            guard let connection = runtime.connection else {
                throw ACPError.launch("Agent process is not running")
            }
            await connection.allowWorkspace(session.cwd)
            let created = try await connection.newSession(
                cwd: session.cwd,
                meta: runtime.harness.sessionMeta(autoApprove: autoApprove)
            )
            guard !session.isClosed else { return }
            session.applySetup(sessionId: created.sessionId, modes: created.modes, configOptions: created.configOptions)
            session.phase = .ready
            persistIfNeeded(session)
        } catch {
            fail(session, error)
        }
    }

    func openExisting(_ session: ChatSession) async {
        guard let acpId = session.acpSessionId else { return }
        session.phase = .connecting
        session.log("Loading \(session.agent.title) session")
        do {
            let runtime = try await ensureRuntime(session.agent)
            session.agentInfo = runtime.agentInfo
            guard runtime.canLoad else {
                throw ACPError.launch("This agent does not support restoring sessions")
            }
            guard let connection = runtime.connection else {
                throw ACPError.launch("Agent process is not running")
            }
            session.resetTranscript()
            session.isReplaying = true
            defer { session.isReplaying = false }
            await connection.allowWorkspace(session.cwd)
            let loaded = try await connection.loadSession(
                sessionId: acpId,
                cwd: session.cwd,
                meta: runtime.harness.sessionMeta(autoApprove: autoApprove)
            )
            guard !session.isClosed else { return }
            session.applySetup(sessionId: loaded.sessionId ?? acpId, modes: loaded.modes, configOptions: loaded.configOptions)
            session.phase = .ready
            persistIfNeeded(session)
        } catch {
            fail(session, error)
        }
    }

    func reopen(_ session: ChatSession) async {
        session.phase = .connecting
        do {
            let runtime = try await ensureRuntime(session.agent)
            session.agentInfo = runtime.agentInfo
            guard let connection = runtime.connection else {
                throw ACPError.launch("Agent process is not running")
            }
            if let acpId = session.acpSessionId {
                guard runtime.canLoad else {
                    throw ACPError.launch("This agent does not support restoring sessions")
                }
                session.resetTranscript()
                session.isReplaying = true
                defer { session.isReplaying = false }
                await connection.allowWorkspace(session.cwd)
                let loaded = try await connection.loadSession(
                    sessionId: acpId,
                    cwd: session.cwd,
                    meta: runtime.harness.sessionMeta(autoApprove: autoApprove)
                )
                session.applySetup(sessionId: loaded.sessionId ?? acpId, modes: loaded.modes, configOptions: loaded.configOptions)
                session.phase = .ready
            } else {
                await connection.allowWorkspace(session.cwd)
                let created = try await connection.newSession(
                    cwd: session.cwd,
                    meta: runtime.harness.sessionMeta(autoApprove: autoApprove)
                )
                session.applySetup(sessionId: created.sessionId, modes: created.modes, configOptions: created.configOptions)
                session.phase = .ready
                persistIfNeeded(session)
            }
        } catch {
            fail(session, error)
        }
    }

    func enqueuePrompt(_ session: ChatSession, message: OutgoingMessage, reconnect: Bool = false) {
        session.promptTask?.cancel()
        session.promptTask = Task {
            if reconnect {
                if session.acpSessionId != nil {
                    await openExisting(session)
                    guard !Task.isCancelled, !session.isClosed else { return }
                    guard session.phase.isReady else {
                        // 连接失败也要把用户这条消息留在界面上，避免静默丢失。
                        session.appendUser(message.text, attachments: message.attachments)
                        return
                    }
                    session.appendUser(message.text, attachments: message.attachments)
                    persistIfNeeded(session)
                } else {
                    await connectNew(session)
                }
            }
            guard !Task.isCancelled, !session.isClosed, session.phase.isReady else { return }
            await prompt(session, message: message)
        }
    }

    func prompt(_ session: ChatSession, message: OutgoingMessage) async {
        guard let acpId = session.acpSessionId, session.phase.isReady else { return }
        guard let connection = await liveConnection(for: session.agent) else {
            fail(session, ACPError.transportClosed("连接已断开"))
            session.items.append(.status(UUID(), "连接已断开，发送消息可重新连接"))
            session.transcriptRevision += 1
            return
        }
        session.isStreaming = true
        defer { session.isStreaming = false }
        do {
            let response = try await connection.prompt(sessionId: acpId, prompt: message.contentBlocks())
            session.finalizeOpenToolCalls("completed")
            if let reason = response.stopReason {
                session.items.append(.status(UUID(), "Stop: \(reason)"))
            }
            persistIfNeeded(session)
        } catch is CancellationError {
            session.finalizeOpenToolCalls("cancelled")
            session.items.append(.status(UUID(), "Stop: cancelled"))
        } catch {
            session.finalizeOpenToolCalls("cancelled")
            session.items.append(.status(UUID(), error.localizedDescription))
            session.transcriptRevision += 1
        }
    }

    func pullList(from runtime: HarnessRuntime) async {
        guard runtime.canList, let connection = runtime.connection else { return }
        do {
            let listed = try await connection.listSessions()
            let listedById = Dictionary(listed.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
            for session in sessions where session.agent.id == runtime.agent.id {
                guard let acpId = session.acpSessionId, let remote = listedById[acpId] else { continue }
                if let title = remote.title, !title.isEmpty {
                    session.title = title
                }
                persistIfNeeded(session)
            }
        } catch {
            // List only refreshes titles for sessions this client already created.
        }
    }

    func persistIfNeeded(_ session: ChatSession) {
        guard let acpId = session.acpSessionId else { return }
        guard runtimes[session.agent.id]?.canPersistHistory == true else { return }
        let link = SessionLink(
            agentId: session.agent.id,
            acpSessionId: acpId,
            cwd: session.cwd,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: Date()
        )
        try? store?.upsert(link)
    }

    func fail(_ session: ChatSession, _ error: Error) {
        session.endCurrentRun()
        session.phase = .failed(error.localizedDescription)
        errorMessage = error.localizedDescription
    }

    func ensureRuntime(_ profile: AgentProfile) async throws -> HarnessRuntime {
        let runtime = runtimes[profile.id] ?? HarnessRegistry.resolve(profile).makeRuntime()
        runtimes[profile.id] = runtime
        try await runtime.ensureStarted(
            cwd: workspacePath,
            autoApprove: autoApprove,
            environment: HostEnvironment.augmented(),
            handlers: handlers(for: profile.id)
        )
        if runtime.canList, !runtime.didSyncList {
            runtime.didSyncList = true
            await pullList(from: runtime)
        }
        return runtime
    }

    func shouldKeepOnClose(_ session: ChatSession) -> Bool {
        guard let acpId = session.acpSessionId else { return false }
        if runtimes[session.agent.id]?.canPersistHistory == true { return true }
        if let rows = try? store?.list(agentId: session.agent.id) {
            return rows.contains { $0.acpSessionId == acpId }
        }
        return false
    }

    func allowWorkspaceOnRuntimes(_ path: String) async {
        for runtime in runtimes.values {
            await runtime.connection?.allowWorkspace(path)
        }
    }

    func liveConnection(for agent: AgentProfile) async -> ACPConnection? {
        guard let connection = runtimes[agent.id]?.connection, await connection.isActive() else {
            return nil
        }
        return connection
    }

    func shutdownRuntimeIfIdle(_ agentId: String) async {
        let busy = sessions.contains {
            $0.agent.id == agentId && !$0.isClosed && ($0.phase.isReady || $0.phase == .connecting || $0.isStreaming)
        }
        guard !busy else { return }
        await runtimes[agentId]?.shutdown()
    }

    func handlers(for agentId: String) -> ACPHandlers {
        let bridge = AgentBridge(agentId: agentId, model: self)
        return ACPHandlers(
            onUpdate: { notification in
                await MainActor.run { bridge.model?.applyUpdate(agentId: agentId, notification) }
            },
            onPermission: { prompt in
                await MainActor.run {
                    if let tool = prompt.toolCall {
                        bridge.model?.session(agentId: agentId, acpSessionId: prompt.sessionId)?.appendTool(tool)
                    }
                }
                if await MainActor.run(body: { bridge.model?.autoApprove ?? false }) {
                    if let option = prompt.options.first(where: \.isAllow) ?? prompt.options.first {
                        return .selected(option.optionId)
                    }
                    return .cancelled
                }
                guard let session = await MainActor.run(body: {
                    bridge.model?.session(agentId: agentId, acpSessionId: prompt.sessionId)
                }) else { return .cancelled }
                return await session.waitForPermission(prompt)
            },
            onLog: { line in
                await MainActor.run { bridge.model?.appendLog(agentId: agentId, line: line) }
            },
            onFileOp: { type, path in
                await MainActor.run { bridge.model?.appendFileOp(agentId: agentId, type: type, path: path) }
            },
            onExit: { _ in
                await MainActor.run { bridge.model?.handleRuntimeExit(agentId: agentId) }
            }
        )
    }

    func applyUpdate(agentId: String, _ notification: SessionNotification) {
        guard let session = session(agentId: agentId, acpSessionId: notification.sessionId) else { return }
        let previousTitle = session.title
        session.apply(notification)
        if session.title != previousTitle {
            persistIfNeeded(session)
        }
    }

    func session(agentId: String, acpSessionId: String) -> ChatSession? {
        sessions.first(where: { $0.agent.id == agentId && $0.acpSessionId == acpSessionId && !$0.isClosed })
    }

    func appendLog(agentId: String, line: String) {
        if let selected = selectedSession, selected.agent.id == agentId {
            selected.log(line)
            return
        }
        sessions.first(where: { $0.agent.id == agentId && $0.phase.isReady })?.log(line)
    }

    func appendFileOp(agentId: String, type: String, path: String) {
        if type == "write" {
            agentWroteFile(path)
        }
        if let selected = selectedSession, selected.agent.id == agentId {
            selected.recordFileOp(type: type, path: path)
            return
        }
        sessions.first(where: { $0.agent.id == agentId && $0.phase.isReady })?.recordFileOp(type: type, path: path)
    }

    func handleRuntimeExit(agentId: String) {
        runtimes[agentId]?.markDead()
        for session in sessions where session.agent.id == agentId && (session.phase.isReady || session.phase == .connecting) {
            session.phase = .idle
            session.isStreaming = false
            session.resumePermission(.cancelled)
        }
    }
}

private final class AgentBridge: @unchecked Sendable {
    let agentId: String
    weak var model: AppModel?

    init(agentId: String, model: AppModel) {
        self.agentId = agentId
        self.model = model
    }
}
