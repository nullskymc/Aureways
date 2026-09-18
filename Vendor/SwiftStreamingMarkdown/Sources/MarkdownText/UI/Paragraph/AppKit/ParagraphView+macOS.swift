//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

#if canImport(AppKit)
import SwiftUI

struct ParagraphView: NSViewRepresentable {
  @Environment(\.openURL) var openURL
  @Environment(\.markdownConfig) var config: MarkdownRenderConfig
  @Environment(\.markdownController) var markdownController: MarkdownController?

  var contents: NSMutableAttributedString
  var lineSpacing: CGFloat?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> ParagraphNSView {
    let openUrlFunction = openURL.callAsFunction(_:)
    // Do not reuse paragraph views on macOS. Reused NSTextView instances can retain
    // stale attachment subviews (e.g. LaTeX views vended by LatexViewProvider) from a
    // previously displayed document, which then render at the wrong positions. Each
    // paragraph gets its own view instead.
    let view = ParagraphNSView()
    view.onUrlTap = openUrlFunction
    view.setParagraphContents(contents, lineSpacing: lineSpacing, animatedByWord: false)
    view.setTextContextMenu(config.resolvedTextContextMenu)
    view.setMarkdownController(markdownController)

    if config.shouldAnimateText {
      view.alphaValue = 0
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = ParagraphNSView.animationDuration
        view.animator().alphaValue = 1
      }
    }

    return view
  }

  func updateNSView(_ view: ParagraphNSView, context: Context) {
    synchronize(view)
    view.setTextContextMenu(config.resolvedTextContextMenu)
    view.setMarkdownController(markdownController)
  }

  private func synchronize(_ view: ParagraphNSView) {
    if !view.paragraphContents.hasSameMarkdownIdentity(as: contents) || view.lineSpacing != lineSpacing {
      let shouldAnimate = view.window != nil && config.shouldAnimateText
      view.setParagraphContents(contents, lineSpacing: lineSpacing, animatedByWord: shouldAnimate)
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ParagraphNSView, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0, width.isFinite else {
      return nil
    }

    synchronize(nsView)
    if context.coordinator.contentRevision != nsView.contentRevision {
      context.coordinator.sizeCache.removeAll()
      context.coordinator.cacheOrder.removeAll()
      context.coordinator.contentRevision = nsView.contentRevision
    }

    // Round fitting width to integer points to prevent sub-pixel misses during drag/resizing (PERF-09)
    let cacheKey = width.rounded()
    let coordinator = context.coordinator

    if let cachedSize = coordinator.sizeCache[cacheKey] {
      coordinator.promote(cacheKey)
      return cachedSize
    }

    let calculatedSize = nsView.measureSize(fittingWidth: cacheKey)
    coordinator.store(calculatedSize, for: cacheKey)
    return calculatedSize
  }

  class Coordinator {
    var sizeCache: [CGFloat: CGSize] = [:]
    var cacheOrder: [CGFloat] = []
    var contentRevision: UInt64?
    private let cacheLimit = 32

    func promote(_ key: CGFloat) {
      if let index = cacheOrder.firstIndex(of: key) {
        cacheOrder.remove(at: index)
        cacheOrder.append(key)
      }
    }

    func store(_ size: CGSize, for key: CGFloat) {
      if sizeCache[key] == nil, sizeCache.count >= cacheLimit, let oldest = cacheOrder.first {
        sizeCache.removeValue(forKey: oldest)
        cacheOrder.removeFirst()
      }
      sizeCache[key] = size
      if let index = cacheOrder.firstIndex(of: key) {
        cacheOrder.remove(at: index)
      }
      cacheOrder.append(key)
    }
  }
}

extension ParagraphView: Equatable {
  static func == (lhs: ParagraphView, rhs: ParagraphView) -> Bool {
    lhs.contents.hasSameMarkdownIdentity(as: rhs.contents) && lhs.lineSpacing == rhs.lineSpacing
  }
}
#endif
