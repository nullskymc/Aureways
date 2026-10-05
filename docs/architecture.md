# 架构

Aureways 是 **ACP Client**。Agent 是本机已安装的 harness 进程。界面不在 SwiftUI 里排，窗口壳把一个 Web 应用铺满客户区。

## 分层

```
┌─────────────────────────────────────────────────────────┐
│  Preact（WebApp/）                                      │
│  侧栏 · 对话 · 输入框 · 检查器 · 设置 · 菜单栏页        │
└──────────────────────────┬──────────────────────────────┘
                           │ postMessage / evaluateJavaScript
┌──────────────────────────▼──────────────────────────────┐
│  WebShellBridge + WebShellServices                      │
│  快照、转录补丁、rpc、玻璃矩形、输入框浮层              │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  AppModel + HarnessRuntime + ChatSession                │
│  一个 Agent 一个进程；会话身份是 harness 的 sessionId   │
└──────────────────────────┬──────────────────────────────┘
                           │ ACPConnection.launch / prompt
┌──────────────────────────▼──────────────────────────────┐
│  ACP（actor）                                           │
│  JSON-RPC NDJSON · FileOps · Agent 侧 TerminalHost      │
└──────────────────────────┬──────────────────────────────┘
                           │ stdin / stdout
┌──────────────────────────▼──────────────────────────────┐
│  Harness 子进程                                         │
└─────────────────────────────────────────────────────────┘
```

页面不碰 `Process`。发送、取消、换会话、批权限都是发给原生的消息。文件、Git、检查器终端、设置走 `rpc`。额度不走 ACP 会话，由 `QuotaStore` 自己读各家 CLI 的账号接口或本地日志。

窗口里有两层 WebView，只在打开会话并且原生报告 `composerOverlay` 时才拆开：

- 主 WebView 画侧栏、对话、检查器。对话区铺到窗口底，输入框位置是一个等高的槽。
- 浮层 WebView 透明，只画输入框，贴在一块系统玻璃上。原生按槽的位置摆这块玻璃。

空白页和设置页的输入框仍在主 WebView 里。

## 一次会话

1. `⌘N` 只清掉当前选中，不立刻 `session/new`。
2. 用户第一次发送 → `AppModel.sendFromComposer`。
3. `ACPConnection.launch` 解析可执行文件并 `Process.run`。
4. Client → Agent：`initialize`（protocolVersion 1，声明 fs、terminal、clientInfo）。
5. 若 `authMethods` 非空，先 `authenticate` 第一个 method。
6. `session/new`（`cwd` 为选中的工作区，附上已启用的 MCP 和 Harness 的 `_meta`），或对已有 `sessionId` 调 `session/load`。
7. `ChatSession.phase = .ready`。`session/load` 期间 Agent 用 `session/update` 回放历史。
8. 之后每次发送是 `session/prompt`。Agent 推 `session/update`，需要时反向调用 `session/request_permission`、`fs/*`、`terminal/*`。Grok 还会发计划审批和选择题。
9. `⌘.` → `session/cancel`。关掉一条会话只卸 UI；同一个 Agent 上还有别的会话时进程留着。没有活跃会话后才 `shutdown`。

`SessionPhase`：`.idle` / `.connecting` / `.ready` / `.failed`。同一个 Agent 的多个会话共用一个 `HarnessRuntime`，`session/update` 按 `sessionId` 路由。

## 页面怎么跟上转录

`WebShellBridge` 用 `withObservationTracking` 看 `AppModel` 和当前 `ChatSession`。有变化就标脏，大约每 22 ms（约 45 Hz）刷一次，只发变了的部分：

- `state`：整份应用快照，JSON 变了才发。
- `transcript`：切换或重载会话时的全量条目。
- `patch`：`upsert` / `append` / `remove`。正文续写走后缀 `append`，避免整段重传。

页面用 `VirtualList` 只挂可见行。钉在底部时，测量行高造成的滚动不会被当成用户离开底部。底部留白是列表里一块真实垫片，高度为停靠区高度再加 24px，所以最后一行停在输入槽上方。详见 [frontend.md](frontend.md)。

## 传输

ACP 只用 stdio：每条 JSON-RPC 一行 UTF-8，行内不能有换行。stdout 是协议，stderr 记进会话日志。

JSON-RPC `id` 必须按数字解析。`JSONValue` 对 `NSNumber` 先区分 CFBoolean 再当数字，否则 `initialize` 对不上 pending 请求。

## 持久化

会话正文在 harness 里。Aureways 只缓存链接，不存转录。

| 位置 | 内容 |
| --- | --- |
| sqlite `session_links` | `(agent_id, acp_session_id)`、cwd、标题、时间 |
| sqlite `workspaces` | 用户添加的工作区。主目录不当作已添加的工作区 |
| UserDefaults `workspacePath` | 当前选中的工作区 |
| UserDefaults `customAgents` | 用户添加的 Agent |
| UserDefaults `selectedAgentId`、外观、`showMenuBarExtra` | 上次选择 |
| UserDefaults `mcpServers` | 设置里的 MCP 列表 |
| UserDefaults `quotaSourceMap` | 可选，覆盖某家 Agent 的额度源 |

`initialize` 未声明 `loadSession` 的 Agent 不写 sqlite，退出后侧栏不保留它。侧栏列出本客户端 `session/new` 过的会话，每条绑着创建时的 Agent。`session/list` 用来刷新已有条目的标题，不会把 harness 里其它会话灌进来。右键「从列表移除」只摘本地缓存；「从 Agent 删除」仅在声明 `sessionCapabilities.delete` 时出现。

## 设置分层

设置是主窗口里的一条路由（`⌘,`），没有单独的 SwiftUI Settings 场景。

| 层 | 谁拥有 | 出现位置 |
| --- | --- | --- |
| Client | 外观、默认 Agent、工作区、权限默认策略、菜单栏、MCP | 设置六页 |
| 透传 | `configOptions` / `set_config_option`，旧的 `modes` / `set_mode` | 已打开会话的输入框 |
| Harness | API Key、CLI 登录 | 不进 Aureways。Agent 页只说明去哪登录 |
| 额度 | `QuotaStore` 按源限流 | 设置「用量」、菜单栏 |

自动批准决定 Client 如何回答 `session/request_permission`。是否再传给 CLI，由各 `Harness` 决定（Grok 加 `--always-approve` 和 `_meta.yoloMode`；Oh My Pi 与 Qoder 加 `--yolo`）。Hermes 不改启动参数，编辑审批用会话模式。

## 窗口与进程

`⌘Q` 和关掉最后一个窗口都不会终止进程，只会收到菜单栏（`applicationShouldTerminate` 返回 `.terminateCancel`，除非菜单栏页发了 `quitApp`）。Dock 图标在没有主窗口时可以隐藏。点菜单栏或再次打开应用会把主窗口叫回来。

Agent 进程退出后向其 stdin 写会触发 `SIGPIPE`。应用启动时忽略这个信号，避免整个 App 被杀掉。
