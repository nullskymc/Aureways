import Foundation

// MARK: - State snapshot

extension WebShellBridge {
func encodeState() -> [String: Any] {
        let selected = model.selectedSession
        let sessions = model.sessions.filter { !$0.isClosed }
        var state: [String: Any] = [
            "locale": L10n.locale.language.languageCode?.identifier == "zh" ? "zh" : "en",
            "appearance": model.appearance,
            "selectedSessionId": selected?.id.uuidString ?? NSNull(),
            "selectedAgentId": model.selectedAgentId,
            "workspacePath": WorkspaceRecord.normalized(model.workspacePath),
            "workspaceName": model.currentWorkspaceName,
            "branch": model.workspaceBranch ?? NSNull(),
            "homePath": WorkspaceRecord.homePath,
            "error": model.errorMessage ?? NSNull(),
            "chrome": [
                "trafficLights": [
                    "x": chrome.trafficLights.minX, "y": chrome.trafficLights.minY,
                    "w": chrome.trafficLights.width, "h": chrome.trafficLights.height,
                ],
                "fullscreen": chrome.fullscreen,
                "titlebarHeight": chrome.titlebarHeight,
                "leadingInset": chrome.leadingInset,
                "newChatInset": chrome.newChatInset,
                "trailingInset": chrome.trailingInset,
                "addInset": chrome.addInset,
                "nativeTitlebar": role == .main,
                "glass": role != .menuBar,
                "composerOverlay": role == .main,
            ],
        ]
        state["workspaces"] = model.workspaces.map { ["path": WorkspaceRecord.normalized($0.path), "name": $0.name] }
        state["agents"] = model.selectableAgents.map { agent -> [String: Any] in
            [
                "id": agent.id,
                "title": agent.title,
                "subtitle": agent.subtitle,
                "available": model.availability[agent.id] == true,
            ]
        }
        state["sessions"] = sessions.map { session -> [String: Any] in
            var row: [String: Any] = [
                "id": session.id.uuidString,
                "title": session.title,
                "agentId": session.agent.id,
                "agentTitle": session.agent.title,
                "cwd": session.cwd,
                "ws": WorkspaceRecord.normalized(session.cwd),
                "phase": Self.phaseName(session.phase),
                "streaming": session.isStreaming,
                "attention": session.pendingPermission != nil || session.pendingPlanApproval != nil
                    || session.pendingUserQuestion != nil,
                "createdAt": session.createdAt.timeIntervalSince1970 * 1000,
            ]
            if case .failed(let message) = session.phase { row["error"] = message }
            // Cross-session cards: the web shows these for sessions that aren't selected.
            if session.id != selected?.id {
                if let prompt = session.pendingPermission {
                    row["permission"] = Self.encode(prompt)
                } else if session.pendingPlanApproval != nil {
                    row["pendingKind"] = "plan"
                } else if session.pendingUserQuestion != nil {
                    row["pendingKind"] = "question"
                }
            }
            return row
        }
        if role == .main { notifier.update(sessions: sessions, selectedID: selected?.id) }
        state["uiPrefs"] = uiPrefs
        state["settings"] = encodeSettings()
        state["quota"] = encodeQuota()
        state["inspectorRoot"] = model.inspectorRoot
        state["composer"] = encodeComposer(selected)
        if let selected {
            if let prompt = selected.pendingPermission {
                state["permission"] = Self.encode(prompt)
            }
            if let plan = selected.pendingPlanApproval {
                state["planApproval"] = ["content": plan.content, "filePath": Self.orNull(plan.filePath)] as [String: Any]
            }
            if let question = selected.pendingUserQuestion {
                state["question"] = [
                    "questions": question.questions.map { q -> [String: Any] in
                        [
                            "id": q.id.uuidString,
                            "text": q.text,
                            "multi": q.multiSelect,
                            "options": q.options.map { option -> [String: Any] in ["label": option.label, "description": Self.orNull(option.description)] },
                        ]
                    },
                ]
            }
            if let usage = selected.usage {
                state["usage"] = ["used": usage.used, "size": usage.size]
            }
        }
        return state
    }

    private func encodeComposer(_ session: ChatSession?) -> [String: Any] {
        var composer: [String: Any] = [
            "attachments": pendingAttachments.map { attachment -> [String: Any] in
                var row: [String: Any] = [
                    "id": attachment.id.uuidString,
                    "name": attachment.name,
                    "kind": Self.attachmentKind(attachment.kind),
                ]
                if let path = attachment.url?.path { row["path"] = path }
                if attachment.characterCount > 0 { row["chars"] = attachment.characterCount }
                if attachment.kind == .image, let data = attachment.imageData, data.count < 4_000_000 {
                    row["src"] = "data:\(attachment.mimeType);base64,\(data.base64EncodedString())"
                }
                return row
            },
        ]
        guard let session else { return composer }
        composer["sessionId"] = session.id.uuidString
        composer["commands"] = session.availableCommands.map { ["name": $0.name, "description": $0.description ?? ""] }
        guard session.phase.isReady else { return composer }
        if let option = session.modelOption, !option.options.isEmpty {
            composer["model"] = Self.encodePicker(configId: option.id, current: option.selectedString, choices: option.options)
        }
        if let option = session.thoughtLevelOption, !option.options.isEmpty {
            composer["effort"] = Self.encodePicker(configId: option.id, current: option.selectedString, choices: option.options)
        }
        if !session.modeChoices.isEmpty {
            composer["mode"] = Self.encodePicker(configId: nil, current: session.currentModeId, choices: session.modeChoices)
        }
        return composer
    }

    private static func encodePicker(configId: String?, current: String?, choices: [SessionMode]) -> [String: Any] {
        [
            "configId": configId ?? NSNull(),
            "current": current ?? NSNull(),
            "options": choices.map { choice -> [String: Any] in
                ["id": choice.id, "name": choice.name, "group": orNull(choice.providerLabel),
                 "description": orNull(choice.description)]
            },
        ]
    }

    private static func orNull(_ value: String?) -> Any {
        value ?? NSNull()
    }

    private static func attachmentKind(_ kind: ComposerAttachment.Kind) -> String {
        switch kind {
        case .image: return "image"
        case .file: return "file"
        case .pastedText: return "pastedText"
        }
    }

    private static func phaseName(_ phase: SessionPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
}
