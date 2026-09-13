# 协议交互延时排查

对「Aureways ↔ harness 协议交互延时」的一次只读排查记录。基线为 `main`，HEAD `7993449`（0.1.9），工作区无改动。本文只记录事实与证据，不含优化方案。

## 1. 范围与观测边界

链路形态：

```
SwiftUI / AppModel（MainActor）
  → ACPConnection actor
  → 本地 harness 子进程 stdin/stdout（NDJSON JSON-RPC）
  → session/update
  → 帧级合并队列（SessionUpdateInbox + DisplayPulse）
  → ChatSession
  → SwiftUI transcript
  → 流式 Markdown
```

ACP 只实现 stdio NDJSON，没有 WebSocket/HTTP（`docs/backend.md:83`）。HTTP/SSE 只是传给 harness 的 MCP server 配置（`Aureways/ACP/SessionModels.swift:69-96`）；仓库里的直接 `URLSession` 请求属于 quota 探测，不是 prompt 传输。

仓库能观测到的最深边界是写入 adapter stdin 与从 adapter stdout 收到 update。Claude Code 的入口是 `npx -y @agentclientprotocol/claude-agent-acp`（`Aureways/Harness/ClaudeCode.swift:3-16`），该 npm 包、Claude CLI、Anthropic API 请求与服务端流式协议都不在仓库内。因此 DNS/TLS、服务端排队、模型推理首 token 无法在本仓库继续下钻，只能作为黑盒整体时间。

## 2. 端到端调用链

### 2.1 提交

- `Aureways/Views/Composer.swift:541-549`：`submit()` 先清空输入框和附件，再调 `model.sendFromComposer(...)`。
- `Aureways/AppModel+Sessions.swift:29-59`：构造 `OutgoingMessage`；已就绪会话先 `appendUser`、同步持久化，再 `enqueuePrompt`；空白页创建 `ChatSession` 后走 reconnect/cold-start。
- `Aureways/AppModel.swift:5-7`、`Aureways/Domain/Session/ChatSession.swift:82-84`：`AppModel` 与 `ChatSession` 都是 MainActor 状态，所以提交阶段的附件转换、transcript projection、SQLite 调用都可能占用主线程。

### 2.2 冷启动与握手

一个 Agent profile 复用一个 `HarnessRuntime`（`Aureways/Harness/HarnessRuntime.swift:3-18`），`ensureStarted()` 用 `startTask` 合并并发启动（同文件 `:24-56`）。实际顺序：

```
ensureRuntime
  → HarnessRuntime.ensureStarted
  → HarnessRuntime.launch
  → ACPConnection.launch（Process.run）
  → initialize
  → 可选 session/list
  → session/new 或 session/load
  → 可选 auth_required → authenticate → 重试
  → quota refresh
  → session/prompt
```

关键位置：`Aureways/Harness/HarnessRuntime.swift:79-106`（串行 handshake）、`Aureways/ACP/Connection.swift:39-64`（`Process` + 三条 `Pipe` + 同步 `process.run()`）、`Aureways/Harness/HarnessRuntime.swift:108-123`（只发一个 `initialize`）、`Aureways/ACP/Models.swift:79-89`（client 声明 fs/terminal/session config 能力）、`Aureways/AppModel+Runtime.swift:6-31`（新会话 `ensureRuntime → prepareWorkspaces → session/new`）。

握手没有真正的 timeout。`requestStall` 默认 8 秒（`Aureways/ACP/Connection.swift:22-24`）只显示「仍在等待」，不中断请求（`:467-499`），覆盖 `initialize`、`authenticate`、`session/new`、`session/load`、`session/list`（`:493-499`），**`session/prompt` 被明确排除**。`ACPError.timeout` 在 `Aureways/ACP/Models.swift:12` 定义，`Aureways/` 下没有调用点。

### 2.3 写 harness

```
PromptRequest → JSONEncoder → JSONValue → JSONRPCMessage
  → JSONSerialization → String + "\n" → Data → FileHandle.write(stdin)
```

