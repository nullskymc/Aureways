# 架构

Aureways 是 **ACP Client**，不是 Agent。Agent 是本机已安装的 harness 进程。

## 分层

```
┌─────────────────────────────────────────────────────────┐
│  SwiftUI Views                                          │
│  Sidebar / SessionStatusBar / Transcript / Composer     │
└──────────────────────────┬──────────────────────────────┘
                           │ @Environment(AppModel)
┌──────────────────────────▼──────────────────────────────┐
│  AppModel + HarnessRuntime + ChatSession                │
│  一 Agent 一进程；会话身份是 harness 的 sessionId       │
└──────────────────────────┬──────────────────────────────┘
                           │ ACPConnection.launch / list / load / prompt
┌──────────────────────────▼──────────────────────────────┐
│  ACP 后端（actor）                                      │
│  JSON-RPC NDJSON · FileOps · TerminalHost               │
└──────────────────────────┬──────────────────────────────┘
                           │ stdin / stdout / stderr
┌──────────────────────────▼──────────────────────────────┐
│  Harness 子进程                                         │
│  grok | npx …codex-acp | agy --acp | …                │
└─────────────────────────────────────────────────────────┘
```

前端不直接碰 `Process`。视图只读 `ChatSession` / `AppModel`，写操作走 `startNewSession`、`sendFromComposer`、`retry`、`cancel`、`resolvePermission`。

## 一次会话

1. 用户第一次发送 → `AppModel.sendFromComposer`（⌘N 只清空选中，不立刻 `session/new`）
2. `ACPConnection.launch` 解析可执行文件并 `Process.run`
3. Client → Agent：`initialize`（protocolVersion 1，声明 fs + terminal）
4. 若 `authMethods` 非空，先 `authenticate` 第一个 method
5. Client → Agent：`session/new`（`cwd` = 工具栏选中的 workspace；`_meta` 由当前 Harness 提供），或对已有 `sessionId` 调 `session/load`
6. `ChatSession.phase = .ready`，输入框可用。`session/load` 期间 Agent 用 `session/update` 回放历史
7. 用户发送 → `session/prompt`；期间 Agent 推 `session/update`，需要时反向调用 `session/request_permission`、`fs/*`、`terminal/*`
8. 用户 ⌘. → `session/cancel` 并取消本地 prompt wait。关闭会话只卸 UI，同一 Agent 上其它会话仍占用该进程；没有活跃会话后才 `shutdown`

### Agentic 输入框

Composer 底层是 `ComposerTextView`（NSTextView wrapper，模板取自文件编辑器）：`paste:` 拦截剪贴板、注册 `.fileURL/.tiff/.png` 接收拖拽、`doCommandBy` 上报 Return/↑↓/Tab/Esc 给 `ComposerCard` 的补全状态机与提交。附件模型两段式：`ComposerAttachment`（含 NSImage 缩略图，Composer 侧）→ `TranscriptAttachment`（值类型，进 transcript 渲染）。发送时 `OutgoingMessage.contentBlocks()` 组装 ACP 内容块：文本 → `text`，粘贴/拖入的图片（≤10MB，超限 JPEG 重压后仍超则拒绝）→ base64 `image`，文件与 @ 引用 → `resource_link`（agent 自己读）。能力门控读握手后的 `promptCapabilities.image`：明确 `false` 时图片附件加警示角标并禁发，未知照发。`/` 与 `@` 补全弹层挂在卡片 `overlay` 上方，不参与布局（开合不抖动 transcript）；工作区文件索引 `WorkspaceFileIndex` 后台 BFS 扫描（深度 6 / 4000 条封顶，排除 `node_modules` 等重目录）。

`SessionPhase`：`.idle` / `.connecting` / `.ready` / `.failed(String)`。未 `.ready` 时 Composer 禁用（`.idle` / `.failed` 发送会先 load 或重连）。同一 Agent 的多个会话共用一个 `HarnessRuntime` 进程，`session/update` 按 `sessionId` 路由。

## 传输

ACP stdio：每条 JSON-RPC 消息一行 UTF-8，禁止嵌入换行。stdout 是协议，stderr 当日志记录进会话 `logs`（面板暂不展示）。

JSON-RPC `id` 必须按数字解析。`NSNumber` 在 Swift 里可能桥成 `Bool`，`JSONValue` 对 `NSNumber` 先区分 CFBoolean 再当数字，否则 `initialize` 对不上 pending 请求。

## 持久化

会话本体在 harness。Aureways 只缓存该 Agent `session/list`（以及本连接 `session/new`）返回的元数据，不存 transcript。

| 位置 | 内容 |
| --- | --- |
| UserDefaults `workspacePath` | 当前选中的工作区绝对路径 |
| sqlite `workspaces` | 用户添加的工作区目录（不含 `$HOME`；主目录只当未选工作区时的临时 cwd） |
| UserDefaults `customAgents` | 用户添加的 `AgentProfile` JSON 数组 |
| UserDefaults `selectedAgentId` / 外观 | 上次 Agent、浅色/深色、Liquid Glass |
| `~/Library/Application Support/ai.aureways.client/aureways.sqlite` | `session_links`：`(agent_id, acp_session_id)`、cwd、title、时间戳 |

`initialize` 未声明 `loadSession` 的 Agent 不写 sqlite，退出后侧栏不保留。侧栏列出**本客户端 `session/new` 过的全部会话**（不按当前选中 harness 过滤）；每条会话绑定创建时的 Agent。`session/list` 只用来刷新已有条目的标题，不会把 harness 里其它会话灌进来。空白画布上选择的 harness / 工作区只作用于下一条新对话。打开历史走 `session/load`。右键「从列表移除」只摘本地缓存；「从 Agent 删除」仅在声明 `sessionCapabilities.delete` 时出现。

## 设置分层

| 层 | 谁拥有 | 出现位置 |
| --- | --- | --- |
| Client | 外观、默认 harness、工作区列表、权限默认策略 | Preferences 四页 |
| 透传 | `configOptions` / `set_config_option`，旧 `modes` / `set_mode` | 已打开会话的 Composer 与检查器「信息」 |
| Harness | API Key、CLI 登录、家目录配置 | 不进 Aureways；Agent 页只说明 |

Auto-approve 是 Client 如何回答 `session/request_permission`。是否再透传到 CLI，由各 `Harness` 子类决定（Grok 会加 `--always-approve` 与 `_meta.yoloMode`）。

## 与「前后端分离」的关系

没有独立 backend 仓库、没有 REST。所谓后端是 `Aureways/ACP/` 这一层，随 `.app` 一起分发。前端是 `Views/` + `AurewaysApp.swift`。`AppModel.swift` 两边都用。
