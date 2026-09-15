//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import RegexBuilder

/// Pre-process the inline and block latex in markdown.
/// This is a less heavy-weight approach than forking commonmark-gfm and swift-markdown to support parsing latex nodes.
protocol LaTexPreProcessor {
  func process(input: String, matchingRules: [MarkdownParseOption.LatexMatching]) -> String
}

extension LaTexPreProcessor {
  func process(input: String) -> String {
    return process(input: input, matchingRules: MarkdownParseOption.LatexMatching.allCases)
  }
}

final class LaTexPreProcessorImpl: LaTexPreProcessor {

  static let latexRef = Reference(Substring.self)
  static let latexOpenIndentation = Reference(Substring.self)

  static let dollarBlockMath = Regex {
    Anchor.startOfLine
    Capture(as: latexOpenIndentation) {
      ZeroOrMore(.horizontalWhitespace)
    }
    "$$"
    Capture(as: latexRef) {
      OneOrMore(.any, .reluctant)
    }
    ZeroOrMore(.horizontalWhitespace)
    "$$"
    ZeroOrMore(.horizontalWhitespace)
    Anchor.endOfLine
  }

  static let slashBracketMath = Regex {
    Anchor.startOfLine
    Capture(as: latexOpenIndentation) {
      ZeroOrMore(.horizontalWhitespace)
    }
    "\\["
    Capture(as: latexRef) {
      OneOrMore(.any, .reluctant)
    }
    ZeroOrMore(.horizontalWhitespace)
    "\\]"
    ZeroOrMore(.horizontalWhitespace)
    Anchor.endOfLine
  }

  static let inlineParenthesisMath = Regex {
    "\\("
    Capture(as: latexRef) {
      OneOrMore(.any, .reluctant)
    }
    "\\)"
  }

  static let boxedLatex = Regex {
    Capture {
      "\\boxed"
    }
  }

  static let dfracLatex = Regex {
    Capture {
      "\\dfrac"
    }
  }

  static let tfracLatex = Regex {
    Capture {
      "\\tfrac"
    }
  }

  static let bracketSize = Regex {
    Capture {
      ChoiceOf {
        "\\bigl"
        "\\biggl"
        "\\Bigl"
        "\\Biggl"
        "\\bigr"
        "\\biggr"
        "\\Bigr"
        "\\Biggr"
        "\\big"
      }
    }
  }

  static let primeLatex = Regex {
    Capture {
      "'"
    }
  }

  static let vectorLatex = Regex {
    Capture {
      "\\overrightarrow"
    }
  }

  static let rightArrowLatex = Regex {
    Capture {
      "\\implies"
    }
  }

  static let harpoonsLatex = Regex {
    Capture {
      "\\rightleftharpoons"
    }
  }

  static let dotsLatex = Regex {
    Capture {
      "\\dots"
    }
  }

  static let customCodeType = "blockmath"
  static let inlineCodePrefix = "\\("
  static let inlineCodeSuffix = "\\)"
  static let newline = "\n"

  init() {}

  func process(input: String, matchingRules: [MarkdownParseOption.LatexMatching]) -> String {
    let rules = Set(matchingRules)
    let result = processBlockMath(input: input, rules: rules)
    return processInlineMath(input: result, rules: rules)
  }

  /// This replace block math with a special code block node. By treating it as a code block it will avoid over escaping characters within latex.
  func processBlockMath(input: String, rules: Set<MarkdownParseOption.LatexMatching>) -> String {
    var result = input
    if rules.contains(.blockDollar) {
      result.replace(Self.dollarBlockMath, with: { match in
        let indentation = match[Self.latexOpenIndentation]
        let latex = match[Self.latexRef]
        return Self.buildCodeBlock(indentation: indentation, latex: latex)
      })
    }

    if rules.contains(.blockSlashBracket) {
      result.replace(Self.slashBracketMath, with: { match in
        let indentation = match[Self.latexOpenIndentation]
        let latex = match[Self.latexRef]
        return Self.buildCodeBlock(indentation: indentation, latex: latex)
      })
    }
    return result
  }

