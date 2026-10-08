import Foundation

// MARK: - Transcript encoding

extension WebShellBridge {
static func encode(_ item: TranscriptItem, runs: [UUID: ActivityRun]) -> [String: Any] {
        var row: [String: Any]
        switch item {
        case .user(let id, let text, let attachments):
            row = [
                "id": id.uuidString, "kind": "user", "text": text,
                "attachments": attachments.map(encode(attachment:)),
            ]
        case .agent(let id, let text):
            row = ["id": id.uuidString, "kind": "agent", "text": text]
        case .thought(let id, let text):
            row = ["id": id.uuidString, "kind": "thought", "text": text]
        case .tool(let id, let call):
            row = encode(tool: call)
            row["id"] = id.uuidString
            row["kind"] = "tool"
        case .plan(let id, let entries):
            row = [
                "id": id.uuidString, "kind": "plan",
                "entries": entries.map { ["content": $0.content, "status": $0.status] },
            ]
        case .status(let id, let text):
            row = ["id": id.uuidString, "kind": "status", "text": text]
        }
        if let run = runs[item.id] {
            row["run"] = [
                "s": run.startedAt.timeIntervalSince1970 * 1000,
                "e": run.endedAt.map { $0.timeIntervalSince1970 * 1000 as Any } ?? NSNull(),
            ]
        }
        return row
    }

    static func encode(attachment: TranscriptAttachment) -> [String: Any] {
        var row: [String: Any] = [
            "id": attachment.id.uuidString,
            "kind": attachment.isPastedText ? "pastedText" : attachment.kind,
            "name": attachment.name,
        ]
        if let path = attachment.path { row["path"] = path }
        if attachment.characterCount > 0 { row["chars"] = attachment.characterCount }
        if attachment.kind == "image", let base64 = attachment.imageBase64, !base64.isEmpty, base64.utf8.count < 6_000_000 {
            if base64.hasPrefix("data:") {
                row["src"] = base64
            } else {
                row["src"] = "data:\(attachment.mimeType ?? "image/png");base64,\(base64)"
            }
        }
        return row
    }

    private static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        return encoder
    }()

    private static let outputLimit = 24_000
    private static let diffLineLimit = 600

    static func encode(tool call: ToolCallView) -> [String: Any] {
        var row: [String: Any] = [
            "callId": call.toolCallId,
            "title": call.compactTitle,
            "fullTitle": call.displayTitle,
            "toolKind": call.kind,
            "status": call.status.lowercased(),
            "layout": call.cardLayout.rawValue,
            "progress": call.showsProgress,
        ]
        if let path = call.filePath { row["path"] = path }
        switch call.cardLayout {
        case .command:
            if let command = call.terminalCommand { row["command"] = command }
            if let cwd = call.terminalCwd { row["cwd"] = cwd }
            if let output = call.terminalOutput, !output.isEmpty { row["output"] = tail(output) }
            if let code = call.terminalExitCode { row["exitCode"] = code }
        case .search:
            if let pattern = call.searchPattern { row["pattern"] = pattern }
            if !call.contentText.isEmpty { row["output"] = head(call.contentText) }
        case .fetch:
            if let url = call.fetchURL { row["url"] = url }
            if !call.contentText.isEmpty { row["output"] = head(call.contentText) }
        default:
            if !call.contentText.isEmpty { row["output"] = head(call.contentText) }
        }
        let diffs = call.diffs
        if !diffs.isEmpty {
            let settled = !["", "pending", "in_progress", "running"].contains(call.status.lowercased())
            var budget = diffLineLimit
            row["diffs"] = diffs.map { diff -> [String: Any] in
                let result = TextDiff.compare(old: diff.oldText, new: diff.newText)
                var hunks: [[String: Any]] = []
                for hunk in result.hunks where budget > 0 {
                    let lines = hunk.lines.prefix(budget)
                    budget -= lines.count
                    hunks.append([
                        "header": hunk.header,
                        "oldStart": hunk.oldStart,
                        "newStart": hunk.newStart,
                        "lines": lines.map { $0.prefix + $0.text },
                    ])
                }
                var row: [String: Any] = [
                    "path": diff.path,
                    "added": result.added,
                    "removed": result.removed,
                    "truncated": result.truncated || budget <= 0,
                    "isNew": diff.oldText == nil || diff.oldText?.isEmpty == true,
                    "hunks": hunks,
                ]
                // 片段在整份文件里的起始行（0 基），Web 加到 hunk 行号上显示真实行号。
                if let offset = EditLineIndex.shared.offset(
                    path: diff.path, oldText: diff.oldText, newText: diff.newText, settled: settled
                ) {
                    row["lineOffset"] = offset
                }
                return row
            }
        }
        if row["output"] == nil, diffs.isEmpty, let raw = call.rawInput,
           let data = try? Self.prettyEncoder.encode(raw), data.count < 8_000,
           let text = String(data: data, encoding: .utf8), text != "{}", text != "null" {
            row["input"] = text
        }
        return row
    }

    static func encode(_ prompt: PermissionPrompt) -> [String: Any] {
        var row: [String: Any] = [
            "title": prompt.title,
            "options": prompt.options.map { option -> [String: Any] in
                ["id": option.optionId, "name": option.name, "kind": option.kind, "allow": option.isAllow]
            },
        ]
        if let tool = prompt.toolCall { row["tool"] = encode(tool: tool) }
        return row
    }

    private static func head(_ text: String) -> String {
        guard text.utf16.count > outputLimit else { return text }
        let end = text.utf16.index(text.startIndex, offsetBy: outputLimit)
        return String(text[..<end]) + "\n…"
    }

    private static func tail(_ text: String) -> String {
        let count = text.utf16.count
        guard count > outputLimit else { return text }
        let start = text.utf16.index(text.startIndex, offsetBy: count - outputLimit)
        return "…\n" + String(text[start...])
    }
}
