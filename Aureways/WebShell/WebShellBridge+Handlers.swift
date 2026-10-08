import AppKit
import WebKit

// MARK: - JS -> Swift & Native UI helpers

extension WebShellBridge: WKScriptMessageHandler {
func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        handle(type, body)
    }

    func session(_ body: [String: Any], key: String = "id") -> ChatSession? {
        guard let raw = body[key] as? String, let id = UUID(uuidString: raw) else { return nil }
        return model.sessions.first { $0.id == id }
    }

    private func handle(_ type: String, _ body: [String: Any]) {
        if role == .menuBar, handleMenuBar(type, body) { return }
        if role == .composer {
            switch type {
            case "composerLayout":
                onComposerLayout?(body)
                return
            case "composerEscape":
                WebShellBridge.current?.sendCommand("escape")
                return
            case "uiPrefs", "dragRegions", "glass":
                return
            default:
                break
            }
        }
        switch type {
        case "ready":
            isReady = true
            resetSentState()
            flush()
            let queued = queuedCommands
            queuedCommands = []
            queued.forEach(post)
            onReady?()
        case "log":
            NSLog("[web] %@", String(describing: body["message"] ?? ""))
        case "send":
            let text = body["text"] as? String ?? ""
            let attachments = pendingAttachments
            model.sendFromComposer(text: text, attachments: attachments)
            pendingAttachments = []
        case "focusComposer":
            if role == .main { sendCommand("focusComposer") }
        case "cancel":
            model.cancel()
        case "newSession":
            if let path = body["workspace"] as? String, !path.isEmpty {
                model.startNewSession(inWorkspace: path)
            } else {
                model.startNewSession()
            }
            sendCommand("focusComposer")
        case "selectSession":
            if let session = session(body) { model.select(session) }
        case "closeSession":
            if let session = session(body) { model.close(session) }
        case "retry":
            if let session = session(body) ?? model.selectedSession { model.retry(session) }
        case "selectAgent":
            if let id = body["id"] as? String, model.agents.contains(where: { $0.id == id }) {
                model.selectedAgentId = id
            }
        case "setConfig":
            if let session = model.selectedSession, let configId = body["configId"] as? String,
               let value = body["value"] as? String {
                model.setSessionConfig(session, configId: configId, value: .string(value))
            }
        case "setMode":
            if let session = model.selectedSession, let modeId = body["modeId"] as? String {
                model.setSessionMode(session, modeId: modeId)
            }
        case "permission":
            guard let session = session(body, key: "sessionId") ?? model.selectedSession,
                  session.pendingPermission != nil else { return }
            if let optionId = body["optionId"] as? String {
                session.resumePermission(.selected(optionId))
            } else {
                session.resumePermission(.cancelled)
            }
        case "planApproval":
            guard let session = model.selectedSession, session.pendingPlanApproval != nil else { return }
            switch body["decision"] as? String {
            case "approve": session.resumePlanApproval(.approved(feedback: body["feedback"] as? String ?? ""))
            case "changes": session.resumePlanApproval(.requestChanges)
            default: session.resumePlanApproval(.quit)
            }
        case "question":
            guard let session = model.selectedSession, let prompt = session.pendingUserQuestion else { return }
            if body["skip"] as? Bool == true {
                session.resumeUserQuestion(.skipInterview)
                return
            }
            let answers = body["answers"] as? [String: [String]] ?? [:]
            var mapped: [UUID: [String]] = [:]
            for question in prompt.questions {
                mapped[question.id] = answers[question.id.uuidString] ?? []
            }
            session.resumeUserQuestion(.accepted(mapped))
        case "rpc":
            handleRPC(body)
        case "term.input":
            if let id = body["id"] as? String, let data = body["data"] as? String { terminals.input(id: id, data: data) }
        case "term.resize":
            if let id = body["id"] as? String {
                terminals.resize(id: id, cols: (body["cols"] as? NSNumber)?.intValue ?? 0, rows: (body["rows"] as? NSNumber)?.intValue ?? 0)
            }
        case "term.close":
            if let id = body["id"] as? String { terminals.close(id: id) }
        case "uiPrefs":
            if let prefs = body["prefs"] as? [String: Any] {
                for (key, value) in prefs { uiPrefs[key] = value is NSNull ? nil : value }
                UserDefaults.standard.set(uiPrefs, forKey: Self.uiPrefsKey)
            }
        case "pasteNative":
            let attachments = ComposerAttachment.fromPasteboard(.general)
            if attachments.isEmpty {
                sendCommand("pasteFallback")
            } else {
                pendingAttachments.append(contentsOf: attachments)
            }
        case "pasteImage":
            if let base64 = body["data"] as? String, let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
                pendingAttachments.append(ComposerAttachment(
                    kind: .image, name: body["name"] as? String ?? "图片".localized, url: nil,
                    mimeType: body["mime"] as? String ?? "image/png", imageData: data, thumbnail: image
                ))
            }
        case "attachPaths":
            let urls = (body["paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
            pendingAttachments.append(contentsOf: ComposerAttachment.fromFileURLs(urls))
        case "openPastedText":
            if let raw = body["id"] as? String, let attachment = pendingAttachments.first(where: { $0.id.uuidString == raw }),
               let path = attachment.url?.path {
                openFiles([path])
            }
        case "attach":
            presentOpenPanel()
        case "removeAttachment":
            if let raw = body["id"] as? String, let attachment = pendingAttachments.first(where: { $0.id.uuidString == raw }) {
                if attachment.kind == .pastedText { model.discardPastedTextDraft(attachment) }
                pendingAttachments.removeAll { $0.id == attachment.id }
            }
        case "pasteText":
            if let text = body["text"] as? String, let attachment = model.capturePastedText(text) {
                pendingAttachments.append(attachment)
            }
        case "openLink":
            if let href = body["href"] as? String { WebAssetSchemeHandler.openExternally(href) }
        case "openPath":
            if let path = body["path"] as? String, !path.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        case "copy":
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "selectWorkspace":
            if let path = body["path"] as? String { model.selectWorkspace(path) }
        case "addWorkspace":
            model.addWorkspace()
        case "revealWorkspace":
            model.openWorkspaceInFinder(body["path"] as? String)
        case "openSettings":
            sendCommand("openSettings")
        case "dismissError":
            model.errorMessage = nil
        case "dragRegions":
            let rects = (body["rects"] as? [[String: Any]] ?? []).compactMap { rect -> CGRect? in
                guard let x = (rect["x"] as? NSNumber)?.doubleValue, let y = (rect["y"] as? NSNumber)?.doubleValue,
                      let w = (rect["w"] as? NSNumber)?.doubleValue, let h = (rect["h"] as? NSNumber)?.doubleValue
                else { return nil }
                return CGRect(x: x, y: y, width: w, height: h)
            }
            onDragRegions?(rects, (body["height"] as? NSNumber).map { CGFloat($0.doubleValue) })
        case "composerInsert":
            if let text = body["text"] as? String { composerPeer?.sendCommand("insertText", ["text": text]) }
        case "glass":
            let panels = (body["rects"] as? [[String: Any]] ?? []).compactMap { rect -> GlassLayerView.Panel? in
                func number(_ key: String) -> CGFloat? { (rect[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
                guard let x = number("x"), let y = number("y"), let w = number("w"), let h = number("h"), w > 0, h > 0
                else { return nil }
                var extra: [String: CGFloat] = [:]
                for key in ["al", "ar", "mw"] { extra[key] = number(key) }
                return GlassLayerView.Panel(kind: rect["k"] as? String ?? "", frame: CGRect(x: x, y: y, width: w, height: h), radius: number("r") ?? 12, extra: extra)
            }
            onGlassRects?(panels)
        case "menu":
            let token = (body["token"] as? NSNumber)?.intValue ?? 0
            let items = body["items"] as? [[String: Any]] ?? []
            let point = CGPoint(x: (body["x"] as? NSNumber)?.doubleValue ?? 0, y: (body["y"] as? NSNumber)?.doubleValue ?? 0)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let chosen = self.popUpMenu(items, at: point)
                    self.post(["type": "menuResult", "token": token, "id": chosen ?? NSNull()])
                }
            }
        case "sessionMenu":
            guard let session = session(body) else { return }
            let point = CGPoint(x: (body["x"] as? NSNumber)?.doubleValue ?? 0, y: (body["y"] as? NSNumber)?.doubleValue ?? 0)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.showSessionMenu(session, at: point) }
            }
        default:
            NSLog("[web] unknown message %@", type)
        }
    }

    // MARK: Native UI helpers

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: model.inspectorRoot)
        panel.prompt = "添加".localized
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            self.pendingAttachments.append(contentsOf: ComposerAttachment.fromFileURLs(panel.urls))
        }
        if let window = hostView?.window {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    private final class MenuTarget: NSObject {
        var chosen: String?
        @objc func pick(_ sender: NSMenuItem) { chosen = sender.representedObject as? String }
    }

    /// Items: `{id, title, subtitle?, checked?, disabled?, icon? (SF Symbol)}`,
    /// `{type: "separator"}`, `{type: "header", title}`.
    private func popUpMenu(_ specs: [[String: Any]], at point: CGPoint) -> String? {
        guard let hostView else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = MenuTarget()
        for spec in specs {
            let title = spec["title"] as? String ?? ""
            switch spec["type"] as? String {
            case "separator":
                menu.addItem(.separator())
                continue
            case "header":
                menu.addItem(.sectionHeader(title: title))
                continue
            default:
                break
            }
            let item = NSMenuItem(title: title, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = spec["id"] as? String
            item.state = (spec["checked"] as? Bool == true) ? .on : .off
            item.isEnabled = spec["disabled"] as? Bool != true
            if let subtitle = spec["subtitle"] as? String, !subtitle.isEmpty { item.subtitle = subtitle }
            if let icon = spec["icon"] as? String {
                item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: hostView)
        return target.chosen
    }

    private func showSessionMenu(_ session: ChatSession, at point: CGPoint) {
        var items: [[String: Any]] = [
            ["id": "reveal", "title": "在 Finder 中显示".localized, "icon": "folder"],
            ["id": "copyId", "title": "复制会话 ID".localized, "icon": "doc.on.doc",
             "disabled": session.acpSessionId == nil],
            ["type": "separator"],
            ["id": "close", "title": "关闭会话".localized, "icon": "xmark.circle"],
            ["id": "forget", "title": "从列表移除".localized, "icon": "eye.slash"],
        ]
        if model.canDelete(session) {
            items.append(["id": "delete", "title": "删除会话".localized, "icon": "trash"])
        }
        switch popUpMenu(items, at: point) {
        case "reveal":
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
        case "copyId":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.acpSessionId ?? "", forType: .string)
        case "close":
            model.close(session)
        case "forget":
            model.forget(session)
        case "delete":
            model.delete(session)
        default:
            break
        }
    }
}