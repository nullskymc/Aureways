import Foundation

/// Precomputed sidebar rows so each nav item does not rebuild the full
/// workspace × session filter (PERF-14).
enum SidebarListing {
    struct Snapshot {
        var filtered: [ChatSession]
        var visibleWorkspaces: [WorkspaceRecord]
        var sessionsByWorkspace: [String: [ChatSession]]
        var ordered: [ChatSession]
        var shortcutByID: [UUID: String]
    }

    struct Signature: Equatable {
        var searchQuery: String
        var workspacePaths: [String]
        var sessions: [SessionBit]

        struct SessionBit: Equatable {
            var id: UUID
            var isClosed: Bool
            var title: String
            var agentTitle: String
            var cwd: String
        }

        @MainActor
        init(sessions: [ChatSession], workspaces: [WorkspaceRecord], searchQuery: String) {
            self.searchQuery = searchQuery
            self.workspacePaths = workspaces.map(\.path)
            self.sessions = sessions.map {
                SessionBit(
                    id: $0.id,
                    isClosed: $0.isClosed,
                    title: $0.title,
                    agentTitle: $0.agent.title,
                    cwd: $0.cwd
                )
            }
        }
    }

    @MainActor
    static func make(
        sessions: [ChatSession],
        workspaces: [WorkspaceRecord],
        searchQuery: String
    ) -> Snapshot {
        let open = sessions.filter { !$0.isClosed }
        let filtered: [ChatSession]
        if searchQuery.isEmpty {
            filtered = open
        } else {
            filtered = open.filter {
                $0.title.localizedCaseInsensitiveContains(searchQuery) ||
                $0.agent.title.localizedCaseInsensitiveContains(searchQuery) ||
                $0.cwd.localizedCaseInsensitiveContains(searchQuery)
            }
        }

        var sessionsByWorkspace: [String: [ChatSession]] = [:]
        sessionsByWorkspace.reserveCapacity(workspaces.count)
        for session in filtered {
            let key = WorkspaceRecord.normalized(session.cwd)
            sessionsByWorkspace[key, default: []].append(session)
        }

        let visible: [WorkspaceRecord]
        if searchQuery.isEmpty {
            visible = workspaces
        } else {
            visible = workspaces.filter { workspace in
                let key = WorkspaceRecord.normalized(workspace.path)
                return !(sessionsByWorkspace[key] ?? []).isEmpty
                    || workspace.name.localizedCaseInsensitiveContains(searchQuery)
            }
        }

        var ordered: [ChatSession] = []
        ordered.reserveCapacity(filtered.count)
        var groupedIDs = Set<UUID>()
        groupedIDs.reserveCapacity(filtered.count)
        for workspace in visible {
            let key = WorkspaceRecord.normalized(workspace.path)
            let grouped = sessionsByWorkspace[key] ?? []
            ordered.append(contentsOf: grouped)
            for session in grouped { groupedIDs.insert(session.id) }
        }
        for session in filtered where !groupedIDs.contains(session.id) {
            ordered.append(session)
        }

        var shortcutByID: [UUID: String] = [:]
        for (index, session) in ordered.prefix(9).enumerated() {
            shortcutByID[session.id] = "⌘\(index + 1)"
        }

        return Snapshot(
            filtered: filtered,
            visibleWorkspaces: visible,
            sessionsByWorkspace: sessionsByWorkspace,
            ordered: ordered,
            shortcutByID: shortcutByID
        )
    }
}

extension AppModel {
    func canDelete(_ session: ChatSession) -> Bool {
        runtimes[session.agent.id]?.canDelete == true
    }

    func select(_ session: ChatSession) {
        switchSelectedSession(to: session.id)
        if session.phase == .idle, session.acpSessionId != nil {
            Task { await openExisting(session) }
        }
    }

    func startNewSession(agent: AgentProfile? = nil) {
        if let agent {
            selectedAgentId = agent.id
        }
        errorMessage = nil
        switchSelectedSession(to: nil)
    }

