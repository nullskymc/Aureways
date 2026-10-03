# WebTranscript (prototype, feature-flagged)

WKWebView-hosted Markdown renderer for agent messages, modeled on the Codex
desktop app approach. The SwiftUI renderer (`MarkdownBody`) remains the default.

## Toggle

- Settings → 通用 → 外观 → “用 Web 渲染消息正文（实验）”, or
- `defaults write ai.aureways.client useWebTranscript -bool true` (relaunch not required; `false` / `defaults delete` to revert)

## Build

```sh
make web            # = cd WebTranscript && npm ci && npm run build
```

Output goes to `Aureways/WebTranscriptBundle/` (a folder reference in the Xcode
project, copied to `Aureways.app/Contents/Resources/WebTranscriptBundle`).
**The output is committed**, so `make build` / `make open` never need Node.

## Stack

- `marked` lexer → top-level blocks; each block rendered by `marked.parser` and
  sanitized with `DOMPurify`.
- Shiki core + JavaScript regex engine (no WASM). Themes (github-light/dark,
  dual via CSS `light-dark()`) and each grammar are lazy chunks; only finished
  code blocks are highlighted, the streaming tail stays plain monospace.
- No framework (vanilla TS). Eager payload ≈ 80 KB raw / 28 KB gz.

## Streaming model

- Raw Markdown is kept per message. While streaming, the tail is patched
  (unclosed fence, unbalanced `` ` `` / `**`, half-typed link target).
- Top-level blocks before the last one are frozen; each frame only re-lexes
  from the start of the last block, and unchanged blocks keep their DOM nodes.
- Updates are batched per `requestAnimationFrame`; Swift also throttles to 30 Hz.
- `finishMessage` re-lexes the whole message once (memoized by block raw).

## Bridge

Swift → JS (`window.aureways`): `setMessages([{id,text,streaming}])`,
`appendDelta(id, text)`, `finishMessage(id, fullText?)`, `setFontScale(x)`.

JS → Swift (`webkit.messageHandlers.aureways`): `ready`, `height`, `link`, `copy`.

Loaded from the custom `aureways-web://app/` scheme served from the app bundle
(ES-module chunks cannot load from `file://`). CSP blocks all network.

## Dev

`npm run dev` then open `http://localhost:5173/?demo` for a streamed sample.
