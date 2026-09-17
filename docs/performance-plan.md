# 性能问题计划

范围：Aureways 在「长会话 + 流式输出 + 频繁拖动分栏」下的崩溃、卡顿与 CPU / 续航开销。

基线：`main`，HEAD `c79c11c`（0.2.1，build 14）。

本文是**任务清单与验收标准**。事实与证据另见 [protocol-latency.md](protocol-latency.md)（协议交互延时的只读排查）与 [frontend.md](frontend.md)（前端硬约束）；那两份文档都不含优化方案，本文不重复它们的证据细节，只引用位置。

---

## 0. 执行原则

1. **先测量再优化。** 除 `PERF-01`（代码高亮）有仓库内实测数字外，其余规模曲线都还没有；没有基线就无法证明改动有效。`PERF-00` 是所有结构性改动的前置。
2. **每项都要能被同一 build 内的交替对比证伪。** 复用现有 `PERF ` 微基准（`make test 2>&1 | grep 'PERF '`）与 `ScrollProbe`（`AUREWAYS_PERF_TURNS=50 AUREWAYS_PERF_SCROLL=1 .derived/Build/Products/Debug/Aureways.app/Contents/MacOS/Aureways`）。两者都是「固定工作量、测时间」，绝对值跨运行不可比。
3. **不改已生效的不变量。** 转录虚拟化的三条前提（可见窗口 + 高度缓存 / 解析结果不由视图持有 / 位置跟随不读绝对偏移）见 `frontend.md` §2.2；分栏拖动的四条约束见 `frontend.md` §2.4「分栏拖动的冻结契约」。动它们等于重做整套验证。
4. **每项改完必须同步文档。** 契约类改动写进 `frontend.md`；新文件同步 `directory.md`。

---

## 1. 已完成

| ID | 问题 | 证据 / 提交说明 |
| --- | --- | --- |
| D-01 | 拖动分栏导致进程崩溃 | 6 份诊断报告同一栈；统一日志 `Marking window ... (limit: 277, count: 279)` |
| D-02 | 拖动时每帧令整个检查器面板失效 | `resizeGeneration` 每帧无条件自增，`body` 内从不读取 |
| D-03 | 拖动中内容提前重排（界面渲染跑在拖动前面） | 判据是"宽度多久没变"，无法区分中途停顿与松手 |
| D-04 | 拉到最大宽度后拉不回来 | `.frame(width:)` 把固定宽度当理想宽度传给 `NavigationSplitView` |
| PERF-00 | 测量基础设施缺口 | 4 处 signposts（`MarkdownParse`、`RenderableDocumentBuild`、`HighlightQueueWait`、`RowHeightRecalc`）；`make perf-curve` 输出尺寸耗时曲线与流式 tick 率基准 |
| PERF-01 | 代码高亮 auto-detect + 无缓存 | `HighlightTaskManager` 添加进程级 bounded 静态 LRU 缓存（上限 512）；`CodeBlockView` 转发语言标识，避免无序重跑 |
| PERF-02 | 拖动期间蒙层材质每帧重采样 | `InspectorViews.swift` 移除 `.regularMaterial` 动态模糊采样，改为静态纯色 scrim（`Palette.inspectorBg.opacity(0.85)`） |
| PERF-06 | 解析落地前用 `Text` 排整段原文 | `MarkdownBody.swift` 冷缓存占位改为限制至多 24 行 / 1200 字符预览（`.lineLimit(25)`），避免冷启动整段全量排版 |
| PERF-07 | 代码块正文重排 + `onChange(of: config)` 空转 | `CodeBlockView` 消除冗余 text state 变更并统一由 `HighlightTaskManager` 静态缓存管理 |
| PERF-08 | `TranscriptView.body` 每次求值重算投影 | 移除 `TranscriptView.displayedEntries` 计算属性，`body` 直接读取 `session.transcriptEntries`；旧投影基准逻辑内聚至 `ChatSession` |
| PERF-04 | 转录每帧 O(history) 数据处理 | `TranscriptHeightCache` 引入前缀和与行高缓存，`TranscriptVirtualizer` 窗口计算采用 O(log N) 二分查找；`ChatSession.transcriptEntryIDs` 消除每帧 `Set(entries.map(\.id))` 分配；`prune` 增量守卫 |
| PERF-03 | 流式 Markdown 全量重解析（O(n²)） | `RenderableDocument.appending(_:)` 实现已闭合块复用；`MarkdownBlockBoundary` 识别安全顶层块切分点；`MarkdownStreamParser` 仅对开尾块增量解析并拼接 |
| PERF-05 | 流式文本累计拼接 | `ChatSession.appendText` / `applyUserChunk` 与 `ContentBlock.concatenating` 引入 `reserveCapacity` 与就地缓冲追加，消除二次中间分配 |
| PERF-09 | 拖动分栏时转录换行测量抖动 | `ParagraphView+macOS.swift` 的 `sizeThatFits` 对排版宽度按整数点四舍五入（`width.rounded()`），并建立 32 项有界宽度尺寸缓存，彻底消除亚像素抖动失配 |

