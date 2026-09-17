# Patches applied to vendored SwiftStreamingMarkdown

Upstream: [microsoft/SwiftStreamingMarkdown](https://github.com/microsoft/SwiftStreamingMarkdown) @ `5f7c04e04313f88f2195f3240212f45348ba53a8`

Changes on top of upstream:

1. **Inline math deduplication** — upstream re-rendered every inline math formula on every streaming chunk, allocating a fresh `MTMathUILabel` each time and spamming the run loop. Patched to key subviews by `(latex, fontSize)` so only new / changed formulas allocate.
2. **Stable content identity** — `NSColor(Color.primary)` mints a new catalog color on every parse, so `NSAttributedString.isEqual` cannot be used across snapshots. Paragraphs compare by string + attachment payload (`hasSameMarkdownIdentity`); `SingleBlockView` uses that for `.equatable()`.
3. **`TextFonts.withSize`** — convenience helper used by `AurewaysMarkdown` to derive scaled type styles from base configurations.
4. **`ParagraphNSView` / `ParagraphUIView`** — if the new attributed string is an extension of the current one, append the suffix instead of `setAttributedString`. Replacing the whole storage destroys attachment subviews and recreates every formula.
5. **`SingleBlockView`** — `Equatable` + `.equatable()`, so unchanged latex / heading / paragraph blocks do not re-enter `updateNSView` / `sizeThatFits` when a later block grows.
6. **Final-document text merging** — collapse adjacent headings, paragraphs, and text-only lists into one attributed paragraph after streaming completes, so native TextKit selection crosses those Markdown block boundaries while rich blocks keep their existing views.
7. **`$...$` inline math** — `LaTexPreProcessor` recognizes Pandoc-style single-dollar spans (`$f_\beta(x)$`, table cells, `\theta`) in addition to `\(...\)`. Currency (`$5` / `$10`) and `$` inside fenced or inline code are left alone; `_` inside math is no longer parsed as emphasis.
8. **Table width** — `TableView` was writing viewport width into `@State` on every split-pane frame (and measuring the grid itself, which depends on that width). Commit width after 80 ms of stability so dragging the inspector does not rebuild every cell / formula.
9. **`HighlightTaskManager` static cache & language forwarding** (`PERF-01` / `PERF-07`) — process-wide bounded LRU cache (`cacheLimit = 512`) keyed by `(code, language, colors)` surviving `CodeBlockView` recycling; forwards fence language to `Highlight.attributedText(_:language:colors:)` falling back to auto-detect; eliminates JavaScriptCore re-tokenization overhead on scroll-back and avoids unneeded text invalidation.
10. **Signpost telemetry** (`PERF-00`) — instrumented `MarkdownParserImpl.parse` (`MarkdownParse`), `RenderableDocument.init` (`RenderableDocumentBuild`), and `HighlightTaskManager` (`HighlightQueueWait`) with `OSSignposter` intervals under subsystem `ai.aureways.client` for unified trace profiling.

11. **Document concatenation for incremental streaming** (`PERF-03`) — added `RenderableDocument.appending(_:)` to allow composing pre-parsed committed block documents with open trailing block documents without full-document reparsing.

12. **Paragraph width rounding & bounded size cache** (`PERF-09`) — `ParagraphView+macOS.swift` rounds `fittingWidth` to integer points in `sizeThatFits` and retains a bounded (32-entry) width-to-size cache, eliminating sub-pixel measurement oscillation and cache misses when resizing or dragging split views below 828 pt.

13. **Native text selection on rich components** — added `.textSelection(.enabled)` to `CodeBlockView`, `TableView`, and `BlockQuoteView` so users can highlight, drag-select, and copy partial code snippets or table contents natively on macOS.

When rebasing onto a newer upstream: copy `Sources/` over, re-apply the items above, and keep this file in sync.
