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
- **工作区树**：工作区与其下会话合为一棵树。点文件夹设为当前 `cwd`（新对话用），箭头展开/收起会话；`+` 添加工作区。行内标明会话绑定的 Agent。状态灯：绿=已连接，灰=已断开，金=连接中，红=失败。快捷键 `⌘1` ~ `⌘9`。
- **Agent 与插件**：只在 **偏好设置（`⌘,`）** 里管理，不在侧栏重复入口。
- **底栏**：用户名 + 齿轮直达偏好设置。

### 2.2 主对话流与空白态 (TranscriptView & EmptyWorkspaceLanding)
- **居中黄金排版**：对话流与空白页均约束在 **`maxWidth: 780pt` 居中文本容器** 内，消除宽屏状态下横向撑满的空旷感。
- **消息卡片轻量化**：
  - **用户消息**：右侧对齐的现代连续曲率气泡（`cornerRadius: 16`），自适应包裹文字。
  - **Agent 回答**：无外层多余实底方框，左侧搭配 `sparkles` 微光头像，右侧由 [SwiftStreamingMarkdown](https://github.com/microsoft/SwiftStreamingMarkdown) 渲染标题、列表、围栏代码和表格。
  - **思考过程**：默认折叠成一行「思考」。
  - **工具调用**：连续工具收成一组「使用了 N 个工具」；完成后默认收起，点开才是短文件名列表，再点一行才看参数/输出。不再每条一张 COMPLETED 大卡片。
  - **计划**：一行摘要 + 可展开步骤。
- **空白落地页 (`EmptyWorkspaceLanding`)**：A 轨道平面标志（浅色蓝标 / 深色白标，`BrandMark`）叠在 Orbit Blue 液态漫射光斑上，居中引导用户输入。Dock 用的分层 squircle 图标不进这块画布。

#### 转录的渲染与虚拟化

长会话滚动的成本必须与**可见内容**成正比，不能与转录总长度成正比。这一节的每条约束都是为此存在的，改动前请先读。

- **一律 `LazyVStack`**，配 `.scrollTargetLayout()`。曾经在非流式时退回 eager `VStack`，因为库的 `MarkdownView` 在异步解析落地前高度是 0，虚拟化的 stack 会把整段历史当成空的、进会话一片空白。代价是每帧布局开销随块数线性增长：实测同一 build 下，单步滚动成本从 90 blocks 的 2.25 ms 涨到 300 blocks 的 23.02 ms，单核跑满。
- **解析结果由 `MarkdownDocumentCache` 持有，不由视图持有。** `MarkdownBody` 用 `DocumentView`（渲染已解析文档）而不是 `MarkdownView`（视图内自己解析），并在 `init` 里同步查缓存，所以块一放上去就有真实高度——上面那条虚拟化的前提就靠这个成立。会话打开和每回合结束时后台预热（300 条约 54 ms）。
- **位置跟随不读绝对偏移。** 用 `ScrollPosition` + `scrollTo(edge: .bottom)`，判据是 `onScrollTargetVisibilityChange` 报告的「最后一块是否可见」。虚拟化下未放置部分的高度是估算值，`contentOffset` / `contentSize` 会随估算漂移，拿它做阈值会不稳（这也是 Apple 在 WWDC26 "Dive into lazy stacks and scrolling with SwiftUI" 里明确点出的反模式）。底部留白用 `.safeAreaPadding`，这样 `scrollTo(edge:)` 认安全区、最后一条消息停在输入卡上方。
- **写 `@State` 前先比较。** 滚动相关的回调每秒触发多次，无条件写状态会让 `TranscriptView.body` 跟着重算，连带 `TranscriptBlock.group` 重跑一遍整段历史。
- **超长文本先在字符串层面截断再交给 `Text`。** `lineLimit` 只限制显示行数，`Text` 仍会把整个字符串排版；工具的输入 / 输出动辄是整个文件（见 `ToolViews.swift` 的 `clamped`）。
- **回归测量。** `AurewaysTests/TranscriptPerfTests.swift` 是微基准（`make test 2>&1 | grep 'PERF '`）；`ScrollProbe` + `PerfFixture` 提供固定转录下的滚动探针，两者都只编进 Debug：

  ```
  AUREWAYS_PERF_TURNS=50 AUREWAYS_PERF_SCROLL=1 \
    .derived/Build/Products/Debug/Aureways.app/Contents/MacOS/Aureways
  ```

  探针是「固定工作量、测时间」：走固定步数，每步强制同步布局与绘制并计时。不要改回按定时器测帧间隔——窗口被遮挡或失焦时绘制会被节流，慢的配置反而测出来快。绝对值运行间可差数倍，只信同一 build 内交替跑出来的对比。

- **已知未解决**：库的 `CodeBlockView` 每次 `onAppear` 都重跑一次 highlight.js，无缓存，且丢掉围栏的语言标签走全语言自动探测（16.6 ms/块，传语言只需 3.2 ms）。只改颜色不改块高，所以不造成布局抖动，代价是 CPU 与续航。补丁见 `docs/upstream-highlight-cache.patch`，需要 fork 或 vendor 才能应用。

### 2.3 悬浮输入卡片 (ComposerCard)
- **居中悬浮卡片 (`maxWidth: 780pt`)**：自然悬浮于主画布下方。
- **环境状态胶囊**：显示当前项目名称、本地环境标签及实时 Git 分支名（自动过滤非 Git 目录的重复标签）。
- **指令与操作整合**：
  - 移除原先横跨屏幕的 20+ 指令胶囊栏。`+` 菜单提供添加文件、添加工作区，以及当前会话的 Slash Commands（如 `/help`、`/review`）；输入框里打 `/` 仍走补全。
  - 支持 `需我确认 / 帮我批准` 快速权限切换胶囊。
  - 右侧提供一键切换 ACP Harness（Grok、Codex、Claude Code 等）的下拉菜单。

### 2.4 工作台面板 (InspectorPaneView)
快捷键 `⌘B` / `⌥⌘I` 展开/折叠。窗口工具栏是系统分段选择器（`PaneTabBar`）：文件浏览器、每个打开的文本文件、每个终端各占一段。右键某一段弹出菜单关闭该标签（文件还有「关闭其它」「在 Finder 中显示」）；文件浏览器常驻不能关。标签条尾部 `+` 是选择菜单：新建终端、文件浏览器、会话信息、在 Finder 中显示工作区。切换标签只是隐藏视图，终端输出与编辑器文本不丢。

1. **文件浏览器（常驻）**：当前工作区的递归目录树，懒加载；点击文件即在编辑器标签打开；Agent 写文件后自动刷新。
2. **文本文件标签**：NSTextView 编辑器（等宽字体 + 行号栏），脏标记 ●、`⌘S` 保存。三层冲突处理：保存时按 mtime 校验外部修改（覆盖 / 放弃 / 取消）；关闭未保存文件弹确认（保存 / 不保存 / 取消）；Agent 写已打开文件时，未脏自动重载、已脏显示「重载 / 保留我的」提示条。>2MB、非 UTF-8、含 NUL 的文件拒绝打开。
3. **终端标签**：[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 真实 PTY 交互终端，按登录 shell 启动并继承完整 PATH；背景 / 前景随浅色、深色切换（与检查器画布同色）。进程在 `openTerminalTab()` 创建，关标签即终止，应用退出统一清理。
4. **信息标签**：协议、Agent、工作区路径、ACP Session ID 与会话配置（`configOptions`）编辑。

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
| `Aureways/Views/Transcript.swift` | 居中对话流容器（虚拟化 + 位置跟随），见 §2.2「转录的渲染与虚拟化」 |
| `Aureways/Views/TranscriptBlocks.swift` | 消息气泡、活动卡、思考折叠块等行视图 |
| `Aureways/TranscriptBlock.swift` | `TranscriptItem` → 渲染行的分组（纯数据，无视图依赖，故可进测试目标） |
| `Aureways/Views/MarkdownBody.swift` | Agent 正文渲染与画布 Markdown 配置（`AurewaysMarkdown`） |
| `Aureways/MarkdownDocumentCache.swift` | 已解析 Markdown 文档缓存与后台预热 |
| `Aureways/Views/Composer.swift` | 居中悬浮输入框、`+` 菜单（文件 / 工作区 / 指令）、会话模型/模式透传、权限切换 |
| `Aureways/Views/Palette.swift` | 色彩、A 轨道平面标志 `BrandMark`、设置页 `AppIconImage` |
| `Aureways/Views/InspectorViews.swift` | 右侧面板容器：标签页分发、保存冲突/关闭确认弹窗、信息标签 |
| `Aureways/Views/PaneTabBar.swift` | 统一标签条与 `+` 新建菜单 |
| `Aureways/Views/FileBrowserTab.swift` | 工作区递归目录树（懒加载） |
| `Aureways/Views/FileEditorTab.swift` | NSTextView 编辑器、行号、保存与冲突处理 |
| `Aureways/Views/TerminalTab.swift` | SwiftTerm 交互终端与外观适配 |
| `Aureways/Views/SettingsView.swift` | 设置中心：通用 / Agent / 工作区 / 权限 |
| `Aureways/AppModel.swift` 及 `AppModel+*.swift` | 状态中心（会话、工作区、运行时、面板标签） |
