import AppKit
import Foundation
import QuartzCore

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
            await prepareWorkspaces(connection, session: session)
            let created = try await connection.newSession(
                cwd: session.cwd,
                additionalDirectories: additionalDirectories(for: runtime, cwd: session.cwd),
                mcpServers: mcpPayload(for: runtime.capabilities),
                meta: runtime.harness.sessionMeta(autoApprove: autoApprove)
            )
            guard !session.isClosed else { return }
            session.applySetup(
                sessionId: created.sessionId,
                modes: created.modes,
                configOptions: created.configOptions,
                mcpServers: created.mcpServers
            )
            flushSessionUpdates()
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
            await prepareWorkspaces(connection, session: session)
            let loaded = try await connection.loadSession(
                sessionId: acpId,
                cwd: session.cwd,
                additionalDirectories: additionalDirectories(for: runtime, cwd: session.cwd),
                mcpServers: mcpPayload(for: runtime.capabilities),
                meta: runtime.harness.sessionMeta(autoApprove: autoApprove)
            )
            guard !session.isClosed else { return }
            session.applySetup(
                sessionId: loaded.sessionId ?? acpId,
                modes: loaded.modes,
                configOptions: loaded.configOptions,
                mcpServers: loaded.mcpServers
            )
            flushSessionUpdates()
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
                await prepareWorkspaces(connection, session: session)
                let loaded = try await connection.loadSession(
                    sessionId: acpId,
                    cwd: session.cwd,
                    additionalDirectories: additionalDirectories(for: runtime, cwd: session.cwd),
                    mcpServers: mcpPayload(for: runtime.capabilities),
                    meta: runtime.harness.sessionMeta(autoApprove: autoApprove)
                )
                session.applySetup(
                    sessionId: loaded.sessionId ?? acpId,
                    modes: loaded.modes,
                    configOptions: loaded.configOptions,
                    mcpServers: loaded.mcpServers
                )
                flushSessionUpdates()
                session.phase = .ready
            } else {
                await prepareWorkspaces(connection, session: session)
                let created = try await connection.newSession(
                    cwd: session.cwd,
                    additionalDirectories: additionalDirectories(for: runtime, cwd: session.cwd),
                    mcpServers: mcpPayload(for: runtime.capabilities),
                    meta: runtime.harness.sessionMeta(autoApprove: autoApprove)
                )
                session.applySetup(
                    sessionId: created.sessionId,
                    modes: created.modes,
                    configOptions: created.configOptions,
                    mcpServers: created.mcpServers
                )
                flushSessionUpdates()
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
        defer {
            flushSessionUpdates()
            session.isStreaming = false
        }
        do {
            let caps = runtimes[session.agent.id]?.capabilities.promptCapabilities
            let response = try await connection.prompt(sessionId: acpId, prompt: message.contentBlocks(promptCapabilities: caps))
            flushSessionUpdates()
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
                if !remote.mcpServers.isEmpty {
                    session.reportedMcpServers = remote.mcpServers
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

    func prepareWorkspaces(_ connection: ACPConnection, session: ChatSession) async {
        await connection.allowWorkspace(session.cwd)
        for path in extraWorkspaceRoots(besides: session.cwd) {
            await connection.allowWorkspace(path)
        }
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
        let inbox = sessionUpdateInbox
        let bridge = AgentBridge(agentId: agentId, model: self)
        return ACPHandlers(
            onUpdate: { notification in
                inbox.push(SessionUpdateInbox.Event(agentId: agentId, notification: notification))
                DispatchQueue.main.async {
                    AppModel.shared?.armSessionUpdatePump()
                }
            },
            onPermission: { prompt in
                await MainActor.run {
                    bridge.model?.flushSessionUpdates()
                    if let tool = prompt.toolCall {
                        bridge.model?.session(agentId: agentId, acpSessionId: prompt.sessionId)?.appendTool(tool)
                    }
                }
                if await MainActor.run(body: { bridge.model?.autoApprove ?? false }) {
                    if let option = prompt.options.first(where: \.isAllow) ?? prompt.options.first {
                        return .selected(option.optionId)
                    }
                    // Auto-approve is on but the request carried no options we can
                    // pick. Denying silently here is indistinguishable from the
                    // tool being broken, so say so.
                    await MainActor.run {
                        bridge.model?.appendLog(
                            agentId: agentId,
                            line: "✗ permission auto-denied: request carried no options (\(prompt.title))"
                        )
                    }
                    return .cancelled
                }
                guard let session = await MainActor.run(body: {
                    bridge.model?.session(agentId: agentId, acpSessionId: prompt.sessionId)
                }) else {
                    // No session matched the id the agent used, so the prompt can
                    // never reach the UI and the turn would be denied without a
                    // trace. `acpSessionId` is reassigned from what session/load
                    // returns, so a mismatch here is the likely cause.
                    await MainActor.run {
                        let known = bridge.model?.sessions
                            .filter { $0.agent.id == agentId }
                            .map { $0.acpSessionId ?? "nil" }
                            .joined(separator: ", ") ?? ""
                        bridge.model?.appendLog(
                            agentId: agentId,
                            line: "✗ permission auto-denied: no session for id \(prompt.sessionId) (known: \(known))"
                        )
                    }
                    return .cancelled
                }
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

    func armSessionUpdatePump() {
        if sessionUpdatePulse == nil {
            let pulse = DisplayPulse()
            pulse.onTick = { [weak self] in
                self?.flushSessionUpdates()
            }
            pulse.start()
            sessionUpdatePulse = pulse
        }
    }

    func flushSessionUpdates() {
        let events = sessionUpdateInbox.take()
        if events.isEmpty {
            sessionUpdatePulse?.stop()
            sessionUpdatePulse = nil
            return
        }
        for event in SessionUpdateInbox.coalesced(events) {
            applyUpdate(agentId: event.agentId, event.notification)
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

final class SessionUpdateInbox: @unchecked Sendable {
    struct Event {
        var agentId: String
        var notification: SessionNotification
    }

    private let lock = NSLock()
    private var events: [Event] = []

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.isEmpty
    }

    func push(_ event: Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func take() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        let copy = events
        events.removeAll(keepingCapacity: true)
        return copy
    }

    static func coalesced(_ events: [Event]) -> [Event] {
        var result: [Event] = []
        result.reserveCapacity(events.count)
        for event in events {
            if let last = result.last,
               last.agentId == event.agentId,
               let merged = last.notification.merging(event.notification) {
                result[result.count - 1] = Event(agentId: last.agentId, notification: merged)
            } else {
                result.append(event)
            }
        }
        return result
    }
}

/// 按帧合并 session update，避免流式输出把主线程刷爆。
/// macOS 没有 CADisplayLink(target:selector:)，只能从 NSScreen/NSView/NSWindow 派生；
/// 拿不到屏幕（无 key window、无头环境）时退回 30Hz 定时器，否则 flush 会彻底停摆。
@MainActor
final class DisplayPulse: NSObject {
    var onTick: (() -> Void)?
    private var link: CADisplayLink?
    private var timer: Timer?

    func start() {
        guard link == nil, timer == nil else { return }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let link = screen.displayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            timer = Timer.scheduledTimer(
                timeInterval: 1.0 / 30.0,
                target: self,
                selector: #selector(tick),
                userInfo: nil,
                repeats: true
            )
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        onTick?()
    }
}
