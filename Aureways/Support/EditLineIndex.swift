import Foundation

/// ACP 编辑工具只给 oldText/newText 片段，TextDiff 的行号从片段第一行算起（「@@ -1,6 +1,6 @@」）。
/// 这里在后台读一次文件，找出片段在整份文件里的起始行，Web 端把它加到 hunk 的行号上，
/// 显示真实的文件行号。找不到就不给偏移，Web 维持片段内的相对行号。
enum EditLineLocator {
    /// 超过这个大小的文件不读，直接退回片段行号。
    static let maxFileBytes = 2_000_000
    /// 片段在文件里重复太多次时不再继续找。
    static let maxMatches = 10_000

    /// `snippet` 第一个字节之前有多少个换行，即片段起始行的 0 基行号；不存在时为 nil。
    /// 多处匹配时取离 `hint`（上一次编辑落在的行）最近的一处（距离相同取靠前的），没有 hint 取第一处。
    static func lineOffset(of snippet: [UInt8], in content: [UInt8], near hint: Int? = nil) -> Int? {
        guard !snippet.isEmpty, snippet.count <= content.count else { return nil }
        return content.withUnsafeBytes { hay -> Int? in
            snippet.withUnsafeBytes { needle -> Int? in
                guard let base = hay.baseAddress, let pattern = needle.baseAddress else { return nil }
                var best: Int?
                var bestDistance = Int.max
                var line = 0
                var scanned = 0
                var start = 0
                var matches = 0
                while start + needle.count <= hay.count, matches < maxMatches {
                    guard let hit = memmem(base + start, hay.count - start, pattern, needle.count) else { break }
                    let index = base.distance(to: UnsafeRawPointer(hit))
                    while scanned < index {
                        if hay[scanned] == 0x0A { line += 1 }
                        scanned += 1
                    }
                    matches += 1
                    guard let hint else { return line }
                    let distance = abs(line - hint)
                    if distance < bestDistance {
                        best = line
                        bestDistance = distance
                    } else if line > hint {
                        break
                    }
                    start = index + 1
                }
                return best
            }
        }
    }

    /// 编辑后文件里先找 newText；找不到（编辑被拒、失败或还没落盘）再找 oldText——
    /// 两者在编辑前后都从同一行开始。新建文件（没有 oldText）本来就是整份文件，不需要偏移。
    static func resolve(
        oldText: String?, newText: String?, hint: Int?, content: () -> [UInt8]?
    ) -> Int? {
        guard let oldText, !oldText.isEmpty else { return nil }
        let candidates = [newText ?? "", oldText].filter { !$0.isEmpty }
        guard !candidates.isEmpty, let bytes = content() else { return nil }
        for text in candidates {
            if let line = lineOffset(of: Array(text.utf8), in: bytes, near: hint) { return line }
        }
        return nil
    }

    /// 读整个文件；超过 `limit` 或读不到时返回 nil。
    static func readCapped(_ path: String, limit: Int = maxFileBytes) -> [UInt8]? {
        let url = URL(fileURLWithPath: path)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])).flatMap({ values -> Int? in
            values.isRegularFile == true ? values.fileSize : nil
        }), size <= limit else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= limit else { return nil }
        return [UInt8](data)
    }
}

/// 每条编辑记录（路径 + 片段）对应的行偏移缓存。第一次 encode 时排队到后台串行队列计算，
/// 算出来后发 `didResolve`，桥接层把含这个文件的工具行重新 upsert 给 Web。主线程只查字典。
@MainActor
final class EditLineIndex {
    static let shared = EditLineIndex()
    static let didResolve = Notification.Name("ai.aureways.editLineIndex.didResolve")
    /// 防止超长会话无限增长；超了就整个清掉重新按需计算。
    static let maxEntries = 4_000

    struct Key: Hashable, Sendable {
        let path: String
        let oldText: String?
        let newText: String?
    }

    private enum Entry {
        case pending
        case resolved(Int?)
    }

    private var entries: [Key: Entry] = [:]
    private let worker: Worker

    init(read: @escaping @Sendable (String) -> [UInt8]? = { EditLineLocator.readCapped($0) }) {
        worker = Worker(read: read)
    }

    /// 已经算出的偏移；还没算过就在后台开始算并返回 nil。`settled` 表示工具已经结束——
    /// 结束前没找到不记缓存，结束后会再试一次。
    func offset(path: String, oldText: String?, newText: String?, settled: Bool) -> Int? {
        guard path.hasPrefix("/"), let oldText, !oldText.isEmpty else { return nil }
        let key = Key(path: path, oldText: oldText, newText: newText)
        switch entries[key] {
        case .resolved(let value)?: return value
        case .pending?: return nil
        case nil: break
        }
        if entries.count >= Self.maxEntries { entries.removeAll(keepingCapacity: true) }
        entries[key] = .pending
        worker.enqueue(key) { [weak self] value in
            guard let self else { return }
            if value == nil, !settled {
                self.entries[key] = nil
                return
            }
            self.entries[key] = .resolved(value)
            if value != nil {
                NotificationCenter.default.post(name: Self.didResolve, object: self, userInfo: ["path": key.path])
            }
        }
        return nil
    }

    /// 测试用：等后台队列清空。
    nonisolated func drain() { worker.drain() }

    private final class Worker: @unchecked Sendable {
        private let queue = DispatchQueue(label: "ai.aureways.edit-line-index", qos: .utility)
        private let read: @Sendable (String) -> [UInt8]?
        /// 每个文件上一次编辑落在的行（只在 queue 上读写），用来在多处匹配里挑最近的。
        private var lastLine: [String: Int] = [:]

        init(read: @escaping @Sendable (String) -> [UInt8]?) { self.read = read }

        func enqueue(_ key: Key, done: @escaping @MainActor @Sendable (Int?) -> Void) {
            queue.async {
                let value = EditLineLocator.resolve(
                    oldText: key.oldText, newText: key.newText, hint: self.lastLine[key.path]
                ) { self.read(key.path) }
                if let value { self.lastLine[key.path] = value }
                DispatchQueue.main.async { MainActor.assumeIsolated { done(value) } }
            }
        }

        func drain() { queue.sync {} }
    }
}