    /// 在指定工作区开启新对话：切换当前工作区后回到新建对话落地页。
    func startNewSession(inWorkspace path: String) {
        selectWorkspace(path)
        startNewSession()
    }

    func sendFromComposer(text: String, attachments: [ComposerAttachment] = [], agent: AgentProfile? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = OutgoingMessage(
            text: trimmed,
            attachments: attachments.map(\.transcriptAttachment)
        )
        guard !message.isEmpty else { return }

        if let session = selectedSession {
            switch session.phase {
            case .connecting:
                return
            case .ready:
                session.appendUser(message.text, attachments: message.attachments)
                persistIfNeeded(session)
                enqueuePrompt(session, message: message)
                return
            case .idle, .failed:
                enqueuePrompt(session, message: message, reconnect: true)
                return
            }
        }

        let targetAgent = agent ?? selectedAgent
        selectedAgentId = targetAgent.id
        let session = ChatSession(agent: targetAgent, cwd: workspacePath, phase: .connecting)
        sessions.insert(session, at: 0)
        adoptInspectorForNewSession(session.id)
        selectedSessionID = session.id
        session.appendUser(message.text, attachments: message.attachments)
        enqueuePrompt(session, message: message, reconnect: true)
    }

    func retry(_ session: ChatSession) {
        session.promptTask?.cancel()
        session.promptTask = nil
        Task { await reopen(session) }
    }

    func cancel() {
        guard let session = selectedSession else { return }
        session.promptTask?.cancel()
        session.promptTask = nil
        session.isStreaming = false
        session.resumeBlockingPrompts()
        guard let acpId = session.acpSessionId else { return }
        Task {
            if let connection = await liveConnection(for: session.agent) {
                await connection.cancel(sessionId: acpId)
            }
        }
    }

    func close(_ session: ChatSession) {
        session.promptTask?.cancel()
        session.promptTask = nil
        session.resumeBlockingPrompts()
        session.isStreaming = false
        if let acpId = session.acpSessionId {
            Task {
                if let connection = await liveConnection(for: session.agent) {
                    await connection.cancel(sessionId: acpId)
                }
            }
        }

        let persist = shouldKeepOnClose(session)
        if persist {
            session.isClosed = false
            session.isReplaying = false
            session.resetTranscript()
            session.phase = .idle
        } else {
            session.isClosed = true
            sessions.removeAll { $0.id == session.id }
        }
        if selectedSessionID == session.id {
            let next = persist ? session.id : sessions.first(where: { $0.id != session.id && !$0.isClosed })?.id
            switchSelectedSession(to: next)
        }
        if !persist {
            discardInspectorState(session.id)
        }
        Task { await shutdownRuntimeIfIdle(session.agent.id) }
    }

