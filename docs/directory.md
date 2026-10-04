# 目录结构

仓库根目录（`Aureways.xcodeproj` 所在层）才是工程根。内层 `Aureways/` 是应用源码。

```
Aureways/                              # 仓库根
├── README.md
├── README.zh-CN.md
├── LICENSE                            # MIT
├── Makefile                           # build / open / test / release / clean / web
├── .github/workflows/release.yml      # 只有 v* tag 才构建发版
├── docs/
├── design/app-icon/                   # 图标几何源与生成的 SVG / PNG
├── WebApp/                            # 窗口里的 Preact 应用
│   ├── src/
│   ├── package.json
│   └── package-lock.json
├── Aureways.xcodeproj/
├── Aureways/                          # 应用源码（bundle id: ai.aureways.client）
│   ├── AurewaysApp.swift              # @main：主窗口 + 菜单栏 + 菜单命令
│   ├── AppActivation.swift            # 关窗口留在菜单栏、重新打开、用本应用打开文件
│   ├── AttentionNotifier.swift        # 后台会话的系统通知与 Dock 角标
│   ├── Localization.swift             # 语言切换与本地化辅助函数
│   ├── Localizable.xcstrings          # 本地化多语言字符串字典
│   ├── Info.plist
│   ├── AppIcon.icon/
│   ├── Assets.xcassets/
│   ├── WebAppBundle/                  # make web 的产物，不入库
│   ├── Model/                         # AppModel 及按职责拆分的扩展
│   │   ├── AppModel.swift
│   │   ├── AppModel+Workspace.swift
│   │   ├── AppModel+Sessions.swift
│   │   ├── AppModel+Runtime.swift
│   │   └── AppModel+Inspector.swift
│   ├── WebShell/                      # 原生窗口宿主与 Web 桥接
│   │   ├── WebShellView.swift         # 窗口宿主、玻璃层、输入框浮层
│   │   ├── WebShellBridge.swift       # AppModel ↔ 页面核心与生命周期
│   │   ├── WebShellBridge+State.swift # 状态快照编码
│   │   ├── WebShellBridge+Transcript.swift # 转录条目与工具调用编码
│   │   ├── WebShellBridge+Handlers.swift   # JS 消息分发与原生操作
│   │   ├── WebShellServices.swift     # fs / git / 终端 / 选择器的 rpc
│   │   ├── WebShellSettings.swift     # 设置与 Agent 目录的 rpc
│   │   ├── WebAssetScheme.swift       # aureways-web://app/ 提供页面资源
│   │   └── WebTerminalService.swift   # 检查器终端的无界面 PTY
│   ├── Domain/
│   │   ├── Session/                   # ChatSession、SessionStore（sqlite）
│   │   └── Workspace/                 # 文件树与 @ 补全用的索引
│   ├── Harness/                       # 各家启动命令与协议偏差
│   ├── ACP/                           # JSON-RPC、会话模型、fs / terminal
│   ├── Quota/                         # QuotaStore、各家额度源
│   └── Support/                       # 辅助工具与通用类型
│       ├── ComposerAttachment.swift
│       ├── MarkdownFile.swift
│       ├── TextDiff.swift
│       └── PerfFixture.swift
└── AurewaysTests/
```

`Aureways/Views/` 和 `Vendor/` 已经删掉。主窗口不再用 SwiftUI 排对话和检查器。

## WebApp/src

| 路径 | 职责 |
| --- | --- |
| `main.tsx` | 启动。`#menubar` 走菜单栏页，否则走主窗口 |
| `components/App.tsx` | 侧栏、顶栏、对话、停靠区、检查器、设置路由 |
| `components/VirtualList.tsx` | 窗口化列表与底部钉住 |
| `components/Composer.tsx` | 输入框。会话打开且原生浮层开启时，主页面只留一个等高的槽 |
| `components/ComposerOverlay.tsx` | 浮层 WebView 里的输入框，并回报卡片高度 |
| `components/MenuBar.tsx` | 菜单栏：额度、最近会话、打开主窗口、退出 |
| `inspector/` | 文件树、编辑器、变更、xterm 终端 |
| `settings/` | 通用、Agent、用量、工作区、权限、MCP |
| `markdown/` | marked 分块、DOMPurify、按需 Shiki |
| `glass.ts` | 把 `data-glass` 矩形发给原生玻璃层 |
| `bridge.ts` / `rpc.ts` / `store.ts` | 消息、请求、状态 |
| `demo.ts` | 没有 `webkit.messageHandlers.aureways` 时的演示数据 |

## Xcode Target

| Target | 类型 | 源码 |
| --- | --- | --- |
| **Aureways** | macOS Application | `Aureways/` 下的 Swift、资源、`WebAppBundle` |
| **AurewaysTests** | Unit Test Bundle | `AurewaysTests/`。不把 `.app` 当 TEST_HOST |

构建设置（`project.pbxproj`）：

- `MACOSX_DEPLOYMENT_TARGET = 26.0`
- `MARKETING_VERSION = 0.3.1`，`CURRENT_PROJECT_VERSION = 19`
- `PRODUCT_BUNDLE_IDENTIFIER = ai.aureways.client`
- App Sandbox 未开启（要拉起 CLI、读写工作区）
- Debug：`CODE_SIGN_IDENTITY = "-"`，`ENABLE_DEBUG_DYLIB = NO`，`ENABLE_PREVIEWS = NO`

Swift 包只有 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.0。它带一个 build tool 插件，`Makefile` 用 `-skipPackagePluginValidation` 跳过命令行确认。`swift-argument-parser` 是该插件的依赖。

## 运行时生成物（不入库）

| 路径 | 说明 |
| --- | 说明 |
| `.derived/` | Makefile 的 DerivedData |
| `.derived/Build/Products/Debug/Aureways.app` | `make open` 打开的包 |
| UserDefaults | 工作区、自定义 Agent、外观、菜单栏开关、额度源覆盖、MCP |
| `~/Library/Application Support/ai.aureways.client/aureways.sqlite` | 会话链接与工作区目录 |

`.gitignore` 忽略 `.derived`、`DerivedData`、`xcuserdata`、`.build`、`*.trace`、`.claude/`。`WebApp/node_modules` 和 `Aureways/WebAppBundle/` 不入库。

## 源码职责

| 路径 | 职责 |
| --- | --- |
| `AurewaysApp.swift` | 窗口场景、菜单栏场景、菜单快捷键 |
| `Model/` | AppModel 核心状态管理、会话、工作区与检查器扩展 |
| `WebShell/` | 玻璃宿主、主/浮层 WebView、JS-Native 桥接及系统 RPC 服务 |
| `Harness/` | 各 Agent CLI 启动参数、PATH、工具卡片规范化 |
| `ACP/` | JSON-RPC 协议与 Client/Agent 双方调用契约 |
| `Quota/` | 额度缓存、限流调度与各 Agent 额度源解析 |
| `Domain/` | 会话存储（sqlite: `session_links`, `workspaces`）与工作区索引 |
| `Support/` | 文本差异比对、富文本附件模型、Markdown 解析及性能测试桩 |
