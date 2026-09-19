# 前端架构与 UI 设计

技术栈：SwiftUI，macOS 26+，基于原生 macOS 统一工具栏（`.windowToolbarStyle(.unified)`）与自适应色彩系统（`NSColor(dynamicProvider:)`）。

## 1. 窗口布局架构

基于现代化三栏式布局（类似 Codex / Linear / Xcode），由 `SidebarView`、`MainWorkspaceView` 与可折叠的 `InspectorPaneView` 组成：

```
┌──────────────┬──────────────────────────────────────────┬──────────────────┐
│ Sidebar      │ 统一工具栏：📁 工作区 · 会话状态 · 搜索     │ Inspector (⌘B)   │
│              ├──────────────────────────────────────────┤ 统一标签条 (+ 菜单)│
│ • 新对话 (⌘N)│ 主对话画布 (流式阅读流，maxWidth: 780pt)  │ • 文件（常驻树）  │
│ • Agent 中心 │ • 用户气泡 (右对齐圆角气泡)              │ • 文本文件标签    │
│ • 工作区目录 │ • 思考过程 (折叠微光引用块)              │ • 交互终端标签    │
│              │ • Agent 消息 (自然 Markdown 文本流)      │ • 信息标签        │
│ 项目与会话:  │ • 工具调用卡片 (ToolCard / PlanCard)     │                  │
│ 📁 Workspace ├──────────────────────────────────────────┤                  │
│   ● 会话 ⌘1  │ 悬浮 Liquid Glass Composer (居中 780pt)  │                  │
│              │ 📁 状态胶囊 · 多行输入 · + 菜单 · Agent选择│                  │
│ ⚙️ 个人设置  │                                          │                  │
└──────────────┴──────────────────────────────────────────┴──────────────────┘
```

---

## 2. 界面核心模块

### 2.1 侧边栏 (SidebarView)
- **品牌菜单**：添加工作区、在 Finder 打开、偏好设置。
- **新对话 (`⌘N`)**：进入空白画布。
- **工作区树**：工作区与其下会话合为一棵树。点文件夹设为新对话默认 `cwd`；点会话则打开该对话，并把检查器绑到该会话的 `cwd`（文件树、终端、已打开文件）。箭头展开/收起会话；`+` 添加工作区。行内标明会话绑定的 Agent。状态灯：绿=已连接，灰=已断开，金=连接中，红=失败。快捷键 `⌘1` ~ `⌘9`。
- **Agent 与插件**：只在 **偏好设置（`⌘,`）** 里管理，不在侧栏重复入口。
- **底栏**：用户名 + 齿轮直达偏好设置。

