import XCTest

final class TextDiffTests: XCTestCase {
    func testReplacesASingleLine() {
        let result = TextDiff.compare(old: "a\nb\nc", new: "a\nX\nc")
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.hunks.count, 1)
        let hunk = result.hunks[0]
        XCTAssertEqual(hunk.header, "@@ -1,3 +1,3 @@")
        XCTAssertEqual(hunk.lines.map(\.prefix), [" ", "-", "+", " "])
        XCTAssertEqual(hunk.lines.map(\.text), ["a", "b", "X", "c"])
    }

    func testAppendsAtEnd() {
        let result = TextDiff.compare(old: "a\nb", new: "a\nb\nc")
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.hunks.count, 1)
        XCTAssertEqual(result.hunks[0].header, "@@ -1,2 +1,3 @@")
        XCTAssertEqual(result.hunks[0].lines.last?.kind, .insert)
        XCTAssertEqual(result.hunks[0].lines.last?.text, "c")
    }

    func testNewFileIsAllInserts() {
        let result = TextDiff.compare(old: nil, new: "one\ntwo")
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.hunks.count, 1)
        XCTAssertEqual(result.hunks[0].header, "@@ -0,0 +1,2 @@")
        XCTAssertTrue(result.hunks[0].lines.allSatisfy { $0.kind == .insert })
    }

    func testDeletedFileIsAllDeletes() {
        let result = TextDiff.compare(old: "gone", new: nil)
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.hunks[0].header, "@@ -1,1 +0,0 @@")
        XCTAssertEqual(result.hunks[0].lines.map(\.kind), [.delete])
    }

    func testIdentityHasNoHunks() {
        let result = TextDiff.compare(old: "same\nfile", new: "same\nfile")
        XCTAssertTrue(result.isIdentity)
        XCTAssertTrue(result.hunks.isEmpty)
    }

    func testContextCollapsesDistantChanges() {
        let old = (1...20).map(String.init).joined(separator: "\n")
        let newLines = (1...20).map(String.init)
        var replaced = newLines
        replaced[4] = "X"
        replaced[15] = "Y"
        let result = TextDiff.compare(old: old, new: replaced.joined(separator: "\n"), context: 2)
        XCTAssertEqual(result.hunks.count, 2)
        XCTAssertEqual(result.hunks[0].oldStart, 3)
        XCTAssertEqual(result.hunks[1].oldStart, 14)
        XCTAssertTrue(result.hunks[0].lines.contains(where: { $0.text == "X" && $0.kind == .insert }))
        XCTAssertTrue(result.hunks[1].lines.contains(where: { $0.text == "Y" && $0.kind == .insert }))
    }

    func testEmptyOldAndNew() {
        let result = TextDiff.compare(old: "", new: "")
        XCTAssertTrue(result.isIdentity)
        XCTAssertTrue(result.hunks.isEmpty)
        XCTAssertFalse(result.truncated)
    }
}
