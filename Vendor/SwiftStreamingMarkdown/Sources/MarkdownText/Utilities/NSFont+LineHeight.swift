//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

#if canImport(AppKit) && !canImport(UIKit)
import AppKit

extension NSFont {
  /// Approximate `UIFont.lineHeight` using font metrics available on AppKit.
  var lineHeight: CGFloat {
    ceil(ascender - descender + leading)
  }
}
#endif
