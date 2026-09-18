import Foundation
import os

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
    private static let signposter = OSSignposter(subsystem: "ai.aureways.client", category: "Virtualizer")

    var lastOffset: CGFloat = 0
    var lastViewport: CGFloat = 720
    private var heights: [UUID: CGFloat] = [:]

    // Cached prefix sums and row heights for entries (PERF-04)
    private var cachedEntryIDs: [UUID] = []
    private var cachedEntryVersions: [UInt64] = []
    private var cachedRowHeights: [CGFloat] = []
    private var cachedPrefixes: [CGFloat] = []
    private var isIndexValid = false

    func height(for block: TranscriptBlock) -> CGFloat {
        heights[block.id] ?? Self.estimate(block)
    }

    func rowHeights(for entries: [TranscriptEntry]) -> [CGFloat] {
        ensureIndex(for: entries)
        return cachedRowHeights
    }

    @discardableResult
    func set(_ id: UUID, _ height: CGFloat) -> Bool {
        let rounded = (height * 2).rounded() / 2
        guard rounded > 0, heights[id] != rounded else { return false }
        heights[id] = rounded
        isIndexValid = false
        return true
    }

    @discardableResult
    func prune(keeping ids: Set<UUID>) -> Int {
        let before = heights.count
        if before == 0 { return 0 }
        if before <= ids.count, heights.keys.allSatisfy({ ids.contains($0) }) {
            return 0
        }
        heights = heights.filter { ids.contains($0.key) }
        isIndexValid = false
        return before - heights.count
    }

    func window(
        for entries: [TranscriptEntry],
        offset: CGFloat,
        viewport: CGFloat,
        overscan: CGFloat = TranscriptVirtualizer.overscan,
        spacing: CGFloat = TranscriptVirtualizer.spacing
    ) -> TranscriptWindow {
        ensureIndex(for: entries)
        guard !cachedRowHeights.isEmpty else { return .empty }
        return TranscriptVirtualizer.window(
            rowHeights: cachedRowHeights,
            offset: offset,
            viewport: viewport,
            overscan: overscan,
            spacing: spacing,
            prefixes: cachedPrefixes
        )
    }

    private func ensureIndex(for entries: [TranscriptEntry]) {
        if isIndexValid && entriesMatchCache(entries) {
            return
        }

        let signpostID = Self.signposter.makeSignpostID()
        let state = Self.signposter.beginInterval("RowHeightRecalc", id: signpostID)
        defer { Self.signposter.endInterval("RowHeightRecalc", state) }

        // Fast path: append of a single item to previous valid index
        if isIndexValid,
           entries.count == cachedEntryIDs.count + 1,
           let last = entries.last,
           cachedEntryIDs.elementsEqual(entries.dropLast().lazy.map(\.id)),
           cachedEntryVersions.elementsEqual(entries.dropLast().lazy.map(\.version)) {
            let n = cachedEntryIDs.count
            let h = height(for: last.block)
            cachedEntryIDs.append(last.id)
            cachedEntryVersions.append(last.version)
            cachedRowHeights.append(h)
            // prefixes[n] currently stores content total. After a following
            // row exists that becomes the start of the new row (old total +
            // spacing). prefixes[0] stays 0 when n == 0.
            if n > 0 {
                cachedPrefixes[n] += TranscriptVirtualizer.spacing
            }
            cachedPrefixes.append(cachedPrefixes[n] + h)
            return
        }

        // Fast path: last row grew in place (streaming). Prefix rows unchanged.
        if isIndexValid,
           entries.count == cachedEntryIDs.count,
           let last = entries.last,
           last.id == cachedEntryIDs.last {
            let lastIndex = entries.count - 1
            var prefixMatches = true
            if lastIndex > 0 {
                for index in 0..<lastIndex {
                    if entries[index].id != cachedEntryIDs[index]
                        || entries[index].version != cachedEntryVersions[index] {
                        prefixMatches = false
                        break
                    }
                }
            }
            if prefixMatches {
                let h = height(for: last.block)
                let delta = h - cachedRowHeights[lastIndex]
                cachedEntryVersions[lastIndex] = last.version
                cachedRowHeights[lastIndex] = h
                cachedPrefixes[lastIndex + 1] += delta
                #if DEBUG
                PerfCounters.countIndexLastRowUpdate()
                #endif
                return
            }
        }

        // Full rebuild
        let count = entries.count
        var rowHeights = [CGFloat]()
        rowHeights.reserveCapacity(count)
        var ids = [UUID]()
        ids.reserveCapacity(count)
        var versions = [UInt64]()
        versions.reserveCapacity(count)
        var prefixes = [CGFloat](repeating: 0, count: count + 1)

        var y: CGFloat = 0
        for index in 0..<count {
            let entry = entries[index]
            ids.append(entry.id)
            versions.append(entry.version)
            let h = height(for: entry.block)
            rowHeights.append(h)
            prefixes[index] = y
            y += h
            if index < count - 1 { y += TranscriptVirtualizer.spacing }
        }
        prefixes[count] = y

        cachedEntryIDs = ids
        cachedEntryVersions = versions
        cachedRowHeights = rowHeights
        cachedPrefixes = prefixes
        isIndexValid = true
        #if DEBUG
        PerfCounters.countIndexFullRebuild()
        #endif
    }

    private func entriesMatchCache(_ entries: [TranscriptEntry]) -> Bool {
        guard entries.count == cachedEntryIDs.count else { return false }
        for index in 0..<entries.count {
            if entries[index].id != cachedEntryIDs[index] || entries[index].version != cachedEntryVersions[index] {
                return false
            }
        }
        return true
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
        spacing: CGFloat = spacing,
        prefixes: [CGFloat]? = nil
    ) -> TranscriptWindow {
        let count = rowHeights.count
        guard count > 0 else { return .empty }

        let pre: [CGFloat]
        let contentHeight: CGFloat
        if let prefixes, prefixes.count == count + 1 {
            pre = prefixes
            contentHeight = prefixes[count]
        } else {
            var computed = [CGFloat](repeating: 0, count: count + 1)
            var y: CGFloat = 0
            for index in 0..<count {
                computed[index] = y
                y += rowHeights[index]
                if index < count - 1 { y += spacing }
            }
            computed[count] = y
            pre = computed
            contentHeight = y
        }

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

        // Binary search: find start (first row whose bottom edge reaches or passes viewTop)
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if pre[mid] + rowHeights[mid] < viewTop {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var start = low

        // Binary search: find end (first row whose top edge reaches or passes viewBottom)
        low = start
        high = count
        while low < high {
            let mid = (low + high) / 2
            if pre[mid] < viewBottom {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var end = low
        if end <= start { end = min(start + 1, count) }

        let topHeight = pre[start]
        let innerHeight = (pre[end - 1] + rowHeights[end - 1]) - pre[start]
        let bottomHeight = max(0, contentHeight - topHeight - innerHeight)
        return TranscriptWindow(
            start: start,
            end: end,
            topHeight: start == 0 ? 0 : topHeight,
            bottomHeight: end == count ? 0 : bottomHeight
        )
    }
}
