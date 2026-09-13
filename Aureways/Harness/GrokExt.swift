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
        let questions = params["questions"]?.arrayValue?.compactMap(UserQuestion.init) ?? []
        return UserQuestionPrompt(sessionId: sessionId, questions: questions)
    }
}

struct PlanApprovalPrompt: Sendable, Equatable {
    var sessionId: String
    var content: String
    var filePath: String?

    var isEmpty: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum PlanApprovalDecision: Sendable, Equatable {
    case approved(feedback: String)
    case requestChanges
    case quit

    /// `ExitPlanModeExtResponse` is a 2-field struct in grok. Extra keys are
    /// ignored by default serde; keep `approved` + `comments` as the pair.
    var json: JSONValue {
        switch self {
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
}

struct UserQuestionOption: Identifiable, Sendable, Equatable {
    var id: String { label }
    var label: String
    var description: String?
    var preview: String?

    init?(json: JSONValue) {
        guard let label = json.string(from: "label", "name", "id"), !label.isEmpty else { return nil }
        self.label = label
        let description = json.string(from: "description", "detail")
        self.description = description?.isEmpty == false ? description : nil
        let preview = json.string(from: "preview")
        self.preview = preview?.isEmpty == false ? preview : nil
    }
}

struct UserQuestion: Identifiable, Sendable, Equatable {
    let id: UUID
    var text: String
    var options: [UserQuestionOption]
    var multiSelect: Bool

    init?(json: JSONValue) {
        guard let text = json.string(from: "question", "text", "prompt"), !text.isEmpty else { return nil }
        self.id = UUID()
        self.text = text
        self.options = json["options"]?.arrayValue?.compactMap(UserQuestionOption.init) ?? []
        self.multiSelect = json["multiSelect"]?.boolValue
            ?? json["multi_select"]?.boolValue
            ?? false
    }
}

struct UserQuestionPrompt: Sendable, Equatable {
    var sessionId: String
    var questions: [UserQuestion]
}

enum UserQuestionDecision: Sendable, Equatable {
    /// Selected labels keyed by question id.
    case accepted([UUID: [String]])
    case skipInterview
    case chatAboutThis

    func json(for prompt: UserQuestionPrompt) -> JSONValue {
        switch self {
        case .skipInterview:
            return .object(["outcome": .string("skip_interview")])
        case .chatAboutThis:
            return .object(["outcome": .string("chat_about_this")])
        case .accepted(let selections):
            // `answers` is a map (question text → selected labels), not an array.
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
