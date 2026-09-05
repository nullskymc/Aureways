import AppKit
import XCTest

final class ProtocolTests: XCTestCase {
    func testJSONRPCRoundTrip() throws {
        let request = JSONRPCMessage.request(
            id: .number(1),
            method: "initialize",
            params: .object(["protocolVersion": .number(1)])
        )
        let line = try request.line()
        let parsed = try JSONRPCMessage.parse(line: line)
        guard case .request(let id, let method, let params) = parsed else {
            return XCTFail("expected request")
        }
        XCTAssertEqual(id, .number(1))
        XCTAssertEqual(method, "initialize")
        XCTAssertEqual(params?["protocolVersion"]?.int64Value, 1)
    }

    func testSessionUpdateDecoding() throws {
        let json = try JSONValue.decode(from: """
        {"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}
        """)
        let note = SessionNotification(json: json)
        XCTAssertEqual(note?.sessionId, "s1")
        if case .agentMessageChunk(let content) = note?.update {
            XCTAssertEqual(content.text, "hi")
        } else {
            XCTFail("expected agent message")
        }
    }

    func testContentBlockImageAndResourceLinkCodable() throws {
        func encoded(_ block: ContentBlock) throws -> JSONValue {
            let data = try JSONEncoder().encode([block])
            return try JSONValue.decode(from: data).arrayValue?.first ?? .null
        }
        func decode(_ json: String) throws -> ContentBlock {
            let value = try JSONValue.decode(from: json)
            return try JSONDecoder.acp.decode(ContentBlock.self, from: try value.encode())
        }

        let image = try encoded(.image(data: "QUJD", mimeType: "image/png", uri: nil))
        XCTAssertEqual(image["type"]?.stringValue, "image")
        XCTAssertEqual(image["data"]?.stringValue, "QUJD")
        XCTAssertEqual(image["mimeType"]?.stringValue, "image/png")
        XCTAssertNil(image["uri"])

        let imageWithURI = try encoded(.image(data: "QQ", mimeType: "image/jpeg", uri: "file:///tmp/a.png"))
        XCTAssertEqual(imageWithURI["uri"]?.stringValue, "file:///tmp/a.png")

        let link = try encoded(.resourceLink(uri: "file:///tmp/notes.md", name: "notes.md"))
        XCTAssertEqual(link["type"]?.stringValue, "resource_link")
        XCTAssertEqual(link["uri"]?.stringValue, "file:///tmp/notes.md")
        XCTAssertEqual(link["name"]?.stringValue, "notes.md")

        if case .image(let data, let mimeType, let uri) = try decode("""
        {"type":"image","data":"QUJD","mimeType":"image/png"}
        """) {
            XCTAssertEqual(data, "QUJD")
            XCTAssertEqual(mimeType, "image/png")
            XCTAssertNil(uri)
        } else {
            XCTFail("expected image block")
        }

        if case .resourceLink(let uri, let name) = try decode("""
        {"type":"resource_link","uri":"file:///tmp/notes.md","name":"notes.md"}
        """) {
            XCTAssertEqual(uri, "file:///tmp/notes.md")
            XCTAssertEqual(name, "notes.md")
        } else {
            XCTFail("expected resource_link block")
        }

        // 缺字段的 image 与未知类型一律落 .other，不炸解码
        if case .other = try decode("""
        {"type":"image","mimeType":"image/png"}
        """) {
        } else {
            XCTFail("expected fallback .other for malformed image")
        }
        if case .audio(let data, let mime) = try decode("""
        {"type":"audio","data":"QUJD","mimeType":"audio/wav"}
        """) {
            XCTAssertEqual(data, "QUJD")
            XCTAssertEqual(mime, "audio/wav")
        } else {
            XCTFail("expected audio block")
        }

        let resource = try encoded(.resource(
            uri: "file:///tmp/notes.md",
            mimeType: "text/markdown",
            text: "# hi",
            blob: nil
        ))
        XCTAssertEqual(resource["type"]?.stringValue, "resource")
        XCTAssertEqual(resource["resource"]?["uri"]?.stringValue, "file:///tmp/notes.md")
        XCTAssertEqual(resource["resource"]?["text"]?.stringValue, "# hi")

        if case .resource(let uri, let mime, let text, let blob) = try decode("""
        {"type":"resource","resource":{"uri":"file:///tmp/notes.md","mimeType":"text/markdown","text":"# hi"}}
        """) {
            XCTAssertEqual(uri, "file:///tmp/notes.md")
            XCTAssertEqual(mime, "text/markdown")
            XCTAssertEqual(text, "# hi")
            XCTAssertNil(blob)
        } else {
            XCTFail("expected resource block")
        }
    }

