# Web shell

主窗口是一层原生壳。里面画出来的侧栏、主区域标签、输入框、权限卡、设置，都是 `WebApp/` 这一个 Preact 应用。SwiftUI 只保留 `App`、窗口场景、菜单栏场景和菜单命令。

以前用 `NavigationSplitView` 时，跨屏幕拖窗口会在 `SplitViewChildController` 里把约束更新打满并崩溃。窗口里不再做 SwiftUI 分栏。客户区是一个 `NSView`（`WebShellHostView`），子视图只有玻璃层、WebView 和标题栏拖拽条，尺寸用 frame 和 autoresizing，不向 SwiftUI 回传最小/最大尺寸。`WebShellHostView.isFlipped = true`（y 向下）。

## 谁负责什么

| 原生壳 | Web 应用 |
| --- | --- |
| 窗口样式、红绿灯位置、全尺寸内容 | 侧栏：工作区、会话、搜索、新对话 |
| `NSGlassEffectView`。页面把对应区域做成透明 | 顶栏、对话与文件标签、设置 |
| 标题栏拖拽条。WKWebView 不支持 `-webkit-app-region`，页面上报不可拖的矩形 | 对话列表、Markdown、工具行、思考、计划 |
| 菜单命令转发成 `command` | 输入框：发送/停止、模型与模式、附件、`/` 与 `@` |
| `NSMenu`、`NSOpenPanel`、粘贴板、用系统打开链接 | 权限卡、计划卡、选择题、错误条 |
| ACP、会话、额度、PTY、通知 | 不保存业务真相，只保留折叠、滚动、栏宽这类 UI 状态 |

菜单栏额外窗口加载同一份包，地址是 `#menubar`，固定 340×470。它看额度和最近会话，可以新建对话、打开主窗口、打开设置、退出进程。

## 玻璃与输入框浮层

`glass.ts` 测量 `[data-glass]` 的矩形，有变化才 `post('glass')`。原生在同样的位置放 `NSGlassEffectView`。种类：

| `data-glass` | 作用 |
| --- | --- |
| `sidebar` | 侧栏玻璃，四周收 8px，圆角 16 |
| `control` | 胶囊控件，圆角为高度的一半 |
| `composer` | 主页面里的输入卡（空白页） |
| `slot` | 不铺玻璃。告诉浮层输入卡该坐在哪，并带上栏的左右内边距和 `max-width`（768） |

打开会话且 `chrome.composerOverlay` 为真时，主页面用 `.composer-slot` 占住卡片高度，真正的输入框在第二个透明 WKWebView 里（`ComposerOverlay`）。这块 WebView 底对齐槽的底边，盖在玻璃上，这样对话滚到玻璃下面时能透出系统材质。

浮层把卡片高度报成 `composerLayout`。原生再发 `command: composerHeight`，字段 `h` 是卡片高，`total` 是卡片加弹出层的高度。主页面用 `h` 撑开槽，用 `total` 把「回到底部」按钮抬到弹出层之上。

系统玻璃不够用时（例如没有对应的 AppKit 材质），`chrome.glass` 为假，输入框留在主页面里，不再拆浮层。

## 资源与通道

页面从 app 包里经 `aureways-web://app/` 加载（`WebAssetScheme`）。JS → Swift：`window.webkit.messageHandlers.aureways.postMessage`。Swift → JS：`evaluateJavaScript` 调用 `window.__aw.receive`。

没有这个 message handler 时（浏览器里打开构建产物），`demo.ts` 灌一份演示状态。

## Swift → JS

```jsonc
{ "type": "state", "state": AppState }
{ "type": "transcript", "sessionId": "…", "items": [Item] }
{ "type": "patch", "sessionId": "…", "ops": [
    { "op": "upsert", "index": 12, "item": Item },
    { "op": "append", "id": "…", "delta": "more tokens" },
    { "op": "remove", "id": "…" } ] }
{ "type": "command", "name": "find" | "toggleSidebar" | "focusComposer" | "newChat"
    | "toggleInspector" | "showFiles" | "showChanges" | "newTerminal" | "splitRight"
    | "openMarkdown" | "openReader" | "openSettings" | "openFiles" | "composerHeight" | "escape" }
{ "type": "rpcResult", "id": 7, "result": "…" }
{ "type": "termData", "id": "…", "data": "<base64>" }
{ "type": "termExit", "id": "…", "code": 0 }
{ "type": "fileChanged", "path": "…" }
{ "type": "menuResult", "token": 3, "id": "model:gpt-5" }
```

`AppState` 含会话、工作区、选中的 Agent、各 Agent 是否在 PATH 上、输入框配置、待处理的权限 / 计划 / 选择题、错误、窗口度量（红绿灯、标题栏高度、`glass`、`composerOverlay`）、额度快照、设置。

`Item` 种类：`user`、`agent`、`thought`、`tool`、`plan`、`status`。思考、工具、计划带 `run` 起止，用来显示耗时。

## JS → Swift

`ready`、`send`、`cancel`、`newSession`、`selectSession`、`closeSession`、`retry`、`selectAgent`、`setConfig`、`setMode`、`permission`、`planApproval`、`question`、`attach`、`attachPaths`、`removeAttachment`、`openLink`、`openPath`、`copy`、`selectWorkspace`、`addWorkspace`、`revealWorkspace`、`openSettings`、`menu`、`dragRegions`、`sessionMenu`、`glass`、`composerLayout`、`dismissError`、`uiPrefs`。

菜单栏页另外发送 `menuBarOpened`、`openApp`、`quitApp`。

终端字节不走 rpc：`term.input`、`term.resize`、`term.close`。

## rpc

JS 发 `{type:"rpc", id, method, params}`，Swift 回 `rpcResult`。

| 方法 | 作用 |
| --- | --- |
| `fs.list` / `fs.read` / `fs.write` / `fs.search` | 工作区文件。写入核对 mtime，冲突则拒绝 |
| `git.diff` | 检查器「变更」 |
| `term.open` | 开一条 PTY，返回 id |
| `ui.confirm` | 原生确认框 |
| `pick.markdown` / `pick.folder` / `pick.executable` | 系统面板 |
| `settings.refresh` / `settings.set` / `settings.markdownDefault` | 设置 |
| `agent.enable` / `agent.remove` / `agent.add` / `agent.copyLaunch` | Agent 目录 |
| `quota.refresh` | 手动刷新额度（仍受每源最短间隔限制） |
| `workspace.remove` / `workspace.select` | 工作区 |
| `mcp.add` / `mcp.enable` / `mcp.remove` | MCP 列表。真正传给 Agent 发生在下一次 `session/new` 或 `session/load` |

## 构建页面

```bash
make web    # 锁文件变化时 npm ci，然后 npm run build
```

`npm run build` 是 `tsc --noEmit && vite build`。产物在 `Aureways/WebAppBundle/`，作为文件夹引用打进 `Aureways.app/Contents/Resources/WebAppBundle`。这个目录不入库。`make build`、`make open`、`make test`、`make release` 会先编它。

浏览器里看演示：在 `WebApp/` 执行 `npm run dev`。演示数据不会连上真的 Agent。
