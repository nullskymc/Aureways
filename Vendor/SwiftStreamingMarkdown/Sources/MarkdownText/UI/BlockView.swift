//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import SwiftUI

struct BlockView: View {

  @Environment(\.markdownConfig) var config: MarkdownRenderConfig

  let renderables: [MarkdownRenderable]
  /// Inspector previews of long files: only materialize on-screen blocks.
  /// Transcript stays eager so virtualized row heights are known up front.
  var lazy: Bool = false

  init(renderables: [MarkdownRenderable], lazy: Bool = false) {
    self.renderables = renderables
    self.lazy = lazy
  }

  var body: some View {
    let spacing = config.blockSpacing
    if lazy {
      LazyVStack(alignment: .leading, spacing: spacing) {
        blockStack
      }
    } else {
      VStack(alignment: .leading, spacing: spacing) {
        blockStack
      }
    }
  }

  @ViewBuilder
  private var blockStack: some View {
    ForEach(renderables) { renderable in
      // Skip body (and therefore AppKit/UIKit representable updates) when the
      // parsed block has not changed. Streaming re-parses the whole document
      // on every token; without this, already-closed latex is typeset again.
      SingleBlockView(renderable: renderable)
        .equatable()
    }
  }
}

struct SingleBlockView: View, Equatable {

  @Environment(\.markdownConfig) var config: MarkdownRenderConfig

  let renderable: MarkdownRenderable

  init(renderable: MarkdownRenderable) {
    self.renderable = renderable
  }

  static func == (lhs: SingleBlockView, rhs: SingleBlockView) -> Bool {
    lhs.renderable.hasStableRenderedContent(equalTo: rhs.renderable)
  }

  var body: some View {
    Group {
      switch renderable {
      case .heading(_, _, let contents):
        ParagraphView(contents: contents)
          .accessibilityAddTraits(.isHeader)
      case .paragraph(_, let contents):
        ParagraphView(contents: contents, lineSpacing: 5)
          .fixedSize(horizontal: false, vertical: true)
      case .latex(_, let latexString):
        ScrollView(.horizontal) {
          HStack(spacing: 0) {
            BlockMathView(latex: latexString, color: config.paragraphStyle.textColor)
            Spacer()
          }
        }.scrollIndicators(.hidden)
      case .orderedList(_, let items):
        OrderedListView(items: items)
      case .unorderedList(_, let items, let nestedLevel):
        UnorderedListView(items: items, nestedLevel: nestedLevel)
      case .codeBlock(_, let language, let code):
        CodeBlockView(language: language ?? "",
                      code: code)
      case .thematicBreak:
        ThematicBreakView()
      case .table(_, let headers, let rows, let rawMarkdown):
        TableView(headings: headers,
                  rows: rows,
                  rawMarkdown: rawMarkdown)
      case .blockQuote(_, let item):
        BlockQuoteView(item: item)
      case .image(let id, let data):
        BlockImageView(data: data)
          .id(id)
      }
    }
  }
}
