//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Inline LaTeX attachment whose equality is payload-based.
///
/// `NSTextAttachment` uses object identity for `isEqual:`. Streaming re-parses
/// the whole document on every token, so each parse minted a new attachment
/// even when the formula was unchanged. `NSAttributedString.isEqual` then
/// failed, `setAttributedString` rebuilt the text storage, and every
/// `MTMathUILabel` flickered as its view provider was torn down.
final class LatexTextAttachment: NSTextAttachment {
  let payload: LatexAttachmentData

  init(payload: LatexAttachmentData, encoded: Data) {
    self.payload = payload
    super.init(data: encoded, ofType: UTType.data.identifier)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? LatexTextAttachment else {
      return super.isEqual(object)
    }
    return payload == other.payload
  }

  override var hash: Int {
    var hasher = Hasher()
    hasher.combine(payload)
    return hasher.finalize()
  }
}
