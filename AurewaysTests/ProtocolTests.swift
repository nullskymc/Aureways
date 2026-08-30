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
        let response = try await connection.prompt(sessionId: session.sessionId, text: "hello")
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
        let response = try await connection.prompt(sessionId: session.sessionId, text: "read")
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
        {"loadSession":true,"sessionCapabilities":{"list":{},"delete":{}}}
        """
        let capabilities = try JSONDecoder.acp.decode(AgentCapabilities.self, from: Data(json.utf8))
        XCTAssertTrue(capabilities.canLoad)
        XCTAssertTrue(capabilities.canList)
        XCTAssertTrue(capabilities.canDelete)
        XCTAssertTrue(capabilities.canPersistHistory)
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
        _ = try await connection.prompt(sessionId: created.sessionId, text: "hello")
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
