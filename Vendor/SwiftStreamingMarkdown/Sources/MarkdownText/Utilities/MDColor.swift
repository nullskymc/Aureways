//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

#if canImport(UIKit)
import UIKit
/// Cross-platform color type for NSAttributedString attributes.
/// Resolves to `UIColor` on UIKit platforms and `NSColor` on AppKit platforms.
typealias MDColor = UIColor
#elseif canImport(AppKit)
import AppKit
/// Cross-platform color type for NSAttributedString attributes.
/// Resolves to `UIColor` on UIKit platforms and `NSColor` on AppKit platforms.
typealias MDColor = NSColor

extension NSColor {
  /// Resolve a dynamic color for a specific appearance name (e.g. `.aqua`, `.darkAqua`).
  func resolvedForAppearance(_ name: NSAppearance.Name) -> NSColor {
    var resolved = self
    NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
      resolved = self.usingColorSpace(.sRGB) ?? self
    }
    return resolved
  }
}
#endif
