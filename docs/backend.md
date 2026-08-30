# 后端

后端是同进程 Swift 代码，入口 `ACPConnection`（`actor`）。职责：spawn harness、JSON-RPC、实现 Client 被调用的方法。

## 模块

| 文件 | 作用 |
| --- | --- |
| `Harness/Harness.swift` | 基类 `Harness`、`AgentProfile`、`HarnessRegistry`、`HostEnvironment` |
| `Harness/*.swift` | 各家启动命令、可用性、`session/_meta` |
| `Harness/HarnessRuntime.swift` | 一 harness 一 ACP 进程 |
| `JSONRPC.swift` | `JSONValue`、`JSONRPCMessage`（request / notification / response / error） |
| `Models.swift` | ACP 载荷：initialize、session、content、tool call、permission |
| `Connection.swift` | 子进程生命周期与方法路由 |
| `ClientOps.swift` | `FileOps`、`AgentTerminal` / `TerminalHost` |

`AppModel.ensureRuntime` 按 Agent 复用进程：`Harness.makeRuntime()` → launch → initialize → 若 `authMethods` 非空则先 `authenticate` 第一个方法。然后按能力 `session/list`，新对话 `session/new`，打开历史 `session/load`。`ACPConnection` 挂在 `HarnessRuntime` 上，不挂在单条 `ChatSession`。各家差异（参数、环境、`_meta`）写在对应 `Harness` 子类里，不要塞进 `AppModel`。

## 启动 Harness

`ACPLaunch`：`command`、`arguments`、`cwd`、`environment`。

`HostEnvironment.augmented()` 在 GUI 进程的 PATH 前拼接：

- `/opt/homebrew/bin`、`/usr/local/bin`
- `~/.local/bin`、`~/.cargo/bin`、`~/.volta/bin`
- `/usr/bin`、`/bin`

`resolveExecutable` 按 PATH `isExecutableFile` 查找。找不到则 `ACPError.launch("Command not found: …")`，前端 `phase = .failed`。

侧栏绿点 = 启动命令（如 `grok`、`npx`）在 PATH 上，不保证该 harness 已登录或能完成 `initialize`。

Auto-approve 时由当前 `Harness.sessionMeta` / `launchArguments` 决定透传。Grok Build 把参数换成 `["agent", "--always-approve", "stdio"]`，并在 `session/new` 的 `_meta.yoloMode` 里再声明一次。

## JSON-RPC 循环

- 写出：`stdin` 一行一个 message
- 读入：后台队列按 `\n` 切行，经 `AsyncStream` 回到 actor，保证顺序。EOF 时若 buffer 里还有未以换行结束的一行，仍会派发
- Client 发起的调用放进 `pending[id]`，对上 response / error。写失败或 `shutdown` 只会 resume 仍在 `pending` 里的 continuation，避免 double-resume
- Agent 的 notification：目前处理 `session/update`
- Agent 的 request：`perform(method:)` 处理后 `write` response

`shutdown` 终止子进程、取消 pending、关掉 stdin。进程退出码进 stderr 日志。

## Client 能力

`InitializeRequest` 声明：

- `fs.readTextFile` / `fs.writeTextFile`
- `terminal: true`
- `clientInfo`: name `aureways`，title `Aureways`，version `0.1.0`

Agent 回调实现：

| 方法 | 行为 |
| --- | --- |
| `session/request_permission` | 交给 UI；Auto-approve 则选 allow |
| `fs/read_text_file` | 读工作区内路径；支持 `line`（1-based）、`limit` |
| `fs/write_text_file` | 工作区内创建父目录后原子写 |
| `terminal/create` | 再 spawn 一条命令，截断输出字节 |
| `terminal/output` | 返回累计 stdout+stderr |
| `terminal/wait_for_exit` | 等到退出码 |
| `terminal/kill` / `release` | SIGTERM 并可选丢弃 |

终端不是完整 PTY，是 `Process` + Pipe。`fs/*` 限制在已添加的工作区目录之下（当前 `cwd` 以及工作区目录列表里的路径）；终端命令仍按 harness 传入的 `cwd`/`env` 执行。应用未开 App Sandbox。

## 发给 Agent 的方法

| 方法 | 时机 |
| --- | --- |
| `initialize` | 连接后第一条 |
| `session/new` | 新对话 |
| `session/load` | 打开 harness 已有 session；回放历史 |
| `session/list` | 刷新该 Agent 的侧栏缓存 |
| `session/delete` | 从 harness 删除会话 |
| `session/prompt` | 用户发送；`prompt: [{type:text}]` |
| `session/cancel` | 通知，无 id |
| `authenticate` | initialize 若返回 `authMethods`，连接时用第一个 methodId 调用 |

未实现：`session/resume`、WebSocket / HTTP 传输。

## 环境注意

从 Finder / `open *.app` 启动时没有 shell 的 nvm PATH。若 `npx` 只在 `~/.nvm/versions/node/.../bin`，侧栏 Codex / Claude 会灰。把 node 链进 `/opt/homebrew/bin` 或在自定义 agent 里填绝对路径。
