# 目录结构

仓库根目录（`Aureways.xcodeproj` 所在层）才是工程根。内层 `Aureways/` 只是应用源码文件夹。

```
Aureways/                          # 仓库根
├── README.md
├── LICENSE                        # MIT
├── Makefile                       # build / release / test / open / clean
├── .github/workflows/
│   └── release.yml                # tag 触发的构建发版工作流
├── docs/                          # 本目录：项目文档
│   ├── README.md
│   ├── directory.md
│   ├── architecture.md
│   ├── frontend.md
│   ├── backend.md
│   ├── protocol.md
│   ├── development.md
│   └── brand/app-icon.md          # A 轨道 App Icon 规范
├── design/app-icon/               # 图标几何源：build_icon.py + reference/，SVG 与 PNG 均为生成物
├── Vendor/
│   └── SwiftStreamingMarkdown/  # 本地化的正文渲染库（LaTeX 流式去重，见 PATCHES.md）
├── Aureways.xcodeproj/
│   ├── project.pbxproj            # 两个 target：Aureways、AurewaysTests
│   └── xcshareddata/xcschemes/
│       └── Aureways.xcscheme
├── Aureways/                      # 应用源码（bundle id: ai.aureways.client）
│   ├── AurewaysApp.swift          # @main，主窗口 + Settings + 退出清理
│   ├── Info.plist                 # 与 GENERATE_INFOPLIST_FILE 合并：Markdown 文档类型
│   ├── Localization.swift         # L10n / String.localized
│   ├── Localizable.xcstrings      # zh-Hans 源文案 + en 翻译
│   ├── AppModel.swift             # 应用状态
│   ├── AppModel+Workspace.swift   # 工作区目录
│   ├── AppModel+Sessions.swift    # 会话列表 / 发送 / 关闭 / 删除
│   ├── AppModel+Runtime.swift     # ACP 进程、prompt、权限桥
│   ├── AppModel+Inspector.swift   # 面板标签、编辑保存/冲突、超长粘贴草稿
│   ├── ChatSession.swift          # 单会话 transcript 状态
│   ├── SessionStore.swift         # sqlite 会话列表缓存
│   ├── AppIcon.icon/              # macOS 26+ Icon Composer（A / 轨道 / 星）
│   ├── Assets.xcassets/           # AccentColor、BrandMark 平面标志、AppIcon.appiconset 扁平回退
│   ├── Harness/                   # 各家 ACP 运行时
│   │   ├── Harness.swift          # 基类、配方、PATH、注册表
│   │   ├── HarnessRuntime.swift   # 共用 stdio 连接生命周期
│   │   ├── GrokBuild.swift
│   │   ├── GrokExt.swift          # Grok `_x.ai/exit_plan_mode` / `ask_user_question` 解析
│   │   ├── Codex.swift
│   │   ├── ClaudeCode.swift
│   │   ├── Antigravity.swift      # 取代 Gemini CLI
│   │   ├── Copilot.swift
│   │   ├── Cursor.swift
│   │   ├── OpenCode.swift
│   │   ├── OhMyPi.swift
│   │   ├── Qoder.swift
│   │   └── CustomHarness.swift
│   ├── ACP/                       # 后端：协议与进程
│   │   ├── JSONRPC.swift          # JSON-RPC 2.0 NDJSON + JSONValue
│   │   ├── Models.swift           # initialize / capabilities
│   │   ├── SessionModels.swift    # session/new|load|list|prompt
│   │   ├── UpdateModels.swift     # session/update、tool、permission
│   │   ├── Connection.swift       # 子进程 + 双向 RPC
│   │   └── ClientOps.swift        # fs/*、terminal/*
│   ├── MarkdownFile.swift          # Markdown 扩展名、读盘、默认打开方式
│   ├── MarkdownDocumentCache.swift # 已解析 Markdown 文档缓存
│   ├── TranscriptVirtualizer.swift # 对话流可见窗口与行高缓存
│   └── Views/                     # 前端
│       ├── Palette.swift          # 色彩、BrandMark、AppIconImage
│       ├── Chrome.swift           # Liquid Glass 修饰器
│       ├── RootView.swift         # NavigationSplitView
│       ├── Sidebar.swift          # 新对话、底栏
│       ├── WorkspaceTree.swift    # 工作区树
│       ├── Transcript.swift       # 窗口化对话流、位置跟随
│       ├── TranscriptBlocks.swift # 用户/助手/思考块；展开状态不跟视图走
│       ├── ToolViews.swift        # 工具卡片（命令 / 编辑 / 读取 / 搜索 / 抓取）
│       ├── MarkdownBody.swift     # vendored SwiftStreamingMarkdown + 流式单通道 parse
│       ├── Composer.swift         # 输入框（超长粘贴为字数占位卡）
│       ├── ComposerTextView.swift # NSTextView 输入与拖拽；超长粘贴不进输入框
│       ├── CompletionPopup.swift  # / 与 @ 补全
│       ├── PermissionCard.swift   # 权限确认
│       ├── PlanApprovalCard.swift # Grok 计划审批 + 选择题
│       ├── InspectorViews.swift   # 右栏面板容器与信息标签
│       ├── SplitResize.swift      # 分栏拖动状态机（按指针按下/抬起冻结内容宽度）
│       ├── PaneTabBar.swift       # 面板统一标签条
│       ├── FileBrowserTab.swift   # 工作区目录树
│       ├── FileEditorTab.swift    # 文本编辑器（Markdown 可预览）
│       ├── TerminalTab.swift      # SwiftTerm 交互终端
│       ├── EmptyWorkspace.swift   # 空白画布
│       ├── AgentSheets.swift      # 自定义 Agent
│       └── SettingsView.swift     # 设置中心
└── AurewaysTests/
    ├── ProtocolTests.swift        # JSON-RPC 与 mock agent 集成测试
    ├── MarkdownFileTests.swift    # Markdown 扩展名与 UTF-8 读盘
    ├── SplitResizeEngineTests.swift # 分栏拖动：指针判据 + 只在边沿翻转 observable 状态
    └── ComposerTextViewTests.swift
```

