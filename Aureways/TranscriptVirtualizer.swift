import Foundation

/// Visible slice of a virtualized transcript, plus spacer heights for everything
/// above and below. Off-screen rows are not views — they are `Color.clear`
/// frames — so opening the inspector or dragging a split does not re-typeset
/// the whole history.
struct TranscriptWindow: Equatable {
    var start: Int
    var end: Int
    var topHeight: CGFloat
    var bottomHeight: CGFloat

    static let empty = TranscriptWindow(start: 0, end: 0, topHeight: 0, bottomHeight: 0)

    func clamped(to count: Int) -> TranscriptWindow {
        let start = min(max(self.start, 0), count)
        let end = min(max(self.end, start), count)
        return TranscriptWindow(
            start: start,
            end: end,
            topHeight: start == 0 ? 0 : topHeight,
            bottomHeight: end == count ? 0 : bottomHeight
        )
    }
}

/// Measured row heights, keyed by block id. Not observable: writing a height
/// must not invalidate `TranscriptView.body`. Visible rows size themselves;
/// spacers read the cache the next time the window is recomputed.
@MainActor
final class TranscriptHeightCache {
    var lastOffset: CGFloat = 0
    var lastViewport: CGFloat = 720
    private var heights: [UUID: CGFloat] = [:]

    func height(for block: TranscriptBlock) -> CGFloat {
        heights[block.id] ?? Self.estimate(block)
    }

    func rowHeights(for entries: [TranscriptEntry]) -> [CGFloat] {
        entries.map { height(for: $0.block) }
    }

    @discardableResult
    func set(_ id: UUID, _ height: CGFloat) -> Bool {
        let rounded = (height * 2).rounded() / 2
        guard rounded > 0, heights[id] != rounded else { return false }
        heights[id] = rounded
        return true
    }

    func prune(keeping ids: Set<UUID>) {
        heights = heights.filter { ids.contains($0.key) }
    }

    /// Cheap stand-in used only until a row has been on screen once. Live
    /// activity cards sit at the bottom and get measured immediately; collapsed
    /// history cards are a single summary row.
    static func estimate(_ block: TranscriptBlock) -> CGFloat {
        switch block {
        case .user(_, let text, let attachments):
            let lines = max(1, (text.count + 41) / 42)
            let textHeight = 18 + min(lines, 12) * 20
            let attachmentHeight: Int
            if attachments.isEmpty {
                attachmentHeight = 0
            } else if attachments.contains(where: { $0.kind == "image" }) {
                attachmentHeight = 156
            } else {
                attachmentHeight = 36
            }
            return CGFloat(textHeight + attachmentHeight)
        case .agent(_, let text):
            return min(480, max(36, CGFloat(text.count) / 52 * 20))
        case .activity:
            return 44
        case .status:
            return 40
        }
    }
}

enum TranscriptVirtualizer {
    static let spacing: CGFloat = 16
    static let overscan: CGFloat = 900

    /// Maps a scroll offset onto a contiguous range of rows. `offset` of
    /// `.infinity` pins the window to the bottom (follow / first paint).
    static func window(
        rowHeights: [CGFloat],
        offset: CGFloat,
        viewport: CGFloat,
        overscan: CGFloat = overscan,
        spacing: CGFloat = spacing
    ) -> TranscriptWindow {
        let count = rowHeights.count
        guard count > 0 else { return .empty }

        var prefixes = [CGFloat](repeating: 0, count: count + 1)
        var y: CGFloat = 0
        for index in 0..<count {
            prefixes[index] = y
            y += rowHeights[index]
            if index < count - 1 { y += spacing }
        }
        prefixes[count] = y
        let contentHeight = y

        let viewportHeight = max(viewport, 1)
        let maxOffset = max(0, contentHeight - viewportHeight)
        let origin: CGFloat
        if offset.isFinite {
            origin = min(max(offset, 0), maxOffset)
        } else {
            origin = maxOffset
        }
        let viewTop = max(0, origin - overscan)
        let viewBottom = origin + viewportHeight + overscan

        var start = 0
        while start < count, prefixes[start] + rowHeights[start] < viewTop {
            start += 1
        }
        var end = start
        while end < count, prefixes[end] < viewBottom {
            end += 1
        }
        if end <= start { end = min(start + 1, count) }

        let topHeight = prefixes[start]
        let gapCount = max(0, end - start - 1)
        var innerHeight = CGFloat(gapCount) * spacing
        for index in start..<end {
            innerHeight += rowHeights[index]
        }
        let bottomHeight = max(0, contentHeight - topHeight - innerHeight)
        return TranscriptWindow(
            start: start,
            end: end,
            topHeight: start == 0 ? 0 : topHeight,
            bottomHeight: end == count ? 0 : bottomHeight
        )
    }
}
