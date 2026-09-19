//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum RowContent: Equatable {
  case text(string: AttributedString)
  case containsAttachment(string: NSAttributedString)
}

struct TableView: View {
  @Environment(\.markdownConfig) var config: MarkdownRenderConfig
  @Environment(\.markdownController) var controller: MarkdownController?

  let headings: [AttributedString]
  let rows: [[RowContent]]
  let columnMaxWidths: [Int: CGFloat]

  private let defaultMaxColumnWidth: CGFloat = 200

  private let rawMarkdown: String

  init(headings: [NSMutableAttributedString], rows: [[NSMutableAttributedString]], columnMaxWidths: [Int: CGFloat] = [:], rawMarkdown: String = "") {
    self.headings = headings.map { AttributedString($0) }
    self.rows = rows.map { row in
      row.map { content in
        if content.containsAttachments(in: NSRange(location: 0, length: content.length)) {
          return .containsAttachment(string: content)
        } else {
          return .text(string: AttributedString(content))
        }
      }
    }

    self.columnMaxWidths = columnMaxWidths
    self.rawMarkdown = rawMarkdown
  }

  private var numOfRows: Int {
    return rows.count
  }

  private func headerView(colIdx: Int) -> some View {
    HStack(spacing: 0) {
      Text(headings[colIdx])
        .textSelection(.enabled)
        .foregroundStyle(config.tableStyle.headerTextColor)
        .lineLimit(nil)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .if(config.shouldAnimateText) { view in
          view.fadeInTextTransition(attributedString: headings[colIdx])
        }
        .accessibilityValue(String.itemPositionInTable(rowIndex: 1, totalRow: numOfRows + 1, columnIndex: colIdx + 1, totalColumn: headings.count))
      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
    .id("\(colIdx)-heading")
    .background(config.tableStyle.headerBackgroundColor)
    .applyHeaderBorder(colIndex: colIdx, colCount: headings.count, color: config.tableStyle.borderColor)
  }

  @ViewBuilder
  var gridView: some View {
    VStack(alignment: .leading, spacing: 0) {
      TableLayout(columnCount: headings.count, columnMaxWidths: self.staticColumnMaxWidths()) {
        ForEach(0..<headings.count, id: \.self) { colIdx in
          headerView(colIdx: colIdx)
        }

        ForEach(0..<numOfRows, id: \.self) { rowIdx in
          ForEach(0..<headings.count, id: \.self) { colIdx in
            gridCellViewFor(rowIdx: rowIdx, colIdx: colIdx)
          }
        }
      }
      .textSelection(.enabled)
    }
  }

  /// Caps only — never derived from the container width. Measuring the
  /// viewport into `@State` and feeding it back as `minWidth` / column
  /// budget made the table's ideal size track the bubble, which then
  /// leaked into `NavigationSplitView` and aborted on a constraints loop.
  private func staticColumnMaxWidths() -> [CGFloat] {
    (0..<headings.count).map { columnMaxWidths[$0] ?? defaultMaxColumnWidth }
  }

  @ViewBuilder
  private func gridCellViewFor(rowIdx: Int, colIdx: Int) -> some View {
    let content = rows[rowIdx][colIdx]
    switch content {
    case .containsAttachment(let nsAttributedString):
      HStack(spacing: 0) {
        ParagraphView(contents: applyTypographyThemingAndGetContent(nsAttributedString))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .accessibilityValue(String.itemPositionInTable(rowIndex: rowIdx + 2, totalRow: numOfRows + 1, columnIndex: colIdx + 1, totalColumn: headings.count))
        Spacer()
      }
      .frame(maxHeight: .infinity)
      .padding(.horizontal, 10)
      .padding(.vertical, 10)
      .id("\(colIdx)-\(rowIdx)")
      .applyCellBorder(colIndex: colIdx, colCount: headings.count, rowIndex: rowIdx, rowCount: numOfRows, color: config.tableStyle.borderColor)
    case .text(let attributedString):
      HStack(spacing: 0) {
        Text(attributedString)
          .textSelection(.enabled)
          .foregroundStyle(config.tableStyle.regularTextColor)
          .lineLimit(nil)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .if(config.shouldAnimateText) { view in
            view.fadeInTextTransition(attributedString: attributedString)
          }
          .accessibilityValue(String.itemPositionInTable(rowIndex: rowIdx + 2, totalRow: numOfRows + 1, columnIndex: colIdx + 1, totalColumn: headings.count))
        Spacer()
      }
      .frame(maxHeight: .infinity)
      .padding(.horizontal, 10)
      .padding(.vertical, 10)
      .id("\(colIdx)-\(rowIdx)")
      .applyCellBorder(colIndex: colIdx, colCount: headings.count, rowIndex: rowIdx, rowCount: numOfRows, color: config.tableStyle.borderColor)
    }
  }

  var body: some View {
    // Fill the bubble in placeSubviews. sizeThatFits must keep the intrinsic
    // width — returning the proposed (bubble / column) width made
    // NavigationSplitView min/max track the pane and abort on a constraints
    // loop while the last message was streaming.
    TableWidthHost {
      gridView
        .contentShape(Rectangle())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

}

extension View {

  func applyHeaderBorder(colIndex: Int, colCount: Int, color: Color) -> some View {
    // Horizontal rule under the header only — no vertical column lines.
    _ = colIndex
    _ = colCount
    return border(width: 1, edges: [.bottom], color: color)
  }

  func applyCellBorder(colIndex: Int, colCount: Int, rowIndex: Int, rowCount: Int, color: Color) -> some View {
    // Row separators only (skip the last row so the table has no outer bottom box).
    _ = colIndex
    _ = colCount
    var edges: [Edge] = []
    if rowIndex < rowCount - 1 {
      edges.append(.bottom)
    }
    return border(width: 1, edges: edges, color: color)
  }

  @ViewBuilder
  func fadeInTextTransition(attributedString: AttributedString) -> some View {
    self.fadeInTextTransition(config: .variableDuration(
      glyphCount: attributedString.characters.count,
      glyphDelay: 0.02,
      glyphDuration: 0.2))
  }
}

struct TableLayout: Layout {
  struct CacheData {
    let columnWidths: [CGFloat]
    let rowHeights: [CGFloat]
  }

  let columnCount: Int
  let columnMaxWidths: [CGFloat]

  private let defaultRowHeight: CGFloat = 44

  func makeCache(subviews: Subviews) -> CacheData {
    guard columnCount > 0 else { return CacheData(columnWidths: [], rowHeights: []) }
    let rowCount = subviews.count / columnCount

    var columnWidths = Array(repeating: CGFloat(0), count: columnCount)
    for row in 0..<rowCount {
      for col in 0..<columnCount {
        let index = row * columnCount + col
        let size = subviews[index].sizeThatFits(.unspecified)
        columnWidths[col] = min(max(columnWidths[col], size.width), columnMaxWidths[col])
      }
    }

    // Do not grow to a container budget here. Ideal width must stay intrinsic;
    // stretching to the bubble happens in `placeSubviews` from `bounds.width`.

    var rowHeights = Array(repeating: CGFloat(0), count: rowCount)
    for row in 0..<rowCount {
      var rowHeight: CGFloat = 0
      for col in 0..<columnCount {
        let index = row * columnCount + col
        let height = subviews[index].sizeThatFits(.init(width: columnWidths[col], height: nil)).height
        let cellHeight = height.isFinite ? height : defaultRowHeight
        rowHeight = max(rowHeight, cellHeight)
      }
      rowHeights[row] = rowHeight
    }

    return CacheData(columnWidths: columnWidths, rowHeights: rowHeights)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) -> CGSize {
    // Width is always the column-cap sum. Adopting `proposal.width` made the
    // table's measured size track the transcript column, which
    // `SplitViewChildController` then wrote back as min/max and could not
    // settle. Stretching happens in `placeSubviews`, not here.
    let contentWidth = cache.columnWidths.reduce(0, +)
    let contentHeight = cache.rowHeights.reduce(0, +)
    _ = subviews
    _ = proposal
    return CGSize(width: contentWidth, height: contentHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) {
    guard bounds.origin.y.isFinite else {
      return
    }
    let rowCount = subviews.count / columnCount
    var columnWidths = cache.columnWidths
    let contentSum = columnWidths.reduce(0, +)
    // The host may report a smaller (intrinsic) size than the bubble. Use the
    // parent's proposal so columns still span the offered width.
    let targetWidth = max(bounds.width, proposal.width ?? 0)
    if targetWidth > contentSum + 0.5, contentSum > 0 {
      let share = (targetWidth - contentSum) / CGFloat(columnCount)
      for col in 0..<columnCount {
        columnWidths[col] += share
      }
    }

    var y: CGFloat = bounds.origin.y

    for row in 0..<rowCount {
      var x: CGFloat = bounds.minX.isNaN ? 0 : bounds.minX
      let rowHeight = cache.rowHeights[row]

      for col in 0..<columnCount {
        let index = row * columnCount + col
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: .init(width: columnWidths[col], height: rowHeight))
        x += columnWidths[col]
      }

      y += rowHeight
    }
  }
}

/// Reports the grid's intrinsic size for every proposal, then places it at the
/// offered width so columns can stretch. Returning `proposedWidth` from
/// `sizeThatFits` was enough for `NavigationSplitView` to treat the current
/// column width as the table's min/max and abort during streaming layout.
struct TableWidthHost: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let child = subviews.first else { return .zero }
    _ = proposal
    return child.sizeThatFits(.unspecified)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let child = subviews.first else { return }
    let intrinsic = child.sizeThatFits(.unspecified)
    let offered = proposal.width ?? bounds.width
    let layoutWidth = max(
      bounds.width,
      offered.isFinite ? offered : bounds.width,
      intrinsic.width
    )
    child.place(
      at: bounds.origin,
      anchor: .topLeading,
      proposal: ProposedViewSize(width: layoutWidth, height: bounds.height)
    )
  }
}

// MARK: - Helper Functions
extension TableView {
  /// Apply typography theming and return themed content for use with ParagraphView
  private func applyTypographyThemingAndGetContent(_ attributedString: NSAttributedString) -> NSMutableAttributedString {
    // Apply typography theming for table cells
    let mutableAttributedString = NSMutableAttributedString(attributedString: attributedString)
    let fullRange = NSRange(location: 0, length: mutableAttributedString.length)
    let themeColor = MDColor(config.tableStyle.regularTextColor)

    // Apply theme color to text that doesn't already have a foreground color
    mutableAttributedString.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { existingColor, range, _ in
      if existingColor == nil {
        mutableAttributedString.addAttribute(.foregroundColor, value: themeColor, range: range)
      }
    }

    // Apply citation baseline offset for proper alignment
    // This is needed because table cells bypass Paragraph+ parsing where baseline offset is normally applied
    var containsCitationAttachments = false
    var containsNonAttachmentContent = false
    var citationRanges: [NSRange] = []

    // One pass: detect & collect citation ranges
    mutableAttributedString.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
      guard range.length > 0 else { return }

      // Check if it's a citation attachment
      if let citationAttachment = attributes[.attachment] as? InlineCitationAttachment,
         citationAttachment.citationData != nil {
        containsCitationAttachments = true
        citationRanges.append(range)
        return
      }

      if attributes[.link] != nil {
        containsNonAttachmentContent = true
        return
      }

      // Plain text (non-attachment content)
      containsNonAttachmentContent = true
    }

