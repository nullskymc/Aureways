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

enum Typography: CaseIterable, Sendable {
  case extraLargeStrong
  case extraLargeStrongItalic
  case extraLarge
  case extraLargeItalic

  case largeStrong
  case largeStrongItalic
  case large
  case largeItalic

  case mediumStrong
  case mediumStrongItalic
  case medium
  case mediumItalic

  case baseStrong
  case baseStrongItalic
  case baseItalic
  case base

  case smallStrong
  case smallStrongItalic
  case small
  case smallItalic

  case extraSmallStrong
  case extraSmallStrongItalic
  case extraSmall
  case extraSmallItalic

  case code
  case tripleExtraSmallCustom450

  var mdFont: MDFont {
    return switch self {
    case .tripleExtraSmallCustom450: Self.systemFont(size: 10.0, weight: .regular)
    case .code: Self.systemMonospacedFont(size: 15.0, weight: .regular)

    case .extraLargeStrong: Self.systemFont(size: 28.0, weight: .semibold)
    case .extraLargeStrongItalic: Self.systemFont(size: 28.0, weight: .semibold, italic: true)
    case .extraLarge: Self.systemFont(size: 28.0, weight: .regular)
    case .extraLargeItalic: Self.systemFont(size: 28.0, weight: .regular, italic: true)

    case .largeStrong: Self.systemFont(size: 24.0, weight: .semibold)
    case .largeStrongItalic: Self.systemFont(size: 24.0, weight: .semibold, italic: true)
    case .large: Self.systemFont(size: 24.0, weight: .regular)
    case .largeItalic: Self.systemFont(size: 24.0, weight: .regular, italic: true)

    case .mediumStrong: Self.systemFont(size: 20.0, weight: .semibold)
    case .mediumStrongItalic: Self.systemFont(size: 20.0, weight: .semibold, italic: true)
    case .medium: Self.systemFont(size: 20.0, weight: .regular)
    case .mediumItalic: Self.systemFont(size: 20.0, weight: .regular, italic: true)

    case .baseStrong: Self.systemFont(size: 17.0, weight: .semibold)
    case .baseStrongItalic: Self.systemFont(size: 17.0, weight: .semibold, italic: true)
    case .baseItalic: Self.systemFont(size: 17.0, weight: .regular, italic: true)
    case .base: Self.systemFont(size: 17.0, weight: .regular)

    case .smallStrong: Self.systemFont(size: 15.0, weight: .semibold)
    case .smallStrongItalic: Self.systemFont(size: 15.0, weight: .semibold, italic: true)
    case .small: Self.systemFont(size: 15.0, weight: .regular)
    case .smallItalic: Self.systemFont(size: 15.0, weight: .regular, italic: true)

    case .extraSmallStrong: Self.systemFont(size: 14.0, weight: .semibold)
    case .extraSmallStrongItalic: Self.systemFont(size: 14.0, weight: .semibold, italic: true)
    case .extraSmall: Self.systemFont(size: 14.0, weight: .regular)
    case .extraSmallItalic: Self.systemFont(size: 14.0, weight: .regular, italic: true)
    }
  }

  #if canImport(UIKit)
  private static func systemFont(size: CGFloat, weight: MDFont.Weight, italic: Bool = false) -> MDFont {
    let scaledSize = UIFontMetrics.default.scaledValue(for: size)
    let baseFont = MDFont.systemFont(ofSize: scaledSize, weight: weight)
    guard italic else {
      return baseFont
    }
    return baseFont.withItalicTrait()
  }

  private static func systemMonospacedFont(size: CGFloat, weight: MDFont.Weight) -> MDFont {
    let scaledSize = UIFontMetrics.default.scaledValue(for: size)
    return MDFont.monospacedSystemFont(ofSize: scaledSize, weight: weight)
  }
  #elseif canImport(AppKit)
  private static func systemFont(size: CGFloat, weight: MDFont.Weight, italic: Bool = false) -> MDFont {
    let baseFont = MDFont.systemFont(ofSize: size, weight: weight)
    guard italic else {
      return baseFont
    }
    return baseFont.withItalicTrait()
  }

  private static func systemMonospacedFont(size: CGFloat, weight: MDFont.Weight) -> MDFont {
    MDFont.monospacedSystemFont(ofSize: size, weight: weight)
  }
  #endif

  var font: Font {
    return Font(mdFont)
  }

  static var extraLargeTextFonts: TextFonts {
    return TextFonts(
      normal: Typography.extraLarge.mdFont,
      italic: Typography.extraLargeItalic.mdFont,
      bold: Typography.extraLargeStrong.mdFont,
      boldItalic: Typography.extraLargeStrongItalic.mdFont,
      preferredLetterSpacing: -0.28,
      preferredLineHeight: 32.0
    )
  }

  static var largeTextFonts: TextFonts {
    return TextFonts(
      normal: Typography.large.mdFont,
      italic: Typography.largeItalic.mdFont,
      bold: Typography.largeStrong.mdFont,
      boldItalic: Typography.largeStrongItalic.mdFont,
      preferredLetterSpacing: -0.24,
      preferredLineHeight: 32.0
    )
  }

  static var mediumTextFonts: TextFonts {
    return TextFonts(
      normal: Typography.medium.mdFont,
      italic: Typography.mediumItalic.mdFont,
      bold: Typography.mediumStrong.mdFont,
      boldItalic: Typography.mediumStrongItalic.mdFont,
      preferredLetterSpacing: -0.2,
      preferredLineHeight: 26.0
    )
  }

  static var baseTextFonts: TextFonts {
    return TextFonts(
      normal: Typography.base.mdFont,
      italic: Typography.baseItalic.mdFont,
      bold: Typography.baseStrong.mdFont,
      boldItalic: Typography.baseStrongItalic.mdFont,
      preferredLetterSpacing: 0.0,
      preferredLineHeight: 26.0
    )
  }

  static var smallTextFonts: TextFonts {
    return TextFonts(
      normal: Typography.small.mdFont,
      italic: Typography.smallItalic.mdFont,
      bold: Typography.smallStrong.mdFont,
      boldItalic: Typography.smallStrongItalic.mdFont,
      preferredLetterSpacing: 0.0,
      preferredLineHeight: 20.0
    )
  }

  static var extraSmallTextFonts: TextFonts {
    return TextFonts(
      normal: Typography.extraSmall.mdFont,
      italic: Typography.extraSmallItalic.mdFont,
      bold: Typography.extraSmallStrong.mdFont,
      boldItalic: Typography.extraSmallStrongItalic.mdFont,
      preferredLetterSpacing: 0.0,
      preferredLineHeight: 20.0
    )
  }

  static var codeTextFonts: TextFonts {
    return TextFonts(
      normal: Typography.code.mdFont,
      italic: nil,
      bold: nil,
      boldItalic: nil,
      preferredLetterSpacing: -0.12,
      preferredLineHeight: 20.0
    )
  }
}

#if canImport(UIKit)
private extension UIFont {
  func withItalicTrait() -> UIFont {
    let traits = fontDescriptor.symbolicTraits.union(.traitItalic)
    guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else {
      return self
    }
    return UIFont(descriptor: descriptor, size: pointSize)
  }
}
#elseif canImport(AppKit)
private extension NSFont {
  func withItalicTrait() -> NSFont {
    let descriptor = fontDescriptor.withSymbolicTraits(.italic)
    return NSFont(descriptor: descriptor, size: pointSize) ?? self
  }
}
#endif
