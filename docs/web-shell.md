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
{ "type": "command", "name": "find" | "toggleSidebar" | "focusComposer" | "newChat" | "toggleInspector"
    | "showFiles" | "showChanges" | "newTerminal" | "openMarkdown" | "openSettings" | "openFiles" (paths) }
{ "type": "rpcResult", "id": 7, "result": … } | { "type": "rpcResult", "id": 7, "error": "…" }
{ "type": "termData", "id": "…", "data": "<base64>" } | { "type": "termExit", "id": "…", "code": 0 }
{ "type": "fileChanged", "path": "…" }                      // agent wrote a file
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

### Request/response (`rpc`)

JS posts `{type: "rpc", id, method, params}`; Swift answers with `rpcResult`.
Methods (`WebShellServices.swift`, `WebShellSettings.swift`): `fs.list`, `fs.read`,
`fs.write` (mtime conflict check), `fs.search` (workspace file index), `git.diff`,
`term.open`, `ui.confirm`, `pick.markdown` / `pick.folder` / `pick.executable`,
`settings.refresh` / `settings.set` / `settings.markdownDefault`,
`agent.enable` / `agent.remove` / `agent.add` / `agent.copyLaunch`, `quota.refresh`,
`workspace.remove` / `workspace.select`, `mcp.add` / `mcp.enable` / `mcp.remove`.
Terminal input goes as plain messages: `term.input`, `term.resize`, `term.close`.

## Migration plan

1. Web shell is the window content. ✅
2. Inspector (file browser, editor, terminal tabs, diff review) in the web app;
   terminals are xterm.js fed by headless SwiftTerm PTYs
   (`WebTerminalService.swift`), files/git through the `rpc` channel
   (`WebShellServices.swift`). ✅
3. Settings is a web route (⌘, → `openSettings`); the SwiftUI `Settings`
   scene is gone. The menu bar extra hosts the same bundle at `#menubar`. ✅
4. Legacy SwiftUI views (`RootView`/`NavigationSplitView`, native transcript,
   `SwiftStreamingMarkdown`, the `useLegacyNativeUI` flag) are deleted. ✅

## Building the web app

`make web` → `cd WebApp && npm ci && npm run build`, output in
`Aureways/WebAppBundle/` (committed; Xcode never needs Node).
