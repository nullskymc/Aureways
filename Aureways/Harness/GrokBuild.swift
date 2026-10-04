import Foundation

final class GrokBuildHarness: Harness {
    static let id = "grok-build"

    init() {
        super.init(
            profile: AgentProfile(
                id: Self.id,
                title: "Grok Build",
                subtitle: "xAI",
                command: "grok",
                arguments: ["agent", "stdio"],
                builtIn: true,
                notes: "需要已安装 grok 命令行工具并完成登录。")
        )
    }

    override func launchArguments(autoApprove: Bool) -> [String] {
        // `--no-leader`: a shared Grok TUI/leader would take permission
        // prompts instead of this client.
        if autoApprove {
            return ["agent", "--always-approve", "--no-leader", "stdio"]
        }
        return ["agent", "--no-leader", "stdio"]
    }

    override func environment(_ base: [String: String]) -> [String: String] {
        var env = base
        if env["GROK_CLIENT_NAME"] == nil {
            env["GROK_CLIENT_NAME"] = "aureways"
        }
        return env
    }

    override func sessionMeta(autoApprove: Bool) -> [String: JSONValue]? {
        autoApprove ? ["yoloMode": .bool(true)] : nil
    }

    /// Grok's `initialize` still reports `promptCapabilities.image: false`
    /// (agent 1.0.7) while `session/prompt` accepts standard `{type:"image"}`
    /// blocks. Trusting the flag disables paste/send in the composer and
    /// drops clipboard images that have no file path to fall back on.
    override func normalizeCapabilities(_ capabilities: AgentCapabilities) -> AgentCapabilities {
        var capabilities = capabilities
        var prompt = capabilities.promptCapabilities ?? PromptCapabilities()
        prompt.image = true
        capabilities.promptCapabilities = prompt
        return capabilities
    }

    /// Grok 1.0.7 has no `configOptions`. Effort lives on the current model's
    /// `_meta.reasoningEfforts`. Do not read `_meta["x.ai/sessionConfig"]` —
    /// those rows are tagged `category: "mode"` and would steal the mode chip.
    override func normalizeSessionConfig(
        options: [SessionConfigOption],
        models: SessionModelState?,
        modes: SessionModeState?
    ) -> [SessionConfigOption] {
        var result = super.normalizeSessionConfig(options: options, models: models, modes: modes)
        if !result.contains(where: \.isThoughtLevel),
           let model = models?.current,
           let thought = SessionConfigOption.thoughtLevel(from: model) {
            result.append(thought)
        }
        return result
    }

    /// Grok packs an entire shell line into `terminal/create`'s `command` and
    /// sends no `args` — ACP reserves `command` for the program name, so the
    /// request used to fail with "the file `bash -lc '…'` doesn't exist".
    ///
    /// Route it through the login shell explicitly here rather than leaning on
    /// the client's generic PATH-lookup fallback. For an agent that *always*
    /// sends shell lines, that is both deterministic and more correct: builtins,
    /// pipes and redirects work whether or not the first token happens to be a
    /// program on PATH (`cd foo && ls` works; so does a bare `ls`).
    ///
    /// A request that already carries `args` is left alone — that shape is
    /// well-formed and means the agent really did mean a program name.
    override func normalizeClientRequest(method: String, params: JSONValue) -> JSONValue {
        guard method == "terminal/create",
              var object = params.objectValue,
              let line = object["command"]?.stringValue,
              !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (object["args"]?.arrayValue ?? []).isEmpty
        else { return params }
        object["command"] = .string(Self.loginShell)
        object["args"] = .array([.string("-lc"), .string(line)])
        return .object(object)
    }

    private static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Grok's ACP `rawInput` is the internally tagged `ToolInput` enum
    /// (`variant` + `target_file` / `file_path` / `target_directory`). List-dir
    /// is sent as `kind: other`. Grep's title is the bare pattern.
    override func normalizeToolCall(_ json: JSONValue) -> JSONValue {
        ToolCallPatch.apply(json) { patch in
            patch.flattenTaggedInput()
            patch.setKind(fromVariant: Self.kindByVariant)
            patch.aliasInput(from: ["target_file", "file_path", "target_directory"], as: "path")
            patch.inferExecuteIfCommand()
            patch.fillLocationsFromPath(lineKeys: ["offset", "line"])
            patch.fillLocationsFromDiffs()
            patch.preferCommandTitle()
            patch.preferPathTitle()
            patch.replacePathOnlyTitle()
            patch.prefixExecuteTitle()
            patch.canonicalizeOutput()
        }
    }

