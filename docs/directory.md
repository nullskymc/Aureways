# 目录结构

仓库根目录（`Aureways.xcodeproj` 所在层）才是工程根。内层 `Aureways/` 只是应用源码文件夹。

```
Aureways/                          # 仓库根
├── README.md
├── LICENSE                        # MIT
├── Makefile                       # build / test / open / clean
├── docs/                          # 本目录：项目文档
│   ├── README.md
│   ├── directory.md
│   ├── architecture.md
│   ├── frontend.md
│   ├── backend.md
│   ├── protocol.md
│   └── development.md
├── Aureways.xcodeproj/
│   ├── project.pbxproj            # 两个 target：Aureways、AurewaysTests
│   └── xcshareddata/xcschemes/
│       └── Aureways.xcscheme
├── Aureways/                      # 应用源码（bundle id: ai.aureways.client）
│   ├── AurewaysApp.swift          # @main，WindowGroup + Settings
│   ├── AppModel.swift             # 应用状态
│   ├── AppModel+Workspace.swift   # 工作区目录
│   ├── AppModel+Sessions.swift    # 会话列表 / 发送 / 关闭 / 删除
│   ├── AppModel+Runtime.swift     # ACP 进程、prompt、权限桥
│   ├── ChatSession.swift          # 单会话 transcript 状态
│   ├── SessionStore.swift         # sqlite 会话列表缓存
│   ├── Assets.xcassets/           # AccentColor、空 AppIcon
│   ├── Harness/                   # 各家 ACP 运行时
│   │   ├── Harness.swift          # 基类、配方、PATH、注册表
│   │   ├── HarnessRuntime.swift   # 共用 stdio 连接生命周期
│   │   ├── GrokBuild.swift
│   │   ├── Codex.swift
│   │   ├── ClaudeCode.swift
│   │   ├── Antigravity.swift      # 取代 Gemini CLI
│   │   ├── Copilot.swift
│   │   ├── Cursor.swift
│   │   ├── OpenCode.swift
│   │   └── CustomHarness.swift
│   ├── ACP/                       # 后端：协议与进程
│   │   ├── JSONRPC.swift          # JSON-RPC 2.0 NDJSON + JSONValue
│   │   ├── Models.swift           # initialize / capabilities
│   │   ├── SessionModels.swift    # session/new|load|list|prompt
│   │   ├── UpdateModels.swift     # session/update、tool、permission
│   │   ├── Connection.swift       # 子进程 + 双向 RPC
│   │   └── ClientOps.swift        # fs/*、terminal/*
│   └── Views/                     # 前端
│       ├── Palette.swift          # 色彩与 Liquid Glass
│       ├── RootView.swift         # NavigationSplitView
│       ├── Sidebar.swift          # 新对话、底栏
│       ├── WorkspaceTree.swift    # 工作区树
│       ├── Transcript.swift       # 状态条、消息列表
│       ├── TranscriptBlocks.swift # 用户/助手/思考块
│       ├── ToolViews.swift        # 工具组、计划卡
│       ├── MarkdownBody.swift     # MarkdownUI 渲染
│       ├── Composer.swift         # 输入框
│       ├── PermissionSheet.swift  # 权限确认
│       ├── InspectorViews.swift   # 右栏检查器
│       ├── EmptyWorkspace.swift   # 空白画布
│       ├── AgentSheets.swift      # 自定义 Agent
│       └── SettingsView.swift     # 设置中心
└── AurewaysTests/
    └── ProtocolTests.swift        # JSON-RPC 与 mock agent 集成测试
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
| `AurewaysApp.swift` | 前端入口 | 窗口、暗色、⌘N |
| `Views/*` | 前端 | 布局与交互 |
| `Views/MarkdownBody.swift` | 前端 | [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) 渲染 Agent 正文 |
| `Views/SettingsView.swift` | 前端 | 通用 / Agent / 工作区 / 权限 |
| `AppModel.swift` 及 `AppModel+*` | 前后端交界 | 会话列表、connect/send/retry/cancel |
| `ChatSession.swift` | 前后端交界 | 单会话 transcript |
| `Harness/Harness.swift` | 后端 | 基类、AgentProfile、PATH |
| `Harness/HarnessRuntime.swift` | 前后端交界 | 一 harness 一 ACP 进程 |
| `Harness/*.swift` | 后端 | Grok / Codex / Claude / Antigravity 等各自启动参数 |
| `SessionStore.swift` | 本地缓存 | sqlite `session_links` |
| `ACP/Connection.swift` | 后端 | JSON-RPC 连接生命周期 |
| `ACP/JSONRPC.swift` / `Models.swift` / `SessionModels.swift` / `UpdateModels.swift` | 后端 | 编解码 |
| `ACP/ClientOps.swift` | 后端 | 客户端能力：读文件、写文件、终端 |