`Aureways/ACP/JSONRPC.swift:69-71`、`Aureways/ACP/JSONRPC.swift:182-212`、`Aureways/ACP/JSONRPC.swift:215-225`、`Aureways/ACP/Connection.swift:253-262`。`FileHandle.write` 在 `ACPConnection` actor 内同步执行；`pending[id]` + continuation 支持多个未完成 JSON-RPC（`Aureways/ACP/Connection.swift:33-35`、`:451-465`）。

### 2.4 读回

`Aureways/ACP/Connection.swift:264-304`：全局 `userInitiated` 阻塞读 `availableData`，按换行拆 NDJSON，经无显式上限的 `AsyncStream<String>` 回到 actor；`:306-328` 每行完整 parse；`Aureways/ACP/JSONRPC.swift:158-180` 区分 request/notification/response/error；`Aureways/ACP/Connection.swift:330-349` 规范化并解码 `session/update`；`Aureways/ACP/UpdateModels.swift:160-232` 解析各类 update；`Aureways/Harness/Harness.swift:72-90` 做各 harness 的工具调用兼容修正。

### 2.5 到 UI

`onUpdate` 不直接切 MainActor，只写锁保护 inbox 并投一个 main queue closure（`Aureways/AppModel+Runtime.swift:334-343`），然后 `armSessionUpdatePump()` 启动 DisplayPulse（`:455-475`），每 tick `flushSessionUpdates()`（`:489-516`）。`DisplayPulse` 的 `preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)`（`:543-558`），拿不到屏幕时退回 30Hz `Timer`。

每帧：`take()` → `SessionUpdateInbox.coalesced()` 合并相邻同 agent 且 `merging` 成功的 update（`Aureways/AppModel+Runtime.swift:518-531`、`Aureways/ACP/UpdateModels.swift:252-290`）→ `applyUpdate` → `ChatSession.apply` → `transcriptRevision++`。

## 3. 按阶段拆分延时

### 3.1 握手（首次发送 → session ready）

1. 可执行文件解析与 `Process.run`（`Aureways/ACP/Connection.swift:39-64`）。
2. 外部 harness/npx 启动（Claude Code 为 `npx -y`，未 pin 版本，冷缓存时 npm 解析/下载在子进程内，仓库无法测）。
3. `initialize` RPC（`Aureways/Harness/HarnessRuntime.swift:108-123`）。
4. 冷连接上的 `session/list`（`Aureways/AppModel+Runtime.swift:242-245`）。
5. `session/new` 或 `session/load`（`Aureways/AppModel+Runtime.swift:15-28`、`:52-66`）。
6. 必要时 auth-required → authenticate → 重试（`Aureways/Harness/HarnessRuntime.swift:127-147`）。

因为 8 秒只是告警阈值，卡死的 initialize/new/load/list 延时在客户端侧无上限。

### 3.2 首个内容（提交 → 第一段 agent 内容可见）

暖连接：MainActor 上的附件/base64/用户消息 projection/SQLite → `liveConnection` actor hop → `contentBlocks` 与 JSON 编码 → stdin 写入 → 外部 harness/CLI/模型网络 → stdout 等到完整换行 → JSON parse 与 harness normalization → inbox + 主队列调度 + 下一次 pulse tick → `ChatSession.apply` 与 SwiftUI 布局 → 首次 plain-text fallback 或 Markdown document。

冷连接还要叠加 3.1 的全部阶段，以及下方的 quota 等待。

### 3.3 流式事件

Agent stdout flush 粒度、`AsyncStream` 排队、完整 JSON parse、15–30Hz 合并、MainActor projection、Markdown latest-wins parse、SwiftUI 下一次布局/绘制。文本 chunk 只合并相邻同类 update；thought/tool/user/agent 交错会拆成多次 apply。

### 3.4 反向工具调用（agent → client）

