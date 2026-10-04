# 后端

后端是同进程的 Swift。ACP 入口是 `ACPConnection`（`actor`）：拉起 harness、收发 JSON-RPC、实现 Agent 回调的 Client 方法。窗口服务（文件、检查器终端、设置、额度）在 `WebShellServices`、`WebTerminalService`、`QuotaStore`，不进 ACP 连接。

## 模块

| 文件 | 作用 |
| --- | --- |
| `Harness/Harness.swift` | 基类、`AgentProfile`、`HarnessRegistry`、`HostEnvironment` |
| `Harness/*.swift` | 各家启动命令、可用性、`session/_meta`、`normalizeToolCall` |
| `Harness/ToolCallNormalization.swift` | 改写工具 JSON 的共用操作 |
| `Harness/HarnessRuntime.swift` | 一个 harness 一个 ACP 进程 |
| `Harness/HarnessQuota.swift` | 额度快照的形状，以及各家 HTTP / 本地解析 |
| `ACP/JSONRPC.swift` | `JSONValue`、请求 / 通知 / 响应 |
| `ACP/Models.swift` | `initialize` 与能力 |
| `ACP/SessionModels.swift` | `session/new`、`load`、`list`、`prompt` |
| `ACP/UpdateModels.swift` | `session/update`、工具、权限 |
| `ACP/Connection.swift` | 子进程生命周期与方法路由 |
| `ACP/ClientOps.swift` | Agent 调用的 `FileOps` 与 `TerminalHost` |
| `Quota/QuotaStore.swift` | 缓存、限流、与会话解耦 |
| `Quota/QuotaSources.swift` | 每家用哪些源 |
| `WebTerminalService.swift` | 用户终端的 PTY |

`AppModel.ensureRuntime` 按 Agent 复用进程：`Harness.makeRuntime()` → launch → initialize → 若有 `authMethods` 则先 `authenticate`。然后按能力 `session/list`，新对话 `session/new`，打开历史 `session/load`。各家参数写在对应 `Harness` 子类里。

## 启动

`ACPLaunch`：`command`、`arguments`、`cwd`、`environment`。

`HostEnvironment.augmented()` 在 GUI 进程的 PATH 前拼接：

- `/opt/homebrew/bin`、`/usr/local/bin`
- `~/.local/bin`、`~/.bun/bin`、`~/.cargo/bin`、`~/.volta/bin`
- `/usr/bin`、`/bin`

`resolveExecutable` 按 PATH 查找可执行文件。找不到则启动失败，会话 `phase = .failed`。侧栏上的可用状态表示启动命令在 PATH 上，不表示已经登录或 `initialize` 能成功。

从 Finder 打开的 App 没有 shell 里的 nvm PATH。若 `npx` 只在 `~/.nvm/.../bin`，Codex 和 Claude 会显示不可用。把 `node` 链到 `/opt/homebrew/bin`，或在自定义 Agent 里写绝对路径。

自动批准时由 `Harness.launchArguments` 和 `sessionMeta` 决定怎么传。Grok Build 换成 `["agent", "--always-approve", "stdio"]`，并在 `session/new` 的 `_meta.yoloMode` 再声明一次。Oh My Pi 换成 `["acp", "--yolo"]`，Qoder 换成 `["--acp", "--yolo"]`。

## JSON-RPC

- 写出：stdin 一行一条消息。
- 读入：后台按 `\n` 切行，经 `AsyncStream` 回到 actor。EOF 时缓冲区里最后一行没有换行也会派发。
- Client 发出的调用放在 `pending[id]`，对上 response 或 error。
- Agent 的通知目前处理 `session/update`。
- Agent 的请求由 `perform` 处理后写回 response。

`shutdown` 终止子进程、取消 pending、关掉 stdin。

## Agent 能调用的 Client 方法

`initialize` 声明 `fs.readTextFile`、`fs.writeTextFile`、`terminal: true`。`clientInfo` 的 name 是 `aureways`，version 取应用的 marketing version。