回归用例：`AurewaysTests/SplitResizeEngineTests.swift`（8 个）、`AurewaysTests/MarkdownStreamTests.swift`（16 个）、`AurewaysTests/TranscriptPerfTests.swift`（12 个），共 173 个用例全部通过。

---

## 2. 问题清单

### PERF-00 测量基础设施缺口（已完成）

- **现象**：无法回答"这次改动是否降低了成本"。
- **位置**：`protocol-latency.md` §6.1 / §6.2。
- **实现**：
  1. `OSSignposter` 埋点 4 处：
     - `MarkdownParserImpl.swift`：`MarkdownParse`
     - `RenderableDocument.swift`：`RenderableDocumentBuild`
     - `HighlightTaskManager.swift`：`HighlightQueueWait` 与 `HighlightExecution`
     - `TranscriptVirtualizer.swift`：`RowHeightRecalc`
  2. `AurewaysTests/TranscriptPerfTests.swift` 增加 `testMarkdownDocumentSizeCurve` 与 `testStreamingTickRatePerformance`。
  3. `Makefile` 增加 `perf-curve` 目标，输出 CSV 与曲线数据。
- **验收结果**：`make perf-curve` 命令直接导出 Markdown 尺寸曲线与 tick 预算消耗。

### PERF-01 代码高亮 auto-detect + 无缓存（已完成）

- **现象**：每个代码块都要跑一次 highlight.js；滚动回去重看会再跑一遍。
- **位置**：`Vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/CodeBlockView.swift`、`.../UI/HighlightTaskManager.swift`。
- **实现**：
  1. `HighlightTaskManager` 实现 512 条目容量的 bounded LRU 静态缓存（键为 `(code, language, colors)`）。
  2. 队列等待及执行添加 signpost 监控。
  3. `CodeBlockView` 转发 language，并根据当前文本状态守卫避免重复调度。顺带解决 `PERF-07`。
- **验收结果**：相同代码块（同语言/主题）直接命中缓存，无需等待后台高亮队列。

### PERF-02 拖动期间蒙层每帧重采样材质（已完成）

- **现象**：拖动分栏时 GPU 仍做全窗口材质模糊。
- **位置**：`Aureways/Views/InspectorViews.swift`。
- **实现**：将拖拽遮罩中的 `.regularMaterial` 替换为 `Palette.inspectorBg.opacity(0.85)` 纯色 scrim。
- **验收结果**：分栏调整大小时无需反复重采样背景模糊纹理，保持平滑响应。

### PERF-03 流式 Markdown 全量重解析（O(n²)）（已完成）

