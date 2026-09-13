import XCTest

final class GrokExtTests: XCTestCase {
    func testCanonicalMethodHandlesUnderscoreAndBarePrefix() {
        XCTAssertTrue(GrokExt.handles("_x.ai/exit_plan_mode"))
        XCTAssertTrue(GrokExt.handles("x.ai/exit_plan_mode"))
        XCTAssertTrue(GrokExt.handles("_x.ai/ask_user_question"))
        XCTAssertTrue(GrokExt.handles("x.ai/ask_user_question"))
        XCTAssertFalse(GrokExt.handles("x.ai/session/update"))
        XCTAssertFalse(GrokExt.handles("fs/read_text_file"))
        XCTAssertEqual(GrokExt.stripUnderscorePrefix("_x.ai/exit_plan_mode"), "x.ai/exit_plan_mode")
    }

    func testParsePlanApprovalCamelCase() throws {
        let json = try JSONValue.decode(from: """
        {"sessionId":"s1","planContent":"# Hello","planFilePath":"/tmp/plan.md"}
        """)
        let prompt = GrokExt.parsePlanApproval(json)
        XCTAssertEqual(prompt.sessionId, "s1")
        XCTAssertEqual(prompt.content, "# Hello")
        XCTAssertEqual(prompt.filePath, "/tmp/plan.md")
        XCTAssertFalse(prompt.isEmpty)
    }

    func testParsePlanApprovalReadsAbsoluteFileWhenContentMissing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("plan.md")
        try "# From disk\n".write(to: file, atomically: true, encoding: .utf8)
        let json = JSONValue.object([
            "session_id": .string("s2"),
            "plan_file_path": .string(file.path),
        ])
        let prompt = GrokExt.parsePlanApproval(json)
        XCTAssertEqual(prompt.sessionId, "s2")
        XCTAssertTrue(prompt.content.contains("From disk"), prompt.content)
    }

    func testParseUserQuestion() throws {
        let json = try JSONValue.decode(from: """
        {"sessionId":"s1","questions":[{
          "question":"Pick one",
          "multi_select": true,
          "options":[
            {"label":"A","description":"first"},
            {"label":"B","preview":"code"}
          ]
        }]}
        """)
        let prompt = GrokExt.parseUserQuestion(json)
        XCTAssertEqual(prompt.questions.count, 1)
        XCTAssertEqual(prompt.questions[0].text, "Pick one")
        XCTAssertTrue(prompt.questions[0].multiSelect)
        XCTAssertEqual(prompt.questions[0].options.map(\.label), ["A", "B"])
        XCTAssertEqual(prompt.questions[0].options[0].description, "first")
        XCTAssertEqual(prompt.questions[0].options[1].preview, "code")
    }

    func testDecisionJSONShapes() {
        let approved = PlanApprovalDecision.approved(feedback: "").json
        XCTAssertEqual(approved["approved"]?.boolValue, true)
        XCTAssertEqual(approved["outcome"]?.stringValue, "approved")
        XCTAssertNotNil(approved["comments"])

        let quit = PlanApprovalDecision.quit.json
        XCTAssertEqual(quit["approved"]?.boolValue, false)
        XCTAssertEqual(quit["outcome"]?.stringValue, "quit")

        let question = UserQuestionPrompt(
            sessionId: "s",
            questions: []
        )
        XCTAssertEqual(UserQuestionDecision.skipInterview.json(for: question)["outcome"]?.stringValue, "skip_interview")
        XCTAssertEqual(UserQuestionDecision.chatAboutThis.json(for: question)["outcome"]?.stringValue, "chat_about_this")
        let accepted = UserQuestionDecision.accepted([:]).json(for: question)
        if case .object = accepted["answers"] {
        } else {
            XCTFail("answers must be a map, not a sequence")
        }
    }

    @MainActor
    func testPlanApprovalContinuation() async {
        let session = ChatSession(
            agent: AgentProfile(id: "grok-build", title: "Grok", subtitle: "", command: "grok", arguments: [], builtIn: true, notes: ""),
            cwd: "/tmp",
            phase: .ready
        )
        let prompt = PlanApprovalPrompt(sessionId: "s", content: "# x", filePath: nil)
        let task = Task { await session.waitForPlanApproval(prompt) }
        while session.pendingPlanApproval == nil {
            await Task.yield()
        }
        session.resumePlanApproval(.approved(feedback: ""))
        let decision = await task.value
        XCTAssertEqual(decision, .approved(feedback: ""))
        XCTAssertNil(session.pendingPlanApproval)
    }

    @MainActor
    func testResumeBlockingPromptsCancelsPlanAndQuestions() async {
        let session = ChatSession(
            agent: AgentProfile(id: "grok-build", title: "Grok", subtitle: "", command: "grok", arguments: [], builtIn: true, notes: ""),
            cwd: "/tmp",
            phase: .ready
        )
        let planTask = Task {
            await session.waitForPlanApproval(PlanApprovalPrompt(sessionId: "s", content: "", filePath: nil))
        }
        while session.pendingPlanApproval == nil { await Task.yield() }
        session.resumeBlockingPrompts()
        let plan = await planTask.value
        XCTAssertEqual(plan, .quit)
        XCTAssertNil(session.pendingPlanApproval)
        XCTAssertNil(session.pendingUserQuestion)
    }
}
