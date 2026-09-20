import SwiftUI

// MARK: - Tool Row (B: Cursor-like minimal line)

struct ToolCompactRow: View {
    let call: ToolCallView
    let isOpen: Bool
    var connectAbove: Bool = false
    var connectBelow: Bool = false
    let onToggle: () -> Void

    private var isRunning: Bool {
        call.showsProgress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    statusLeading
                        .frame(width: 14, height: 14)

                    // 有 description 时折叠行只显示意图；具体命令在展开的 commandBody 里。
                    HStack(spacing: 8) {
                        Text(shortTitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary.opacity(0.92))
                            .lineLimit(1)

                        if let badge = diffBadge {
                            if badge.added > 0 {
                                Text("+\(badge.added)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Palette.moss)
                            }
                            if badge.removed > 0 {
                                Text("−\(badge.removed)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.red.opacity(0.85))
                            }
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .animation(.easeInOut(duration: 0.15), value: isOpen)
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 时间线段画在整行高度上，图标处留 14pt 空档，避免穿模。
            .overlay(alignment: .topLeading) {
                ActivityTimelineSegments(
                    connectAbove: connectAbove,
                    connectBelow: connectBelow && !isOpen,
                    iconTop: 3,
                    iconSize: 14
                )
            }

            if isOpen {
                // 只用淡入：move + 高度变化会叠成「跳进来」。
                ToolCallDetail(call: call)
                    .padding(.leading, 14)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isOpen)
    }

    @ViewBuilder
    private var statusLeading: some View {
        if isRunning {
            // Keep the live tool indicator on the system ProgressView so streaming
            // matches the activity header (Apple control, same spin cadence).
            ProgressView()
                .controlSize(.mini)
        } else {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(statusColor)
        }
    }

    private static let backtickRegex = try! NSRegularExpression(pattern: #"`([^`]+)`"#)

    private var shortTitle: String {
        // Prefer model intent; fall back to displayTitle (then shorten backtick paths).
        var title = call.compactTitle
        let nsTitle = title as NSString
        let matches = Self.backtickRegex.matches(in: title, range: NSRange(location: 0, length: nsTitle.length))
        for match in matches.reversed() where match.numberOfRanges > 1 {
            let path = nsTitle.substring(with: match.range(at: 1))
            let leaf = URL(fileURLWithPath: path).lastPathComponent
            title = (title as NSString).replacingCharacters(in: match.range, with: leaf)
        }
        return title
    }

    private var icon: String {
        switch call.cardLayout {
        case .command: return "terminal"
        case .edit: return "pencil"
        case .file: return "doc.text"
        case .search: return "magnifyingglass"
        case .fetch: return "globe"
        case .other:
            if ToolCallView.titleHasToken(call.title, ["read", "view", "readfile", "viewfile"]) { return "doc.text" }
            if ToolCallView.titleHasToken(call.title, ["edit", "write", "create", "editfile", "writefile"]) { return "pencil" }
            if ToolCallView.titleHasToken(call.title, ["search", "grep", "find"]) { return "magnifyingglass" }
            return "wrench.and.screwdriver"
        }
    }

    private var diffBadge: (added: Int, removed: Int)? {
        guard call.cardLayout == .edit, !call.diffs.isEmpty else { return nil }
        var added = 0
        var removed = 0
        for diff in call.diffs {
            let result = TextDiff.compare(old: diff.oldText, new: diff.newText)
            added += result.added
            removed += result.removed
        }
        if added == 0, removed == 0 { return nil }
        return (added, removed)
    }

    private var statusColor: Color {
        // 参考图：工具图标偏灰，不拿品牌绿和思考抢对比。
        switch call.status.lowercased() {
        case "completed", "success": return Color.secondary.opacity(0.72)
        case "failed", "error": return .red
        case "in_progress", "running": return Palette.sky
        case "cancelled", "denied", "rejected": return Color.secondary.opacity(0.45)
        default: return Color.secondary.opacity(0.55)
        }
    }
}

// MARK: - Expanded body (also used by the permission card)

struct ToolCallDetail: View {
    @Environment(AppModel.self) private var model
    let call: ToolCallView
    var lineLimit: Int = 16

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.secondary.opacity(0.28))
                .frame(width: 1)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 8) {
                switch call.cardLayout {
                case .command:
                    commandBody
                case .edit:
                    locationLinks
                    diffs
                    extraInput
                case .file:
                    locationLinks
                    labeledText("内容".localized, call.contentText, lines: lineLimit)
                    extraInput
                case .search:
                    if let pattern = call.searchPattern {
                        labeledText("模式".localized, pattern, lines: 3)
                    }
                    locationLinks
                    labeledText("结果".localized, call.contentText, lines: lineLimit)
                    extraInput
                case .fetch:
                    if let url = call.fetchURL {
                        urlRow(url)
                    }
                    labeledText("内容".localized, call.contentText, lines: lineLimit)
                    extraInput
                case .other:
                    locationLinks
                    fallbackInput
                    labeledText(nil, call.contentText, lines: min(lineLimit, 12))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var commandBody: some View {
        if let cwd = call.terminalCwd {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(cwd)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }

        if let command = call.terminalCommand {
            HStack(alignment: .top, spacing: 6) {
                Text("$")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Palette.sky)
                Text(Self.clamped(command))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("复制命令".localized)
            }
        } else if !call.terminalIds.isEmpty {
            Text(call.status.lowercased() == "completed" ? "终端已结束".localized : "终端运行中".localized)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        if let output = call.terminalOutput, !output.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("输出".localized)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    if let code = call.terminalExitCode {
                        Text("退出码 %lld".localized(code))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(code == 0 ? Palette.moss : Color.red)
                    }
                }
                Text(Self.clamped(output))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(lineLimit)
            }
        }

        extraInput
    }

    @ViewBuilder
    private var locationLinks: some View {
        if !call.locations.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(call.locations.enumerated()), id: \.offset) { _, location in
                    Button {
                        model.inspectorOpen = true
                        model.openFileTab(path: location.path)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.doc.on.clipboard")
                                .font(.system(size: 10))
                            Text(locationLabel(location))
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                    .help("在编辑器中打开".localized)
                }
            }
        }
    }