`session/request_permission`、`fs/*`、`terminal/*` 走 `handleRequest`（`Aureways/ACP/Connection.swift:351-366`）：先 `await handlers.onLog(...)`，再 `perform`，再写 response。`fs/read_text_file`、`fs/write_text_file` 在 `perform` 返回前还会 `await handlers.onFileOp?`（`:383-398`）。`onLog` 与 `onFileOp` 都切到 MainActor（`Aureways/AppModel+Runtime.swift:387-392`）。`terminal/create` 在回复前有「收到请求」「准备启动」「已启动」多个串行日志 hop（`Aureways/ACP/Connection.swift:351-365`、`:399-410`）。`initialize` 甚至在请求写入子进程前先等一条 MainActor 日志（`:87-97`）。

`terminal/wait_for_exit` 用 continuation，没有客户端轮询（`Aureways/ACP/ClientOps.swift:103-149`、`:214-220`）。

### 3.5 UI 呈现（传输结束后仍在）

transcript projection 重建、全量 row-height 数组与窗口重算、Markdown parse、文本 fade/word animation、code highlight、`scrollTo(bottom)` 与布局。

## 4. 候选点（按证据强弱）

### 4.1 确定存在，且位于关键路径

**A. 首次 prompt 被 quota 刷新串行阻塞。** `connectNew` 在 `session.phase = .ready` 之后 `await quotaService.refreshQuota(...)`（`Aureways/AppModel+Runtime.swift:28-30`），而 `enqueuePrompt` 要等 `connectNew/openExisting` 返回才调 `prompt`（`:129-149`）。quota 与 ACP prompt 无关。只影响支持 quota 的 agent：`supportsQuota` 返回 true 的是 antigravity、codex、grok（`Aureways/Harness/HarnessQuota.swift:222-228`），**Claude Code 不在其中**。超时上限：`timeoutIntervalForRequest = 4.0`、`timeoutIntervalForResource = 8.0`（`:180-181`），另有 `request.timeoutInterval = 8.0`（`:605`、`:631`）与 `4.0`（`:858`、`:993`）。已有 60 秒 TTL 与 per-agent in-flight gate（`:1077-1118`），但 cache miss 时仍被 await。注意 `cacheTTL` 的注释把「打开菜单栏窗口」列为 force，而 `Aureways/Views/StatusMenu.swift:297-300` 实际传默认 `false`，注释与 9d794d3 之后的代码不一致。

**B. 冷启动 `session/list` 挡住 `session/new`。** `ensureRuntime` 在返回前 `await pullList(from:)`（`Aureways/AppModel+Runtime.swift:233-247`），`pullList` 只刷新本客户端已有条目的 title 与 MCP 信息（`:189-209`），`listSessions` 最多串行 20 页（`Aureways/ACP/Connection.swift:146-159`）。若 list 首次返回 auth-required，会形成 list 失败 → authenticate → list 重试 → session/new。

**C. 每个 update 固定等一帧。** 15–30Hz 的 pulse（`Aureways/AppModel+Runtime.swift:534-558`）：通常增加 0–33ms，display link 取 minimum 15Hz 时约 67ms；主线程忙时无硬上限。另外**每个原始 update 都会投一个 main queue closure**（`:338-342`），即使 pulse 已在运行，closure 仍会排队（`armSessionUpdatePump` 最后 no-op）。最终 response 到达时会主动 flush（`:161-174`），permission 前也会 flush（`:344-350`），尾事件不额外等帧。

**D. 反向请求回复前等 MainActor。** 见 3.4。流式 update 已通过 inbox 与 MainActor 解耦，日志与 file-op 路径没有。

**E. 长 transcript 每帧全量重建。** 普通 text/thought 更新走 `rebuildTranscriptProjection()`（`Aureways/Domain/Session/ChatSession.swift:357-362`）：`TranscriptBlock.group(items, ...)` 遍历全部 raw items（`Aureways/Domain/Session/TranscriptBlock.swift:60-130`），随后 `Set(blocks.map(\.id))`、按 id 过滤 `transcriptEntryVersions`、`Dictionary(uniqueKeysWithValues:)` 重建 entries、`rebuildToolIndex()`（`Aureways/Domain/Session/ChatSession.swift:236-260`）。视图侧 `resolvedWindow` / `applyWindow` 每次 `heightCache.rowHeights(for: entries)` 映射全部条目并构建完整 prefix 数组线性扫描（`Aureways/Views/Transcript.swift:27`、`:143-161`、`Aureways/TranscriptVirtualizer.swift:37-42`、`:99-136`），`transcriptRevision` 变化时还 `heightCache.prune(keeping: Set(entries.map(\.id)))`（`Aureways/Views/Transcript.swift:97-105`）。

