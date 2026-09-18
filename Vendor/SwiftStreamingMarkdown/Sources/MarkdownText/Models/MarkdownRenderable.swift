//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Markdown element representation that is ready to be rendered by a SwiftUI View
/// The representation already have all the parsing and processing completed to minimize rendering overhead on UI thread.
/// This data structure is not thread safe due to the usage of `NSMutableAttributedString`, this needs to be addressed as a future improvement
indirect enum MarkdownRenderable: Identifiable, Equatable, @unchecked Sendable {

  /// To be rendered as a paragraph
  case paragraph(id: String, content: NSMutableAttributedString)

  /// To be rendered as LaTeX (Math formatting)
  case latex(id: String, content: String)

  /// To be rendered as a heading
  case heading(id: String, level: Int, content: NSMutableAttributedString)

  /// To be rendered as a ordered list view
  case orderedList(id: String, items: [MarkdownListItem])

  /// To be rendered as an unordered list
  case unorderedList(id: String, items: [MarkdownListItem], nestedLevel: Int)

  /// To be rendered as a code block
  case codeBlock(id: String, language: String?, code: String)

  /// To be rendered as a table
  case table(id: String, headers: [NSMutableAttributedString], rows: [[NSMutableAttributedString]], rawMarkdown: String)

  /// To be rendered as thematic break
  case thematicBreak(id: String)

  /// To be rendered as a block quote
  case blockQuote(id: String, item: BlockQuoteRenderable)

  /// To be rendered as a block-level image. Experimental; see
  /// `MarkdownRenderConfig.imageConfig`.
  case image(id: String, data: ImageData)

  var id: String {
    switch self {
    case .paragraph(let id, _): return id
    case .latex(let id, _): return id
    case .heading(let id, _, _): return id
    case .orderedList(let id, _): return id
    case .unorderedList(let id, _, _): return id
    case .codeBlock(let id, _, _): return id
    case .table(let id, _, _, _): return id
    case .thematicBreak(let id): return id
    case .blockQuote(let id, _): return id
    case .image(let id, _): return id
    }
  }

  var isCodeBlock: Bool {
    switch self {
    case .codeBlock: return true
    default: return false
    }
  }

  var isBlockQuote: Bool {
    switch self {
    case .blockQuote: return true
    default: return false
    }
  }

  /// Prefixes this block's id (and nested list child ids) so concatenated
  /// documents cannot collide in `ForEach(renderables)`.
  func prefixed(with prefix: String) -> MarkdownRenderable {
    let newID = prefix + id
    switch self {
    case .paragraph(_, let content):
      return .paragraph(id: newID, content: content)
    case .latex(_, let content):
      return .latex(id: newID, content: content)
    case .heading(_, let level, let content):
      return .heading(id: newID, level: level, content: content)
    case .orderedList(_, let items):
      return .orderedList(id: newID, items: items.map { $0.prefixed(with: prefix) })
    case .unorderedList(_, let items, let nestedLevel):
      return .unorderedList(
        id: newID,
        items: items.map { $0.prefixed(with: prefix) },
        nestedLevel: nestedLevel
      )
    case .codeBlock(_, let language, let code):
      return .codeBlock(id: newID, language: language, code: code)
    case .table(_, let headers, let rows, let rawMarkdown):
      return .table(id: newID, headers: headers, rows: rows, rawMarkdown: rawMarkdown)
    case .thematicBreak:
      return .thematicBreak(id: newID)
    case .blockQuote(_, let item):
      return .blockQuote(id: newID, item: item)
    case .image(_, let data):
      return .image(id: newID, data: data)
    }
  }

  /// Content identity that survives a fresh parse of the same source.
  /// `Equatable` on paragraphs uses `NSAttributedString.isEqual`, which fails
  /// across parses because `NSColor(Color.primary)` is a new catalog color
  /// each time. Streaming would then rebuild every latex attachment view.
  func hasStableRenderedContent(equalTo other: MarkdownRenderable) -> Bool {
    switch (self, other) {
    case (.paragraph(let lhsID, let lhsContent), .paragraph(let rhsID, let rhsContent)):
      return lhsID == rhsID && lhsContent.hasSameMarkdownIdentity(as: rhsContent)
    case (.heading(let lhsID, let lhsLevel, let lhsContent), .heading(let rhsID, let rhsLevel, let rhsContent)):
      return lhsID == rhsID && lhsLevel == rhsLevel && lhsContent.hasSameMarkdownIdentity(as: rhsContent)
    case (.latex(let lhsID, let lhsContent), .latex(let rhsID, let rhsContent)):
      return lhsID == rhsID && lhsContent == rhsContent
    case (.codeBlock(let lhsID, let lhsLanguage, let lhsCode), .codeBlock(let rhsID, let rhsLanguage, let rhsCode)):
      return lhsID == rhsID && lhsLanguage == rhsLanguage && lhsCode == rhsCode
    case (.thematicBreak(let lhsID), .thematicBreak(let rhsID)):
      return lhsID == rhsID
    case (.image(let lhsID, let lhsData), .image(let rhsID, let rhsData)):
      return lhsID == rhsID && lhsData == rhsData
    case (.orderedList(let lhsID, let lhsItems), .orderedList(let rhsID, let rhsItems)):
      return lhsID == rhsID && lhsItems.hasStableRenderedContent(equalTo: rhsItems)
    case (.unorderedList(let lhsID, let lhsItems, let lhsLevel), .unorderedList(let rhsID, let rhsItems, let rhsLevel)):
      return lhsID == rhsID && lhsLevel == rhsLevel && lhsItems.hasStableRenderedContent(equalTo: rhsItems)
    case (.table(let lhsID, let lhsHeaders, let lhsRows, let lhsRaw), .table(let rhsID, let rhsHeaders, let rhsRows, let rhsRaw)):
      return lhsID == rhsID && lhsRaw == rhsRaw
        && lhsHeaders.hasStableRenderedContent(equalTo: rhsHeaders)
        && lhsRows.count == rhsRows.count
        && zip(lhsRows, rhsRows).allSatisfy { $0.hasStableRenderedContent(equalTo: $1) }
    case (.blockQuote(let lhsID, let lhsItem), .blockQuote(let rhsID, let rhsItem)):
      return lhsID == rhsID && lhsItem == rhsItem
    default:
      return self == other
    }
  }
}