    @ViewBuilder
    private var diffs: some View {
        ForEach(Array(call.diffs.enumerated()), id: \.offset) { _, diff in
            ToolDiffBlock(
                path: diff.path,
                oldText: diff.oldText,
                newText: diff.newText,
                lineLimit: lineLimit
            )
        }
    }

    /// Leftover rawInput fields as labeled rows — never a single compact JSON blob.
    @ViewBuilder
    private var extraInput: some View {
        structuredFields(from: call.otherRawInput, tone: .tertiary)
    }

    /// `.other` tools: parse rawInput into fields; fall back to pretty JSON only if needed.
    @ViewBuilder
    private var fallbackInput: some View {
        let source = call.otherRawInput ?? call.rawInput
        if case .object(let dict)? = source, !dict.isEmpty {
            structuredFields(from: source, tone: .secondary)
        } else if let source, source != .null {
            Text(Self.clamped(source.prettyPrinted()))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private enum FieldTone {
        case secondary, tertiary
    }

    @ViewBuilder
    private func structuredFields(from json: JSONValue?, tone: FieldTone) -> some View {
        if case .object(let dict)? = json, !dict.isEmpty {
            let keys = dict.keys.sorted()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(keys, id: \.self) { key in
                    if let value = dict[key] {
                        fieldRow(label: Self.humanKey(key), value: value, tone: tone)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fieldRow(label: String, value: JSONValue, tone: FieldTone) -> some View {
        let bodyColor: Color = tone == .secondary ? Color.secondary : Color.secondary.opacity(0.7)
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(Self.clamped(Self.displayValue(value)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(bodyColor)
                .textSelection(.enabled)
                .lineLimit(lineLimit)
        }
    }

    @ViewBuilder
    private func labeledText(_ label: String?, _ text: String, lines: Int) -> some View {
        if !text.isEmpty {
            let shown = Self.maybePrettyJSON(text)
            VStack(alignment: .leading, spacing: 3) {
                if let label {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Text(Self.clamped(shown))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(lines)
            }
        }
    }

    private static func humanKey(_ key: String) -> String {
        switch key.lowercased() {
        case "command", "cmd": return "命令".localized
        case "path", "file_path", "filepath", "target_file": return "路径".localized
        case "cwd", "working_dir", "workingdir", "workdir": return "工作目录".localized
        case "pattern", "query": return "模式".localized
        case "url": return "URL"
        case "content", "text", "output": return "内容".localized
        case "old_string", "oldstring": return "原文".localized
        case "new_string", "newstring": return "新文".localized
        case "offset": return "偏移".localized
        case "limit": return "行数".localized
        default:
            return key.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func displayValue(_ value: JSONValue) -> String {
        if let s = value.stringValue { return maybePrettyJSON(s) }
        if case .bool(let b) = value { return b ? "true" : "false" }
        if case .number(let n) = value { return "\(n)" }
        if case .null = value { return "null" }
        return value.prettyPrinted()
    }

    private static func maybePrettyJSON(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return text }
        guard let parsed = try? JSONValue.decode(from: trimmed) else { return text }
        return parsed.prettyPrinted()
    }

    private func urlRow(_ url: String) -> some View {
        Button {
            if let parsed = URL(string: url) {
                NSWorkspace.shared.open(parsed)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                Text(url)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(2)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accent)
        .help("在浏览器中打开".localized)
    }

    private func locationLabel(_ location: ToolCallLocation) -> String {
        let name = URL(fileURLWithPath: location.path).lastPathComponent
        if let line = location.line {
            return "\(name):\(line)"
        }
        return name
    }

    /// `lineLimit` 只管显示行数，`Text` 仍会把整个字符串排一遍。工具输入 / 输出
    /// 动辄是整个文件，所以先在字符串层面砍掉再交给 Text。
    private static let displayLimit = 4096

    private static func clamped(_ text: String) -> String {
        guard text.count > displayLimit else { return text }
        return String(text.prefix(displayLimit)) + "\n" + "… 已截断 %lld 个字符".localized(text.count - displayLimit)
    }
}

private struct ToolDiffBlock: View {
    let path: String
    let oldText: String?
    let newText: String?
    var lineLimit: Int

    private var result: TextDiff.Result {
        TextDiff.compare(old: oldText, new: newText)
    }

    var body: some View {
        let diff = result
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if diff.added > 0 {
                    Text("+\(diff.added)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.moss)
                }
                if diff.removed > 0 {
                    Text("−\(diff.removed)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.red.opacity(0.85))
                }
            }

            if diff.isIdentity {
                Text("无行级变更".localized)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                hunkList(diff)
            }

            if diff.truncated {
                Text("仅比较前 %lld 行".localized(TextDiff.maxInputLines))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func hunkList(_ diff: TextDiff.Result) -> some View {
        let shown = displayedHunks(diff)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown.rows, id: \.offset) { row in
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.hunk.header)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 2)
                    ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in
                        diffLine(line)
                    }
                }
            }
            if shown.hiddenHunks > 0 || shown.hiddenLines > 0 {
                Text(shown.hiddenHunks > 0
                     ? "还有 %lld 个片段".localized(shown.hiddenHunks)
                     : "还有 %lld 行".localized(shown.hiddenLines))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func displayedHunks(_ diff: TextDiff.Result) -> (
        rows: [(offset: Int, hunk: TextDiff.Hunk, lines: [TextDiff.Line])],
        hiddenHunks: Int,
        hiddenLines: Int
    ) {
        let cap = max(lineLimit, 6)
        var remaining = cap
        var rows: [(offset: Int, hunk: TextDiff.Hunk, lines: [TextDiff.Line])] = []
        for (index, hunk) in diff.hunks.enumerated() {
            guard remaining > 0 else { break }
            let slice = Array(hunk.lines.prefix(remaining))
            remaining -= slice.count
            rows.append((index, hunk, slice))
        }
        return (
            rows,
            diff.hunks.count - rows.count,
            rows.reduce(0) { $0 + ($1.hunk.lines.count - $1.lines.count) }
        )
    }

    private func diffLine(_ line: TextDiff.Line) -> some View {
        let color: Color = {
            switch line.kind {
            case .insert: return Palette.moss
            case .delete: return Color.red.opacity(0.85)
            case .context: return Color.secondary
            }
        }()
        let fill: Color = {
            switch line.kind {
            case .insert: return Palette.moss.opacity(0.10)
            case .delete: return Color.red.opacity(0.08)
            case .context: return Color.clear
            }
        }()
        return HStack(alignment: .top, spacing: 0) {
            Text(line.prefix)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 12, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(line.kind == .context ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 0.5)
        .padding(.horizontal, 2)
        .background(fill)
    }
}