工具更新已有定点范式：`updateProjectedTool` 只改对应 entry 并 bump version，不重建（`Aureways/Domain/Session/ChatSession.swift:439-460`）；普通流式文本没有对应路径。虚拟化避免了离屏 Markdown 布局，但没有避免这些 O(history) 的数据处理。

历史 replay 更敏感：`session/load` 会快速灌入大量交错 update，`flushSessionUpdates()` 对合并后每个 event 逐个 `session.apply`（`Aureways/AppModel+Runtime.swift:466-475`），若一个 tick 内很多事件无法相互合并，会在 transcript 增长时反复完整 group。

### 4.2 确定存在，负载相关

**F. ACP actor 内同步 pipe 写。** `write` 声明 `async` 但内部无 suspension point，`FileHandle.write(contentsOf:)` 同步执行（`Aureways/ACP/Connection.swift:253-262`）。子进程不读 stdin 或单行很大时可阻塞，阻塞期间 actor 无法处理其他写，其他 response/cancel/notification 排队，并占住 cooperative executor 线程。相关负载上限：单张内联图片 10 MiB（`Aureways/ComposerAttachment.swift:4-7`），文本附件 256 KiB 以内同步读取并内嵌（`:264-279`）。普通文本 prompt 不太可能由此主导。

**G. 每消息多层 JSON 转换与复制。** 出站：`Encodable` → `JSONEncoder` Data → `JSONSerialization` → `JSONValue` → `[String: Any]` → `JSONSerialization` Data → String → 加换行 → Data → pipe（`Aureways/ACP/JSONRPC.swift:69-71`、`:93-119`、`:182-218`、`Aureways/ACP/Connection.swift:257-261`）。`JSONEncoder.acp` 开了 `.sortedKeys`（`Aureways/ACP/JSONRPC.swift:220-229`），但随后立刻解析成字典、最终由另一轮 `JSONSerialization` 输出。入站：Data framing → String → `dispatch` 再 trim 成新 String → parser 转回 Data → `JSONSerialization` + 递归 `JSONValue`（`Aureways/ACP/Connection.swift:278-282`、`:306-310`、`Aureways/ACP/JSONRPC.swift:109-119`、`:158-180`）；typed response 又把 `JSONValue` 序列化回 Data 交给 `JSONDecoder`，等于第二轮遍历（`Aureways/ACP/Connection.swift:96-97`、`:125-127`、`:141-154`、`:166-170`）。

**H. JSONL framer 前删与无界队列。** 每个 stdout/stderr 一个全局 GCD block 循环阻塞读（`Aureways/ACP/Connection.swift:80-84`、`:264-293`），每取一行从头扫 newline、`subdata` 复制、`removeSubrange` 从 front 删除、Data 转 String（`:277-282`）。单次 `availableData` 返回大量小行时，反复前删可能趋向二次搬移。`AsyncStream.makeStream()` 无 buffering limit 与 producer backpressure（`:265-286`），快速 harness + 慢消费时在流内无界增长；每个活跃 runtime 长期占两个阻塞 GCD worker。

**I. 流式文本累计拼接。** 批次内 `ContentBlock.concatenating` 用 `left + right`（`Aureways/ACP/UpdateModels.swift:20-23`、`:252-267`），应用到 session 时再 `existing + text`（`Aureways/Domain/Session/ChatSession.swift:596-613`）。帧合并把频率限到 ~30 次/秒，但长回答仍可能呈累计复制特征。

**J. 工具 normalize 与图片解码放大 actor/main-thread 成本。** 工具通知在 ACP actor 上做多层 COW 重写（`Aureways/Harness/Harness.swift:72-90`、`Aureways/Harness/ToolCallNormalization.swift:23-28`、`:232-286`、`:344-358`）。入站图片在 MainActor 上同步 base64 解码并构造 `NSImage`（`Aureways/ComposerAttachment.swift:50-85`，触发点 `Aureways/Domain/Session/ChatSession.swift:616-676`），入站图片没有与出站相同的硬尺寸门槛。

