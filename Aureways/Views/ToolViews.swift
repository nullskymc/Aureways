import SwiftUI

// MARK: - Tool Row

struct ToolCompactRow: View {
    let call: ToolCallView
    let isOpen: Bool
    let onToggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                        .frame(width: 14)
                    Text(shortTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Palette.cardHover.opacity(0.40))
                }
            }
            .onHover { isHovered = $0 }

            if isOpen {
                ToolCallDetail(call: call)
                    .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
    }

    private static let backtickRegex = try! NSRegularExpression(pattern: #"`([^`]+)`"#)

    private var shortTitle: String {
        var title = call.displayTitle
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

    private var statusColor: Color {
        switch call.status.lowercased() {
        case "completed", "success": return Palette.moss
        case "failed", "error": return .red
        case "in_progress", "running": return Palette.sky
        case "cancelled", "denied", "rejected": return Color.secondary
        default: return Palette.gold
        }
    }
}

// MARK: - Expanded body (also used by the permission card)

struct ToolCallDetail: View {
    @Environment(AppModel.self) private var model
    let call: ToolCallView
    var lineLimit: Int = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch call.cardLayout {
            case .command:
                commandBody
            case .edit:
                locationLinks
                diffs
                extraInput
            case .file:
                locationLinks
                labeledText("内容", call.contentText, lines: lineLimit)
                extraInput
            case .search:
                if let pattern = call.searchPattern {
                    labeledText("模式", pattern, lines: 3)
                }
                locationLinks
                labeledText("结果", call.contentText, lines: lineLimit)
                extraInput
            case .fetch:
                if let url = call.fetchURL {
                    urlRow(url)
                }
                labeledText("内容", call.contentText, lines: lineLimit)
                extraInput
            case .other:
                locationLinks
                fallbackInput
                labeledText(nil, call.contentText, lines: min(lineLimit, 12))
            }
        }
    }

    @ViewBuilder
    private var commandBody: some View {
        if let cwd = call.terminalCwd {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(cwd)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Palette.badgeBg.opacity(0.40), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("复制命令")
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.badgeBg.opacity(0.60), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else if !call.terminalIds.isEmpty {
            Text(call.status.lowercased() == "completed" ? "终端已结束" : "终端运行中")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
        }

        if let output = call.terminalOutput, !output.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("输出")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let code = call.terminalExitCode {
                        Text("退出码 \(code)")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(code == 0 ? Palette.moss : Color.red)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                (code == 0 ? Palette.moss : Color.red).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                            )
                    }
                }
                Text(Self.clamped(output))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(lineLimit)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.badgeBg.opacity(0.40), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
                    .help("在编辑器中打开")
                }
            }
        }
    }

    @ViewBuilder
    private var diffs: some View {
        ForEach(Array(call.diffs.enumerated()), id: \.offset) { _, diff in
            VStack(alignment: .leading, spacing: 4) {
                Text(URL(fileURLWithPath: diff.path).lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                if let oldText = diff.oldText, !oldText.isEmpty {
                    Text(Self.clamped(oldText))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(min(lineLimit, 8))
                }
                if let newText = diff.newText, !newText.isEmpty {
                    Text(Self.clamped(newText))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(lineLimit)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.badgeBg.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    @ViewBuilder
    private var extraInput: some View {
        if let extra = call.otherRawInput,
           let extraStr = try? String(data: extra.encode(), encoding: .utf8), extraStr != "{}" {
            Text(Self.clamped(extraStr))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.badgeBg.opacity(0.30), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder
    private var fallbackInput: some View {
        if let rawInput = call.otherRawInput ?? call.rawInput,
           let inputStr = try? String(data: rawInput.encode(), encoding: .utf8),
           inputStr != "{}" {
            Text(Self.clamped(inputStr))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.badgeBg.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    @ViewBuilder
    private func labeledText(_ label: String?, _ text: String, lines: Int) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let label {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(Self.clamped(text))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(lines)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.badgeBg.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
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
        .help("在浏览器中打开")
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
        return String(text.prefix(displayLimit)) + "\n… 已截断 \(text.count - displayLimit) 个字符"
    }
}