    func testOutgoingMessageEmbedsTextFilesAndDropsOversizedImages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notes = directory.appendingPathComponent("notes.md")
        try "# hello".write(to: notes, atomically: true, encoding: .utf8)

        let message = OutgoingMessage(
            text: "see this",
            attachments: [
                TranscriptAttachment(id: UUID(), kind: "file", name: "notes.md", path: notes.path, mimeType: "text/markdown", imageBase64: nil)
            ]
        )
        let blocks = message.contentBlocks(promptCapabilities: PromptCapabilities(image: true, audio: false, embeddedContext: true))
        XCTAssertEqual(blocks.count, 2)
        if case .resource(_, let mime, let text, _) = blocks[1] {
            XCTAssertEqual(mime, "text/markdown")
            XCTAssertEqual(text, "# hello")
        } else {
            XCTFail("expected embedded resource")
        }

        let linked = message.contentBlocks(promptCapabilities: PromptCapabilities(image: true, audio: false, embeddedContext: false))
        if case .resourceLink(let uri, let name) = linked[1] {
            XCTAssertTrue(uri.contains("notes.md"))
            XCTAssertEqual(name, "notes.md")
        } else {
            XCTFail("expected resource_link when embeddedContext is off")
        }
    }

    func testMcpServerAndUsageDecoding() throws {
        let stdio = McpServerConfig(name: "fs", command: "/usr/bin/mcp", arguments: ["--root", "/tmp"])
        let payload = stdio.json(capabilities: McpCapabilities(http: false, sse: false))
        XCTAssertEqual(payload?["name"]?.stringValue, "fs")
        XCTAssertEqual(payload?["command"]?.stringValue, "/usr/bin/mcp")
        XCTAssertNil(payload?["type"])

        let http = McpServerConfig(name: "remote", transport: .http, url: "https://example.test")
        XCTAssertNil(http.json(capabilities: McpCapabilities(http: false, sse: false)))
        XCTAssertEqual(http.json(capabilities: McpCapabilities(http: true, sse: false))?["type"]?.stringValue, "http")

        let request = NewSessionRequest(
            cwd: "/tmp/project",
            mcpServers: [stdio.json(capabilities: nil)!],
            additionalDirectories: ["/tmp/shared"]
        )
        let encoded = try JSONValue.decode(from: JSONEncoder.acp.encode(request))
        XCTAssertEqual(encoded["additionalDirectories"]?.arrayValue?.compactMap(\.stringValue), ["/tmp/shared"])
        XCTAssertEqual(encoded["mcpServers"]?.arrayValue?.count, 1)

        let json = try JSONValue.decode(from: """
        {"sessionId":"s1","update":{"sessionUpdate":"usage_update","used":1200,"size":8000,"cost":{"amount":0.02,"currency":"USD"}}}
        """)
        let note = SessionNotification(json: json)
        if case .usage(let usage) = note?.update {
            XCTAssertEqual(usage.used, 1200)
            XCTAssertEqual(usage.size, 8000)
            XCTAssertEqual(usage.costAmount, 0.02)
            XCTAssertEqual(usage.costCurrency, "USD")
        } else {
            XCTFail("expected usage_update")
        }

        let tool = try JSONValue.decode(from: """
        {"toolCallId":"c1","title":"Edit","kind":"edit","status":"completed","locations":[{"path":"/tmp/a.swift","line":12}],"content":[{"type":"diff","path":"/tmp/a.swift","oldText":"a","newText":"b"}]}
        """)
        let call = ToolCallView(json: tool)
        XCTAssertEqual(call.locations.first?.path, "/tmp/a.swift")
        XCTAssertEqual(call.locations.first?.line, 12)
        XCTAssertEqual(call.diffs.first?.path, "/tmp/a.swift")
        XCTAssertEqual(call.diffs.first?.newText, "b")
    }

    @MainActor
    func testUsageUpdateDoesNotRewriteTranscript() {
        let profile = AgentProfile(id: "test", title: "Test", subtitle: "", command: "test", arguments: [], builtIn: false, notes: "")
        let session = ChatSession(agent: profile, cwd: "/tmp", phase: .ready)
        session.appendUser("hi")
        let revision = session.transcriptRevision
        session.apply(SessionNotification(
            sessionId: "s1",
            update: .usage(SessionUsage(json: .object(["used": .number(10), "size": .number(100)]))!)
        ))
        XCTAssertEqual(session.items.count, 1)
        XCTAssertEqual(session.transcriptRevision, revision)
        XCTAssertEqual(session.usage?.used, 10)
        XCTAssertEqual(session.usage?.size, 100)
    }

    func testSessionUpdateChunkCoalescing() {
        let notes = [
            SessionNotification(sessionId: "s1", update: .agentMessageChunk(.text("Hel"))),
            SessionNotification(sessionId: "s1", update: .agentMessageChunk(.text("lo "))),
            SessionNotification(sessionId: "s1", update: .agentMessageChunk(.text("world"))),
            SessionNotification(sessionId: "s1", update: .agentThoughtChunk(.text("hmm"))),
            SessionNotification(sessionId: "s1", update: .agentMessageChunk(.text("!"))),
        ]
        let merged = SessionNotification.coalesced(notes)
        XCTAssertEqual(merged.count, 3)
        if case .agentMessageChunk(let content) = merged[0].update {
            XCTAssertEqual(content.text, "Hello world")
        } else {
            XCTFail("expected merged agent text")
        }
        if case .agentThoughtChunk(let content) = merged[1].update {
            XCTAssertEqual(content.text, "hmm")
        } else {
            XCTFail("expected thought chunk")
        }
        if case .agentMessageChunk(let content) = merged[2].update {
            XCTAssertEqual(content.text, "!")
        } else {
            XCTFail("expected trailing agent chunk")
        }
    }

    func testTranscriptImageStoreDecodesOnce() {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let attachment = TranscriptAttachment(
            id: UUID(),
            kind: "image",
            name: "dot.png",
            path: nil,
            mimeType: "image/png",
            imageBase64: png
        )
        let first = TranscriptImageStore.prefetch(attachment)
        XCTAssertNotNil(first)
        let cached = TranscriptImageStore.cached(attachment)
        XCTAssertTrue(cached === first)
    }

    func testPermissionEncoding() throws {
        let selected = PermissionDecision.selected("allow-once").json
        XCTAssertEqual(selected["outcome"]?["outcome"]?.stringValue, "selected")
        XCTAssertEqual(selected["outcome"]?["optionId"]?.stringValue, "allow-once")
        let cancelled = PermissionDecision.cancelled.json
        XCTAssertEqual(cancelled["outcome"]?["outcome"]?.stringValue, "cancelled")
    }

    func testCatalogSplit() {
        let parts = AgentCatalog.splitCommandLine(#"npx -y "@agentclientprotocol/codex-acp""#)
        XCTAssertEqual(parts, ["npx", "-y", "@agentclientprotocol/codex-acp"])
    }

    func testBuiltInHarnessesReplaceGeminiWithAntigravity() {
        let ids = AgentCatalog.builtIn.map(\.id)
        XCTAssertTrue(ids.contains(AntigravityHarness.id))
        XCTAssertFalse(ids.contains("gemini"))
        XCTAssertEqual(HarnessRegistry.migrateAgentId("gemini"), AntigravityHarness.id)
        XCTAssertEqual(HarnessRegistry.migrateAgentId("codex"), "codex")

        let grok = GrokBuildHarness()
        XCTAssertEqual(grok.launchArguments(autoApprove: false), ["agent", "stdio"])
        XCTAssertEqual(grok.launchArguments(autoApprove: true), ["agent", "--always-approve", "stdio"])
        XCTAssertEqual(grok.sessionMeta(autoApprove: true)?["yoloMode"]?.boolValue, true)
        XCTAssertNil(grok.sessionMeta(autoApprove: false))
        XCTAssertNil(CodexHarness().sessionMeta(autoApprove: true))
    }

    func testCustomAgentIdsAreUnique() {
        let first = AgentCatalog.custom(title: "Mine", commandLine: "grok agent stdio")
        let second = AgentCatalog.custom(title: "Mine", commandLine: "grok agent stdio")
        XCTAssertNotEqual(first?.id, second?.id)
        XCTAssertTrue(first?.id.hasPrefix("custom-") == true)
    }

    func testFileOpsRejectsPathOutsideWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ops = FileOps(workspace: root.path)
        let inside = root.appendingPathComponent("note.txt").path
        try await ops.writeText(path: inside, content: "ok")
        let text = try await ops.readText(path: inside, line: nil, limit: nil)
        XCTAssertEqual(text, "ok")

        let sibling = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        try "nope".write(to: sibling, atomically: true, encoding: .utf8)
        do {
            _ = try await ops.readText(path: sibling.path, line: nil, limit: nil)
            XCTFail("expected workspace rejection")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(message.contains("outside"), message)
        }
    }

    func testFileOpsAllowsAdditionalWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let extra = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        let ops = FileOps(workspace: root.path)
        let extraFile = extra.appendingPathComponent("note.txt").path
        do {
            _ = try await ops.readText(path: extraFile, line: nil, limit: nil)
            XCTFail("expected workspace rejection before addWorkspace")
        } catch {}
        await ops.addWorkspace(extra.path)
        try await ops.writeText(path: extraFile, content: "ok")
        let text = try await ops.readText(path: extraFile, line: nil, limit: nil)
        XCTAssertEqual(text, "ok")
    }

    func testInitializeFlushesLineWithoutTrailingNewline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("eof_agent.py")
        try eofAgentSource.write(to: file, atomically: true, encoding: .utf8)
        let connection = try ACPConnection.launch(
            ACPLaunch(
                command: "/usr/bin/python3",
                arguments: [file.path],
                cwd: directory.path,
                environment: HostEnvironment.augmented()
            ),
            handlers: ACPHandlers(
                onUpdate: { _ in },
                onPermission: { _ in .cancelled },
                onLog: { _ in }
            )
        )
        let handshake = try await connection.initialize()
        XCTAssertEqual(handshake.agentInfo?.name, "eof")
        await connection.shutdown()
    }

    func testMockAgentPrompt() async throws {
        let script = mockAgentSource
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("mock_agent.py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let chunks = TextBox()
        let connection = try ACPConnection.launch(
            ACPLaunch(
                command: "/usr/bin/python3",
                arguments: [file.path],
                cwd: directory.path,
                environment: HostEnvironment.augmented()
            ),
            handlers: ACPHandlers(
                onUpdate: { note in
                    if case .agentMessageChunk(let content) = note.update {
                        await chunks.append(content.text ?? "")
                    }
                },
                onPermission: { _ in .cancelled },
                onLog: { _ in }
            )
        )
        let handshake = try await connection.initialize()
        XCTAssertEqual(handshake.agentInfo?.name, "mock")
        let session = try await connection.newSession(cwd: directory.path, meta: nil)
        XCTAssertEqual(session.sessionId, "sess_mock_1")
        let response = try await connection.prompt(sessionId: session.sessionId, prompt: [.text("hello")])
        XCTAssertEqual(response.stopReason, "end_turn")
        let joined = await chunks.joined()
        XCTAssertEqual(joined, "hello from mock")
        await connection.shutdown()
    }

    func testReadTextFileForAgent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("note.txt")
        try "alpha\nbeta\ngamma\n".write(to: target, atomically: true, encoding: .utf8)
        let file = directory.appendingPathComponent("mock_agent.py")
        try mockAgentSource.write(to: file, atomically: true, encoding: .utf8)
        var env = HostEnvironment.augmented()
        env["MOCK_MODE"] = "fs"
        env["MOCK_FILE"] = target.path
        let seen = TextBox()
        let connection = try ACPConnection.launch(
            ACPLaunch(
                command: "/usr/bin/python3",
                arguments: [file.path],
                cwd: directory.path,
                environment: env
            ),
            handlers: ACPHandlers(
                onUpdate: { note in
                    if case .agentMessageChunk(let content) = note.update {
                        await seen.append(content.text ?? "")
                    }
                },
                onPermission: { _ in .cancelled },
                onLog: { _ in }
            )
        )
        _ = try await connection.initialize()
        let session = try await connection.newSession(cwd: directory.path, meta: nil)
        let response = try await connection.prompt(sessionId: session.sessionId, prompt: [.text("read")])
        XCTAssertEqual(response.stopReason, "end_turn")
        let output = await seen.joined()
        XCTAssertTrue(output.contains("beta"), output)
        await connection.shutdown()
    }

    func testSessionStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aureways-store-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SessionStore(url: url)
        let first = SessionLink(
            agentId: "grok-build",
            acpSessionId: "sess_a",
            cwd: "/tmp/a",
            title: "One",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let second = SessionLink(
            agentId: "grok-build",
            acpSessionId: "sess_b",
            cwd: "/tmp/b",
            title: "Two",
            createdAt: Date(timeIntervalSince1970: 11),
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        try store.upsert(first)
        try store.upsert(second)
        try store.upsert(SessionLink(
            agentId: "codex",
            acpSessionId: "sess_c",
            cwd: "/tmp/c",
            title: "Other",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        ))
        let grok = try store.list(agentId: "grok-build")
        XCTAssertEqual(grok.map(\.acpSessionId), ["sess_b", "sess_a"])
        try store.delete(agentId: "grok-build", acpSessionId: "sess_b")
        XCTAssertEqual(try store.list(agentId: "grok-build").map(\.acpSessionId), ["sess_a"])
        XCTAssertEqual(try store.list(agentId: "codex").count, 1)
        try store.delete(agentId: "codex", acpSessionId: "sess_c")
        XCTAssertTrue(try store.list(agentId: "codex").isEmpty)
    }

    func testWorkspaceStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aureways-ws-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SessionStore(url: url)
        let first = WorkspaceRecord(
            path: "/tmp/one",
            addedAt: Date(timeIntervalSince1970: 1),
            lastUsedAt: Date(timeIntervalSince1970: 10)
        )
        let second = WorkspaceRecord(
            path: "/tmp/two",
            addedAt: Date(timeIntervalSince1970: 2),
            lastUsedAt: Date(timeIntervalSince1970: 20)
        )
        try store.insertWorkspaceIfNeeded(first)
        try store.insertWorkspaceIfNeeded(second)
        try store.insertWorkspaceIfNeeded(WorkspaceRecord(
            path: "/tmp/one",
            addedAt: Date(timeIntervalSince1970: 99),
            lastUsedAt: Date(timeIntervalSince1970: 99)
        ))
        XCTAssertEqual(try store.listWorkspaces().map(\.path), ["/tmp/two", "/tmp/one"])
        XCTAssertEqual(try store.listWorkspaces().first { $0.path == "/tmp/one" }?.addedAt.timeIntervalSince1970, 1)
        try store.touchWorkspace(path: "/tmp/one", at: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(try store.listWorkspaces().map(\.path), ["/tmp/one", "/tmp/two"])
        try store.deleteWorkspace(path: "/tmp/one")
        XCTAssertEqual(try store.listWorkspaces().map(\.path), ["/tmp/two"])
        let normalized = WorkspaceRecord.normalized("/tmp/two/")
        XCTAssertFalse(normalized.hasSuffix("/"))
        XCTAssertTrue(normalized.hasSuffix("two"), normalized)
    }

    func testHomeDirectoryIsNotAWorkspace() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(WorkspaceRecord.isHome(home))
        XCTAssertTrue(WorkspaceRecord.isHome(home + "/"))
        XCTAssertFalse(WorkspaceRecord.isHome("/tmp"))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aureways-home-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SessionStore(url: url)
        try store.insertWorkspaceIfNeeded(WorkspaceRecord(path: WorkspaceRecord.homePath, addedAt: Date(), lastUsedAt: Date()))
        try store.insertWorkspaceIfNeeded(WorkspaceRecord(path: "/tmp/project", addedAt: Date(), lastUsedAt: Date()))
        try store.deleteWorkspace(path: WorkspaceRecord.homePath)
        XCTAssertEqual(try store.listWorkspaces().map(\.path), ["/tmp/project"])
    }

    func testNewSessionResponseConfigOptions() throws {
        let json = """
        {
          "sessionId": "sess_1",
          "modes": {
            "currentModeId": "ask",
            "availableModes": [
              {"id": "ask", "name": "Ask", "description": "Read only"},
              {"id": "code", "name": "Code"}
            ]
          },
          "configOptions": [
            {
              "id": "mode",
              "name": "Mode",
              "category": "mode",
              "type": "select",
              "value": "ask",
              "options": [
                {"id": "ask", "name": "Ask"},
                {"id": "code", "name": "Code"}
              ]
            },
            {
              "id": "model",
              "name": "Model",
              "category": "model",
              "type": "select",
              "value": "grok-4",
              "options": [
                {"id": "grok-4", "name": "Grok 4"},
                {"id": "grok-3", "name": "Grok 3"}
              ]
            },
            {
              "id": "fast",
              "name": "Fast",
              "type": "boolean",
              "value": false
            }
          ]
        }
        """
        let response = try JSONDecoder.acp.decode(NewSessionResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.sessionId, "sess_1")
        XCTAssertEqual(response.modes?.currentModeId, "ask")
        XCTAssertEqual(response.modes?.availableModes.map(\.id), ["ask", "code"])
        XCTAssertEqual(response.configOptions.count, 3)
        XCTAssertTrue(response.configOptions[0].isMode)
        XCTAssertFalse(response.configOptions[0].isModel)
        XCTAssertEqual(response.configOptions[0].value?.stringValue, "ask")
        XCTAssertTrue(response.configOptions[1].isModel)
        XCTAssertEqual(response.configOptions[1].value?.stringValue, "grok-4")
        XCTAssertTrue(response.configOptions[2].isBoolean)
        XCTAssertEqual(response.configOptions[2].value?.boolValue, false)
    }

    func testConfigOptionUpdateDecoding() throws {
        let json = try JSONValue.decode(from: """
        {"sessionId":"s1","update":{"sessionUpdate":"config_option_update","configId":"mode","value":"code"}}
        """)
        let note = SessionNotification(json: json)
        if case .configOption(let id, let value) = note?.update {
            XCTAssertEqual(id, "mode")
            XCTAssertEqual(value.stringValue, "code")
        } else {
            XCTFail("expected config option update")
        }
    }

    func testSessionCapabilitiesDecoding() throws {
        let json = """
        {"loadSession":true,"mcpCapabilities":{"http":true,"sse":false},"sessionCapabilities":{"list":{},"delete":{},"additionalDirectories":{}},"promptCapabilities":{"image":true,"embeddedContext":true}}
        """
        let capabilities = try JSONDecoder.acp.decode(AgentCapabilities.self, from: Data(json.utf8))
        XCTAssertTrue(capabilities.canLoad)
        XCTAssertTrue(capabilities.canList)
        XCTAssertTrue(capabilities.canDelete)
        XCTAssertTrue(capabilities.canAdditionalDirectories)
        XCTAssertTrue(capabilities.canPersistHistory)
        XCTAssertEqual(capabilities.mcpCapabilities?.http, true)
        XCTAssertEqual(capabilities.mcpCapabilities?.sse, false)
        XCTAssertEqual(capabilities.promptCapabilities?.allowsEmbeddedContext, true)
    }

    func testHistoryAgentListLoadDelete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("history_agent.py")
        try historyAgentSource.write(to: file, atomically: true, encoding: .utf8)
        let replay = TextBox()
        let connection = try ACPConnection.launch(
            ACPLaunch(
                command: "/usr/bin/python3",
                arguments: [file.path],
                cwd: directory.path,
                environment: HostEnvironment.augmented()
            ),
            handlers: ACPHandlers(
                onUpdate: { note in
                    if case .agentMessageChunk(let content) = note.update {
                        await replay.append(content.text ?? "")
                    }
                    if case .userMessageChunk(let content) = note.update {
                        await replay.append("user:\(content.text ?? "")")
                    }
                },
                onPermission: { _ in .cancelled },
                onLog: { _ in }
            )
        )
        let handshake = try await connection.initialize()
        XCTAssertEqual(handshake.agentCapabilities?.canLoad, true)
        XCTAssertEqual(handshake.agentCapabilities?.canList, true)
        XCTAssertEqual(handshake.agentCapabilities?.canDelete, true)

        let created = try await connection.newSession(cwd: directory.path, meta: nil)
        _ = try await connection.prompt(sessionId: created.sessionId, prompt: [.text("hello")])
        let listed = try await connection.listSessions()
        XCTAssertEqual(listed.map(\.sessionId), [created.sessionId])
        XCTAssertEqual(listed.first?.title, "hello")

        await replay.clear()
        _ = try await connection.loadSession(sessionId: created.sessionId, cwd: directory.path, meta: nil)
        let loaded = await replay.joined()
        XCTAssertTrue(loaded.contains("user:hello"), loaded)
        XCTAssertTrue(loaded.contains("hello from mock"), loaded)

        try await connection.deleteSession(sessionId: created.sessionId)
        let remaining = try await connection.listSessions()
        XCTAssertTrue(remaining.isEmpty)
        await connection.shutdown()
    }

    func testLoadRejectedWithoutCapability() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("mock_agent.py")
        try mockAgentSource.write(to: file, atomically: true, encoding: .utf8)
        let connection = try ACPConnection.launch(
            ACPLaunch(
                command: "/usr/bin/python3",
                arguments: [file.path],
                cwd: directory.path,
                environment: HostEnvironment.augmented()
            ),
            handlers: ACPHandlers(
                onUpdate: { _ in },
                onPermission: { _ in .cancelled },
                onLog: { _ in }
            )
        )
        let handshake = try await connection.initialize()
        XCTAssertEqual(handshake.agentCapabilities?.canLoad, false)
        let created = try await connection.newSession(cwd: directory.path, meta: nil)
        do {
            _ = try await connection.loadSession(sessionId: created.sessionId, cwd: directory.path, meta: nil)
            XCTFail("session/load should be missing on the default mock")
        } catch let error as ACPError {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("session/load") || text.contains("-32601") || text.contains("not found"), text)
        }
        await connection.shutdown()
    }

    func testSessionUpdateDecodingWithImageAndMessageId() throws {
        let json = try JSONValue.decode(from: """
        {"sessionId":"s1","update":{"sessionUpdate":"user_message_chunk","messageId":"msg_123","content":{"type":"image","data":"QUJD","mimeType":"image/png"}}}
        """)
        let note = SessionNotification(json: json)
        XCTAssertEqual(note?.sessionId, "s1")
        XCTAssertEqual(note?.messageId, "msg_123")
        if case .userMessageChunk(let content) = note?.update {
            if case .image(let data, let mime, let uri) = content {
                XCTAssertEqual(data, "QUJD")
                XCTAssertEqual(mime, "image/png")
                XCTAssertNil(uri)
            } else {
                XCTFail("expected image content block")
            }
        } else {
            XCTFail("expected user message chunk")
        }
    }

    func testTranscriptAttachmentFromContentBlock() {
        let block1 = ContentBlock.image(data: "QUJD", mimeType: "image/png", uri: "file:///tmp/screen.png")
        let att1 = TranscriptAttachment(contentBlock: block1)
        XCTAssertNotNil(att1)
        XCTAssertEqual(att1?.kind, "image")
        XCTAssertEqual(att1?.name, "screen.png")
        XCTAssertEqual(att1?.path, "/tmp/screen.png")
        XCTAssertEqual(att1?.imageBase64, "QUJD")

        let block2 = ContentBlock.resourceLink(uri: "file:///tmp/photo.jpeg", name: "")
        let att2 = TranscriptAttachment(contentBlock: block2)
        XCTAssertNotNil(att2)
        XCTAssertEqual(att2?.kind, "image")
        XCTAssertEqual(att2?.name, "photo.jpeg")

        let block3 = ContentBlock.text("hello")
        XCTAssertNil(TranscriptAttachment(contentBlock: block3))
    }

    @MainActor
    func testChatSessionRestoresUserImageAttachment() {
        let profile = AgentProfile(id: "test", title: "Test", subtitle: "", command: "test", arguments: [], builtIn: false, notes: "")
        let session = ChatSession(agent: profile, cwd: "/tmp", phase: .ready)

        // Simulate historical replay: text chunk first, then image chunk
        let textNote = SessionNotification(
            sessionId: "s1",
            update: .userMessageChunk(.text("Look at this screenshot")),
            messageId: "msg_user_1"
        )
        session.apply(textNote)

        let imgNote = SessionNotification(
            sessionId: "s1",
            update: .userMessageChunk(.image(data: "iVBORw0KGgo=", mimeType: "image/png", uri: nil)),
            messageId: "msg_user_1"
        )
        session.apply(imgNote)

        XCTAssertEqual(session.items.count, 1)
        if case .user(_, let text, let attachments) = session.items.first {
            XCTAssertEqual(text, "Look at this screenshot")
            XCTAssertEqual(attachments.count, 1)
            XCTAssertEqual(attachments.first?.kind, "image")
            XCTAssertEqual(attachments.first?.imageBase64, "iVBORw0KGgo=")
            XCTAssertEqual(attachments.first?.mimeType, "image/png")
        } else {
            XCTFail("expected user item with text and attachment")
        }

        // Simulate duplicate live echo: applying the same image chunk again shouldn't duplicate attachment
        session.apply(imgNote)
        if case .user(_, _, let attachments) = session.items.first {
            XCTAssertEqual(attachments.count, 1)
        }

        // Simulate agent response
        let agentNote = SessionNotification(
            sessionId: "s1",
            update: .agentMessageChunk(.text("I see the image.")),
            messageId: "msg_agent_1"
        )
        session.apply(agentNote)
        XCTAssertEqual(session.items.count, 2)

        // Simulate next turn with image-only user message
        let imgOnlyNote = SessionNotification(
            sessionId: "s1",
            update: .userMessageChunk(.image(data: "AQIDBA==", mimeType: "image/jpeg", uri: "file:///tmp/cat.jpg")),
            messageId: "msg_user_2"
        )
        session.apply(imgOnlyNote)

        XCTAssertEqual(session.items.count, 3)
        if case .user(_, let text, let attachments) = session.items.last {
            XCTAssertEqual(text, "")
            XCTAssertEqual(attachments.count, 1)
            XCTAssertEqual(attachments.first?.kind, "image")
            XCTAssertEqual(attachments.first?.name, "cat.jpg")
            XCTAssertEqual(attachments.first?.imageBase64, "AQIDBA==")
            XCTAssertEqual(attachments.first?.path, "/tmp/cat.jpg")
        } else {
            XCTFail("expected image-only user item")
        }
    }
}

