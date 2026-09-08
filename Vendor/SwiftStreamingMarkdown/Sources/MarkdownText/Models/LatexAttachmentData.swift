//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation

struct LatexAttachmentData: Codable, Equatable, Hashable {
  let latex: String
  let fontSize: CGFloat
  let lightTextColor: String
  let darkTextColor: String
}