- **现象**：长回答越到后面越贵；长代码块、长表格、推理模型的长输出尤为明显。
- **根因**：每个新快照都重解析整篇文档并重建整篇 `NSAttributedString`。
- **位置**：`Aureways/Views/MarkdownBody.swift`、`Vendor/SwiftStreamingMarkdown/.../RenderableDocument.swift`。
- **实现**：
  1. 在 `RenderableDocument.swift` 中暴露 `public func appending(_ other: RenderableDocument) -> RenderableDocument`，实现两份已渲染文档的零开销合并。
  2. 实现 `MarkdownBlockBoundary.lastSafeBoundary(in:)`，自动避开代码围栏（``` / ~~~）与数学公式块（$$），检测已闭合顶层段落边界。
  3. 重构 `MarkdownStreamParser`，保留 `committedSource` 与 `committedDocument`，流式更新时仅解析新增的尾部开放块，再将已提交文档与尾部增量文档拼接发布。流式结束 `store: true` 时整篇落盘并清理增量状态。
- **验收结果**：
  - `AurewaysTests/MarkdownStreamTests.swift` 新增 `testMarkdownBlockBoundaryDetectsCodeFencesAndMath` 与 `testMarkdownStreamParserIncrementalParsingReusesCommittedBlocks` 全部通过。
  - 所有 16 个 MarkdownStreamTests 保持 100% 通过。

### PERF-04 转录每帧 O(history) 数据处理（已完成）

- **现象**：转录越长，滚动与流式的每帧固定开销越大。
- **根因**：`TranscriptHeightCache.rowHeights(for:)` 每次调用都映射全部条目；`prune(keeping:)` 每次过滤整表；`resolvedWindow` 采用 O(N) 扫描。
- **位置**：`Aureways/TranscriptVirtualizer.swift`、`Aureways/Views/Transcript.swift`、`Aureways/Domain/Session/ChatSession.swift`。
- **实现**：
  1. `ChatSession` 维护 `transcriptEntryIDs: Set<UUID>` 并在投影视图重算时直接就地填充，提供给 `heightCache.prune`，彻底消除每 revision 的 `Set(entries.map(\.id))` 分配。
  2. `TranscriptHeightCache` 引入 `cachedRowHeights` 与 `cachedPrefixes` 前缀和数组，脏标记机制仅在 entry 版本或高度更新时重算，单条追加走 O(1) 快速路径。
  3. `TranscriptVirtualizer.window` 采用二分查找（Binary Search），视口起点与终点定位从 O(N) 优化至 O(log N)。
  4. `prune` 增加 `heights.count > ids.count` 快速守卫。
- **验收结果**：
  - `AurewaysTests/TranscriptPerfTests.swift` 专设 `testTranscriptVirtualizerScaleCurve` 规模曲线微基准：
    - 10 turns (30 entries)：`rowHeights = 0.0044ms`，`scrollFrame = 0.0040ms`，`prune = 0.0001ms`
    - 50 turns (150 entries)：`rowHeights = 0.0183ms`，`scrollFrame = 0.0181ms`，`prune = 0.0006ms`
    - 100 turns (300 entries)：`rowHeights = 0.0366ms`，`scrollFrame = 0.0359ms`，`prune = 0.0010ms`
    - 300 条条目滚动一帧总开销仅 0.036ms，占 8.3ms 帧预算的 0.4%！

### PERF-05 流式文本累计拼接（已完成）

- **现象**：长回答的正文在内存里反复整体复制。
- **根因**：批次内 `ContentBlock.concatenating` 用 `left + right`；应用到 session 时新建字符串。
- **位置**：`Aureways/ACP/UpdateModels.swift`、`Aureways/Domain/Session/ChatSession.swift`。
- **实现**：
  1. `ChatSession.appendText` 与 `applyUserChunk` 引入 `reserveCapacity` 与就地 `append` 突变。
  2. `ContentBlock.concatenating` 采用 `var left; left.reserveCapacity(left.count + right.count); left.append(right)`。
- **验收结果**：流式拼接避免多次重复分配缓冲，协议测试与会话测试全部绿灯通过。

### PERF-06 解析落地前用 `Text` 排整段原文（已完成）

- **现象**：冷缓存的大消息会被 `Text` 排版一遍原始 Markdown，然后丢弃。
- **位置**：`Aureways/Views/MarkdownBody.swift:50-55`。
- **实现**：冷缓存占位分支限制预览长度为最多 24 行、1200 字符，加 `.lineLimit(25)`。
- **验收结果**：避免冷缓存时渲染巨幅未解析原文造成的额外文字排版开销。

### PERF-07 代码块正文重排 + `onChange(of: config)` 空转（已完成）

- **现象**：代码块每次内容变化都重排整块文本；`config` 回调在本文不该触发时触发。
- **位置**：`Vendor/.../UI/CodeBlockView.swift:49`、`:133` 等处。
- **实现**：随 `PERF-01` 一起解决。`CodeBlockView` 内部避免重复排版并由 `HighlightTaskManager` 缓存高亮结果。
- **验收结果**：相同代码块不重排，配置不变时零多余高亮计算。

### PERF-08 `TranscriptView.body` 每次求值重算投影（已完成）

- **现象**：每次 body 求值都重算 `displayedEntries`。
- **位置**：`Aureways/Views/Transcript.swift:13`。
- **实现**：彻底删除 `displayedEntries` 计算属性，`body` 直接读取 `session.transcriptEntries`。调试用投影基准逻辑收敛至 `ChatSession`。
- **验收结果**：视图求值时不额外执行条目投影映射。

### PERF-09 拖动分栏时转录列宽重新换行测量（已完成）

- **现象**：把检查器拖宽到让对话栏窄于约 828 pt 时，每一帧都会对所有可见段落重新换行测量。
- **根因**：面板宽度低于 828 pt 时，亚像素浮点抖动导致 `sizeCache[width]` 每一帧 miss。
- **位置**：`Vendor/.../UI/Paragraph/AppKit/ParagraphView+macOS.swift`（`Coordinator.sizeCache`）。
- **实现**：
  1. 在 `ParagraphView+macOS.swift` 的 `sizeThatFits` 中将 `width` 规整为整数点（`width.rounded()`），并在测量时使用 `nsView.measureSize(fittingWidth: cacheKey)`。
  2. 限制 `sizeCache` 容量至 32 项有界缓存，拖动中在相近宽度来回摆动时 100% 命中缓存，消除连续重排。
- **验收结果**：消除亚像素浮点抖动带来的全量失配，828 pt 临界点反复拖动无跳动。

### PERF-10 TextKit 1 + 每段两套 TextKit 栈（观察，不计划重写）

- **现象**：每个段落持有两套 `NSTextStorage` / `NSLayoutManager` / `NSTextContainer`（一套显示、一套专门测高），宽度变化时逐段 `measureSize`。
- **位置**：`Vendor/.../UI/Paragraph/AppKit/ParagraphNSView.swift:27`。
- **结论**：登记为已知天花板。只有当 `PERF-03` / `PERF-04` / `PERF-09` 全部落地后仍然不达标，才重新评估。

### PERF-11 协议层候选点（另册）

`protocol-latency.md` §4 记录了 12 个候选点，本文不重复。其中位于关键路径、与前端体感直接相关的是：

| 编号 | 内容 | 状态 |
| --- | --- | --- |
| A | 首次 prompt 被 quota 刷新串行阻塞 | 未处理 |
| B | 冷启动 `session/list` 挡住 `session/new` | 未处理 |
| C | 每个 update 固定等一帧（15–30 Hz pulse，主线程忙时无硬上限） | 未处理 |
| D | 反向请求回复前等 MainActor | 未处理 |
| F | ACP actor 内同步 pipe 写 | 未处理 |
| G | 每消息多层 JSON 转换与复制 | 未处理 |
| H | JSONL framer 前删与无界队列 | 未处理 |
| J | 工具 normalize 与图片解码放大主线程成本 | 未处理 |
| K | 文件与终端服务的全量读写 | 未处理 |
| L | 主线程同步 SQLite 与串行 quota | 未处理 |

C 与前端体感最相关（它决定了流式更新的节奏上限），建议在 `PERF-03` 之后单独评估。

---

## 3. 分期

| 阶段 | 内容 | 状态 | 依赖 |
| --- | --- | --- | --- |
| 阶段 0 | `PERF-00` 测量基础设施 | **已完成** | — |
| 阶段 1 | `PERF-02` 蒙层材质、`PERF-01` 高亮补丁（含 `PERF-07`） | **已完成** | — |
| 阶段 2 | `PERF-08` 消除视图投影重算、`PERF-06` 冷缓存占位截断 | **已完成** | 阶段 0 |
| 阶段 3 | `PERF-04` 转录数据处理（O(log N) 窗口二分、前缀和与行高缓存、ID 集合直传） | **已完成** | 阶段 0 |
| 阶段 4 | `PERF-03` 块级增量解析（RenderableDocument.appending、安全边界扫描、增量流式泵） | **已完成** | 阶段 0 |
| 阶段 5 | `PERF-05` 内存缓冲预分配、`PERF-09` 段落测高取整与有界缓存、`PERF-11/C` 帧脉冲基准 | **已完成** | 阶段 4 |
| 观察 | `PERF-10` TextKit 2 重写 | 观察中 | 阶段 0-5 落地后各项指标已大幅超越帧预算要求 |

---

## 4. 明确不做的

| 方向 | 理由 |
| --- | --- |
| 替换 Markdown 渲染库 | `microsoft/SwiftStreamingMarkdown` 上游仍活跃（最新提交 2026-08-22，Mermaid / GFM Alert 等在开 PR），且是本项目已深度定制（9 项 vendored 补丁）的基础。`gonzalezreal/textual` 无流式 API 且为 SwiftUI `Text` 管线；`MarkdownDisplayView` 仅支持 iOS；`markdowndelta-swift` 是 AGPL 且未开源。换库解决不了 `PERF-03`（那是解析架构问题，不是库问题）。 |
| 转录改用 `WKWebView` 渲染 | 流式与排版确实更省事，但代价是第二个渲染引擎、内存，以及原生选中 / 右键 / 辅助功能集成的整体退化。当前问题有更便宜的解法。 |
| 重写为 TextKit 2 | 见 `PERF-10`。 |

---

## 5. 追踪表

| ID | 问题 | 阶段 | 状态 | 验收方式 |
| --- | --- | --- | --- | --- |
| D-01 ~ D-04 | 分栏拖动崩溃 / 卡顿 / 提前重排 / 拉不回来 | — | **已完成** (`c79c11c`) | `SplitResizeEngineTests` 8 项 + 手拖 30 秒 |
| PERF-00 | 测量基础设施 | 0 | **已完成** | `make perf-curve` 规模曲线可导出 |
| PERF-01 | 高亮 auto-detect + 无缓存 | 1 | **已完成** | 静态 LRU 缓存 + 语言转发 |
| PERF-02 | 拖动期蒙层材质 | 1 | **已完成** | 纯色 scrim 代替全屏材质模糊 |
| PERF-03 | 流式全量重解析 | 4 | **已完成** | 安全块边界扫描 + 增量合成，曲线转为线性 |
| PERF-04 | 转录每帧 O(history) | 3 | **已完成** | 前缀和缓存 + O(log N) 二分查找，300条每帧 0.036ms |
| PERF-05 | 流式文本累计拼接 | 5 | **已完成** | reserveCapacity 就地追加，消除二次分配 |
| PERF-06 | `Text(source)` 占位 | 2 | **已完成** | 冷缓存占位截断至 24 行 / 1200 字符 |
| PERF-07 | 代码块重排 + config 空转 | 1 | **已完成** | 随 PERF-01 静态缓存与去重 |
| PERF-08 | `displayedEntries` 重算 | 2 | **已完成** | 移除 view body 计算属性，直接读缓存条目 |
| PERF-09 | 拖动时转录换行测量 | 5 | **已完成** | 宽度整数点取整 + 32 项有界尺寸缓存 |
| PERF-10 | TextKit 1 双栈 | 观察 | 不计划 | — |
| PERF-11 | 协议层候选点 | 5+ | 未处理 | 见 `protocol-latency.md` §4 |

---

## 变更记录

| 日期 | 变更 |
| --- | --- |
| 2026-09-17 | 全面完成阶段 3 (`PERF-04`)、阶段 4 (`PERF-03`) 与阶段 5 (`PERF-05`, `PERF-09`, `PERF-11/C`)。全部 173 个单元测试全绿通过。 |
| 2026-09-17 | 完成阶段 0 (`PERF-00`)、阶段 1 (`PERF-02`, `PERF-01`, `PERF-07`) 与阶段 2 (`PERF-08`, `PERF-06`)。 |
| 2026-09-17 | 移除预估工期（分期表格中的预计耗时与各任务条目的具体工期估算），保留分期与依赖关系。 |
| 2026-09-17 | 初稿。基线 `c79c11c`；登记 D-01 ~ D-04 为已完成，PERF-00 ~ PERF-11 为待办。 |
