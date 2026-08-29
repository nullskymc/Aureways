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
│  AppModel + ChatSession                                 │
│  会话列表、phase、权限 continuation、UserDefaults       │
└──────────────────────────┬──────────────────────────────┘
                           │ ACPConnection.launch / prompt
┌──────────────────────────▼──────────────────────────────┐
│  ACP 后端（actor）                                      │
│  JSON-RPC NDJSON · FileOps · TerminalHost               │
└──────────────────────────┬──────────────────────────────┘
                           │ stdin / stdout / stderr
┌──────────────────────────▼──────────────────────────────┐
│  Harness 子进程                                         │
│  grok | npx …codex-acp | npx …claude-agent-acp | …    │
└─────────────────────────────────────────────────────────┘
```

前端不直接碰 `Process`。视图只读 `ChatSession` / `AppModel`，写操作走 `startSession`、`send`、`retry`、`cancel`、`resolvePermission`。

## 一次会话

1. 用户点 harness → `AppModel.startSession`
2. `ACPConnection.launch` 解析可执行文件并 `Process.run`
3. Client → Agent：`initialize`（protocolVersion 1，声明 fs + terminal）
4. 若 `authMethods` 非空，先 `authenticate` 第一个 method
5. Client → Agent：`session/new`（`cwd` = 工具栏选中的 workspace；Auto-approve 时带 `_meta.yoloMode`）
6. `ChatSession.phase = .ready`，输入框可用
7. 用户发送 → `session/prompt`；期间 Agent 推 `session/update`，需要时反向调用 `session/request_permission`、`fs/*`、`terminal/*`
8. 用户 ⌘. → `session/cancel` 并取消本地 prompt wait；关闭会话 → `shutdown()` 结束子进程

`SessionPhase`：`.connecting` / `.ready` / `.failed(String)`。未 `.ready` 时 Composer 禁用，避免出现「发了 hello 却 Session is not connected」。

## 传输

ACP stdio：每条 JSON-RPC 消息一行 UTF-8，禁止嵌入换行。stdout 是协议，stderr 当日志进 Inspector。

JSON-RPC `id` 必须按数字解析。`NSNumber` 在 Swift 里可能桥成 `Bool`，`JSONValue` 对 `NSNumber` 先区分 CFBoolean 再当数字，否则 `initialize` 对不上 pending 请求。

## 持久化

| Key | 内容 |
| --- | --- |
| `workspacePath` | 当前工作区绝对路径 |
| `customAgents` | 用户添加的 `AgentProfile` JSON 数组 |

会话 transcript **不落盘**。进程退出即丢失。Harness 自己的 session 存储（例如 `~/.grok/sessions`）与本应用无关。

## 与「前后端分离」的关系

没有独立 backend 仓库、没有 REST。所谓后端是 `Aureways/ACP/` 这一层，随 `.app` 一起分发。前端是 `Views/` + `AurewaysApp.swift`。`AppModel.swift` 两边都用。