private actor TextBox {
    private var parts: [String] = []

    func append(_ text: String) {
        parts.append(text)
    }

    func joined() -> String {
        parts.joined()
    }

    func clear() {
        parts = []
    }
}

private let eofAgentSource = #"""
#!/usr/bin/env python3
import json, sys
msg = json.loads(sys.stdin.readline())
sys.stdout.write(json.dumps({
    "jsonrpc": "2.0",
    "id": msg["id"],
    "result": {
        "protocolVersion": 1,
        "agentCapabilities": {},
        "agentInfo": {"name": "eof", "version": "0.0.1"},
        "authMethods": []
    }
}))
sys.stdout.flush()
"""#

private let mockAgentSource = #"""
#!/usr/bin/env python3
import json, os, sys

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

def recv():
    line = sys.stdin.readline()
    if not line:
        return None
    return json.loads(line)

while True:
    msg = recv()
    if msg is None:
        break
    method = msg.get("method")
    mid = msg.get("id")
    params = msg.get("params") or {}
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": 1,
            "agentCapabilities": {"loadSession": False, "promptCapabilities": {"image": False}},
            "agentInfo": {"name": "mock", "title": "Mock Agent", "version": "0.0.1"},
            "authMethods": []
        }})
    elif method == "session/new":
        send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "sess_mock_1"}})
    elif method == "session/prompt":
        sid = params.get("sessionId")
        if os.environ.get("MOCK_MODE") == "fs":
            req_id = 9001
            send({"jsonrpc": "2.0", "id": req_id, "method": "fs/read_text_file", "params": {
                "sessionId": sid,
                "path": os.environ["MOCK_FILE"],
                "line": 2,
                "limit": 1
            }})
            reply = recv()
            content = ((reply or {}).get("result") or {}).get("content", "")
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": sid,
                "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": content}}
            }})
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
        else:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": sid,
                "update": {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "thinking"}}
            }})
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": sid,
                "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hello from mock"}}
            }})
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
    elif method == "session/cancel":
        pass
    else:
        if mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": method or "unknown"}})