    private static let kindByVariant: [String: String] = [
        "ReadFile": "read",
        "CodexReadFile": "read",
        "MemoryGet": "read",
        "ListDir": "read",
        "CodexListDir": "read",
        "SearchReplace": "edit",
        "Write": "edit",
        "HashlineEdit": "edit",
        "ApplyPatch": "edit",
        "Bash": "execute",
        "Grep": "search",
        "CodexGrepFiles": "search",
        "WebSearch": "search",
        "WebFetch": "fetch",
        "TodoWrite": "think",
        "EnterPlanMode": "think",
        "ExitPlanMode": "think",
        "AskUserQuestion": "other",
    ]

    // MARK: - Session Update Detection

    override class func isSessionUpdate(_ method: String) -> Bool {
        super.isSessionUpdate(method)
            || method == "x.ai/session/update"
            || method == "_x.ai/session/update"
            || method == "_x.ai/session_notification"
    }

    // MARK: - Models Normalization

    /// Grok CLI's `session/new` can report only its bundled offline catalog
    /// (e.g. grok-4.6 / grok-4.5) while the server already serves newer models.
    /// The CLI keeps the live catalog in `~/.grok/models_cache.json`; we add
    /// those entries to what the agent reported.
    ///
    /// Nothing is hard-coded: with no cache the agent's list is returned as is,
    /// and if the agent reports no models at all we do not invent a picker.
    override func normalizeModels(_ models: SessionModelState?) -> SessionModelState? {
        Self.mergeModels(models, cached: Self.readCachedModels())
    }

    /// Union of agent-reported and cached models.
    /// - Agent entries win per field (it is what the CLI will accept); cache only fills gaps.
    /// - `currentModelId` is always the agent's.
    /// - Order is deterministic: newest version first, base id before its variants.
    static func mergeModels(_ models: SessionModelState?, cached: [SessionModelInfo]?) -> SessionModelState? {
        guard var models else { return nil }
        guard let cached, !cached.isEmpty else { return models }

        var merged = models.availableModels
        for model in cached {
            if let idx = merged.firstIndex(where: { $0.id == model.id }) {
                let agent = merged[idx]
                merged[idx] = SessionModelInfo(
                    id: agent.id,
                    name: agent.name.isEmpty || agent.name == agent.id ? model.name : agent.name,
                    description: agent.description ?? model.description,
                    meta: mergeMeta(agent: agent.meta, cache: model.meta)
                )
            } else {
                merged.append(model)
            }
        }

        let indexed = merged.enumerated().map { (offset: $0.offset, model: $0.element) }
        models.availableModels = indexed.sorted { lhs, rhs in
            let l = versionKey(lhs.model.id), r = versionKey(rhs.model.id)
            if l != r { return r.lexicographicallyPrecedes(l) }
            if lhs.model.id.count != rhs.model.id.count { return lhs.model.id.count < rhs.model.id.count }
            return lhs.offset < rhs.offset
        }.map(\.model)
        return models
    }

    private static func mergeMeta(agent: JSONValue?, cache: JSONValue?) -> JSONValue? {
        guard let cacheObject = cache?.objectValue else { return agent }
        guard let agentObject = agent?.objectValue else { return agent ?? cache }
        return .object(cacheObject.merging(agentObject) { _, agentValue in agentValue })
    }

    /// First dotted number in the id: `grok-4.7-build-fast` → [4, 7]. No number → [].
    private static func versionKey(_ id: String) -> [Int] {
        guard let range = id.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else { return [] }
        return id[range].split(separator: ".").compactMap { Int($0) }
    }

