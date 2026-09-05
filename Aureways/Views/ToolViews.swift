import SwiftUI

// MARK: - Tool Row

struct ToolCompactRow: View {
    @Environment(AppModel.self) private var model
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
                    .padding(.horizontal, 8)
                }
                ForEach(Array(call.diffs.enumerated()), id: \.offset) { _, diff in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(fileURLWithPath: diff.path).lastPathComponent)
                            .font(.system(size: 11, weight: .semibold))
                        if let newText = diff.newText, !newText.isEmpty {
                            Text(Self.clamped(newText))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(16)
                        } else if let oldText = diff.oldText, !oldText.isEmpty {
                            Text(Self.clamped(oldText))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(12)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.badgeBg.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                if let rawInput = call.rawInput, let inputStr = try? String(data: rawInput.encode(), encoding: .utf8) {
                    Text(Self.clamped(inputStr))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.badgeBg.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                if !call.contentText.isEmpty {
                    Text(Self.clamped(call.contentText))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(12)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.badgeBg.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// `lineLimit` 只管显示行数，`Text` 仍会把整个字符串排一遍。工具输入 / 输出
    /// 动辄是整个文件，所以先在字符串层面砍掉再交给 Text。
    private static let displayLimit = 4096

    private static func clamped(_ text: String) -> String {
        guard text.count > displayLimit else { return text }
        return String(text.prefix(displayLimit)) + "\n… 已截断 \(text.count - displayLimit) 个字符"
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
        switch call.kind {
        case "read": return "doc.text"
        case "edit", "delete", "move": return "pencil"
        case "execute": return "terminal"
        case "search": return "magnifyingglass"
        case "fetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    private func locationLabel(_ location: ToolCallLocation) -> String {
        let name = URL(fileURLWithPath: location.path).lastPathComponent
        if let line = location.line {
            return "\(name):\(line)"
        }
        return name
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

