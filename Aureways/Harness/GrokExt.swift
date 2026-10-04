import Foundation

/// Grok ACP extensions that are **requests** (they have a JSON-RPC id and
/// must be answered). Notifications such as `x.ai/session/update` stay on
/// the existing update path.
///
/// Wire names observed from `grok agent stdio`: `_x.ai/exit_plan_mode` and
/// `_x.ai/ask_user_question` (underscore optional). Params are camelCase
/// (`planContent`, `planFilePath`, `sessionId`, `questions`).
enum GrokExt {
    static func stripUnderscorePrefix(_ method: String) -> String {
        method.hasPrefix("_x.ai/") ? String(method.dropFirst()) : method
    }

    static func handles(_ method: String) -> Bool {
        switch stripUnderscorePrefix(method) {
        case "x.ai/exit_plan_mode", "x.ai/ask_user_question":
            return true
        default:
            return false
        }
    }

    static func parsePlanApproval(_ params: JSONValue) -> PlanApprovalPrompt {
        let sessionId = params.string(from: "sessionId", "session_id") ?? ""
        let path = params.string(from: "planFilePath", "plan_file_path", "path")
        var content = params.string(from: "planContent", "plan_content", "content", "plan") ?? ""
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let path, (path as NSString).isAbsolutePath {
            content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        }
        return PlanApprovalPrompt(sessionId: sessionId, content: content, filePath: path)
    }

    static func parseUserQuestion(_ params: JSONValue) -> UserQuestionPrompt {
        let sessionId = params.string(from: "sessionId", "session_id") ?? ""
        let questions = params["questions"]?.arrayValue?.compactMap(UserQuestion.init(grokJSON:)) ?? []
        return UserQuestionPrompt(sessionId: sessionId, questions: questions)
    }

    /// `ExitPlanModeExtResponse` is a 2-field struct in grok. Extra keys are
    /// ignored by default serde; keep `approved` + `comments` as the pair.
    static func planApprovalResponse(for decision: PlanApprovalDecision) -> JSONValue {
        switch decision {
        case .approved(let feedback):
            return .object([
                "approved": .bool(true),
                "outcome": .string("approved"),
                "comments": .array([]),
                "annotations": .array([]),
                "additionalFeedback": .string(feedback),
            ])
        case .requestChanges:
            return .object([
                "approved": .bool(false),
                "outcome": .string("request_changes"),
                "comments": .array([]),
                "annotations": .array([]),
            ])
        case .quit:
            return .object([
                "approved": .bool(false),
                "outcome": .string("quit"),
                "comments": .array([]),
                "annotations": .array([]),
            ])
        }
    }

    static func userQuestionResponse(decision: UserQuestionDecision, prompt: UserQuestionPrompt) -> JSONValue {
        switch decision {
        case .skipInterview:
            return .object(["outcome": .string("skip_interview")])
        case .chatAboutThis:
            return .object(["outcome": .string("chat_about_this")])
        case .accepted(let selections):
            // `answers` is a map (question text -> selected labels), not an array.
            // Grok rejected the sequence with: expected a map.
            var answers: [String: JSONValue] = [:]
            for question in prompt.questions {
                let selected = selections[question.id] ?? []
                answers[question.text] = .array(selected.map { .string($0) })
            }
            return .object([
                "outcome": .string("accepted"),
                "answers": .object(answers),
                "partial_answers": .bool(false),
            ])
        }
    }
}

extension PlanApprovalDecision {
    var json: JSONValue {
        GrokExt.planApprovalResponse(for: self)
    }
}

extension UserQuestionDecision {
    func json(for prompt: UserQuestionPrompt) -> JSONValue {
        GrokExt.userQuestionResponse(decision: self, prompt: prompt)
    }
}

extension UserQuestionOption {
    init?(grokJSON json: JSONValue) {
        guard let label = json.string(from: "label", "name", "id"), !label.isEmpty else { return nil }
        let description = json.string(from: "description", "detail")
        let preview = json.string(from: "preview")
        self.init(
            label: label,
            description: description?.isEmpty == false ? description : nil,
            preview: preview?.isEmpty == false ? preview : nil
        )
    }

    init?(json: JSONValue) {
        self.init(grokJSON: json)
    }
}

extension UserQuestion {
    init?(grokJSON json: JSONValue) {
        guard let text = json.string(from: "question", "text", "prompt"), !text.isEmpty else { return nil }
        let options = json["options"]?.arrayValue?.compactMap(UserQuestionOption.init(grokJSON:)) ?? []
        let multiSelect = json["multiSelect"]?.boolValue
            ?? json["multi_select"]?.boolValue
            ?? false
        self.init(
            id: UUID(),
            text: text,
            options: options,
            multiSelect: multiSelect
        )
    }

    init?(json: JSONValue) {
        self.init(grokJSON: json)
    }
}

private extension JSONValue {
    func string(from keys: String...) -> String? {
        for key in keys {
            if let value = self[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