    // Apply baseline offset only when we have both citations and non-attachment content
    let shouldApplyBaselineOffset = containsCitationAttachments && containsNonAttachmentContent
    if shouldApplyBaselineOffset {
      let baselineOffsetValue = Typography.base.mdFont.descender
      for range in citationRanges {
        mutableAttributedString.addAttribute(.baselineOffset, value: baselineOffsetValue, range: range)
      }
    }

    // Since citations are now already NSTextAttachment in the attributed string during parsing,
    // we can return the themed string directly
    return mutableAttributedString
  }
}

#if DEBUG

let tableViewHeadingMock: [NSMutableAttributedString] = [
  NSMutableAttributedString(string: "Table Heading"),

  NSMutableAttributedString(string: "heading2"),
  NSMutableAttributedString(string: "heading3"),
  NSMutableAttributedString(string: "heading4"),
  NSMutableAttributedString(string: "heading5")
]

let tableviewRowsMock: [[NSMutableAttributedString]] =  [
  [
    NSMutableAttributedString(string: "row1-1 cell Dragon"),
    NSMutableAttributedString(string: "Table body"),
    NSMutableAttributedString(string: "row1-3 cell"),
    NSMutableAttributedString(string: "row1-4 cell"),
    NSMutableAttributedString(string: "row1-5 cell")
  ],
  [
    NSMutableAttributedString(string: "row2-1 cell"),
    NSMutableAttributedString(string: "row2-2 cell"),
    NSMutableAttributedString(string: "row2-3 cell"),
    NSMutableAttributedString(string: "row2-4 cell"),
    NSMutableAttributedString(string: "row2-5 cell")
  ],
  [
    NSMutableAttributedString(string: "row3-1 cell"),
    NSMutableAttributedString(string: "row3-2 cell"),
    NSMutableAttributedString(string: "row3-3 cell"),
    NSMutableAttributedString(string: "row3-4 cell"),
    NSMutableAttributedString(string: "row3-5 cell")
  ]
]