    private static func readCachedModels() -> [SessionModelInfo]? {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ("~" as NSString).expandingTildeInPath
        let cachePath = (home as NSString).appendingPathComponent(".grok/models_cache.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
              let json = try? JSONValue.decode(from: data) else {
            return nil
        }
        return parseModelsCache(json)
    }

    /// Parse `~/.grok/models_cache.json`. Hidden models are skipped.
    static func parseModelsCache(_ json: JSONValue) -> [SessionModelInfo]? {
        var results: [SessionModelInfo] = []

        if let dict = json["models"]?.objectValue {
            for key in dict.keys.sorted() {
                guard let modelData = dict[key] else { continue }
                let info = modelData["info"] ?? modelData
                if info["hidden"]?.boolValue == true { continue }
                guard let id = info["id"]?.stringValue ?? info["model"]?.stringValue, !id.isEmpty else {
                    continue
                }
                let name = info["name"]?.stringValue ?? id
                let desc = info["description"]?.stringValue
                var metaObj: [String: JSONValue] = [:]
                if let effort = info["reasoning_effort"]?.stringValue ?? info["reasoningEffort"]?.stringValue {
                    metaObj["reasoningEffort"] = .string(effort)
                }
                if let efforts = info["reasoning_efforts"]?.arrayValue ?? info["reasoningEfforts"]?.arrayValue {
                    let normalizedEfforts: [JSONValue] = efforts.compactMap { item in
                        if let s = item.stringValue {
                            return .object(["id": .string(s), "name": .string(s)])
                        }
                        if let obj = item.objectValue, let id = obj["id"]?.stringValue ?? obj["value"]?.stringValue {
                            let label = obj["label"]?.stringValue ?? obj["name"]?.stringValue ?? id
                            return .object(["id": .string(id), "name": .string(label)])
                        }
                        return nil
                    }
                    metaObj["reasoningEfforts"] = .array(normalizedEfforts)
                }
                results.append(SessionModelInfo(
                    id: id, name: name, description: desc,
                    meta: metaObj.isEmpty ? nil : .object(metaObj)
                ))
            }
        } else if let list = json["models"]?.arrayValue ?? json.arrayValue {
            for item in list {
                if item["hidden"]?.boolValue == true { continue }
                guard let id = item["id"]?.stringValue ?? item["name"]?.stringValue, !id.isEmpty else {
                    continue
                }
                let name = item["name"]?.stringValue ?? item["title"]?.stringValue ?? id
                let desc = item["description"]?.stringValue
                let meta = item["_meta"] ?? item["meta"]
                results.append(SessionModelInfo(id: id, name: name, description: desc, meta: meta))
            }
        }

        return results.isEmpty ? nil : results
    }

    // MARK: - Notification Normalization

    /// Grok injects internal synthetic prompts (e.g. background task completion reminders)
    /// as `user_message_chunk` with `_meta: { hideFromScrollback: true }` and wrapped in
    /// `<system-reminder>` XML tags.
    ///
    /// Grok's official client filters these from the chat scrollback. We strip or drop them
    /// here in Grok's compatibility layer so internal synthetic events do not render as fake user chat bubbles.
    override func normalizeNotification(method: String, params: JSONValue) -> JSONValue {
        guard Self.isSessionUpdate(method),
              let update = params["update"],
              let sessionUpdate = update["sessionUpdate"]?.stringValue
        else {
            return super.normalizeNotification(method: method, params: params)
        }

        if sessionUpdate == "user_message_chunk" {
            let isHidden = update["_meta"]?["hideFromScrollback"]?.boolValue
                ?? params["_meta"]?["hideFromScrollback"]?.boolValue
                ?? false
            if isHidden {
                return .null
            }

            if let contentObj = update["content"]?.objectValue,
               let text = contentObj["text"]?.stringValue,
               text.contains("<system-reminder>") {
                let cleaned = text.replacingOccurrences(
                    of: #"<system-reminder>[\s\S]*?(</system-reminder>|$)"#,
                    with: "",
                    options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)

                if cleaned.isEmpty {
                    return .null
                }

                var newContent = contentObj
                newContent["text"] = .string(cleaned)
                var newUpdate = update.objectValue ?? [:]
                newUpdate["content"] = .object(newContent)
                var newParams = params.objectValue ?? [:]
                newParams["update"] = .object(newUpdate)
                return .object(newParams)
            }
        }

        return super.normalizeNotification(method: method, params: params)
    }

    // MARK: - Extension Requests

    override func handleExtRequest(
        method: String,
        params: JSONValue,
        session: ChatSession
    ) async throws -> JSONValue? {
        guard GrokExt.handles(method) else { return nil }
        switch GrokExt.stripUnderscorePrefix(method) {
        case "x.ai/exit_plan_mode":
            let prompt = GrokExt.parsePlanApproval(params)
            let decision = await session.waitForPlanApproval(prompt)
            return GrokExt.planApprovalResponse(for: decision)
        case "x.ai/ask_user_question":
            let prompt = GrokExt.parseUserQuestion(params)
            let decision = await session.waitForUserQuestion(prompt)
            return GrokExt.userQuestionResponse(decision: decision, prompt: prompt)
        default:
            return nil
        }
    }
}
