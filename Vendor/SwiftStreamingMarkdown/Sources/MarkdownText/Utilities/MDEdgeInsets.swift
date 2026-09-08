//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

#if canImport(UIKit)
import UIKit
/// Cross-platform edge insets type. Resolves to `UIEdgeInsets` on UIKit platforms and `NSEdgeInsets` on AppKit platforms.
typealias MDEdgeInsets = UIEdgeInsets
#elseif canImport(AppKit)
import AppKit
/// Cross-platform edge insets type. Resolves to `UIEdgeInsets` on UIKit platforms and `NSEdgeInsets` on AppKit platforms.
typealias MDEdgeInsets = NSEdgeInsets
#endif
