import UniformTypeIdentifiers
import XCTest
@testable import Aureways

final class MarkdownFileTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("aureways-md-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        scratch = nil
    }

    func testMatchesCommonMarkdownExtensions() {
        XCTAssertTrue(MarkdownFile.matches(path: "/tmp/README.md"))
        XCTAssertTrue(MarkdownFile.matches(path: "/tmp/Notes.MARKDOWN"))
        XCTAssertTrue(MarkdownFile.matches(path: "/tmp/page.mdown"))
        XCTAssertTrue(MarkdownFile.matches(path: "/tmp/doc.mkd"))
        XCTAssertTrue(MarkdownFile.matches(path: "/tmp/wiki.mkdn"))
        XCTAssertTrue(MarkdownFile.matches(path: "/tmp/old.mdwn"))
        XCTAssertFalse(MarkdownFile.matches(path: "/tmp/README.txt"))
        XCTAssertFalse(MarkdownFile.matches(path: "/tmp/README"))
        XCTAssertFalse(MarkdownFile.matches(path: "/tmp/notes.mdx"))
    }

    func testImportedTypeConformsToPlainText() {
        XCTAssertEqual(MarkdownFile.importedType.identifier, "net.daringfireball.markdown")
        XCTAssertTrue(MarkdownFile.importedType.conforms(to: .plainText))
        XCTAssertFalse(MarkdownFile.contentTypes.contains(where: { $0.identifier == UTType.plainText.identifier }))
    }

    func testReadUTF8Text() throws {
        let url = scratch.appendingPathComponent("note.md")
        try "# Hello\n\n世界".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try TextFile.read(from: url), "# Hello\n\n世界")
    }

    func testRejectsMissingFile() {
        let url = scratch.appendingPathComponent("missing.md")
        XCTAssertThrowsError(try TextFile.read(from: url)) { error in
            XCTAssertEqual(error as? TextFile.ReadError, .unreadable)
        }
    }

    func testRejectsTooLargeFile() throws {
        let url = scratch.appendingPathComponent("huge.md")
        try Data(repeating: 0x61, count: 64).write(to: url)
        XCTAssertThrowsError(try TextFile.read(from: url, maxBytes: 32)) { error in
            XCTAssertEqual(error as? TextFile.ReadError, .tooLarge)
        }
    }

    func testRejectsNULAndNonUTF8() throws {
        let binary = scratch.appendingPathComponent("binary.md")
        try Data([0x61, 0x00, 0x62]).write(to: binary)
        XCTAssertThrowsError(try TextFile.read(from: binary)) { error in
            XCTAssertEqual(error as? TextFile.ReadError, .binaryOrNotUTF8)
        }

        let latin1 = scratch.appendingPathComponent("latin1.md")
        try Data([0xFF, 0xFE, 0x41]).write(to: latin1)
        XCTAssertThrowsError(try TextFile.read(from: latin1)) { error in
            XCTAssertEqual(error as? TextFile.ReadError, .binaryOrNotUTF8)
        }
    }
}