#Preview("Full Table", body: {
  return VStack {
    Spacer()
      .frame(maxHeight: .infinity)
    TableView(
      headings: tableViewHeadingMock,
      rows: tableviewRowsMock
    )
    Spacer()
      .frame(maxHeight: .infinity)
  }
})

#Preview("Header Only", body: {
  return VStack {
    Spacer()
      .frame(maxHeight: .infinity)
    TableView(
      headings: tableViewHeadingMock,
      rows: []
    )
    Spacer()
      .frame(maxHeight: .infinity)
  }
})

#Preview("Table with Citations", body: {
  // Create citation attachments safely
  guard let citationData1 = CitationCoder.default.decode(
    linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=Research&citationA11yValue=Research%20Study"
  ),
    let citation1 = InlineCitationAttachment(citationData: citationData1, citationConfig: .default),
    let citationData2 = CitationCoder.default.decode(
      linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=Analysis&citationA11yValue=Data%20Analysis"
    ),
    let citation2 = InlineCitationAttachment(citationData: citationData2, citationConfig: .default) else {
    return Text(verbatim: "Preview unavailable: Citation creation failed")
  }

  // Create rows with citations
  let rowWithCitation1 = NSMutableAttributedString(string: "Study shows ")
  rowWithCitation1.append(NSAttributedString(attachment: citation1))
  rowWithCitation1.append(NSAttributedString(string: " significant results"))

  let rowWithCitation2 = NSMutableAttributedString(string: "According to ")
  rowWithCitation2.append(NSAttributedString(attachment: citation2))
  rowWithCitation2.append(NSAttributedString(string: ", data confirms trends"))

  let headings = [
    NSMutableAttributedString(string: "Finding"),
    NSMutableAttributedString(string: "Source")
  ]

  let rows = [
    [rowWithCitation1, NSMutableAttributedString(string: "Primary research")],
    [rowWithCitation2, NSMutableAttributedString(string: "Secondary analysis")]
  ]

  return VStack {
    TableView(
      headings: headings,
      rows: rows
    )
    Spacer()
  }
})

