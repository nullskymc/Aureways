//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import SwiftUI
import iosMath

#if canImport(UIKit)

struct BlockMathView: UIViewRepresentable {
  let latex: String
  let color: Color
  let pointSize: CGFloat

  init(latex: String, color: Color = Color.Theme.Foreground.Primary.Primary750, pointSize: CGFloat = Typography.base.mdFont.pointSize) {
    self.latex = latex
    self.color = color
    self.pointSize = pointSize
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> MTMathUILabel {
    let label = MTMathUILabel()
    label.latex = latex
    label.textColor = UIColor(color)
    label.displayErrorInline = false
    label.fontSize = pointSize
    label.setContentHuggingPriority(.defaultHigh, for: .vertical)
    context.coordinator.latex = latex
    context.coordinator.color = color
    context.coordinator.pointSize = pointSize
    return label
  }

  func updateUIView(_ uiView: MTMathUILabel, context: Context) {
    // MTMathUILabel.setLatex: reparses and invalidates layout with no equality
    // check. Streaming re-renders the document on every token, so assigning the
    // same string again makes already-closed formulas flicker.
    if context.coordinator.latex != latex {
      context.coordinator.latex = latex
      context.coordinator.size = nil
      uiView.latex = latex
    }
    if context.coordinator.color != color {
      context.coordinator.color = color
      uiView.textColor = UIColor(color)
    }
    if context.coordinator.pointSize != pointSize {
      context.coordinator.pointSize = pointSize
      context.coordinator.size = nil
      uiView.fontSize = pointSize
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
    if let cached = context.coordinator.size {
      return cached
    }
    uiView.sizeToFit()
    let size = uiView.bounds.size
    // It's a known issue that MTMathUILabel may be cut off for some short statement. Manually add 1 to the height fix it.
    let fitted = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up) + 1)
    context.coordinator.size = fitted
    return fitted
  }

  final class Coordinator {
    var latex: String?
    var color: Color?
    var pointSize: CGFloat?
    var size: CGSize?
  }
}

#elseif canImport(AppKit)

struct BlockMathView: NSViewRepresentable {
  let latex: String
  let color: Color
  let pointSize: CGFloat

  init(latex: String, color: Color = Color.Theme.Foreground.Primary.Primary750, pointSize: CGFloat = Typography.base.mdFont.pointSize) {
    self.latex = latex
    self.color = color
    self.pointSize = pointSize
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> MTMathUILabel {
    let label = MTMathUILabel()
    label.latex = latex
    label.textColor = NSColor(color)
    label.displayErrorInline = false
    label.fontSize = pointSize
    label.setContentHuggingPriority(.defaultHigh, for: .vertical)
    context.coordinator.latex = latex
    context.coordinator.color = color
    context.coordinator.pointSize = pointSize
    return label
  }

  func updateNSView(_ nsView: MTMathUILabel, context: Context) {
    // MTMathUILabel.setLatex: reparses and invalidates layout with no equality
    // check. Streaming re-renders the document on every token, so assigning the
    // same string again makes already-closed formulas flicker.
    if context.coordinator.latex != latex {
      context.coordinator.latex = latex
      context.coordinator.size = nil
      nsView.latex = latex
    }
    if context.coordinator.color != color {
      context.coordinator.color = color
      nsView.textColor = NSColor(color)
    }
    if context.coordinator.pointSize != pointSize {
      context.coordinator.pointSize = pointSize
      context.coordinator.size = nil
      nsView.fontSize = pointSize
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
    if let cached = context.coordinator.size {
      return cached
    }
    let size = nsView.intrinsicContentSize
    let fitted = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up) + 1)
    context.coordinator.size = fitted
    return fitted
  }

  final class Coordinator {
    var latex: String?
    var color: Color?
    var pointSize: CGFloat?
    var size: CGSize?
  }
}

#endif
