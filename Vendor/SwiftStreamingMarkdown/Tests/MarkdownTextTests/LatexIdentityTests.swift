//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

#if canImport(AppKit)
import AppKit
@testable import SwiftStreamingMarkdown
import XCTest

@MainActor
final class LatexIdentityTests: XCTestCase {

  func testLatexAttachmentsWithTheSamePayloadAreEqual() throws {
    let payload = LatexAttachmentData(
      latex: "E = mc^2",
      fontSize: 13.5,
      lightTextColor: "#000000",
      darkTextColor: "#FFFFFF"
    )
    let encoded = try JSONEncoder().encode(payload)
    let lhs = LatexTextAttachment(payload: payload, encoded: encoded)
    let rhs = LatexTextAttachment(payload: payload, encoded: encoded)
    XCTAssertEqual(lhs, rhs)
    XCTAssertTrue(lhs.isEqual(rhs))
  }

  func testTwoParsesOfTheSameInlineLatexAreEqual() async {
    let source = #"Energy is \(E = mc^2\) in this frame."#
    let first = await MarkdownParserImpl().parse(text: source, config: .default)
    let second = await MarkdownParserImpl().parse(text: source, config: .default)
    XCTAssertEqual(first, second)
  }

  func testTwoParsesOfTheSameBlockLatexAreEqual() async {
    let source = """
    The identity:

    $$a^2 + b^2 = c^2$$

    holds in the plane.
    """
    let first = await MarkdownParserImpl().parse(text: source, config: .default)
    let second = await MarkdownParserImpl().parse(text: source, config: .default)
    XCTAssertEqual(first, second)
  }

  func testParagraphIdentityIgnoresDynamicColorCatalog() async {
    let source = #"Energy is \(E = mc^2\) in this frame."#
    let first = await MarkdownParserImpl().parse(text: source, config: .default)
    try? await Task.sleep(nanoseconds: 50_000_000)
    let second = await MarkdownParserImpl().parse(text: source, config: .default)
    guard
      case .paragraph(_, let lhs) = first.renderables.first,
      case .paragraph(_, let rhs) = second.renderables.first
    else {
      return XCTFail("expected paragraphs")
    }
    XCTAssertTrue(lhs.hasSameMarkdownIdentity(as: rhs))
    XCTAssertTrue(first.renderables[0].hasStableRenderedContent(equalTo: second.renderables[0]))
  }

  func testGrowingTextAfterInlineLatexIsAPrefixExtension() async {
    let closed = #"Let \(a = 1\)"#
    let grown = #"Let \(a = 1\) and then some."#
    let first = await MarkdownParserImpl().parse(text: closed, config: .default)
    let second = await MarkdownParserImpl().parse(text: grown, config: .default)
    guard
      case .paragraph(_, let prefix) = first.renderables.first,
      case .paragraph(_, let full) = second.renderables.first
    else {
      return XCTFail("expected paragraphs")
    }
    XCTAssertTrue(full.markdownPrefix(equalTo: prefix))
    XCTAssertGreaterThan(full.length, prefix.length)
  }

  func testParagraphNSViewAppendsInsteadOfReplacingWhenLatexPrefixIsStable() async {
    let closed = #"Let \(a = 1\)"#
    let grown = #"Let \(a = 1\) and then some."#
    let first = await MarkdownParserImpl().parse(text: closed, config: .default)
    let second = await MarkdownParserImpl().parse(text: grown, config: .default)
    guard
      case .paragraph(_, let prefix) = first.renderables.first,
      case .paragraph(_, let full) = second.renderables.first
    else {
      return XCTFail("expected paragraphs")
    }

    let view = ParagraphNSView()
    view.setParagraphContents(prefix, animatedByWord: false)
    let storage = view.textStorage
    XCTAssertNotNil(storage)
    let identity = ObjectIdentifier(storage!)
    let prefixLength = storage?.length ?? 0

    view.setParagraphContents(NSMutableAttributedString(attributedString: prefix), animatedByWord: false)
    XCTAssertEqual(ObjectIdentifier(view.textStorage!), identity)
    XCTAssertEqual(view.textStorage?.length, prefixLength)

    view.setParagraphContents(full, animatedByWord: false)
    XCTAssertEqual(ObjectIdentifier(view.textStorage!), identity)
    XCTAssertGreaterThan(view.textStorage?.length ?? 0, prefixLength)
  }
}
#endif
