# 一次发送要经过哪里

0.1.9 那次针对 SwiftUI 转录的延时排查已经作废：那些视图、解析缓存和滚动探针都不在仓库里。下面是现在这条链路。没有新的计时数字。

```
输入框 Return
  → post('send')
  → WebShellBridge → AppModel.sendFromComposer（主线程）
  → HarnessRuntime.ensureStarted / ACPConnection.prompt
  → harness stdin 上的一行 session/prompt
  → harness stdout 上的 session/update
  → ChatSession
  → WebShellBridge 至多约 45 Hz 的 patch
  → VirtualList 更新可见行
```

能在本仓库里看到的最远边界，是写进 adapter 的 stdin，以及从 stdout 读回的 update。`npx` 拉起的适配器、各家 CLI、以及模型服务都不在这里。DNS、排队和首 token 只能当成一段黑盒时间。

ACP 只有 stdio NDJSON。设置里的 MCP 可以是 HTTP 或 SSE，那是交给 harness 的服务器配置，不是这条 prompt 通道。额度请求使用 `URLSession`，和 prompt 无关。

提交发生在主线程上：组内容块、把用户消息放进转录、写 sqlite 里的会话链接。冷启动还要 `Process.run` 和 `initialize`。一个 Agent 配置共用一个 `HarnessRuntime`，并发的第一次发送会并到同一次启动上。

页面侧，已经在底部时跟随新行；不在底部时不把视口拽下去。行高是量出来的，不是估算的。