**K. 文件与终端服务。** `FileOps.readText` 总是先读完整文件，同时有 `line` 和 `limit` 时 split/join 两次（`Aureways/ACP/ClientOps.swift:17-29`），没有 agent-read 文件大小上限。终端环形缓冲超限后每个 chunk 复制整个 suffix（`:109-132`），每次 `terminal/output` 在锁内把累计 Data 全量转 String（`:199-211`）。

**L. 主线程同步 SQLite 与串行 quota。** 标题变化在 update batch 中同步持久化（`Aureways/AppModel+Runtime.swift:402-408`、`:211-223`），`SessionStore` 用 `NSLock` 包同步 SQLite（`Aureways/Domain/Session/SessionStore.swift:51-74`、`:121-139`、`:205-209`）。配额没有周期轮询（事件触发 + 60s 窗口 + per-agent single-flight，`Aureways/Harness/HarnessQuota.swift:1077-1118`），但 `refreshAll` 串行 await 各 provider（`:1121-1125`）；回合结束的 force refresh 已在独立 Task 中（`Aureways/AppModel+Runtime.swift:160-168`）。

### 4.3 只是推测，需要测量

- 并发 client request 的 wire 顺序：`request` 先登记 pending 再创建非结构化 Task 写消息（`Aureways/ACP/Connection.swift:228-246`），写入由 actor 串行不会字节交错，但多个并发 request 或 request 后立即 cancel 的发送顺序依赖调度，没有显式 FIFO writer queue。未观察到失败。
- framer 反复前删是否已成为二次复杂度热点——取决于 `availableData` 实际返回的 chunk 大小与 Foundation Data 的优化。
- `String +` 是否产生显著累计 allocations——Swift runtime 可能对部分情形有优化。
- `Process.run()` 是否造成可见主线程停顿——调用点在 MainActor 路径（`Aureways/Harness/HarnessRuntime.swift:79-105`），但通常只做 spawn。

### 4.4 仓库文档中已有的实测

代码高亮：约 20 行 Swift block，自动探测中位数 16.6 ms、明确语言 3.2 ms；50 块自动探测约 518 ms（`docs/frontend.md:65`、`docs/upstream-highlight-cache.patch:15-24`）。当前 `CodeBlockView` 每次 `onAppear` 重跑高亮、不传 fenced language、`HighlightTaskManager` 无跨 view cache（`Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/CodeBlockView.swift:29-33`、`:146-150`、`.../UI/HighlightTaskManager.swift:9-47`）。

## 5. 已有且应保留的机制

1. 一 harness 一进程复用（`Aureways/Harness/HarnessRuntime.swift:4-18`）。
2. 并发启动去重 `startTask`（同文件 `:24-56`）。
3. 延迟认证：只有实际 auth-required 才多走 authenticate（同文件 `:125-147`）。
4. 帧级事件合并（`Aureways/AppModel+Runtime.swift:489-531`）。
5. response/permission 前主动 flush（`:161-174`、`:344-350`）。
6. 工具卡局部 projection 更新（`Aureways/Domain/Session/ChatSession.swift:439-460`）。
7. 可见窗口 + 高度缓存（`Aureways/Views/Transcript.swift:27-66`、`Aureways/TranscriptVirtualizer.swift:27-49`）。
8. Markdown latest-snapshot-wins 单通道解析（`Aureways/Views/MarkdownBody.swift:108-201`）。
9. 最终文档缓存与后台预热，按 source bytes 限 8 MiB（`Aureways/MarkdownDocumentCache.swift:22-35`、`:57-105`、`:125-135`）。
10. 段落后缀增量 append，不替换整份 TextKit storage（`Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/Paragraph/AppKit/ParagraphNSView.swift:121-159`）。
11. quota 60 秒 TTL 与并发刷新抑制（`Aureways/Harness/HarnessQuota.swift:1083-1118`）。
12. 事件驱动 terminal 完成（`Aureways/ACP/ClientOps.swift:103-149`）。

