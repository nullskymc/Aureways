import XCTest

/// `terminal/create` compatibility. ACP reserves `command` for the program name
/// and `args` for its arguments, but not every agent honours that — Grok sends
/// the whole shell line in `command` with no `args`, which used to fail with a
/// bare "the file … doesn't exist" naming the entire line.
final class TerminalHostTests: XCTestCase {

    private func host() -> TerminalHost {
        TerminalHost(environment: HostEnvironment.augmented())
    }

    /// Runs a terminal to completion and returns what it printed.
    private func run(_ params: JSONValue, on host: TerminalHost) async throws -> (output: String, exit: Int32) {
        let created = try await host.create(params: params)
        guard let id = created.result["terminalId"]?.stringValue else {
            XCTFail("create returned no terminalId")
            return ("", -1)
        }
        let waited = try await host.wait(id: id)
        let exit = Int32(waited["exitCode"]?.int64Value ?? -1)
        let output = try await host.output(id: id)["output"]?.stringValue ?? ""
        _ = await host.release(id: id)
        return (output, exit)
    }

    /// A well-formed request runs the program directly, no shell involved.
    func testWellFormedCommandRunsDirectly() async throws {
        let host = host()
        let params = JSONValue.object([
            "command": .string("/bin/echo"),
            "args": .array([.string("hello")])
        ])
        let created = try await host.create(params: params)
        XCTAssertEqual(created.launched, "/bin/echo hello")
        _ = await host.release(id: created.result["terminalId"]?.stringValue ?? "")
    }

    /// A bare program name is resolved on PATH rather than shell-wrapped.
    func testBareProgramNameResolvesOnPath() async throws {
        let host = host()
        let created = try await host.create(params: .object([
            "command": .string("echo"),
            "args": .array([.string("hi")])
        ]))
        XCTAssertTrue(created.launched.hasSuffix("echo hi"), created.launched)
        XCTAssertTrue(
            created.launched.hasPrefix("/"),
            "the bare name should be resolved to an absolute path, got \(created.launched)"
        )
        _ = await host.release(id: created.result["terminalId"]?.stringValue ?? "")
    }

    /// A shell line in `command` is a malformed request at this layer. The ACP
    /// code reads the spec straight; absorbing an agent's deviation is that
    /// agent's `Harness.normalizeClientRequest`, not this function's job.
    func testShellLineInCommandIsRejected() async throws {
        let host = host()
        for line in [
            #"echo "terminal-ok" && echo second"#,
            #"bash -lc 'echo terminal-ok && pwd'"#
        ] {
            do {
                _ = try await host.create(params: .object(["command": .string(line)]))
                XCTFail("expected create to reject \(line)")
            } catch {
                XCTAssertTrue(
                    "\(error)".contains("not found on PATH"),
                    "expected a PATH error for \(line), got \(error)"
                )
            }
        }
    }

    /// A command that does not resolve is an error whether or not `args` came
    /// with it — no reinterpretation either way.
    func testMissingProgramIsAnError() async throws {
        let host = host()
        for params in [
            JSONValue.object(["command": .string("definitely-not-a-real-program")]),
            JSONValue.object([
                "command": .string("definitely-not-a-real-program"),
                "args": .array([.string("--version")])
            ])
        ] {
            do {
                _ = try await host.create(params: params)
                XCTFail("expected create to throw")
            } catch {
                XCTAssertTrue(
                    "\(error)".contains("not found on PATH"),
                    "expected a PATH error, got \(error)"
                )
            }
        }
    }

    /// Output is captured from stderr as well as stdout. Spelled the well-formed
    /// way: the shell is the program, the script is an argument.
    func testStderrIsCaptured() async throws {
        let host = host()
        let result = try await run(
            .object([
                "command": .string("/bin/zsh"),
                "args": .array([.string("-lc"), .string("echo to-stderr 1>&2")])
            ]),
            on: host
        )
        XCTAssertEqual(result.exit, 0)
        XCTAssertTrue(result.output.contains("to-stderr"), result.output)
    }

    /// A non-zero exit is reported rather than swallowed.
    func testNonZeroExitIsReported() async throws {
        let host = host()
        let result = try await run(
            .object([
                "command": .string("/bin/zsh"),
                "args": .array([.string("-lc"), .string("exit 3")])
            ]),
            on: host
        )
        XCTAssertEqual(result.exit, 3)
    }
}