  /// This wraps inline math as inline code to avoid over-unescaping issue.
  /// `\(...\)` is rewritten first; `$...$` then walks the string so it can skip
  /// fenced / inline code (including the spans just produced).
  func processInlineMath(input: String, rules: Set<MarkdownParseOption.LatexMatching>) -> String {
    var result = input
    if rules.contains(.inlineSlashBracket) {
      result.replace(Self.inlineParenthesisMath, with: { match in
        let latex = String(match[Self.latexRef]).filteringUnsupportedSyntaxes()
        return "`\\(\(latex)\\)`"
      })
    }
    if rules.contains(.inlineDollar) {
      result = processInlineDollarMath(input: result)
    }
    return result
  }

  /// Pandoc-style `$...$`: opening `$` not followed by whitespace, closing `$`
  /// not preceded by whitespace and not followed by a digit. Newlines reject
  /// the span so a missing closer cannot swallow the rest of the document.
  func processInlineDollarMath(input: String) -> String {
    var output = ""
    output.reserveCapacity(input.count)
    var index = input.startIndex
    let end = input.endIndex
    while index < end {
      if let fence = consumeFencedCode(input, from: index) {
        output.append(contentsOf: fence.text)
        index = fence.next
        continue
      }
      if let code = consumeInlineCode(input, from: index) {
        output.append(contentsOf: code.text)
        index = code.next
        continue
      }
      if input[index] == "\\" {
        output.append("\\")
        index = input.index(after: index)
        if index < end {
          output.append(input[index])
          index = input.index(after: index)
        }
        continue
      }
      if input[index] == "$", let math = consumeInlineDollar(input, from: index) {
        let latex = String(math.latex).filteringUnsupportedSyntaxes()
        output.append("`\\(\(latex)\\)`")
        index = math.next
        continue
      }
      output.append(input[index])
      index = input.index(after: index)
    }
    return output
  }

  private func isLineStart(_ input: String, _ index: String.Index) -> Bool {
    index == input.startIndex || input[input.index(before: index)] == "\n"
  }

  private func consumeFencedCode(
    _ input: String,
    from index: String.Index
  ) -> (text: Substring, next: String.Index)? {
    guard isLineStart(input, index) else { return nil }
    var cursor = index
    var indent = 0
    while cursor < input.endIndex, input[cursor] == " ", indent < 3 {
      indent += 1
      cursor = input.index(after: cursor)
    }
    guard cursor < input.endIndex else { return nil }
    let fenceChar = input[cursor]
    guard fenceChar == "`" || fenceChar == "~" else { return nil }
    var fenceLength = 0
    while cursor < input.endIndex, input[cursor] == fenceChar {
      fenceLength += 1
      cursor = input.index(after: cursor)
    }
    guard fenceLength >= 3 else { return nil }
    while cursor < input.endIndex, input[cursor] != "\n" {
      cursor = input.index(after: cursor)
    }
    if cursor < input.endIndex {
      cursor = input.index(after: cursor)
    }
    while cursor < input.endIndex {
      let lineStart = cursor
      var look = cursor
      var lineIndent = 0
      while look < input.endIndex, input[look] == " ", lineIndent < 3 {
        lineIndent += 1
        look = input.index(after: look)
      }
      var closeLength = 0
      while look < input.endIndex, input[look] == fenceChar {
        closeLength += 1
        look = input.index(after: look)
      }
      if closeLength >= fenceLength {
        while look < input.endIndex, input[look] == " " || input[look] == "\t" {
          look = input.index(after: look)
        }
        if look == input.endIndex || input[look] == "\n" {
          if look < input.endIndex {
            look = input.index(after: look)
          }
          return (input[index..<look], look)
        }
      }
      cursor = lineStart
      while cursor < input.endIndex, input[cursor] != "\n" {
        cursor = input.index(after: cursor)
      }
      if cursor < input.endIndex {
        cursor = input.index(after: cursor)
      }
    }
    return (input[index..<input.endIndex], input.endIndex)
  }

  private func consumeInlineCode(
    _ input: String,
    from index: String.Index
  ) -> (text: Substring, next: String.Index)? {
    guard input[index] == "`" else { return nil }
    var cursor = index
    var ticks = 0
    while cursor < input.endIndex, input[cursor] == "`" {
      ticks += 1
      cursor = input.index(after: cursor)
    }
    guard ticks > 0 else { return nil }
    var look = cursor
    while look < input.endIndex {
      if input[look] == "`" {
        var close = 0
        var closer = look
        while closer < input.endIndex, input[closer] == "`" {
          close += 1
          closer = input.index(after: closer)
        }
        if close == ticks {
          return (input[index..<closer], closer)
        }
        look = closer
        continue
      }
      look = input.index(after: look)
    }
    return nil
  }