## 6. 测量现状与缺口

### 6.1 已有

- 握手卡顿诊断：8 秒后显示 pending 请求的 JSON-RPC（`Aureways/ACP/Connection.swift:467-499`、`Aureways/AppModel+Runtime.swift:396-398`、`:423-433`、`Aureways/Domain/Session/ChatSession.swift:185-217`、`Aureways/Views/TranscriptBlocks.swift:49-71`）。测试见 `AurewaysTests/ProtocolTests.swift:652-687`、`:689-716`、`:578-593`。
- Wire 日志：initialize payload/result（`Aureways/ACP/Connection.swift:87-97`）、每个 agent→client request（`:351-366`）、非法 stdout 行前 180 字符（`:306-327`）、进程退出与 pending 方法（`:436-448`）。日志保留最近 400 行（`Aureways/Domain/Session/ChatSession.swift:688-692`）。日志面板已从 UI 移除（`docs/development.md:110-115`、`docs/frontend.md:76-84`）。
- Transcript 微基准：`AurewaysTests/TranscriptPerfTests.swift:3-8` 明确是打印数字的 measurement 而非断言；`group()` 10/50/100 turns × 200 次（`:15-29`），block equality（`:31-42`），计时用 `DispatchTime.now().uptimeNanoseconds`（`:166-175`）。Debug `-Onone`（`Aureways.xcodeproj/project.pbxproj:567-582`），无 XCTest metrics/baseline/CI gate。
- 固定 fixture：`Aureways/PerfFixture.swift:36-48` 每 turn 固定 7 个 raw item（`:54-67`），`AUREWAYS_PERF_NOCODE=1`、`AUREWAYS_PERF_LEGACY=1`、`AUREWAYS_PERF_TURNS`（`:131-167`、`Aureways/AppModel.swift:224-241`）。
- 滚动探针：`Aureways/ScrollProbe.swift:5-21` 采用「固定工作量、测时间」，600 步 × 55pt、6 秒 warm-up（`:26-31`），每步同步强制 layout/display/CATransaction flush（`:79-106`），输出 mean/median/p95/p99/max/CPU/RSS 与运行前中后三段（`:184-232`），仅 Debug 启动（`Aureways/AurewaysApp.swift:36-41`）。

ScrollProbe 的已知局限（来自代码与文档）：`AUREWAYS_PERF_LEGACY` 只替换 transcript projection，两组仍共享当前 windowed view、Markdown cache 与绝大多数 UI；`toolUpdate` 的 output 随 `step + 1` 增长（`Aureways/PerfFixture.swift:81-91`），前中后三段同时混入 payload 增长；它测的是同步强制 layout/display 成本，不是 frame time（`docs/frontend.md:56-65`）。

### 6.2 缺口

- 没有 `os_signpost`/`OSLog`/MetricKit/`XCTest.measure`/`XCTClockMetric`。ACP 请求不保存开始时间、RTT、字节数、首字节、首个 update、首次可见文本或整轮时长。
- `ActivityRun` 的秒数（`Aureways/Domain/Session/ChatSession.swift:487-499`、`Aureways/Views/TranscriptBlocks.swift:365-370`）不包含 submit → 首个 activity，使用 wall clock，分辨率 1 秒，不是协议延时。
- 协议层无 benchmark：encode/decode、line framing、request RTT、session load、prompt、反向调用服务时间均未测。
- 无 TTFT 定义。ACP 层能可靠定义的只是首个非空 `agent_message_chunk`；provider 的真实 token 边界不可见。
- 无 prompt stall/timeout 诊断；无队列延时（stdout 收到 → inbox push → pulse → apply → layout）计时。
- 无 session/load 规模曲线（现有回放 fixture 很小，`AurewaysTests/ProtocolTests.swift:1154-1201`）。
- 无并发/乱序 RPC 测试；无 partial-read/大行吞吐测试（只测了 EOF 前无换行，`:629-650`）；无 cancel 与迟到 response 的竞态测试。
- quota 测试只覆盖 snapshot 管理（`AurewaysTests/HarnessQuotaTests.swift:231-251`），未验证 60 秒 TTL、force、并发去重、实际 fetch 次数；`lastFetchTimes` 在 fetch 返回后无论成败都更新（`Aureways/Harness/HarnessQuota.swift:1113-1118`），失败也会被抑制 60 秒。
- 文档明确未覆盖真实 Codex/Grok/Claude 二进制（`docs/protocol.md:99-115`）。

