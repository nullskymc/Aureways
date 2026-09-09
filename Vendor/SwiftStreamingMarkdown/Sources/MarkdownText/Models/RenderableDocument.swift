//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Markdown
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A `MarkdownRenderConfig`-aware snapshot of a parsed markdown `Document`,
/// ready to be handed to a `MarkdownView` for rendering. Producing one is
/// the heavyweight step; rendering it is cheap.
public struct RenderableDocument: Equatable, Sendable {
  let renderables: [MarkdownRenderable]

  var containsCodeBlock: Bool {
    return renderables.contains(where: { $0.isCodeBlock })
  }

  var containsBlockQuote: Bool {
    return renderables.contains(where: { $0.isBlockQuote })
  }

  var isEmpty: Bool {
    return renderables.isEmpty
  }

  /// Convert a parsed `Document` into a `RenderableDocument` using the supplied config.
  /// - Parameters:
  ///   - document: The parsed markdown tree.
  ///   - config: Styling and behavior used during conversion.
  public init(document: Markdown.Document, config: MarkdownRenderConfig) async {
    self.renderables = document.convert(with: config)
  }

  /// Construct a renderable wrapping a single plain-text paragraph styled
  /// with `config.paragraphStyle`. Useful for showing non-markdown text in a
  /// `MarkdownView` without round-tripping through the parser.
  public init(plainText: String, config: MarkdownRenderConfig) {
    var attributes: [NSAttributedString.Key: Any] = [
      .font: config.paragraphStyle.textFonts.normal,
      .foregroundColor: MDColor(config.paragraphStyle.textColor)
    ]
    if let kern = config.paragraphStyle.textFonts.preferredLetterSpacing {
      attributes[.kern] = kern
    }
    let content = NSMutableAttributedString(string: plainText, attributes: attributes)
    self.init(renderables: [.paragraph(id: UUID().uuidString, content: content)])
  }

  init(renderables: [MarkdownRenderable]) {
    self.renderables = renderables
  }

  /// An empty document, equivalent to `RenderableDocument(plainText: "", …)`
  /// but allocation-free.
  public static let empty = RenderableDocument(renderables: [])
}

extension RenderableDocument {
  var attributedStrings: [NSAttributedString] {
    return renderables.flatMap { $0.extractAttributedStrings() }
  }

  /// Adjacent headings, paragraphs, and text-only lists collapsed into one
  /// TextKit storage. Rich blocks keep their native rendering.
  public var mergingAdjacentTextBlocks: RenderableDocument {
    var merged: [MarkdownRenderable] = []
    var pending: NSMutableAttributedString?
    var pendingID: String?

    for renderable in renderables {
      if let text = renderable.mergeableText {
        if pending == nil {
          pending = NSMutableAttributedString(attributedString: text.content)
          pendingID = text.id
        } else {
          pending?.append(NSAttributedString(string: "\n\n"))
          pending?.append(text.content)
        }
      } else {
        if let pending, let pendingID {
          merged.append(.paragraph(id: pendingID, content: pending))
        }
        pending = nil
        pendingID = nil
        merged.append(renderable)
      }
    }
    if let pending, let pendingID {
      merged.append(.paragraph(id: pendingID, content: pending))
    }
    return RenderableDocument(renderables: merged)
  }

  /// The full document rendered as plain text, across every block kind
  /// (headings, paragraphs, lists, code blocks, tables, block quotes). Used to
  /// populate the "Select more text" modal.
  var plainText: String {
    renderables
      .compactMap { $0.plainText }
      .joined(separator: "\n\n")
  }
}

extension MarkdownRenderable {
  fileprivate var mergeableText: (id: String, content: NSAttributedString)? {
    switch self {
    case .paragraph(let id, let content), .heading(let id, _, let content):
      return (id, content)
    case .orderedList(let id, let items):
      return textList(id: id, items: items, ordered: true)
    case .unorderedList(let id, let items, _):
      return textList(id: id, items: items, ordered: false)
    default:
      return nil
    }
  }

  private func textList(
    id: String,
    items: [MarkdownListItem],
    ordered: Bool
  ) -> (id: String, content: NSAttributedString)? {
    let result = NSMutableAttributedString()
    for (index, item) in items.enumerated() {
      guard item.children.count == 1,
            case .paragraph(_, let content) = item.children[0] else { return nil }
      if index > 0 { result.append(NSAttributedString(string: "\n")) }
      let marker: String
      if ordered {
        marker = "\(index + 1).  "
      } else {
        marker = switch item.checkbox {
        case .checked: "☑  "
        case .unchecked: "☐  "
        case nil: "•  "
        }
      }
      var attributes: [NSAttributedString.Key: Any] = [:]
      if content.length > 0 { attributes = content.attributes(at: 0, effectiveRange: nil) }
      result.append(NSAttributedString(string: marker, attributes: attributes))
      result.append(content)
    }
    return (id, result)
  }

  /// A plain-text representation of this block, or `nil` for blocks that carry
  /// no selectable text (e.g. thematic breaks).
  var plainText: String? {
    switch self {
    case .paragraph(_, let content), .heading(_, _, let content):
      return content.string
    case .latex(_, let content):
      return content
    case .orderedList(_, let items):
      return items.plainText(separator: "\n")
    case .unorderedList(_, let items, _):
      return items.plainText(separator: "\n")
    case .codeBlock(_, _, let code):
      return code
    case .table(_, let headers, let rows, _):
      let headerLine = headers.map { $0.string }.joined(separator: "\t")
      let rowLines = rows.map { row in row.map { $0.string }.joined(separator: "\t") }
      return ([headerLine] + rowLines).joined(separator: "\n")
    case .blockQuote(_, let item):
      return item.quoteType.plainText
    case .thematicBreak:
      return nil
    case .image(_, let data):
      return data.alt.isEmpty ? nil : data.alt
    }
  }
}

private extension Array where Element == MarkdownListItem {
  func plainText(separator: String) -> String? {
    let lines = flatMap { item in
      item.children.compactMap { $0.plainText }
    }
    return lines.isEmpty ? nil : lines.joined(separator: separator)
  }
}

private extension BlockQuoteType {
  var plainText: String {
    switch self {
    case .text(let text):
      return text
    case .nested(let items):
      return items.map { $0.plainText }.joined(separator: "\n")
    }
  }
}

extension MarkdownRenderable {
  func extractAttributedStrings() -> [NSAttributedString] {
    switch self {
    case .paragraph(_, let str):
      return [str]
    case .orderedList(_, let items):
      return items.flatMap { $0.attributedStrings() }
    case .unorderedList(_, let items, _):
      return items.flatMap { $0.attributedStrings() }
    case .table(_, let headers, let rows, _):
      return headers + rows.flatMap { $0 }
    default:
      return []
    }
  }
}

extension MarkdownListItem {
  func attributedStrings() -> [NSAttributedString] {
    return self.children.flatMap { $0.extractAttributedStrings() }
  }
}
