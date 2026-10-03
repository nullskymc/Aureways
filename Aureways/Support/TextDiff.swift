import Foundation

/// Line-oriented unified diff for ACP edit tool cards (`oldText` / `newText`).
enum TextDiff {
    static let maxInputLines = 2000
    static let defaultContext = 3

    struct Line: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case context
            case insert
            case delete
        }

        var kind: Kind
        var text: String

        var prefix: String {
            switch kind {
            case .context: return " "
            case .insert: return "+"
            case .delete: return "-"
            }
        }
    }

    struct Hunk: Equatable, Sendable {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        var lines: [Line]

        var header: String {
            "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        }
    }

    struct Result: Equatable, Sendable {
        var hunks: [Hunk]
        var added: Int
        var removed: Int
        var truncated: Bool

        var isIdentity: Bool { added == 0 && removed == 0 }
    }

    static func compare(old: String?, new: String?, context: Int = defaultContext) -> Result {
        let oldLines = splitLines(old ?? "")
        let newLines = splitLines(new ?? "")
        let truncated = oldLines.count > maxInputLines || newLines.count > maxInputLines
        let a = Array(oldLines.prefix(maxInputLines))
        let b = Array(newLines.prefix(maxInputLines))
        let classified = classify(old: a, new: b)
        let added = classified.reduce(0) { $0 + ($1.kind == .insert ? 1 : 0) }
        let removed = classified.reduce(0) { $0 + ($1.kind == .delete ? 1 : 0) }
        return Result(
            hunks: hunks(from: classified, context: max(0, context)),
            added: added,
            removed: removed,
            truncated: truncated
        )
    }

    static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func classify(old: [String], new: [String]) -> [Line] {
        var removals = Set<Int>()
        var insertions = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _):
                removals.insert(offset)
            case .insert(let offset, _, _):
                insertions.insert(offset)
            }
        }

        var result: [Line] = []
        result.reserveCapacity(old.count + new.count)
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removals.contains(i) {
                result.append(Line(kind: .delete, text: old[i]))
                i += 1
            } else if j < new.count, insertions.contains(j) {
                result.append(Line(kind: .insert, text: new[j]))
                j += 1
            } else if i < old.count, j < new.count {
                result.append(Line(kind: .context, text: old[i]))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return result
    }

    static func hunks(from lines: [Line], context: Int) -> [Hunk] {
        var islands: [(Int, Int)] = []
        var index = 0
        while index < lines.count {
            if lines[index].kind == .context {
                index += 1
                continue
            }
            var end = index
            while end + 1 < lines.count, lines[end + 1].kind != .context {
                end += 1
            }
            islands.append((index, end))
            index = end + 1
        }
        guard !islands.isEmpty else { return [] }

        var ranges: [(Int, Int)] = []
        for (start, end) in islands {
            let lo = max(0, start - context)
            let hi = min(lines.count - 1, end + context)
            if let last = ranges.last, lo <= last.1 + 1 {
                ranges[ranges.count - 1] = (last.0, max(last.1, hi))
            } else {
                ranges.append((lo, hi))
            }
        }

        var oldLine = 0
        var newLine = 0
        var cursor = 0
        var result: [Hunk] = []
        result.reserveCapacity(ranges.count)
        for (lo, hi) in ranges {
            while cursor < lo {
                advance(&oldLine, &newLine, kind: lines[cursor].kind)
                cursor += 1
            }
            var oldCount = 0
            var newCount = 0
            var hunkLines: [Line] = []
            hunkLines.reserveCapacity(hi - lo + 1)
            var idx = lo
            while idx <= hi {
                let line = lines[idx]
                hunkLines.append(line)
                switch line.kind {
                case .context:
                    oldCount += 1
                    newCount += 1
                case .delete:
                    oldCount += 1
                case .insert:
                    newCount += 1
                }
                idx += 1
            }
            let oldStart = oldCount == 0 ? oldLine : oldLine + 1
            let newStart = newCount == 0 ? newLine : newLine + 1
            result.append(
                Hunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, lines: hunkLines)
            )
            while cursor <= hi {
                advance(&oldLine, &newLine, kind: lines[cursor].kind)
                cursor += 1
            }
        }
        return result
    }

    private static func advance(_ oldLine: inout Int, _ newLine: inout Int, kind: Line.Kind) {
        switch kind {
        case .context:
            oldLine += 1
            newLine += 1
        case .delete:
            oldLine += 1
        case .insert:
            newLine += 1
        }
    }
}