## 7. 帧、flush 与顺序语义

ACP stdio 规范要求每条 JSON-RPC message 用 `\n` 分隔，message 内不能含真实 newline，stdout 只输出 ACP message，stderr 可输出 UTF-8 日志（`docs/protocol.md:1-4`，实现 `Aureways/ACP/JSONRPC.swift:182-211`）。规范未规定 flush 时机，也未明确允许 EOF 前最后一条无尾换行消息。当前行为：正常只在读到 `\n` 时派发，EOF 时兼容派发残余 buffer（`Aureways/ACP/Connection.swift:269-285`，测试 `AurewaysTests/ProtocolTests.swift:629-650`）。因此 harness 若写完整 JSON 但既不写换行也不关 stdout，客户端会一直等，8 秒后只显示诊断。mock harness 每行后 `sys.stdout.flush()`（`AurewaysTests/ProtocolTests.swift:1493-1505`、`:1565-1577`）。出站是直接 pipe `FileHandle.write`，没有用户态缓冲需要额外 synchronize。

stdout 顺序由单 reader + 单 actor dispatch 保持。agent 发来的 request 会拆成独立 Task（`Aureways/ACP/Connection.swift:306-324`），使慢 permission 或 `terminal/wait_for_exit` 能在 actor suspension 时与其他消息交错，不会完全堵死 receive loop。

## 8. 相关提交

| 提交 | 可证实的变更区域 |
|---|---|
| `a91883c`（2026-09-12） | handshake stalled JSON-RPC；`Connection.swift`、`JSONRPC.swift`、`Models.swift`、runtime、ChatSession、TranscriptBlocks、ProtocolTests |
| `9d794d3`（2026-09-10） | quota/session/menu refresh 走 60 秒 cache gate；回合结束保留 force refresh |
| `812871b`（2026-09-09） | transcript visible-window virtualizer、height cache、scroll probe 更新 |
| `4a8f790`（2026-09-09） | streaming transcript work 有界化、增量 projection、single-flight markdown、perf counters |
| `3993d78`（2026-09-09） | authentication 改为收到 `auth_required` 后才执行 |
| `f65a925`（2026-09-08） | streaming LaTeX 避免每 token 重建、vendored Markdown 修复与测试 |
| `c4b818a`（2026-09-05） | 首批 transcript fixture、scroll probe、Markdown cache、微基准 |

## 9. 文档与代码不一致处

- `docs/architecture.md:33-38`、`docs/backend.md:18,81` 仍写「initialize 宣告 authMethods 后立即 authenticate」，实际是按需认证（`Aureways/Harness/HarnessRuntime.swift:119-147`）。
- `Aureways/Harness/HarnessQuota.swift:1083` 注释称打开菜单栏窗口属于 force，`Aureways/Views/StatusMenu.swift:297-300` 实际传 `false`。
- `docs/development.md:124-130` 称测试 target 不使用 `.app` 作为 TEST_HOST，工程实际设置了 `BUNDLE_LOADER` 与 `TEST_HOST`（`Aureways.xcodeproj/project.pbxproj:662-692`）。
- `Aureways/PerfFixture.swift:42` 注释称 50 turns 生成「350 items / 300 blocks」，按当前 grouping 每 turn 通常是 user + activity + agent 三块，注释已过时，应以 probe 实际输出为准。

## 10. 本次排查未做的事

未修改或创建任何仓库源码、测试或配置；未运行测试或应用；未执行任何写操作。所有结论来自对 `main`(7993449) 的只读代码阅读与仓库内已有文档。
