# Aureways patches

Vendored from [microsoft/SwiftStreamingMarkdown](https://github.com/microsoft/SwiftStreamingMarkdown) at revision `5f7c04e0558df6146f90d482edb62cb456986bda`.

Streaming a growing Markdown snapshot used to re-parse the whole document and then rebuild every `MTMathUILabel`. Already-closed formulas flickered and CPU scaled with (formula count × token rate).

Changes on top of upstream:

1. **`LatexTextAttachment`** — inline math attachments compare equal by payload (`latex`, size, colors), not by object identity.
2. **Stable content identity** — `NSColor(Color.primary)` mints a new catalog color on every parse, so `NSAttributedString.isEqual` cannot be used across snapshots. Paragraphs compare by string + attachment payload (`hasSameMarkdownIdentity`); `SingleBlockView` uses that for `.equatable()`.
3. **`BlockMathView`** — skip `latex` / color assignment when they have not changed, and cache `sizeThatFits`. iosMath reparses and typesets on every `setLatex:` with no equality check.
4. **`ParagraphNSView` / `ParagraphUIView`** — if the new attributed string is an extension of the current one, append the suffix instead of `setAttributedString`. Replacing the whole storage destroys attachment subviews and recreates every formula.
5. **`SingleBlockView`** — `Equatable` + `.equatable()`, so unchanged latex / heading / paragraph blocks do not re-enter `updateNSView` / `sizeThatFits` when a later block grows.
6. **Final-document text merging** — collapse adjacent headings, paragraphs, and text-only lists into one attributed paragraph after streaming completes, so native TextKit selection crosses those Markdown block boundaries while rich blocks keep their existing views.

When rebasing onto a newer upstream: copy `Sources/` over, re-apply the items above, and keep this file in sync.
