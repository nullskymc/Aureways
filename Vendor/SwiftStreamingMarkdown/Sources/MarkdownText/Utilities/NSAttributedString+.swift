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

extension NSAttributedString {
  func splitIntoWords(withIn range: NSRange) -> [NSRange] {
    var words: [NSRange] = []
    let string = self.string as NSString

    guard range.location != NSNotFound,
          range.location >= 0,
          NSMaxRange(range) <= string.length else {
      return words
    }

    string.enumerateSubstrings(
      in: range,
      options: [.byWords, .localized, .substringNotRequired]
    ) { (_, substringRange, _, _) in

      // Add any separator/whitespace before this word
      if let lastWord = words.last {
        let gapStart = NSMaxRange(lastWord)
        let gapLength = substringRange.location - gapStart

        if gapLength > 0 {
          let gapRange = NSRange(location: gapStart, length: gapLength)
          words.append(gapRange)
        }
      } else {
        // Handle any leading separators/whitespace
        let leadingGapLength = substringRange.location - range.location
        if leadingGapLength > 0 {
          let leadingGapRange = NSRange(location: range.location, length: leadingGapLength)
          words.append(leadingGapRange)
        }
      }

      // Add the word range
      words.append(substringRange)
    }

    // Handle any trailing separators/whitespace
    if let lastWord = words.last {
      let trailingStart = NSMaxRange(lastWord)
      let trailingLength = NSMaxRange(range) - trailingStart

      if trailingLength > 0 {
        let trailingRange = NSRange(location: trailingStart, length: trailingLength)
        words.append(trailingRange)
      }
    } else {
      // If no words were found, return entire range
      if range.length > 0 {
        words.append(range)
      }
    }

    return words
  }

  /// True when `prefix` matches the receiver's leading characters and inline
  /// attachments (LaTeX by payload). Ignores `NSColor` catalog identity:
  /// `NSColor(Color.primary)` mints a new dynamic color on every parse, so
  /// `isEqual` would treat an unchanged formula as a full rewrite.
  func markdownPrefix(equalTo prefix: NSAttributedString) -> Bool {
    guard length >= prefix.length else { return false }
    if prefix.length == 0 { return true }
    return attributedSubstring(from: NSRange(location: 0, length: prefix.length))
      .hasSameMarkdownIdentity(as: prefix)
  }

  func hasSameMarkdownIdentity(as other: NSAttributedString) -> Bool {
    guard string == other.string, length == other.length else { return false }
    if length == 0 { return true }

    var location = 0
    while location < length {
      var lhsRange = NSRange()
      var rhsRange = NSRange()
      let lhs = attributes(at: location, effectiveRange: &lhsRange)
      let rhs = other.attributes(at: location, effectiveRange: &rhsRange)
      guard Self.attributesHaveSameMarkdownIdentity(lhs, rhs) else { return false }
      location = min(NSMaxRange(lhsRange), NSMaxRange(rhsRange))
    }
    return true
  }

  private static func attributesHaveSameMarkdownIdentity(
    _ lhs: [NSAttributedString.Key: Any],
    _ rhs: [NSAttributedString.Key: Any]
  ) -> Bool {
    guard lhs.keys == rhs.keys else { return false }
    for key in lhs.keys {
      let left = lhs[key]
      let right = rhs[key]
      switch key {
      case .attachment:
        guard attachmentsHaveSamePayload(left, right) else { return false }
      #if canImport(AppKit)
      case .foregroundColor, .backgroundColor, .underlineColor, .strikethroughColor:
        guard colorsHaveSameAppearance(left, right) else { return false }
      case .font:
        guard let l = left as? NSFont, let r = right as? NSFont,
              l.fontDescriptor == r.fontDescriptor, l.pointSize == r.pointSize else { return false }
      #endif
      default:
        guard let l = left as? NSObject, let r = right as? NSObject, l.isEqual(r) else { return false }
      }
    }
    return true
  }

  #if canImport(AppKit)
  private static func colorsHaveSameAppearance(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs = lhs as? NSColor, let rhs = rhs as? NSColor else { return false }
    for appearance in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)].compactMap({ $0 }) {
      var left: NSColor?
      var right: NSColor?
      appearance.performAsCurrentDrawingAppearance {
        left = lhs.usingColorSpace(.sRGB)
        right = rhs.usingColorSpace(.sRGB)
      }
      guard let left, let right,
            abs(left.redComponent - right.redComponent) < 0.0001,
            abs(left.greenComponent - right.greenComponent) < 0.0001,
            abs(left.blueComponent - right.blueComponent) < 0.0001,
            abs(left.alphaComponent - right.alphaComponent) < 0.0001 else { return false }
    }
    return true
  }
  #endif

  private static func attachmentsHaveSamePayload(_ lhs: Any?, _ rhs: Any?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
      return true
    case let (left as LatexTextAttachment, right as LatexTextAttachment):
      return left.payload == right.payload
    case let (left as InlineCitationAttachment, right as InlineCitationAttachment):
      return left.citationData == right.citationData
        && left.font == right.font
        && colorsHaveSameAppearance(left.textColor, right.textColor)
        && colorsHaveSameAppearance(left.backgroundColor, right.backgroundColor)
    case let (left as NSTextAttachment, right as NSTextAttachment):
      return left.isEqual(right)
    default:
      return false
    }
  }
}
