import Foundation

extension AppModel {
    func canDelete(_ session: ChatSession) -> Bool {
        runtimes[session.agent.id]?.canDelete == true
    }

    func select(_ session: ChatSession) {
        selectedSessionID = session.id
        if session.phase == .idle, session.acpSessionId != nil {
            Task { await openExisting(session) }
        }
    }

    func startNewSession(agent: AgentProfile? = nil) {
        if let agent {
            selectedAgentId = agent.id
        }
        errorMessage = nil
        selectedSessionID = nil
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
        session.resumePermission(.cancelled)
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
        session.resumePermission(.cancelled)
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
            selectedSessionID = persist ? session.id : sessions.first(where: { $0.id != session.id && !$0.isClosed })?.id
        }
        Task { await shutdownRuntimeIfIdle(session.agent.id) }
    }

    func forget(_ session: ChatSession) {
        session.promptTask?.cancel()
        session.promptTask = nil
        session.resumePermission(.cancelled)
        session.isClosed = true
        if let acpId = session.acpSessionId {
            try? store?.delete(agentId: session.agent.id, acpSessionId: acpId)
        }
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.first(where: { $0.id != session.id && !$0.isClosed })?.id
        }
        Task { await shutdownRuntimeIfIdle(session.agent.id) }
    }

    func delete(_ session: ChatSession) {
        guard canDelete(session), let acpId = session.acpSessionId else { return }
        session.promptTask?.cancel()
        session.promptTask = nil
        session.resumePermission(.cancelled)
        session.isClosed = true
        Task {
            do {
                let runtime = try await ensureRuntime(session.agent)
                guard let connection = runtime.connection else { return }
                try await connection.deleteSession(sessionId: acpId)
                try? store?.delete(agentId: session.agent.id, acpSessionId: acpId)
                sessions.removeAll { $0.id == session.id }
                if selectedSessionID == session.id {
                    selectedSessionID = sessions.first(where: { $0.id != session.id && !$0.isClosed })?.id
                }
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
        let open = sessions.filter { !$0.isClosed }
        if searchQuery.isEmpty {
            return open
        }
        return open.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery) ||
            $0.agent.title.localizedCaseInsensitiveContains(searchQuery) ||
            $0.cwd.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    func sessions(inWorkspace path: String) -> [ChatSession] {
        let normalized = WorkspaceRecord.normalized(path)
        return filteredSessions.filter { WorkspaceRecord.normalized($0.cwd) == normalized }
    }

    /// ⌘N / 悬停徽标使用的会话顺序：与侧栏一致——按工作区分组展开后的扁平序。
    /// cwd 不在任何已登记工作区（如主目录）的会话排在末尾，保证仍可被快捷键选中。
    var sidebarOrderedSessions: [ChatSession] {
        let grouped = visibleWorkspaces.flatMap { sessions(inWorkspace: $0.path) }
        let groupedIDs = Set(grouped.map(\.id))
        let orphans = filteredSessions.filter { !groupedIDs.contains($0.id) }
        return grouped + orphans
    }

    var visibleWorkspaces: [WorkspaceRecord] {
        if searchQuery.isEmpty {
            return workspaces
        }
        return workspaces.filter { workspace in
            !sessions(inWorkspace: workspace.path).isEmpty ||
            workspace.name.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    func sessionShortcut(for session: ChatSession) -> String? {
        let all = sidebarOrderedSessions
        if let idx = all.firstIndex(where: { $0.id == session.id }), idx < 9 {
            return "⌘\(idx + 1)"
        }
        return nil
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
                    try await connection.setConfigOption(sessionId: acpId, configId: session.configOptions.first(where: \.isMode)?.id ?? "mode", value: .string(modeId))
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
                try await connection.setConfigOption(sessionId: acpId, configId: configId, value: value)
            } catch {
                session.log("Failed to set config \(configId): \(error.localizedDescription)")
            }
        }
    }
}
