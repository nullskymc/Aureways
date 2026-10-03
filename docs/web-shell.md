# Web shell architecture (`proto/web-shell`)

> "swiftui给个app壳就好了，里面都用webview"

The main window is a thin native shell. Everything drawn inside it — sidebar,
transcript, composer, permission cards — is **one `WKWebView`** running a small
Preact app (`WebApp/`). SwiftUI keeps only the `App`, scene and menu plumbing.

## Why

`NavigationSplitView` + `NSHostingView.SizeConstraints` kept re-entering
`SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)` until AppKit
threw *"more Update Constraints in Window passes than there are views in the
window"*. It reproduced with every SwiftUI content variant (web transcript
flag on or off). The fix is structural: no split view and no SwiftUI content
layout inside the window. The window now hosts a single `NSView` whose only
subviews are an `NSVisualEffectView`, the web view, and a titlebar drag strip;
nothing reports min/max sizes back to SwiftUI on every pass.

## Responsibilities

| Native shell (Swift) | Web app (TS/Preact) |
| --- | --- |
| `App`, single `Window` scene, Settings scene, menu-bar extra | Sidebar: workspaces → sessions, search, new session |
| Window chrome: full-size content, transparent titlebar, traffic lights, `NSVisualEffectView` (sidebar material) behind a transparent web view | Main header (title, workspace · branch, harness, retry) |
| Titlebar drag strip (`-webkit-app-region` is not supported by WKWebView); web reports no-drag rects for its header buttons | Transcript: virtualized list, user bubbles + attachments, Markdown (marked + DOMPurify + lazy Shiki), tool rows, thinking, plans, status |
| Menus: New Session ⌘N, Settings ⌘, (native SwiftUI Settings for now), Find ⌘F → web, ⌘1…⌘9, ⌘B sidebar | Composer: multiline, send/stop, harness / model / effort / mode chips, attachments |
| Native popup menus (`NSMenu`) on request from web, `NSOpenPanel` for attachments, pasteboard, opening links/files | Permission cards, plan-approval card, connect/error banners |
| ACP client, harness runtimes, session persistence (`AppModel`, `ChatSession`, `SessionStore`) — unchanged | Pure view: holds no source of truth except UI state (collapsed rows, scroll) |

## Bridge protocol

Transport: JS → Swift `window.webkit.messageHandlers.aureways.postMessage(obj)`;
Swift → JS `window.__aw.receive(obj)` via `evaluateJavaScript` (JSON literal).
Assets are served from the app bundle through the `aureways-web://app/` scheme.

`WebShellBridge` observes `AppModel` / `ChatSession` with
`withObservationTracking`. Any change marks the bridge dirty; a flush runs at
most every ~22 ms (≈45 Hz) and emits only what changed.

### Swift → JS

```jsonc
{ "type": "state", "state": AppState }          // full app snapshot, sent only when its JSON changes
{ "type": "transcript", "sessionId": "…", "items": [Item] }   // reset on session switch / reload
{ "type": "patch", "sessionId": "…", "ops": [               // incremental, per flush
    { "op": "upsert", "index": 12, "item": Item },          // new or changed item
    { "op": "append", "id": "…", "delta": "more tokens" },  // agent / thought / user text grew by a suffix
    { "op": "remove", "id": "…" } ] }
{ "type": "command", "name": "find" | "toggleSidebar" | "focusComposer" | "newSession" }
{ "type": "menuResult", "token": 3, "id": "model:gpt-5" | null }
```

`AppState`: sessions (id, title, agent, cwd, phase, streaming, needsAttention),
workspaces, selected session / agent / workspace, agents (+availability),
composer (model / effort / mode options, slash commands, pending attachments),
the selected session's pending permission / plan approval, error message,
window chrome metrics (traffic-light frame, titlebar height).

`Item` kinds: `user {text, attachments}`, `agent {text}`, `thought {text}`,
`tool {title, status, layout, progress, command, output, path, diff{hunks,+,-}}`,
`plan {entries}`, `status {text}`; thought / tool / plan carry `run {s, e}`
timing so the web can show "Worked for 42s".

### JS → Swift

`ready`, `send {text}`, `cancel`, `newSession {workspace?}`, `selectSession {id}`,
`closeSession {id}`, `retry {id}`, `selectAgent {id}`, `setConfig {configId, value}`,
`setMode {modeId}`, `permission {optionId|null}`, `planApproval {decision, feedback}`,
`attach` (native `NSOpenPanel`), `removeAttachment {id}`, `openLink {href}`,
`copy {text}`, `selectWorkspace {path}`, `addWorkspace`, `revealWorkspace {path}`,
`openSettings`, `menu {token, x, y, items}` (native `NSMenu` popup),
`dragRegions {rects}`, `sessionMenu {id, x, y}`.

## Migration plan

1. **(this branch)** Web shell is the default window content. Old SwiftUI root
   (`RootView` + `NavigationSplitView`) stays compiled behind the
   `useLegacyNativeUI` defaults flag for comparison only; the per-message
   `WebMarkdownBody` prototype is removed (its renderer moved into `WebApp/`).
2. Port the inspector (file browser, editor, terminal tabs, diff review) as web
   routes; terminals via xterm.js fed from the existing PTY layer.
3. Port Settings to a web route (`#/settings`) and drop the SwiftUI Settings
   scene; menu-bar extra can stay native.
4. Delete legacy SwiftUI views once parity is reached.

## Building the web app

`make web` → `cd WebApp && npm ci && npm run build`, output in
`Aureways/WebAppBundle/` (committed; Xcode never needs Node).
