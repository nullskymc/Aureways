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
                if let rawInput = call.rawInput, let inputStr = try? String(data: rawInput.encode(), encoding: .utf8) {
                    Text(inputStr)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.badgeBg.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                if !call.contentText.isEmpty {
                    Text(call.contentText)
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

