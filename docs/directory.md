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
│   ├── AppModel.swift             # 会话状态、连接编排
│   ├── Assets.xcassets/           # AccentColor、空 AppIcon
│   ├── ACP/                       # 后端：协议与进程
│   │   ├── JSONRPC.swift          # JSON-RPC 2.0 NDJSON
│   │   ├── Models.swift           # ACP 类型（initialize / update / permission）
│   │   ├── Catalog.swift          # harness 配方 + PATH 解析
│   │   ├── Connection.swift       # 子进程 + 双向 RPC
│   │   └── ClientOps.swift        # fs/*、terminal/*
│   └── Views/                     # 前端
│       ├── RootView.swift         # NavigationSplitView、调色板
│       ├── Sidebar.swift          # harness 列表、会话列表、自定义 agent
│       ├── Transcript.swift       # 状态条、消息流、tool card、日志
│       └── Composer.swift         # 输入框、权限 sheet、Settings
└── AurewaysTests/
    └── ProtocolTests.swift        # JSON-RPC 与 mock agent 集成测试
```

## Xcode Target

| Target | 类型 | 源码 |
| --- | --- | --- |
| **Aureways** | macOS Application | `Aureways/` 下全部 Swift 与 Assets |
| **AurewaysTests** | Unit Test Bundle | `AurewaysTests/ProtocolTests.swift`，并**再编译一份** `Aureways/ACP/*.swift`（不依赖把 SwiftUI 应用当 TEST_HOST） |

构建设置要点（见 `project.pbxproj`）：

- `MACOSX_DEPLOYMENT_TARGET = 14.4`
- `PRODUCT_BUNDLE_IDENTIFIER = ai.aureways.client`
- `ENABLE_APP_SANDBOX` 未开启（需 spawn CLI、读写工作区）
- Debug：`CODE_SIGN_IDENTITY = "-"`（Sign to Run Locally）、`ENABLE_DEBUG_DYLIB = NO`、`ENABLE_PREVIEWS = NO`

## 运行时生成物（不入库）

| 路径 | 说明 |
| --- | --- |
| `.derived/` | Makefile 指定的 DerivedData |
| `.derived/Build/Products/Debug/Aureways.app` | `make open` 打开的包 |
| `~/Library/Preferences/` 下的 UserDefaults | `workspacePath`、`customAgents` |

`.gitignore` 忽略 `.derived`、`DerivedData`、`xcuserdata`、`.build` 等。

## 源码职责一览

| 路径 | 层 | 职责 |
| --- | --- | --- |
| `AurewaysApp.swift` | 前端入口 | 窗口、暗色、⌘N |
| `Views/*` | 前端 | 布局与交互 |
| `AppModel.swift` | 前后端交界 | 会话列表、connect/send/retry/cancel |
| `ACP/Catalog.swift` | 后端 | 内置 harness、which、PATH |
| `ACP/Connection.swift` | 后端 | JSON-RPC 连接生命周期 |
| `ACP/JSONRPC.swift` / `Models.swift` | 后端 | 编解码 |
| `ACP/ClientOps.swift` | 后端 | 客户端能力：读文件、写文件、终端 |
