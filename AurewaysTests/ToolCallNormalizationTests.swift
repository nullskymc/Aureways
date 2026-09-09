import XCTest

final class ToolCallNormalizationTests: XCTestCase {

    func testGrokReadFlattensTaggedInput() throws {
        let json = try JSONValue.decode(from: """
        {
            "sessionUpdate": "tool_call",
            "toolCallId": "c1",
            "title": "Read `src/main.rs`",
            "kind": "read",
            "rawInput": {
                "variant": "ReadFile",
                "target_file": "src/main.rs",
                "offset": 10,
                "limit": 40
            }
        }
        """)
        let call = ToolCallView(json: GrokBuildHarness().normalizeToolCall(json))
        XCTAssertEqual(call.kind, "read")
        XCTAssertEqual(call.rawInput?["path"]?.stringValue, "src/main.rs")
        XCTAssertEqual(call.locations.first?.path, "src/main.rs")
        XCTAssertEqual(call.locations.first?.line, 10)
        XCTAssertEqual(call.kindLabel, "读取文件")
    }

    func testGrokListDirBecomesRead() throws {
        let json = try JSONValue.decode(from: """
        {
            "toolCallId": "c2",
            "title": "List `/tmp/project`",
            "kind": "other",
            "rawInput": {
                "variant": "ListDir",
                "target_directory": "/tmp/project"
            }
        }
        """)
        let call = ToolCallView(json: GrokBuildHarness().normalizeToolCall(json))
        XCTAssertEqual(call.kind, "read")
        XCTAssertEqual(call.rawInput?["path"]?.stringValue, "/tmp/project")
        XCTAssertEqual(call.locations.first?.path, "/tmp/project")
    }

    func testGrokBashAliasesCommand() throws {
        let json = try JSONValue.decode(from: """
        {
            "toolCallId": "c3",
            "title": "Execute `ls`",
            "kind": "execute",
            "rawInput": {
                "variant": "Bash",
                "command": "ls -la",
                "description": "list files",
                "is_background": false
            }
        }
        """)
        let call = ToolCallView(json: GrokBuildHarness().normalizeToolCall(json))
        XCTAssertTrue(call.isTerminal)
        XCTAssertEqual(call.terminalCommand, "ls -la")
        XCTAssertEqual(call.displayTitle, "Execute `ls`")
    }

    func testGrokSessionUpdateEnvelope() throws {
        let params = try JSONValue.decode(from: """
        {
            "sessionId": "s1",
            "update": {
                "sessionUpdate": "tool_call",
                "toolCallId": "c4",
                "kind": "other",
                "title": "Tool",
                "rawInput": {
                    "variant": "SearchReplace",
                    "file_path": "/tmp/a.swift",
                    "old_string": "a",
                    "new_string": "b"
                }
            }
        }
        """)
        let out = GrokBuildHarness().normalizeNotification(method: "session/update", params: params)
        let call = ToolCallView(json: out["update"] ?? .null)
        XCTAssertEqual(call.kind, "edit")
        XCTAssertEqual(call.rawInput?["path"]?.stringValue, "/tmp/a.swift")
        XCTAssertEqual(call.locations.first?.path, "/tmp/a.swift")
        XCTAssertEqual(call.kindLabel, "编辑文件")
    }

    func testClaudeAliasesFilePath() throws {
        let json = try JSONValue.decode(from: """
        {
            "toolCallId": "c1",
            "title": "Read src/a.ts (1 - 20)",
            "kind": "read",
            "rawInput": { "file_path": "src/a.ts", "offset": 1, "limit": 20 },
            "locations": [{ "path": "src/a.ts", "line": 1 }]
        }
        """)
        let call = ToolCallView(json: ClaudeCodeHarness().normalizeToolCall(json))
        XCTAssertEqual(call.rawInput?["path"]?.stringValue, "src/a.ts")
        XCTAssertEqual(call.locations.first?.path, "src/a.ts")
    }

    func testOpenCodeCamelCaseAndPathTitle() throws {
        let json = try JSONValue.decode(from: """
        {
            "toolCallId": "c1",
            "title": "src/foo.ts",
            "kind": "other",
            "status": "completed",
            "rawInput": { "filePath": "src/foo.ts", "content": "hello" }
        }
        """)
        let call = ToolCallView(json: OpenCodeHarness().normalizeToolCall(json))
        XCTAssertEqual(call.kind, "edit")
        XCTAssertEqual(call.rawInput?["path"]?.stringValue, "src/foo.ts")
        XCTAssertEqual(call.displayTitle, "Edit foo.ts")
        XCTAssertEqual(call.diffs.first?.newText, "hello")
    }

    func testOpenCodeBashInjectsCommand() throws {
        let json = try JSONValue.decode(from: """
        {
            "toolCallId": "c2",
            "title": "bash",
            "kind": "execute",
            "rawInput": { "command": "git status", "workdir": "/tmp/repo" }
        }
        """)
        let call = ToolCallView(json: OpenCodeHarness().normalizeToolCall(json))
        XCTAssertTrue(call.isTerminal)
        XCTAssertEqual(call.terminalCommand, "git status")
        XCTAssertEqual(call.terminalCwd, "/tmp/repo")
        XCTAssertEqual(call.displayTitle, "git status")
    }

    func testCodexEditingFilesGetsLocationFromDiff() throws {
        let json = try JSONValue.decode(from: """
        {
            "toolCallId": "c1",
            "title": "Editing files",
            "kind": "edit",
            "content": [{
                "type": "diff",
                "path": "/tmp/a.swift",
                "oldText": "a",
                "newText": "b"
            }]
        }
        """)
        let call = ToolCallView(json: CodexHarness().normalizeToolCall(json))
        XCTAssertEqual(call.locations.first?.path, "/tmp/a.swift")
        XCTAssertEqual(call.displayTitle, "Edit a.swift")
        XCTAssertEqual(call.diffs.first?.newText, "b")
    }