#Preview("Citation Only Cells", body: {
  // Create citation with NFL (known rendering issue case)
  guard let nflCitationData = CitationCoder.default.decode(
    linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=NFL&citationA11yValue=National%20Football%20League"
  ),
    let nflCitation = InlineCitationAttachment(citationData: nflCitationData, citationConfig: .default),
    let espnCitationData = CitationCoder.default.decode(
      linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=ESPN&citationA11yValue=ESPN%20Sports"
    ),
    let espnCitation = InlineCitationAttachment(citationData: espnCitationData, citationConfig: .default) else {
    return Text(verbatim: "Preview unavailable: Citation creation failed")
  }

  // Create cells with ONLY citations (no other text) to test alignment
  let nflOnlyCell = NSMutableAttributedString(attachment: nflCitation)
  let espnOnlyCell = NSMutableAttributedString(attachment: espnCitation)

  let headings = [
    NSMutableAttributedString(string: "Citation Only"),
    NSMutableAttributedString(string: "Status")
  ]

  let rows = [
    [nflOnlyCell, NSMutableAttributedString(string: "NFL citation alignment test")],
    [espnOnlyCell, NSMutableAttributedString(string: "ESPN citation alignment test")],
    [NSMutableAttributedString(string: "Regular text"), NSMutableAttributedString(string: "Standard text alignment")]
  ]

  return VStack {
    TableView(
      headings: headings,
      rows: rows
    )
    Spacer()
  }
})

#Preview("Citation Only - Dark Mode", body: {
  // Create citation with NFL (known rendering issue case)
  guard let nflCitationData = CitationCoder.default.decode(
    linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=NFL&citationA11yValue=National%20Football%20League"
  ),
    let nflCitation = InlineCitationAttachment(citationData: nflCitationData, citationConfig: .default),
    let espnCitationData = CitationCoder.default.decode(
      linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=ESPN&citationA11yValue=ESPN%20Sports"
    ),
    let espnCitation = InlineCitationAttachment(citationData: espnCitationData, citationConfig: .default) else {
    return Text(verbatim: "Preview unavailable: Citation creation failed")
      .preferredColorScheme(.dark)
  }

  // Create cells with ONLY citations (no other text) to test alignment
  let nflOnlyCell = NSMutableAttributedString(attachment: nflCitation)
  let espnOnlyCell = NSMutableAttributedString(attachment: espnCitation)

  let headings = [
    NSMutableAttributedString(string: "Citation Only"),
    NSMutableAttributedString(string: "Status")
  ]

  let rows = [
    [nflOnlyCell, NSMutableAttributedString(string: "NFL citation alignment test")],
    [espnOnlyCell, NSMutableAttributedString(string: "ESPN citation alignment test")],
    [NSMutableAttributedString(string: "Regular text"), NSMutableAttributedString(string: "Standard text alignment")]
  ]

  return VStack {
    TableView(
      headings: headings,
      rows: rows
    )
    Spacer()
  }
  .preferredColorScheme(.dark)
})