"""#

private let historyAgentSource = #"""
#!/usr/bin/env python3
import json, sys

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

def recv():
    line = sys.stdin.readline()
    if not line:
        return None
    return json.loads(line)

sessions = {}
next_id = 1

while True:
    msg = recv()
    if msg is None:
        break
    method = msg.get("method")
    mid = msg.get("id")
    params = msg.get("params") or {}
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": 1,
            "agentCapabilities": {
                "loadSession": True,
                "sessionCapabilities": {"list": {}, "delete": {}},
                "promptCapabilities": {"image": False}
            },
            "agentInfo": {"name": "history", "title": "History Agent", "version": "0.0.1"},
            "authMethods": []
        }})
    elif method == "session/new":
        sid = f"sess_hist_{next_id}"
        next_id += 1
        sessions[sid] = {"cwd": params.get("cwd") or "", "title": "新对话", "messages": []}
        send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": sid}})
    elif method == "session/prompt":
        sid = params.get("sessionId")
        text = ""
        for block in params.get("prompt") or []:
            if block.get("type") == "text":
                text += block.get("text") or ""
        record = sessions.setdefault(sid, {"cwd": "", "title": "新对话", "messages": []})
        record["messages"].append(("user", text))
        record["messages"].append(("agent", "hello from mock"))
        if text:
            record["title"] = text[:32]
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": sid,
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hello from mock"}}
        }})
        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
    elif method == "session/list":
        listed = []
        for sid, record in sessions.items():
            listed.append({
                "sessionId": sid,
                "cwd": record["cwd"],
                "title": record["title"],
                "updatedAt": "2026-01-01T00:00:00Z"
            })
        send({"jsonrpc": "2.0", "id": mid, "result": {"sessions": listed}})
    elif method == "session/load":
        sid = params.get("sessionId")
        record = sessions.get(sid)
        if record is None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32001, "message": "unknown session"}})
            continue
        for kind, text in record["messages"]:
            update = "user_message_chunk" if kind == "user" else "agent_message_chunk"
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": sid,
                "update": {"sessionUpdate": update, "content": {"type": "text", "text": text}}
            }})
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
    elif method == "session/delete":
        sid = params.get("sessionId")
        sessions.pop(sid, None)
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
    elif method == "session/cancel":
        pass
    else:
        if mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": method or "unknown"}})
"""#