    func forget(_ session: ChatSession) {
        session.promptTask?.cancel()
        session.promptTask = nil
        session.resumeBlockingPrompts()
        session.isClosed = true
        if let acpId = session.acpSessionId {
            try? store?.delete(agentId: session.agent.id, acpSessionId: acpId)
        }
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            switchSelectedSession(to: sessions.first(where: { $0.id != session.id && !$0.isClosed })?.id)
        }
        discardInspectorState(session.id)
        Task { await shutdownRuntimeIfIdle(session.agent.id) }
    }

    func delete(_ session: ChatSession) {
        guard canDelete(session), let acpId = session.acpSessionId else { return }
        session.promptTask?.cancel()
        session.promptTask = nil
        session.resumeBlockingPrompts()
        session.isClosed = true
        Task {
            do {
                let runtime = try await ensureRuntime(session.agent)
                guard let connection = runtime.connection else { return }
                try await connection.deleteSession(sessionId: acpId)
                try? store?.delete(agentId: session.agent.id, acpSessionId: acpId)
                sessions.removeAll { $0.id == session.id }
                if selectedSessionID == session.id {
                    switchSelectedSession(to: sessions.first(where: { $0.id != session.id && !$0.isClosed })?.id)
                }
                discardInspectorState(session.id)
                await shutdownRuntimeIfIdle(session.agent.id)
            } catch {
                session.isClosed = false
                session.phase = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectSessionByIndex(_ index: Int) {
        let flat = sidebarOrderedSessions
        if index >= 0 && index < flat.count {
            select(flat[index])
        }
    }

    var filteredSessions: [ChatSession] {
        resolvedSidebarListing().filtered
    }

    func sessions(inWorkspace path: String) -> [ChatSession] {
        let key = WorkspaceRecord.normalized(path)
        return resolvedSidebarListing().sessionsByWorkspace[key] ?? []
    }

    /// ⌘N / 悬停徽标使用的会话顺序：与侧栏一致——按工作区分组展开后的扁平序。
    /// cwd 不在任何已登记工作区（如主目录）的会话排在末尾，保证仍可被快捷键选中。
    var sidebarOrderedSessions: [ChatSession] {
        resolvedSidebarListing().ordered
    }

    var visibleWorkspaces: [WorkspaceRecord] {
        resolvedSidebarListing().visibleWorkspaces
    }

    func sessionShortcut(for session: ChatSession) -> String? {
        resolvedSidebarListing().shortcutByID[session.id]
    }

    private func resolvedSidebarListing() -> SidebarListing.Snapshot {
        let signature = SidebarListing.Signature(
            sessions: sessions,
            workspaces: workspaces,
            searchQuery: searchQuery
        )
        if let cache = sidebarListingCache, cache.signature == signature {
            return cache.snapshot
        }
        let snapshot = SidebarListing.make(
            sessions: sessions,
            workspaces: workspaces,
            searchQuery: searchQuery
        )
        sidebarListingCache = (signature, snapshot)
        return snapshot
    }

    func setSessionMode(_ session: ChatSession, modeId: String) {
        guard let acpId = session.acpSessionId else { return }
        if let option = session.configOptions.first(where: \.isMode) {
            session.applyConfigOption(id: option.id, value: .string(modeId))
        }
        if var modes = session.modes {
            modes.currentModeId = modeId
            session.modes = modes
        } else if !session.modeChoices.isEmpty {
            session.modes = SessionModeState(currentModeId: modeId, availableModes: session.modeChoices)
        }
        Task {
            guard let connection = await liveConnection(for: session.agent) else { return }
            do {
                if session.configOptions.contains(where: \.isMode) {
                    let options = try await connection.setConfigOption(sessionId: acpId, configId: session.configOptions.first(where: \.isMode)?.id ?? "mode", value: .string(modeId))
                    session.replaceConfigOptions(options)
                } else {
                    try await connection.setMode(sessionId: acpId, modeId: modeId)
                }
            } catch {
                session.log("Failed to set mode: \(error.localizedDescription)")
            }
        }
    }

    func setSessionConfig(_ session: ChatSession, configId: String, value: JSONValue) {
        guard let acpId = session.acpSessionId else { return }
        session.applyConfigOption(id: configId, value: value)
        Task {
            guard let connection = await liveConnection(for: session.agent) else { return }
            do {
                let option = session.configOptions.first(where: { $0.id == configId })
                let harness = HarnessRegistry.resolve(session.agent)
                if let option, harness.usesSetModel(for: option, advertisedConfigOptions: session.advertisedConfigOptions) {
                    let modelId = session.modelOption?.selectedString ?? session.models?.currentModelId
                    guard let modelId, !modelId.isEmpty else { return }
                    try await connection.setModel(
                        sessionId: acpId,
                        modelId: modelId,
                        reasoningEffort: session.thoughtLevelOption?.selectedString
                    )
                } else {
                    let options = try await connection.setConfigOption(sessionId: acpId, configId: configId, value: value)
                    session.replaceConfigOptions(options)
                }
            } catch {
                session.log("Failed to set config \(configId): \(error.localizedDescription)")
            }
        }
    }
}
