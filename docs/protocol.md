# ACP 协议对照

实现目标是 **ACP v1**（`protocolVersion: 1`）。规范：<https://agentclientprotocol.com>。传输为 [stdio NDJSON](https://agentclientprotocol.com/protocol/v1/transports)。

## Client → Agent

| 方法 | 实现 | 说明 |
| --- | --- | --- |
| `initialize` | 有 | capabilities + clientInfo |
| `session/new` | 有 | `cwd`、空 `mcpServers`；可选 `_meta`（由当前 Harness 提供，Grok 为 `yoloMode`） |
| `session/prompt` | 有 | 仅 text content block |
| `session/cancel` | 有 | notification |
| `authenticate` | 有 | initialize 返回 `authMethods` 时用第一个 method 调用 |
| `session/load` | 有 | Agent 声明 `loadSession` 时；回放 `session/update` |
| `session/list` | 有 | Agent 声明 `sessionCapabilities.list` 时，带 cursor 分页 |
| `session/delete` | 有 | Agent 声明 `sessionCapabilities.delete` 时 |
| `session/set_config_option` | 有 | 按 Agent 在 `session/new`/`load` 声明的 `configOptions` 透传 |
| `session/set_mode` | 有 | 仅当没有 `configOptions` 时作为旧版 mode 退路 |
| `session/resume` | 无 | |

## Agent → Client

| 方法 / 通知 | 实现 | 说明 |
| --- | --- | --- |
| `session/update` | 有 | 见下表 |
| `session/request_permission` | 有 | 弹窗或自动选 allow |
| `fs/read_text_file` | 有 | 限制在会话 `cwd` 下 |
| `fs/write_text_file` | 有 | 限制在会话 `cwd` 下 |
| `terminal/create` | 有 | 非 PTY |
| `terminal/output` | 有 | |
| `terminal/wait_for_exit` | 有 | flatten `exitCode` |
| `terminal/kill` / `release` | 有 | |
| `x.ai/*` | 忽略 | Grok 扩展只记日志 |

## `session/update` 变体

| `sessionUpdate` | UI |
| --- | --- |
| `agent_message_chunk` | Agent 气泡，流式拼接 |
| `agent_thought_chunk` | Thinking 折叠 |
| `user_message_chunk` | 与本地已插入的用户气泡合并，避免重复 |
| `tool_call` / `tool_call_update` | ToolCard，按 `toolCallId` 合并 |
| `plan` | 步骤列表 |
| `available_commands_update` | Composer 上方 `/command` |
| `current_mode_update` | 灰色 status |
| `session_info_update` | 改会话标题 |
| 其它 | 丢弃 |

权限响应形状（规范要求 outcome 再包一层对象）：

```json
{ "outcome": { "outcome": "selected", "optionId": "allow-once" } }
{ "outcome": { "outcome": "cancelled" } }
```

## 生命周期（规范）

```
initialize
session/new
        ┌── session/update (plan / text / tool_call)
session/prompt ─┤
        │       session/request_permission ⇄ 用户
        └── result { stopReason }
session/cancel（可选，打断当前 turn）
```

`stopReason` 常见：`end_turn`、`cancelled`、`max_tokens`、`refusal`。前端以灰色 status 显示。

## 测试覆盖

`AurewaysTests/ProtocolTests.swift`：

- JSON-RPC 编解码（含数字 id 不被当成 Bool）
- `agent_message_chunk` 解析
- permission JSON
- catalog 命令行拆分（引号）
- 内嵌 Python mock：`initialize` → `session/new` → `session/prompt` 收到 `hello from mock`
- mock 在 prompt 中反向 `fs/read_text_file`（`line=2, limit=1`）
- sqlite 会话缓存 insert/replace/delete
- 带 `list`/`load`/`delete` 的 mock：prompt 后 `session/list`、`session/load` 回放、`session/delete`
- `session/new` 的 `configOptions` / `modes` 解码；`config_option_update`

未覆盖真实 Codex / Grok / Claude 二进制。
