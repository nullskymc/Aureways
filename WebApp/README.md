# WebApp — the Aureways main-window UI

Everything inside the main window (sidebar, transcript, composer, permission
cards) is this app, running in one `WKWebView`. SwiftUI only provides the app
shell. Architecture and the Swift <-> JS protocol: [docs/web-shell.md](../docs/web-shell.md).

```sh
make web        # = cd WebApp && npm ci && npm run build
npm run dev     # vite dev server with a demo state (no Swift side)
```

Output: `Aureways/WebAppBundle/` (folder reference, copied to
`Aureways.app/Contents/Resources/WebAppBundle`). **Committed**, so Xcode builds
never need Node.

## Stack

- **Preact + @preact/signals** (~15 KB min): smallest mainstream runtime with a
  React/JSX model (Codex desktop is React), no compiler step beyond esbuild's
  JSX transform. Svelte 5 and Solid were the alternatives; Preact won on runtime
  size + zero extra build plugins, and the hot path (Markdown streaming) is
  imperative DOM anyway.
- Transcript is windowed from the start (`components/VirtualList.tsx`):
  measured variable heights, bottom pinning, anchor compensation.
- Markdown: `marked` lexer per top-level block, frozen blocks while streaming,
  `DOMPurify`, Shiki core + JS regex engine with lazy grammars/themes
  (`markdown/`).
- Native popups: pickers and context menus call back into Swift for real
  `NSMenu`s; attachments use `NSOpenPanel`.
