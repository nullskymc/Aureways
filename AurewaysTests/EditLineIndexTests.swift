import XCTest

final class EditLineIndexTests: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func numbered(_ count: Int) -> String {
        (1...count).map { "line \($0)" }.joined(separator: "\n") + "\n"
    }

    func testSingleMatchReturnsZeroBasedStartLine() {
        let file = numbered(50)
        XCTAssertEqual(EditLineLocator.lineOffset(of: bytes("line 20\nline 21\n"), in: bytes(file)), 19)
        XCTAssertEqual(EditLineLocator.lineOffset(of: bytes("line 1\n"), in: bytes(file)), 0)
        // 片段从行中间开始时仍算它所在的那一行。
        XCTAssertEqual(EditLineLocator.lineOffset(of: bytes("e 30\nline 31"), in: bytes(file)), 29)
    }

    func testMultipleMatchesPickNearestToHintElseFirst() {
        let file = (0..<40).map { $0 % 10 == 5 ? "return nil" : "x\($0)" }.joined(separator: "\n")
        let snippet = bytes("return nil")
        XCTAssertEqual(EditLineLocator.lineOffset(of: snippet, in: bytes(file)), 5)
        XCTAssertEqual(EditLineLocator.lineOffset(of: snippet, in: bytes(file), near: 23), 25)
        XCTAssertEqual(EditLineLocator.lineOffset(of: snippet, in: bytes(file), near: 33), 35)
        XCTAssertEqual(EditLineLocator.lineOffset(of: snippet, in: bytes(file), near: 0), 5)
        XCTAssertEqual(EditLineLocator.lineOffset(of: snippet, in: bytes(file), near: 1_000), 35)
        // 距离相同取靠前的。
        XCTAssertEqual(EditLineLocator.lineOffset(of: snippet, in: bytes(file), near: 10), 5)
    }

    func testResolvePrefersNewTextThenOldTextAndFallsBackToNil() {
        let file = numbered(30).replacingOccurrences(of: "line 12\n", with: "changed 12\n")
        let content = { self.bytes(file) }
        XCTAssertEqual(EditLineLocator.resolve(oldText: "line 12\n", newText: "changed 12\n", hint: nil, content: content), 11)
        // 编辑没落盘（被拒/失败）：文件里还是旧片段。
        XCTAssertEqual(EditLineLocator.resolve(oldText: "line 7\n", newText: "seven\n", hint: nil, content: content), 6)
        // 都找不到 → nil，Web 保留片段内行号。
        XCTAssertNil(EditLineLocator.resolve(oldText: "gone\n", newText: "also gone\n", hint: nil, content: content))
        // 新建文件本来就是整份文件，不读文件也不给偏移。
        var read = false
        XCTAssertNil(EditLineLocator.resolve(oldText: nil, newText: "a\n", hint: nil) { read = true; return self.bytes(file) })
        XCTAssertNil(EditLineLocator.resolve(oldText: "", newText: "a\n", hint: nil) { read = true; return self.bytes(file) })
        XCTAssertFalse(read)
        XCTAssertNil(EditLineLocator.lineOffset(of: [], in: bytes(file)))
    }

    func testLargeFilesAreSkipped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("edit-lines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = dir.appendingPathComponent("small.txt")
        try Data(numbered(10).utf8).write(to: small)
        XCTAssertEqual(EditLineLocator.readCapped(small.path)?.count, numbered(10).utf8.count)

        let big = dir.appendingPathComponent("big.txt")
        try Data(repeating: 0x61, count: EditLineLocator.maxFileBytes + 1).write(to: big)
        XCTAssertNil(EditLineLocator.readCapped(big.path))
        XCTAssertNil(EditLineLocator.readCapped(dir.path), "directories are not read")
        XCTAssertNil(EditLineLocator.readCapped(dir.appendingPathComponent("missing").path))
        XCTAssertNil(EditLineLocator.resolve(oldText: "a", newText: "b", hint: nil) { EditLineLocator.readCapped(big.path) })
    }

    @MainActor
    func testIndexComputesInBackgroundCachesAndUsesPreviousEditAsHint() async {
        let file = (0..<40).map { $0 % 10 == 5 ? "dup" : "x\($0)" }.joined(separator: "\n")
        let reads = ReadCounter()
        let index = EditLineIndex(read: { _ in reads.bump(); return Array(file.utf8) })
        let resolved = expectation(forNotification: EditLineIndex.didResolve, object: index)
        resolved.expectedFulfillmentCount = 2

        // 第一次查询只排队，不阻塞调用方。
        XCTAssertNil(index.offset(path: "/r/a.txt", oldText: "x32\n", newText: "x32\n", settled: true))
        XCTAssertNil(index.offset(path: "/r/a.txt", oldText: "x32\n", newText: "x32\n", settled: true))
        index.drain()
        // 上一次编辑在第 32 行，重复的「dup」取离它最近的第 35 行而不是第一处。
        XCTAssertNil(index.offset(path: "/r/a.txt", oldText: "old", newText: "dup", settled: true))
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(index.offset(path: "/r/a.txt", oldText: "x32\n", newText: "x32\n", settled: true), 32)
        XCTAssertEqual(index.offset(path: "/r/a.txt", oldText: "old", newText: "dup", settled: true), 35)
        XCTAssertEqual(reads.value, 2, "each edit reads the file once, then hits the cache")
        // 相对路径、新建文件不计算。
        XCTAssertNil(index.offset(path: "a.txt", oldText: "x1", newText: "x1", settled: true))
        XCTAssertNil(index.offset(path: "/r/new.txt", oldText: nil, newText: "x1", settled: true))
        index.drain()
        XCTAssertEqual(reads.value, 2)
    }

    @MainActor
    func testUnsettledMissIsRetriedButSettledMissIsCached() async throws {
        let reads = ReadCounter()
        let index = EditLineIndex(read: { _ in reads.bump(); return Array("nothing here\n".utf8) })
        XCTAssertNil(index.offset(path: "/r/b.txt", oldText: "a", newText: "b", settled: false))
        index.drain()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(index.offset(path: "/r/b.txt", oldText: "a", newText: "b", settled: true))
        index.drain()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(index.offset(path: "/r/b.txt", oldText: "a", newText: "b", settled: true))
        index.drain()
        XCTAssertEqual(reads.value, 2)
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