  private func consumeInlineDollar(
    _ input: String,
    from index: String.Index
  ) -> (latex: Substring, next: String.Index)? {
    let afterOpen = input.index(after: index)
    guard afterOpen < input.endIndex else { return nil }
    let nextChar = input[afterOpen]
    if nextChar == "$" || nextChar.isWhitespace { return nil }

    var cursor = afterOpen
    while cursor < input.endIndex {
      let char = input[cursor]
      if char == "\n" { return nil }
      if char == "\\" {
        let escaped = input.index(after: cursor)
        guard escaped < input.endIndex else { return nil }
        cursor = input.index(after: escaped)
        continue
      }
      if char == "$" {
        let previous = input[input.index(before: cursor)]
        if previous.isWhitespace {
          cursor = input.index(after: cursor)
          continue
        }
        let afterClose = input.index(after: cursor)
        if afterClose < input.endIndex {
          let following = input[afterClose]
          if following.isASCII && following.isNumber {
            cursor = afterClose
            continue
          }
        }
        let latex = input[afterOpen..<cursor]
        guard !latex.isEmpty else { return nil }
        return (latex, afterClose)
      }
      cursor = input.index(after: cursor)
    }
    return nil
  }

  // MARK: - Convenience overloads (default to every supported rule)

  func processBlockMath(input: String) -> String {
    return processBlockMath(input: input, rules: Set(MarkdownParseOption.LatexMatching.allCases))
  }

  func processInlineMath(input: String) -> String {
    return processInlineMath(input: input, rules: Set(MarkdownParseOption.LatexMatching.allCases))
  }

  private static func buildCodeBlock(indentation: Substring, latex: Substring) -> String {
    let processedLatex = latex.trimmingCharacters(in: .newlines).filteringUnsupportedSyntaxes()
    let nextLineIntendation = latex.hasPrefix(Self.newline) ? "" : indentation
    return "\(indentation)```\(Self.customCodeType)\(Self.newline)\(nextLineIntendation)\(processedLatex)\(Self.newline)\(indentation)```"
  }
}

extension String {

  func filteringUnsupportedSyntaxes() -> String {
    return self
      .strippingBoxedLatex()
      .replacingfrac()
      .replacingPrime()
      .replacingVector()
      .replacingImplies()
      .replacingHarpoons()
      .replacingDots()
      .strippingBracketSizeCommands()
  }

  /// This strips "\boxed" string from a given latex. This is because our rendering engine does not support \boxed{...} yet.
  func strippingBoxedLatex() -> String {
    return self.replacing(LaTexPreProcessorImpl.boxedLatex, with: "")
  }

  /// Replacing `dfrac` and `tfac` which is unsupported into simple `frac`
  func replacingfrac() -> String {
    return self
      .replacing(LaTexPreProcessorImpl.dfracLatex, with: "\\frac")
      .replacing(LaTexPreProcessorImpl.tfracLatex, with: "\\frac")
  }

  /// Replacing `'` which is unsupported into `^prime`
  func replacingPrime() -> String {
    return self.replacing(LaTexPreProcessorImpl.primeLatex, with: "^\\prime")
  }

  /// Replacing `overrightarrow` which is unsupported into `vec`
  func replacingVector() -> String {
    return self.replacing(LaTexPreProcessorImpl.vectorLatex, with: "\\vec")
  }

  /// Replacing `implies` which is unsupported into `Rightarrow`
  func replacingImplies() -> String {
    return self.replacing(LaTexPreProcessorImpl.rightArrowLatex, with: "\\Rightarrow")
  }

  /// Replacing `harpoons` which is unsupported into `Leftrightarrow`
  func replacingHarpoons() -> String {
    return self.replacing(LaTexPreProcessorImpl.harpoonsLatex, with: "\\Leftrightarrow")
  }

  /// Replacing `dots` which is unsupported into `ldots`
  func replacingDots() -> String {
    return self.replacing(LaTexPreProcessorImpl.dotsLatex, with: "\\ldots")
  }

  /// Stripping commands to specify bracket sizes(`\Biggl` etc) which is unsupported
  func strippingBracketSizeCommands() -> String {
    return self.replacing(LaTexPreProcessorImpl.bracketSize, with: "")
  }
}