private extension Array where Element == NSMutableAttributedString {
  func hasStableRenderedContent(equalTo other: [NSMutableAttributedString]) -> Bool {
    count == other.count && zip(self, other).allSatisfy { $0.hasSameMarkdownIdentity(as: $1) }
  }
}

private extension Array where Element == MarkdownListItem {
  func hasStableRenderedContent(equalTo other: [MarkdownListItem]) -> Bool {
    count == other.count && zip(self, other).allSatisfy { lhs, rhs in
      lhs.startsWithBold == rhs.startsWithBold
        && lhs.checkbox == rhs.checkbox
        && lhs.children.count == rhs.children.count
        && zip(lhs.children, rhs.children).allSatisfy { $0.hasStableRenderedContent(equalTo: $1) }
    }
  }
}

struct MarkdownListItem: Equatable {
  /// Checkbox state for a GitHub-flavored task list item (`- [ ]` / `- [x]`).
  enum Checkbox {
    case checked
    case unchecked
  }

  let children: [MarkdownRenderable]
  let startsWithBold: Bool
  /// `nil` for regular list items.
  let checkbox: Checkbox?

  init(children: [MarkdownRenderable], startsWithBold: Bool, checkbox: Checkbox? = nil) {
    self.children = children
    self.startsWithBold = startsWithBold
    self.checkbox = checkbox
  }

  func prefixed(with prefix: String) -> MarkdownListItem {
    MarkdownListItem(
      children: children.map { $0.prefixed(with: prefix) },
      startsWithBold: startsWithBold,
      checkbox: checkbox
    )
  }
}