#Preview("Table with Mixed Content", body: {
  // Create citation safely (NO LaTeX to avoid iosMath bundle issues)
  guard let citationData = CitationCoder.default.decode(
    linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=Source&citationA11yValue=Primary%20Source"
  ),
    let citation = InlineCitationAttachment(citationData: citationData, citationConfig: .default) else {
    return Text(verbatim: "Preview unavailable: Citation creation failed")
  }

  // Create content with citation, bold text, and links (NO LaTeX)
  let complexContent = NSMutableAttributedString(string: "Results from ")
  complexContent.append(NSAttributedString(attachment: citation))
  complexContent.append(NSAttributedString(string: " show "))

  let boldText = NSAttributedString(string: "significant improvement", attributes: [
    .font: MDFont.boldSystemFont(ofSize: 14)
  ])
  complexContent.append(boldText)

  // Add regular link instead of LaTeX
  if let docURL = URL(string: "https://example.com") {
    complexContent.append(NSAttributedString(string: " and see "))
    let linkText = NSAttributedString(string: "documentation", attributes: [
      .link: docURL,
      .foregroundColor: MDColor.systemBlue
    ])
    complexContent.append(linkText)
    complexContent.append(NSAttributedString(string: " for details."))
  }

  let headings = [
    NSMutableAttributedString(string: "Summary"),
    NSMutableAttributedString(string: "Status")
  ]

  let rows = [
    [complexContent, NSMutableAttributedString(string: "Complete")],
    [NSMutableAttributedString(string: "Standard text only"), NSMutableAttributedString(string: "Pending")]
  ]

  return VStack {
    TableView(
      headings: headings,
      rows: rows
    )
    Spacer()
  }
})

#Preview("Mixed Content - Dark Mode", body: {
  // Create citation safely (NO LaTeX to avoid iosMath bundle issues)
  guard let citationData = CitationCoder.default.decode(
    linkDestination: "http://example.com?citationMarker=9F742443&citationTitle=Source&citationA11yValue=Primary%20Source"
  ),
    let citation = InlineCitationAttachment(citationData: citationData, citationConfig: .default) else {
    return Text(verbatim: "Preview unavailable: Citation creation failed")
      .preferredColorScheme(.dark)
  }

  // Create content with citation, bold text, and links (NO LaTeX)
  let complexContent = NSMutableAttributedString(string: "Results from ")
  complexContent.append(NSAttributedString(attachment: citation))
  complexContent.append(NSAttributedString(string: " show "))

  let boldText = NSAttributedString(string: "significant improvement", attributes: [
    .font: MDFont.boldSystemFont(ofSize: 14)
  ])
  complexContent.append(boldText)

  // Add regular link instead of LaTeX
  if let docURL = URL(string: "https://example.com") {
    complexContent.append(NSAttributedString(string: " and see "))
    let linkText = NSAttributedString(string: "documentation", attributes: [
      .link: docURL,
      .foregroundColor: MDColor.systemBlue
    ])
    complexContent.append(linkText)
    complexContent.append(NSAttributedString(string: " for details."))
  }

  let headings = [
    NSMutableAttributedString(string: "Summary"),
    NSMutableAttributedString(string: "Status")
  ]

  let rows = [
    [complexContent, NSMutableAttributedString(string: "Complete")],
    [NSMutableAttributedString(string: "Standard text only"), NSMutableAttributedString(string: "Pending")]
  ]

  return VStack {
    TableView(
      headings: headings,
      rows: rows
    )
    Spacer()
  }
  .preferredColorScheme(.dark)
})

#Preview("Compact Table", body: {
  let headings = [
    NSMutableAttributedString(string: "Item"),
    NSMutableAttributedString(string: "Value")
  ]

  let rows = [
    [NSMutableAttributedString(string: "Price"), NSMutableAttributedString(string: "$29.99")],
    [NSMutableAttributedString(string: "Tax"), NSMutableAttributedString(string: "$2.40")],
    [NSMutableAttributedString(string: "Total"), NSMutableAttributedString(string: "$32.39")]
  ]

  return VStack {
    TableView(
      headings: headings,
      rows: rows
    )
    Spacer()
  }
})

#endif
