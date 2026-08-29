# 前端架构与 UI 设计

技术栈：SwiftUI，macOS 14.4+，基于原生 macOS 统一工具栏（`.windowToolbarStyle(.unified)`）与自适应色彩系统（`NSColor(dynamicProvider:)`）。

## 1. 窗口布局架构

基于现代化三栏式布局（类似 Codex / Linear / Xcode），由 `SidebarView`、`MainWorkspaceView` 与可折叠的 `InspectorPaneView` 组成：

```
┌──────────────┬──────────────────────────────────────────┬──────────────────┐
│ Sidebar      │ 统一工具栏：📁 工作区切换 · Auto-approve   │ Inspector (⌘B)   │
│              ├──────────────────────────────────────────┤ 选项卡：         │
│ • 新对话 (⌘N)│ 主对话画布 (流式阅读流，maxWidth: 780pt)  │ • 审查 (Review)  │
│ • Agent 中心 │ ──────────────────────────────────────── │ • 终端 (Terminal)│
│ • 工作区目录 │ • 用户气泡 (右对齐圆角气泡)              │ • 日志 (Logs)    │
│              │ • 思考过程 (折叠微光引用块)              │ • 文件 (Files)   │
│ 项目与会话:  │ • Agent 消息 (自然 Markdown 文本流)      │ • 信息 (Info)    │
│ 📁 Workspace │ • 工具调用卡片 (ToolCard / PlanCard)     │                  │
│   ● 会话 ⌘1  ├──────────────────────────────────────────┤                  │
│              │ 悬浮 Liquid Glass Composer (居中 780pt)  │                  │
│ ⚙️ 个人设置  │ 📁 状态胶囊 · 多行输入 · + 菜单 · Agent选择│                  │
└──────────────┴──────────────────────────────────────────┴──────────────────┘
```

---

## 2. 界面核心模块

### 2.1 侧边栏 (SidebarView)
- **品牌与工作区菜单**：集成工作区快速切换、Finder 打开、Agent 管理入口。
- **实用快捷操作**：
  - 📝 **新对话 (`⌘N`)**：一键重置当前选中的会话进入空白就绪态。
  - 🧩 **Agent 与插件**：实时显示当前系统中可用的本地 ACP Harness 数量，点击呼出管理面板。
  - 📁 **工作区目录**：显示当前工作区与 Git 分支，点击直接在 Finder 中定位。
- **项目与会话分组**：按工作区归类历史会话，显示活动状态指示灯与快捷键角标（`⌘1` ~ `⌘9` 一键切换）。
- **底栏用户面板 (`UserProfileFooter`)**：显示用户名、状态，右侧齿轮菜单可直达 **偏好设置（`⌘,`）** 与 Agent 配置。

### 2.2 主对话流与空白态 (TranscriptView & EmptyWorkspaceLanding)
- **居中黄金排版**：对话流与空白页均约束在 **`maxWidth: 780pt` 居中文本容器** 内，消除宽屏状态下横向撑满的空旷感。
- **消息卡片轻量化**：
  - **用户消息**：右侧对齐的现代连续曲率气泡（`cornerRadius: 16`），自适应包裹文字。
  - **Agent 回答**：无外层多余实底方框，左侧搭配 `sparkles` 微光头像，右侧自然流淌 Markdown 排版，行高调整为舒适阅读行距（`lineSpacing: 4`）。
  - **思考过程 (Thinking)**：折叠微光引用块（`brain.head.profile`），展开时带左侧强调细线。
  - **工具与步骤卡片**：紧凑状态胶囊，支持展开查看输入 JSON 参数与执行输出。
- **空白落地页 (`EmptyWorkspaceLanding`)**：云朵与终端 Logo 搭配可自适应环境光的液态漫射光斑（Ambient Glow），居中引导用户快速输入。

### 2.3 悬浮输入卡片 (ComposerCard)
- **居中悬浮卡片 (`maxWidth: 780pt`)**：自然悬浮于主画布下方。
- **环境状态胶囊**：显示当前项目名称、本地环境标签及实时 Git 分支名（自动过滤非 Git 目录的重复标签）。
- **指令与操作整合**：
  - 移除原先横跨屏幕的 20+ 指令胶囊栏，将 Agent 提供的所有 Slash Commands（如 `/help`、`/review` 等）优雅收纳至 **`+` 快捷操作菜单**。
  - 支持 `需我确认 / 帮我批准` 快速权限切换胶囊。
  - 右侧提供一键切换 ACP Harness（Grok、Codex、Claude Code 等）的下拉菜单。

### 2.4 多功能检查器 (InspectorPaneView)
快捷键 `⌘B` 或 `⌥⌘I` 展开/折叠，内置 5 个选项卡：
1. **审查 (Review)**：本会话的 `fs/read_text_file` / `fs/write_text_file` 记录。
2. **终端 (Terminal)**：占位说明。终端由 Agent 经 ACP `terminal/*` 按需启动，输出尚未接到此面板。
3. **日志 (Logs)**：ACP harness 的 `stderr`。
4. **文件 (Files)**：当前工作区顶层文件与文件夹（非递归树）。
5. **信息 (Info)**：协议、Agent、工作区路径、ACP Session ID。

---

## 3. 外观与主题系统 (Palette & Liquid Glass)

### 3.1 动态自适应色彩 (`Palette`)
基于 `NSColor(dynamicProvider:)` 实现浅色/深色模式全量自适应：
- **浅色模式 (Light)**：纯净极简白底（`#FAFAFC`）、卡片底（`#FFFFFF`）、柔和边框（`#E5E5EB`）。
- **深色模式 (Dark)**：沉浸式暗黑底（`#171719`）、面板底（`#212124`）、卡片底（`#2A2A2E`）。
- **外观模式设置**：可在偏好设置（`⌘,`）中自由切换 **系统默认 / 浅色模式 / 深色模式**。

### 3.2 Liquid Glass 质感系统
- **超薄材质基底**：`.ultraThinMaterial` 实时模糊底层内容。
- **斜向高光漫反射**：叠加 Specular Diagonal Sheen 反射渐变。
- **光源折射边缘描边**：左上到右下的光感渐变细边框。
- **双层景深阴影**：微接触投影 + 远端漫反射阴影。
- **macOS 原生菜单规范**：所有自定义 `Menu` 均应用 `.menuIndicator(.hidden)`，杜绝 macOS 系统自动追加的多余下拉箭头。

---

## 4. 关键代码映射表

| 文件 | 核心职责 |
| --- | --- |
| `Aureways/Views/RootView.swift` | 根容器 `NavigationSplitView`、统一工具栏、`Palette` 色彩系统、`liquidGlassCard` 视图修饰器 |
| `Aureways/Views/Sidebar.swift` | 侧边栏导航行、项目与会话分组、会话状态指示灯、设置菜单底栏、Agent 插件管理面板 |
| `Aureways/Views/Transcript.swift` | 空白工作区落地页、居中对话流容器、轻量化消息气泡、思考折叠块、5 选项卡检查器面板 |
| `Aureways/Views/Composer.swift` | 居中悬浮输入框、上下文胶囊、`+` 指令菜单、权限切换开关、Agent 切换器、偏好设置视图 |
| `Aureways/AppModel.swift` | 状态中心（会话生命周期、外观主题持久化、Git 分支解析、快捷键路由、Agent 调度） |