/// The Grok-specific correction, applied before `TerminalHost` sees the request.
/// Grok always sends a shell line in `command` with no `args`, so its requests
/// are routed through the login shell deterministically rather than depending on
/// whether the first token happens to resolve on PATH.
final class GrokTerminalNormalizationTests: XCTestCase {

    private let harness = GrokBuildHarness()

    private func normalized(_ params: JSONValue) -> JSONValue {
        harness.normalizeClientRequest(method: "terminal/create", params: params)
    }

    func testShellLineIsRoutedThroughLoginShell() {
        let line = #"echo "terminal-ok" && pwd && git status -sb"#
        let result = normalized(.object(["command": .string(line)]))
        XCTAssertEqual(result["args"]?.arrayValue?.first?.stringValue, "-lc")
        XCTAssertEqual(result["args"]?.arrayValue?.last?.stringValue, line)
        XCTAssertTrue(result["command"]?.stringValue?.hasPrefix("/") == true)
    }

    /// Even a bare program name goes through the shell for this agent, so
    /// builtins and aliases behave the same as everything else it sends.
    func testBareCommandAlsoGoesThroughTheShell() {
        let result = normalized(.object(["command": .string("ls")]))
        XCTAssertEqual(result["args"]?.arrayValue?.last?.stringValue, "ls")
    }

    /// A well-formed request already has `args`; leave it exactly as sent.
    func testWellFormedRequestIsUntouched() {
        let params = JSONValue.object([
            "command": .string("/bin/echo"),
            "args": .array([.string("hi")])
        ])
        XCTAssertEqual(normalized(params), params)
    }

    /// Other fields must survive the rewrite.
    func testOtherFieldsSurvive() {
        let result = normalized(.object([
            "command": .string("pwd"),
            "cwd": .string("/tmp"),
            "outputByteLimit": .number(4096)
        ]))
        XCTAssertEqual(result["cwd"]?.stringValue, "/tmp")
        XCTAssertEqual(result["outputByteLimit"]?.int64Value, 4096)
    }

    /// Only terminal/create is rewritten.
    func testOtherMethodsAreUntouched() {
        let params = JSONValue.object(["command": .string("echo hi && pwd")])
        XCTAssertEqual(
            harness.normalizeClientRequest(method: "fs/read_text_file", params: params),
            params
        )
    }

    /// An empty command is not worth wrapping.
    func testEmptyCommandIsUntouched() {
        let params = JSONValue.object(["command": .string("   ")])
        XCTAssertEqual(normalized(params), params)
    }

    /// Harnesses without a quirk must not rewrite anything.
    func testOtherHarnessesDoNotRewrite() {
        let params = JSONValue.object(["command": .string("echo hi && pwd")])
        for harness in [ClaudeCodeHarness(), CodexHarness()] as [Harness] {
            XCTAssertEqual(
                harness.normalizeClientRequest(method: "terminal/create", params: params),
                params,
                "\(harness.id) should not rewrite terminal/create"
            )
        }
    }
}

/// The two halves together: the ACP layer rejects Grok's raw shape, and accepts
/// it once Grok's harness has corrected it. This is the guarantee that matters —
/// either half alone proves nothing about whether the terminal works.
final class GrokTerminalEndToEndTests: XCTestCase {

    func testRawGrokShapeIsRejectedButNormalizedShapeRuns() async throws {
        let host = TerminalHost(environment: HostEnvironment.augmented())
        let raw = JSONValue.object([
            "command": .string(#"echo "terminal-ok" && echo second"#)
        ])

        do {
            _ = try await host.create(params: raw)
            XCTFail("the ACP layer should not accept a shell line as the program name")
        } catch {
            XCTAssertTrue("\(error)".contains("not found on PATH"), "\(error)")
        }

        let corrected = GrokBuildHarness().normalizeClientRequest(
            method: "terminal/create",
            params: raw
        )
        let created = try await host.create(params: corrected)
        guard let id = created.result["terminalId"]?.stringValue else {
            return XCTFail("create returned no terminalId")
        }
        let exit = try await host.wait(id: id)["exitCode"]?.int64Value
        let output = try await host.output(id: id)["output"]?.stringValue ?? ""
        _ = await host.release(id: id)

        XCTAssertEqual(exit, 0)
        XCTAssertTrue(output.contains("terminal-ok"), output)
        XCTAssertTrue(output.contains("second"), "the && should have been interpreted by a shell")
    }
}
