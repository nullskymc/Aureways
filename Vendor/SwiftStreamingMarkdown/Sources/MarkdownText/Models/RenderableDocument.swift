//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Markdown
import os
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
  private static let signposter = OSSignposter(subsystem: "ai.aureways.client", category: "Markdown")
  let renderables: [MarkdownRenderable]

  var containsCodeBlock: Bool {
    return renderables.contains(where: { $0.isCodeBlock })
  }

  var containsBlockQuote: Bool {
    return renderables.contains(where: { $0.isBlockQuote })
  }

  public var isEmpty: Bool {
    return renderables.isEmpty
  }

  /// Convert a parsed `Document` into a `RenderableDocument` using the supplied config.
  /// - Parameters:
  ///   - document: The parsed markdown tree.
  ///   - config: Styling and behavior used during conversion.
  public init(document: Markdown.Document, config: MarkdownRenderConfig) async {
    let signpostID = Self.signposter.makeSignpostID()
    let state = Self.signposter.beginInterval("RenderableDocumentBuild", id: signpostID)
    defer { Self.signposter.endInterval("RenderableDocumentBuild", state) }
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

  /// Growing unclosed fence: skip cmark and publish a single code block.
  public static func synthesizedCodeBlock(language: String?, code: String) -> RenderableDocument {
    RenderableDocument(renderables: [.codeBlock(id: "open-fence", language: language, code: code)])
  }

  /// An empty document, equivalent to `RenderableDocument(plainText: "", …)`
  /// but allocation-free.
  public static let empty = RenderableDocument(renderables: [])

  /// Combines two pre-parsed documents without reparsing (PERF-03).
  /// Tail block ids are prefixed so `ForEach` identity stays unique — cmark
  /// ids restart at `"0"` in every independent parse.
  public func appending(_ other: RenderableDocument) -> RenderableDocument {
    if self.renderables.isEmpty { return other }
    if other.renderables.isEmpty { return self }
    let prefix = "\(renderables.count)."
    return RenderableDocument(
      renderables: renderables + other.renderables.map { $0.prefixed(with: prefix) }
    )
  }
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
      return attributedList(id: id, items: items, ordered: true)
    case .unorderedList(let id, let items, _):
      return attributedList(id: id, items: items, ordered: false)
    case .blockQuote(let id, let item):
      return formatBlockQuote(id: id, item: item)
    case .thematicBreak(let id):
      return formatThematicBreak(id: id)
    default:
      return nil
    }
  }

  private func attributedList(
    id: String,
    items: [MarkdownListItem],
    ordered: Bool,
    indentDepth: Int = 0
  ) -> (id: String, content: NSAttributedString)? {
    guard !items.isEmpty else { return (id, NSAttributedString()) }
    let result = NSMutableAttributedString()
    let indentSpaces = String(repeating: "    ", count: indentDepth)

    for (index, item) in items.enumerated() {
      if index > 0 || (indentDepth > 0 && result.length > 0) {
        result.append(NSAttributedString(string: "\n"))
      }

      let marker: String
      if ordered {
        marker = "\(indentSpaces)\(index + 1).  "
      } else {
        let bullet: String = switch indentDepth {
        case 0: "•  "
        case 1: "◦  "
        default: "▪  "
        }
        let prefix = switch item.checkbox {
        case .checked: "☑  "
        case .unchecked: "☐  "
        case nil: bullet
        }
        marker = "\(indentSpaces)\(prefix)"
      }

      var firstChild = true
      for child in item.children {
        switch child {
        case .paragraph(_, let content), .heading(_, _, let content):
          if firstChild {
            var attributes: [NSAttributedString.Key: Any] = [:]
            if content.length > 0 {
              attributes = content.attributes(at: 0, effectiveRange: nil)
            }
            result.append(NSAttributedString(string: marker, attributes: attributes))
            result.append(content)
            firstChild = false
          } else {
            result.append(NSAttributedString(string: "\n\(indentSpaces)    "))
            result.append(content)
          }

        case .orderedList(let subID, let subItems):
          if let sub = attributedList(id: subID, items: subItems, ordered: true, indentDepth: indentDepth + 1) {
            result.append(NSAttributedString(string: "\n"))
            result.append(sub.content)
          }

        case .unorderedList(let subID, let subItems, _):
          if let sub = attributedList(id: subID, items: subItems, ordered: false, indentDepth: indentDepth + 1) {
            result.append(NSAttributedString(string: "\n"))
            result.append(sub.content)
          }

        case .codeBlock(_, _, let code):
          if firstChild {
            result.append(NSAttributedString(string: marker))
            firstChild = false
          }
          let codeLines = code.split(separator: "\n", omittingEmptySubsequences: false)
          let indentedCode = codeLines.map { "\(indentSpaces)    \($0)" }.joined(separator: "\n")
          let monoAttrs: [NSAttributedString.Key: Any] = [
            .font: MDFont.monospacedSystemFont(ofSize: 12, weight: .regular)
          ]
          result.append(NSAttributedString(string: "\n" + indentedCode, attributes: monoAttrs))

        case .blockQuote(let subID, let subItem):
          if firstChild {
            result.append(NSAttributedString(string: marker))
            firstChild = false
          }
          if let quote = formatBlockQuote(id: subID, item: subItem, indentSpaces: indentSpaces + "    ") {
            result.append(NSAttributedString(string: "\n"))
            result.append(quote.content)
          }

        default:
          if let text = child.plainText, !text.isEmpty {
            if firstChild {
              result.append(NSAttributedString(string: marker))
              firstChild = false
            } else {
              result.append(NSAttributedString(string: "\n\(indentSpaces)    "))
            }
            result.append(NSAttributedString(string: text))
          }
        }
      }

      if firstChild {
        result.append(NSAttributedString(string: marker))
      }
    }

    return (id, result)
  }

  private func formatBlockQuote(
    id: String,
    item: BlockQuoteRenderable,
    indentSpaces: String = ""
  ) -> (id: String, content: NSAttributedString)? {
    let text = item.quoteType.plainText
    guard !text.isEmpty else { return nil }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let formatted = lines.map { "\(indentSpaces)▎ \($0)" }.joined(separator: "\n")
    #if canImport(AppKit)
    let color = MDColor.secondaryLabelColor
    #else
    let color = MDColor.secondaryLabel
    #endif
    let attrs: [NSAttributedString.Key: Any] = [
      .foregroundColor: color
    ]
    return (id, NSAttributedString(string: formatted, attributes: attrs))
  }

  private func formatThematicBreak(id: String) -> (id: String, content: NSAttributedString)? {
    let divider = "────────────────────────────────────────"
    #if canImport(AppKit)
    let color = MDColor.separatorColor
    #else
    let color = MDColor.separator
    #endif
    let attrs: [NSAttributedString.Key: Any] = [
      .foregroundColor: color
    ]
    return (id, NSAttributedString(string: divider, attributes: attrs))
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