## Xcode Target

| Target | 类型 | 源码 |
| --- | --- | --- |
| **Aureways** | macOS Application | `Aureways/` 下全部 Swift 与 Assets |
| **AurewaysTests** | Unit Test Bundle | `AurewaysTests/ProtocolTests.swift`，并**再编译一份** `Aureways/ACP/*.swift` 与 `Aureways/Harness/*.swift`（不依赖把 SwiftUI 应用当 TEST_HOST） |

构建设置要点（见 `project.pbxproj`）：

- `MACOSX_DEPLOYMENT_TARGET = 26.0`
- `PRODUCT_BUNDLE_IDENTIFIER = ai.aureways.client`
- `ENABLE_APP_SANDBOX` 未开启（需 spawn CLI、读写工作区）
- Debug：`CODE_SIGN_IDENTITY = "-"`（Sign to Run Locally）、`ENABLE_DEBUG_DYLIB = NO`、`ENABLE_PREVIEWS = NO`

## 运行时生成物（不入库）

| 路径 | 说明 |
| --- | --- |
| `.derived/` | Makefile 指定的 DerivedData |
| `.derived/Build/Products/Debug/Aureways.app` | `make open` 打开的包 |
| `~/Library/Preferences/` 下的 UserDefaults | `workspacePath`、`customAgents`、`selectedAgentId` |
| `~/Library/Application Support/ai.aureways.client/aureways.sqlite` | harness 会话列表缓存、工作区目录列表 |

`.gitignore` 忽略 `.derived`、`DerivedData`、`xcuserdata`、`.build` 等。

## 源码职责一览

| 路径 | 层 | 职责 |
| --- | --- | --- |
| `AppIcon.icon` | 品牌 | macOS 26 分层图标（A / 轨道 / 星） |
| `AurewaysApp.swift` | 前端入口 | 窗口、暗色、⌘N |
| `Views/*` | 前端 | 布局与交互 |
| `Views/MarkdownBody.swift` | 前端 | vendored SwiftStreamingMarkdown 渲染 Agent 正文（配 `MarkdownDocumentCache` 解析缓存；流式单通道 parse） |
| `Views/SplitResize.swift` | 前端 | 分栏拖动状态机：以指针按下/抬起为拖动判据；每帧宽度只写非 observable 字段，`isResizing` / `frozenWidth` 仅在开始与结束两个边沿变化 |
| `Views/SettingsView.swift` | 前端 | 通用 / Agent / 工作区 / 权限 |
| `AppModel.swift` 及 `AppModel+*` | 前后端交界 | 会话列表、connect/send/retry/cancel |
| `ChatSession.swift` | 前后端交界 | 单会话 transcript |
| `Harness/Harness.swift` | 后端 | 基类、AgentProfile、PATH |
| `Harness/HarnessRuntime.swift` | 前后端交界 | 一 harness 一 ACP 进程 |
| `Harness/*.swift` | 后端 | Grok / Codex / Claude / Antigravity / Oh My Pi / Qoder 等各自启动参数与 `normalizeToolCall` |
| `Harness/ToolCallNormalization.swift` | 后端 | 工具卡片 JSON 改写的共用铅笔（别名、信封、locations）；映射表在各 Harness 里 |
| `SessionStore.swift` | 本地缓存 | sqlite `session_links` |
| `ACP/Connection.swift` | 后端 | JSON-RPC 连接生命周期 |
| `ACP/JSONRPC.swift` / `Models.swift` / `SessionModels.swift` / `UpdateModels.swift` | 后端 | 编解码 |
| `ACP/ClientOps.swift` | 后端 | 客户端能力：读文件、写文件、终端 |