| 方法 | 行为 |
| --- | --- |
| `session/request_permission` | 交给页面；自动批准则选 allow |
| `fs/read_text_file` | 读工作区内的路径，支持 `line`（从 1 计）和 `limit` |
| `fs/write_text_file` | 在工作区内创建父目录后原子写 |
| `terminal/create` | 再起一个 `Process`，截断输出。这不是交互终端 |
| `terminal/output` | 累计的 stdout 和 stderr |
| `terminal/wait_for_exit` | 等到退出码 |
| `terminal/kill` / `release` | SIGTERM，可选丢掉缓冲 |

Agent 侧终端的 stdin 是 `/dev/null`。`fs/*` 限制在已添加的工作区之下。应用未开 App Sandbox。

规范之外、带 id 的 agent 请求（Grok 的 `_x.ai/exit_plan_mode`、`_x.ai/ask_user_question`）由 `ACPConnection` 交给 `onExtRequest`，`AgentBridge` 再转给当前 Agent 的 `Harness.handleExtRequest`。页面点完再回包。自动批准不会自动回答选择题。Harness 不认的方法返回 `nil`，客户端回 32601。

## 用户终端

检查器里的终端是另一套。`WebTerminalService` 用 SwiftTerm 的 `LocalProcess` 开真实 PTY，登录 shell，环境是 `HostEnvironment.augmented()`。xterm.js 负责画。输出大约每 8 ms 合并一次，以 base64 发给页面。关掉标签或应用退出就终止进程。它和 ACP 的 `terminal/*` 无关。

## 发给 Agent 的方法

| 方法 | 时机 |
| --- | --- |
| `initialize` | 连接后第一条 |
| `session/new` | 新对话。带工作区、已启用的 MCP、Harness 的 `_meta` |
| `session/load` | 打开已有会话并回放 |
| `session/list` | 刷新侧栏里已有条目的标题 |
| `session/delete` | 从 harness 删除 |
| `session/prompt` | 用户发送。块由 `OutgoingMessage.contentBlocks` 组装 |
| `session/cancel` | 通知，无 id |
| `session/set_config_option` | 输入框上的模型、力度等 |
| `session/set_mode` | 没有 `configOptions` 时的旧退路 |
| `authenticate` | `initialize` 返回了 `authMethods` 时，用第一个 |

未实现：`session/resume`，以及 WebSocket / HTTP 传输。

## 额度

`QuotaStore` 不从 ACP 的 `usage_update` 推算限额。会话用量只作为补充，和账号额度并排显示。

每个源有自己的上次请求时间和退避，写在缓存里，重启仍然有效。默认间隔：自动刷新 5 分钟，手动刷新 30 秒，后台轮询 10 分钟，失败退避从 60 秒起、上限 30 分钟。429 遵守 `Retry-After`。未登录退避 30 分钟，手动刷新仍可在 30 秒后重试，但不能打断服务器给的 429 窗口。

| Agent id | 源（按顺序） |
| --- | --- |
| `grok-build` | `grok.billing` |
| `codex` | `codex.usage-api`，然后 `codex.session-log`（本地 rollout 日志，无网络） |
| `claude` | `claude.oauth-usage`。只读 `~/.claude/.credentials.json`（或 `CLAUDE_CONFIG_DIR`）。不读钥匙串，macOS 上因此经常是未配置 |
| `antigravity` | `antigravity.cloudcode` |

其余内置 Agent 没有额度源。可用 `defaults write ai.aureways.client quotaSourceMap …` 覆盖；空列表表示关掉这一家。

页面上，只有错误、没有用量数字的快照不画严重程度点。支持额度但未登录的 Agent 会说明未登录。

`usageBreakdown` 的每项可带 `pooled`。Grok Chat 和 Grok Build 共用一个额度池：`isUnifiedBillingUser` 为真，或各产品百分比之和与 `creditUsagePercent` 相差不超过 1 时，这些项标为 `pooled`，页面把它们画成同一根条上的分段（各自占了多少），右侧是剩余；不画成各自独立的 100% 条。旧缓存里没有 `pooled` 字段时，页面按同样的「加起来等于总量」规则推断。
