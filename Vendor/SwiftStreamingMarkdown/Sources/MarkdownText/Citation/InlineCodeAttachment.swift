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
import UniformTypeIdentifiers

/// Rounded inline-code chip. Attributed-string `backgroundColor` is always a hard
/// rectangle; this attachment draws a soft rounded pill with a light shadow.
final class InlineCodeAttachment: NSTextAttachment {
  let code: String
  let font: MDFont
  let textColor: MDColor
  let backgroundColor: MDColor

  private var lightPreviewImage: MDImage?
  private var darkPreviewImage: MDImage?
  private var assignedImage: MDImage?

  static let textInsets = MDEdgeInsets(top: 1.5, left: 5, bottom: 1.5, right: 5)
  static let cornerRadius: CGFloat = 5

  #if canImport(UIKit)
  override var image: UIImage? {
    get {
      if let assignedImage { return assignedImage }
      let app = AppAppearance.$current.read({ $0 })
      switch app {
      case .dark: return darkPreviewImage
      case .light: return lightPreviewImage
      }
    }
    set { assignedImage = newValue }
  }
  #elseif canImport(AppKit)
  override var image: NSImage? {
    get {
      if let assignedImage { return assignedImage }
      let app = AppAppearance.$current.read({ $0 })
      switch app {
      case .dark: return darkPreviewImage
      case .light: return lightPreviewImage
      }
    }
    set { assignedImage = newValue }
  }
  #endif

  init(code: String, font: MDFont, textColor: MDColor, backgroundColor: MDColor) {
    self.code = code
    self.font = font
    self.textColor = textColor
    self.backgroundColor = backgroundColor
    self.lightPreviewImage = Self.renderCodeImage(
      code: code, font: font, textColor: textColor, backgroundColor: backgroundColor, appearance: .light
    )
    self.darkPreviewImage = Self.renderCodeImage(
      code: code, font: font, textColor: textColor, backgroundColor: backgroundColor, appearance: .dark
    )
    super.init(data: Data(code.utf8), ofType: UTType.utf8PlainText.identifier)
  }

  required init?(coder: NSCoder) { nil }

  override func attachmentBounds(
    for textContainer: NSTextContainer?,
    proposedLineFragment lineFrag: CGRect,
    glyphPosition position: CGPoint,
    characterIndex charIndex: Int
  ) -> CGRect {
    guard let image else { return .zero }
    let size = image.size
    let y = (font.capHeight - size.height) / 2
    return CGRect(x: 0, y: y, width: size.width, height: size.height)
  }

  private static func renderCodeImage(
    code: String,
    font: MDFont,
    textColor: MDColor,
    backgroundColor: MDColor,
    appearance: AppAppearance
  ) -> MDImage {
    #if canImport(UIKit)
    let traitCollection = UITraitCollection(userInterfaceStyle: appearance.platformType)
    let resolvedTextColor = textColor.resolvedColor(with: traitCollection)
    let resolvedBackgroundColor = backgroundColor.resolvedColor(with: traitCollection)
    #elseif canImport(AppKit)
    var resolvedTextColor = textColor
    var resolvedBackgroundColor = backgroundColor
    appearance.platformType?.performAsCurrentDrawingAppearance {
      resolvedTextColor = textColor.usingColorSpace(.sRGB) ?? textColor
      resolvedBackgroundColor = backgroundColor.usingColorSpace(.sRGB) ?? backgroundColor
    }
    #endif

    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: resolvedTextColor
    ]
    let textSize = (code as NSString).size(withAttributes: attributes)
    let totalSize = CGSize(
      width: ceil(textSize.width) + textInsets.left + textInsets.right,
      height: ceil(textSize.height) + textInsets.top + textInsets.bottom
    )

    #if canImport(UIKit)
    let renderer = UIGraphicsImageRenderer(size: totalSize)
    return renderer.image { ctx in
      let rect = CGRect(origin: .zero, size: totalSize)
      ctx.cgContext.setShadow(
        offset: CGSize(width: 0, height: 0.5),
        blur: 1.5,
        color: UIColor.black.withAlphaComponent(0.10).cgColor
      )
      let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
      resolvedBackgroundColor.setFill()
      path.fill()
      ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

      let textRect = CGRect(
        x: textInsets.left, y: textInsets.top,
        width: ceil(textSize.width), height: ceil(textSize.height)
      )
      (code as NSString).draw(in: textRect, withAttributes: attributes)
    }
    #elseif canImport(AppKit)
    return NSImage(size: totalSize, flipped: false) { rect in
      if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.setShadow(
          offset: CGSize(width: 0, height: -0.5),
          blur: 1.5,
          color: NSColor.black.withAlphaComponent(0.10).cgColor
        )
      }
      let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
      resolvedBackgroundColor.setFill()
      path.fill()
      if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
      }

      let textRect = CGRect(
        x: textInsets.left, y: textInsets.bottom,
        width: ceil(textSize.width), height: ceil(textSize.height)
      )
      (code as NSString).draw(in: textRect, withAttributes: attributes)
      return true
    }
    #endif
  }
}
