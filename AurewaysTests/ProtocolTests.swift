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
        let session = try await connection.newSession(cwd: directory.path, yolo: false)
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
        let session = try await connection.newSession(cwd: directory.path, yolo: false)
        let response = try await connection.prompt(sessionId: session.sessionId, text: "read")
        XCTAssertEqual(response.stopReason, "end_turn")
        let output = await seen.joined()
        XCTAssertTrue(output.contains("beta"), output)
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
