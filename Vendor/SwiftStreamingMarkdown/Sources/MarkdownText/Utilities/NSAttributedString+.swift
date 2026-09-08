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
    var matches = true
    enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, range, stop in
      let otherValue = other.attribute(.attachment, at: range.location, effectiveRange: nil)
      if !Self.attachmentsHaveSamePayload(value, otherValue) {
        matches = false
        stop.pointee = true
      }
    }
    return matches
  }

  private static func attachmentsHaveSamePayload(_ lhs: Any?, _ rhs: Any?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
      return true
    case let (left as LatexTextAttachment, right as LatexTextAttachment):
      return left.payload == right.payload
    case let (left as NSTextAttachment, right as NSTextAttachment):
      return left.isEqual(right)
    default:
      return false
    }
  }
}