    func testCodexCommandOutputAliases() throws {
        let json = try JSONValue.decode(from: """
        {
            "toolCallId": "c2",
            "title": "ls",
            "kind": "execute",
            "rawInput": { "command": "ls", "cwd": "/tmp" },
            "rawOutput": { "formatted_output": "a.swift", "exit_code": 0 }
        }
        """)
        let call = ToolCallView(json: CodexHarness().normalizeToolCall(json))
        XCTAssertEqual(call.terminalOutput, "a.swift")
        XCTAssertEqual(call.terminalExitCode, 0)
        XCTAssertEqual(call.rawOutput?["output"]?.stringValue, "a.swift")
        XCTAssertEqual(call.rawOutput?["exitCode"]?.int64Value, 0)
    }

    func testAntigravityRunCommand() throws {
        let json = try JSONValue.decode(from: #"""
        {
            "toolCallId": "call_123",
            "title": "run_command",
            "kind": "other",
            "status": "completed",
            "rawInput": {
                "working_dir": "/tmp/repo",
                "command_line": "grep WorkspaceTree"
            },
            "rawOutput": {
                "exit_code": 0,
                "combinedOutput": "WorkspaceTree.swift:10"
            }
        }
        """#)
        let call = ToolCallView(json: AntigravityHarness().normalizeToolCall(json))
        XCTAssertEqual(call.kind, "execute")
        XCTAssertTrue(call.isTerminal)
        XCTAssertEqual(call.terminalCommand, "grep WorkspaceTree")
        XCTAssertEqual(call.terminalCwd, "/tmp/repo")
        XCTAssertEqual(call.terminalExitCode, 0)
        XCTAssertEqual(call.terminalOutput, "WorkspaceTree.swift:10")
        XCTAssertEqual(call.displayTitle, "grep WorkspaceTree")
    }

    func testAntigravityMcpEnvelope() throws {
        let json = try JSONValue.decode(from: """
        {
            "toolCallId": "call_456",
            "title": "call_mcp_tool",
            "kind": "other",
            "rawInput": {
                "ServerName": "default_api",
                "ToolName": "run_command",
                "Arguments": {
                    "CommandLine": "swift test",
                    "Cwd": "/tmp/project"
                }
            }
        }
        """)
        let call = ToolCallView(json: AntigravityHarness().normalizeToolCall(json))
        XCTAssertEqual(call.kind, "execute")
        XCTAssertEqual(call.terminalCommand, "swift test")
        XCTAssertEqual(call.terminalCwd, "/tmp/project")
        XCTAssertEqual(call.displayTitle, "swift test")
    }

    func testAntigravityPermissionEnvelope() throws {
        let params = try JSONValue.decode(from: """
        {
            "sessionId": "sess_1",
            "toolCall": {
                "toolCallId": "call_789",
                "title": "run_command",
                "kind": "execute",
                "rawInput": {
                    "command_line": "git status",
                    "working_dir": "/tmp/repo"
                }
            },
            "options": [
                {"optionId": "allow_once", "name": "允许一次", "kind": "allow_once"}
            ]
        }
        """)
        let normalized = AntigravityHarness().normalizeNotification(
            method: "session/request_permission",
            params: params
        )
        let prompt = PermissionPrompt(json: normalized)
        XCTAssertEqual(prompt?.title, "git status")
        XCTAssertEqual(prompt?.toolCall?.isTerminal, true)
        XCTAssertEqual(prompt?.toolCall?.terminalCommand, "git status")
        XCTAssertEqual(prompt?.toolCall?.terminalCwd, "/tmp/repo")
    }

    func testOhMyPiMoveLocations() throws {
        let json = try JSONValue.decode(from: """
        {
            "toolCallId": "c1",
            "title": "move: a.ts",
            "kind": "move",
            "rawInput": { "oldPath": "/tmp/a.ts", "newPath": "/tmp/b.ts" }
        }
        """)
        let call = ToolCallView(json: OhMyPiHarness().normalizeToolCall(json))
        XCTAssertEqual(call.kind, "move")
        XCTAssertEqual(call.locations.map(\.path), ["/tmp/a.ts", "/tmp/b.ts"])
    }

    func testOhMyPiPromotesNestedDiffs() throws {
        let json = try JSONValue.decode(from: """
        {
            "toolCallId": "c2",
            "title": "write: a.ts",
            "kind": "edit",
            "rawInput": { "path": "/tmp/a.ts" },
            "rawOutput": {
                "details": {
                    "path": "/tmp/a.ts",
                    "oldText": "old",
                    "newText": "new"
                }
            }
        }
        """)
        let call = ToolCallView(json: OhMyPiHarness().normalizeToolCall(json))
        XCTAssertEqual(call.diffs.first?.oldText, "old")
        XCTAssertEqual(call.diffs.first?.newText, "new")
        XCTAssertEqual(call.locations.first?.path, "/tmp/a.ts")
    }

    func testCustomHarnessDoesNotRewrite() throws {
        let json = try JSONValue.decode(from: """
        {
            "toolCallId": "c1",
            "title": "run_command",
            "kind": "other",
            "rawInput": { "command_line": "ls", "working_dir": "/tmp" }
        }
        """)
        let profile = AgentProfile(
            id: "custom",
            title: "Custom",
            subtitle: "",
            command: "echo",
            arguments: [],
            builtIn: false,
            notes: ""
        )
        let out = CustomHarness(profile: profile).normalizeToolCall(json)
        XCTAssertEqual(out["kind"]?.stringValue, "other")
        XCTAssertNil(out["rawInput"]?["command"])
    }
}