### 2.2 主对话流与空白态 (TranscriptView & EmptyWorkspaceLanding)
- **居中黄金排版**：对话流与空白页均约束在 **`maxWidth: 780pt` 居中文本容器** 内，消除宽屏状态下横向撑满的空旷感。
- **消息卡片轻量化**：
  - **用户消息**：右侧对齐的现代连续曲率气泡（`cornerRadius: 16`），自适应包裹文字。
  - **Agent 回答**：无外层多余实底方框，左侧搭配 `sparkles` 微光头像，右侧由 [SwiftStreamingMarkdown](https://github.com/microsoft/SwiftStreamingMarkdown) 渲染标题、列表、围栏代码和表格。
  - **思考过程**：默认折叠成一行「思考」。
  - **工具调用**：连续工具收成一组「使用了 N 个工具」；完成后默认收起，点开才是短文件名列表。展开区按 `ToolCallView.cardLayout` 分流：命令（`$` + cwd + 输出）、编辑（diff）、读取（路径 + 内容）、搜索（模式 + 结果）、抓取（URL + 内容）、其它（截断 rawInput）。权限卡复用同一套 `ToolCallDetail`。
  - **计划**：一行摘要 + 可展开步骤。
- **空白落地页 (`EmptyWorkspaceLanding`)**：A 轨道平面标志（浅色蓝标 / 深色白标，`BrandMark`）叠在 Orbit Blue 液态漫射光斑上，居中引导用户输入。Dock 用的分层 squircle 图标不进这块画布。

#### 转录的渲染与虚拟化

长会话滚动的成本必须与**可见内容**成正比，不能与转录总长度成正比。这一节的每条约束都是为此存在的，改动前请先读。

- **可见窗口 + 高度缓存，不要 eager `VStack`，也不要依赖 `LazyVStack` 的内部估算。** 屏幕内外各用一段 spacer（高度来自 `TranscriptHeightCache`），中间只放真正的行。工作台 Markdown 预览用 `LazyVStack`，且只有当前标签才挂预览。曾经一律 `LazyVStack`：解析高度为 0 时进会话空白；卡片展开时未放置行的估算塌掉，视口被拽回底部，于是退回 eager——单步滚动从 90 块 2.25 ms 涨到 300 块 23.02 ms。窗口化同时修这两头。展开状态放在 `TranscriptChromeState` 里，不跟视图走，回收上屏高度才能对得上。拖检查器分栏的行为见 §2.4「分栏拖动的冻结契约」。
- **解析结果由 `MarkdownDocumentCache` 持有，不由视图持有。** `MarkdownBody` 用 `DocumentView`（渲染已解析文档）而不是 `MarkdownView`（视图内自己解析），并在 `init` 里同步查缓存，所以块一放上去就有真实高度——上面那条虚拟化的前提就靠这个成立。会话打开和每回合结束时后台预热（300 条约 54 ms）。
- **流式 parse 单通道。** token 到达只记下最新快照；同一时刻只跑一次 cmark。取消的 `.task(id:)` 不会把过期文档写回视图。公式已经闭合后，vendored 库按 payload 比较 inline attachment、块公式跳过 `setLatex:`，段落只 append 后缀——已画出的 `MTMathUILabel` 不会被拆掉重建。未闭合围栏从开行切分：已闭合前缀复用，开着的 fence 合成 `.codeBlock`，不把整段 fence 再送进 cmark。
- **流式正文不得重扫 raw items。** agent / thought / user 续写只改 `transcriptEntries.last` 并 bump version（与工具的 `updateProjectedTool` 同一条局部路径）。新块或活动卡结构变化才 `TranscriptBlock.group()`。`transcriptRevision` 仍递增，高度索引对「最后一行 version +1」走 O(1) 快路径。
- **位置跟随不读绝对偏移。** 用 `ScrollPosition` + `scrollTo(edge: .bottom)`，判据是 `onScrollTargetVisibilityChange` 报告的「最后一块是否可见」。`contentOffset` 只用来算可见窗口；拿它当「是否在底部」的阈值会随估算漂移（Apple 在 WWDC26 "Dive into lazy stacks and scrolling with SwiftUI" 里点名的反模式）。底部留白用 `.safeAreaPadding`，这样 `scrollTo(edge:)` 认安全区、最后一条消息停在输入卡上方。
- **写 `@State` 前先比较。** 滚动相关的回调每秒触发多次，无条件写状态会让 `TranscriptView.body` 跟着重算。高度写入 `TranscriptHeightCache`（非 Observable），只有窗口范围真的变了才写 `rowWindow`。
- **超长文本先在字符串层面截断再交给 `Text`。** `lineLimit` 只限制显示行数，`Text` 仍会把整个字符串排版；工具的输入 / 输出动辄是整个文件（见 `ToolViews.swift` 的 `clamped`）。
- **回归测量。** `AurewaysTests/TranscriptPerfTests.swift` 是微基准（`make test 2>&1 | grep 'PERF '`）；`ScrollProbe` + `PerfFixture` 提供固定转录下的滚动探针，两者都只编进 Debug：

  ```
  AUREWAYS_PERF_TURNS=50 AUREWAYS_PERF_SCROLL=1 \
    .derived/Build/Products/Debug/Aureways.app/Contents/MacOS/Aureways
  ```

  探针是「固定工作量、测时间」：走固定步数，每步强制同步布局与绘制并计时。不要改回按定时器测帧间隔——窗口被遮挡或失焦时绘制会被节流，慢的配置反而测出来快。绝对值运行间可差数倍，只信同一 build 内交替跑出来的对比。

- **已知未解决**：库的 `CodeBlockView` 每次 `onAppear` 都重跑一次 highlight.js，无缓存，且丢掉围栏的语言标签走全语言自动探测（16.6 ms/块，传语言只需 3.2 ms）。只改颜色不改块高，所以不造成布局抖动，代价是 CPU 与续航。补丁见 `docs/upstream-highlight-cache.patch`；库已 vendored 在 `Vendor/SwiftStreamingMarkdown`，这块还没合进去。

### 2.3 悬浮输入卡片 (ComposerCard)
- **居中悬浮卡片 (`maxWidth: 780pt`)**：自然悬浮于主画布下方。
- **超长粘贴不进输入框。** 超过 2000 个 UTF-16 单位的文本不会写入 `NSTextView`，也不交给测量用的隐藏 `Text`（`lineLimit` 挡不住整段排版，见 §2.2）。粘贴内容落到当前工作区 `{cwd}/.aureways/pastes/paste-*.txt`，输入卡只显示字数占位；点卡片在右侧检查器打开同一套文件编辑器（`⌘S` 保存，脏标记与外部冲突处理照旧）。卡片只用于渲染。发送前若该标签未保存，先把检查器草稿刷盘，再把原文作为 `text` content block 发出，不是 `resource` / `resource_link`。回显或重放超长 `user_message_chunk` 时仍显示卡片，不把正文灌进用户气泡。超过 2MB 拒绝粘贴。`.aureways` 不进文件树与 `@` 索引。
- **环境状态胶囊**：显示当前项目名称、本地环境标签及实时 Git 分支名（自动过滤非 Git 目录的重复标签）。
- **指令与操作整合**：
  - 移除原先横跨屏幕的 20+ 指令胶囊栏。`+` 菜单提供添加文件、添加工作区，以及当前会话的 Slash Commands（如 `/help`、`/review`）；输入框里打 `/` 仍走补全。
  - 支持 `需我确认 / 帮我批准` 快速权限切换胶囊。
  - 权限请求在输入卡上方出确认卡：选项纵向整行展示、全文换行；空的 `{}` 参数不占一行。Grok 的计划审批（`x.ai/exit_plan_mode`）和选择题（`x.ai/ask_user_question`）占用同一位置，优先级：权限 > 计划 > 选择题。
  - 右侧提供一键切换 ACP Harness（Grok、Codex、Claude Code 等）的下拉菜单。

### 2.4 工作台面板 (InspectorPaneView)
快捷键 `⌘B` / `⌥⌘I` 展开/折叠。窗口工具栏是系统分段选择器（`PaneTabBar`）：文件浏览器、每个打开的文本文件、每个终端各占一段。右键某一段弹出菜单关闭该标签（文件还有「关闭其它」「在 Finder 中显示」）；文件浏览器常驻不能关。标签条尾部 `+` 是选择菜单：新建终端、文件浏览器、会话信息、在 Finder 中显示工作区。切换标签只是隐藏视图，终端输出与编辑器文本不丢。

1. **文件浏览器（常驻）**：跟着**当前会话的 `cwd`**（没有打开会话时才用侧栏选中的工作区）。点左侧文件夹只设定「下一条新对话」的默认路径，不会把正在看的会话的文件树拽走。打开的文件 / 终端标签按会话记住，切换会话时换回那一套。点击文件即在编辑器标签打开；Agent 写文件后自动刷新。
2. **文本文件标签**：NSTextView 编辑器（等宽字体 + 行号栏），脏标记 ●、`⌘S` 保存。`.md` / `.markdown` 等默认预览，顶栏可切回源码；预览复用对话区的 `MarkdownBody`，编辑器在切走时仍存活所以撤销栈不丢。三层冲突处理：保存时按 mtime 校验外部修改（覆盖 / 放弃 / 取消）；关闭未保存文件弹确认（保存 / 不保存 / 取消）；Agent 写已打开文件时，未脏自动重载、已脏显示「重载 / 保留我的」提示条。>2MB、非 UTF-8、含 NUL 的文件拒绝打开。Finder / `⌘O` 打开的 Markdown 也走这个标签，不另开窗口。
3. **终端标签**：[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 真实 PTY 交互终端，按登录 shell 启动并继承完整 PATH；背景 / 前景随浅色、深色切换（与检查器画布同色）。进程在 `openTerminalTab()` 创建，关标签即终止，shell 里敲 `exit` 同样关掉标签并回收 PTY，应用退出统一清理。
4. **信息标签**：协议、Agent、工作区路径、ACP Session ID 与会话配置（`configOptions`）编辑。

#### 分栏拖动的冻结契约

拖动主对话栏与检查器之间的分栏，是**唯一会连续几十秒改写两个窗格宽度**的操作，它的成本必须与拖动帧数无关。这一节的约束改动前请先读。

- **拖动期间冻结内容的提议宽度，不要盖住它。** `InspectorPaneView` 在 `frozenWidth != nil` 时用 `FrozenWidthLayout`（自定义 `Layout`）把子视图的**提议宽度**钉在拖动开始那一刻，外层只变裁剪框，松手后才按最终宽度排一次——表列宽、公式、编辑器与终端的布局在拖动中一次都不重算。遮罩只挡眼睛，**不会让 SwiftUI 跳过布局**。遮罩必须是不透明的 `Palette.inspectorBg`：同色半透明叠上去等于没盖；`.regularMaterial` 会在分栏每帧对整块面板重采样模糊（PERF-02）。
- **冻结必须用 `Layout`，不能用 `.frame(width:)`。** `.frame(width:)` 会把该宽度当成内容的*理想宽度*，并穿过外层的 `.frame(maxWidth: .infinity)` 继续向 `NavigationSplitView` 传播；分栏读到它就把列宽钉住——把分栏拉到最大宽度后就再也拉不回来，夹紧边界处反复夹紧/回弹。`Layout` 的容器尺寸恒等于父级提议，冻结与否都不改变自己占的空间，因此不会泄漏固定宽度。这一条是实测踩过的回归。
- **不要在几何回调里写 `@State`。** 拖动状态由 `SplitResizeEngine`（`Views/SplitResize.swift`）持有：每帧喂进来的宽度只写 `lastWidth` 这类普通字段，`isResizing` / `frozenWidth` 只在**开始与结束两个边沿**变化，于是一个拖动周期只让视图失效两次。`@StateObject` 持有引用类型时，改它的普通属性不会触发更新——这是整条约束的实现基础。
- **拖动起止只认指针按下 / 抬起，不要用"宽度多久没变"。** 宽度不变无法区分"用户中途停顿"和"用户松手"：按住鼠标停顿超过阈值就会提前解冻、内容重排，表现出来就是界面渲染跑在拖动前面。`SplitResizeEngine` 用 `NSEvent.addLocalMonitorForEvents` 监视 `.leftMouseDown` / `.leftMouseUp`，只有"指针按着 + 宽度真的在变"同时成立才冻结；抬起即解冻。它不去上层找 `NSSplitView`：`.inspector` / `NavigationSplitView` 内部用什么容器属于 SwiftUI 的实现细节，顺着视图树找分隔条更脆。剩下的 3 秒兜底计时器只负责在抬起事件丢失时自我恢复。

曾经的实现违反前两条：`isResizing` / `resizeGeneration` / `lastWidth` 三个 `@State` 承接 `onGeometryChange` 回调，其中 `resizeGeneration` 每帧无条件自增——每拖一帧就让整个检查器面板（`ZStack` 内全部标签页）失效一次。这些失效在同一显示周期里把 `setNeedsUpdateConstraints` 反复顶到窗口，累积超过 AppKit 的限额后 `-[NSWindow _postWindowNeedsUpdateConstraints]` 抛 `NSInternalInconsistencyException`，被 `+[NSApplication _crashOnException:]` 终止。诊断报告（`~/Library/Logs/DiagnosticReports/Aureways-*.ips`，2026-09-15/16 共 6 次）的栈是 `NSHostingView.layout → CoreViewSetGeometry → NSView.setFrame → Auto Layout 依赖级联 → NSHostingView.didChangeValue → invalidateSafeAreaInsets → setNeedsUpdateConstraints → _postWindowNeedsUpdateConstraints`；统一日志里对应的判据行是 `Marking window ... as needing Update Constraints in Window (limit: 277, count: 279)`，两次实测的约束更新数与布局数之比恒为 2:1（278/139、310/155），即一次无法收敛的振荡。

> 回归验证：连续来回拖动分栏 30 秒不应崩溃、不应掉帧。`AurewaysTests/SplitResizeEngineTests.swift` 锁住"连续拖动只翻转一次 observable 状态"这条契约。

Aureways 以 **Editor / Alternate** 身份声明 `net.daringfireball.markdown`（扩展名 `.md` `.markdown` `.mdown` `.mkd` `.mkdn` `.mdwn`）。Finder「打开方式」、Dock 拖放、`open -a Aureways file.md`、以及菜单 **打开 Markdown…**（`⌘O`）都唤出主窗口，并在工作台打开对应文件标签。默认不抢系统双击；偏好设置 → Markdown 可「设为默认 Markdown 打开方式」。只改 Markdown UTI，不动 `public.plain-text`。

> 旧版「审查 / 日志」两个只读标签已移除，但 `fileOps` / `logs` 数据仍在后台按会话记录（`ChatSession`），供后续恢复或做差异审查。

---

## 3. 外观与主题系统 (Palette & Liquid Glass)

### 3.1 动态自适应色彩 (`Palette`)
基于 `NSColor(dynamicProvider:)` 实现浅色/深色模式全量自适应：
- **浅色模式 (Light)**：纯净极简白底（`#FAFAFC`）、卡片底（`#FFFFFF`）、柔和边框（`#E5E5EB`）。
- **深色模式 (Dark)**：沉浸式暗黑底（`#171719`）、面板底（`#212124`）、卡片底（`#2A2A2E`）。
- **品牌强调色**：浅色 Orbit Blue `#003DA5`，深色提亮蓝。`AccentColor` 与 `Palette.accent` 同源。金 `Palette.gold` 只用于思考 / 连接中 / 警告，不再当品牌色。
- **外观模式设置**：可在偏好设置（`⌘,`）中自由切换 **系统默认 / 浅色模式 / 深色模式**。

### 3.2 Liquid Glass 质感系统
- **窗口基底**：完全交由系统原生渲染——标题栏、工具栏、侧栏材质均使用 macOS 26 系统默认的 Liquid Glass 表现；应用只把用户的深浅色偏好写到 `NSWindow.appearance`，保证 AppKit 材质与 SwiftUI 内容不出现深浅混色。窗口不再手动设置 `isOpaque`/`backgroundColor`/`titlebarAppearsTransparent`。
- **Chrome 卡片**（`Chrome.swift`）：ink 薄纱 + `.glassEffect(.regular)`（`allowsHitTesting(false)`），形状用 `ConcentricRectangle`（minimum = 14），贴近窗口圆角处自动跟随系统曲率。输入卡 veil 0.65，可读性另由 Transcript 底部 `.scrollEdgeEffectStyle(.hard, for: .bottom)` 滚动边缘效果兜底。
- **控件**：Composer chips / 按钮用官方 `.buttonStyle(.glass)` / `.glass(.regular.tint(...))`（不放 `GlassEffectContainer`——container 只服务 `glassEffect` 视图，包住 glass 按钮会吞 bezel）；右侧标签条是自绘胶囊（选中 `Palette.selection`、悬停 `Palette.badgeBg`）。仅静态展示 chip（会话内 harness 标签）保留 `liquidGlassCapsule`。
- **对话正文**：消息块 / 代码块属于内容层，用 `.regularMaterial` 背景，不再叠加玻璃。
- **侧栏行高亮**：工作区树 / 会话行仍为自绘 `glassRowHighlight` 纯色高亮（非玻璃材质）。
- **所有效果层**：配置 `allowsHitTesting(false)`，不拦截用户点击与滚动。

---

## 4. 关键代码映射表

| 文件 | 核心职责 |
| --- | --- |
| `Aureways/Views/RootView.swift` | 根容器 `NavigationSplitView`、统一工具栏、快捷键路由 |
| `Aureways/Views/Sidebar.swift` | 新对话、工作区树、会话状态、底栏偏好设置 |
| `Aureways/Views/Transcript.swift` | 居中对话流容器（窗口化虚拟化 + 位置跟随），见 §2.2「转录的渲染与虚拟化」 |
| `Aureways/Views/TranscriptBlocks.swift` | 消息气泡、活动卡、思考折叠块等行视图；展开状态在 `TranscriptChromeState` |
| `Aureways/TranscriptVirtualizer.swift` | 可见窗口计算与行高缓存 |
| `Aureways/Domain/Session/TranscriptBlock.swift` | `TranscriptItem` → 渲染行的分组（纯数据，无视图依赖，故可进测试目标） |
| `Aureways/Views/MarkdownBody.swift` | Agent 正文渲染与画布 Markdown 配置（`AurewaysMarkdown`）；流式单通道 parse |
| `Vendor/SwiftStreamingMarkdown` | 正文渲染库本地副本：LaTeX attachment 按 payload 相等、块公式跳过重复 typeset、段落增量 append |
| `Aureways/MarkdownDocumentCache.swift` | 已解析 Markdown 文档缓存与后台预热 |
| `Aureways/Views/Composer.swift` | 居中悬浮输入框、`+` 菜单（文件 / 工作区 / 指令）、会话模型/模式透传、权限切换 |
| `Aureways/Views/Palette.swift` | 色彩、A 轨道平面标志 `BrandMark`、设置页 `AppIconImage` |
| `Aureways/Views/InspectorViews.swift` | 右侧面板容器：标签页分发、保存冲突/关闭确认弹窗、信息标签 |
| `Aureways/Views/SplitResize.swift` | 分栏拖动状态机：拖动期间冻结内容宽度，observable 状态只在开始 / 结束翻转 |
| `Aureways/Views/PaneTabBar.swift` | 统一标签条与 `+` 新建菜单 |
| `Aureways/Views/FileBrowserTab.swift` | 工作区递归目录树（懒加载） |
| `Aureways/Views/FileEditorTab.swift` | NSTextView 编辑器、行号、保存与冲突处理；Markdown 源码/预览切换 |
| `Aureways/MarkdownFile.swift` | 扩展名识别、UTF-8 读盘、默认打开方式 |
| `Aureways/Info.plist` | 文档类型与导入的 Markdown UTI |
| `Aureways/Views/TerminalTab.swift` | SwiftTerm 交互终端与外观适配 |
| `Aureways/Views/SettingsView.swift` | 设置中心：通用 / Agent / 工作区 / 权限 / Markdown 默认打开方式 |
| `Aureways/AppModel.swift` 及 `AppModel+*.swift` | 状态中心（会话、工作区、运行时、面板标签） |
