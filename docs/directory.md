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
    ├── AurewaysApp.swift              # @main：主窗口 + 菜单栏 + 菜单命令
    ├── AppActivation.swift            # 关窗口留在菜单栏、重新打开、用本应用打开文件
    ├── WebShellView.swift             # 窗口宿主、玻璃层、输入框浮层
    ├── WebShellBridge.swift           # AppModel ↔ 页面
    ├── WebShellServices.swift         # fs / git / 终端 / 选择器的 rpc
    ├── WebShellSettings.swift         # 设置与 Agent 目录的 rpc
    ├── WebAssetScheme.swift           # aureways-web://app/ 提供页面资源
    ├── WebTerminalService.swift       # 检查器终端的无界面 PTY
    ├── AttentionNotifier.swift        # 后台会话的系统通知与 Dock 角标
    ├── WebAppBundle/                  # make web 的产物，已提交
    ├── AppModel.swift
    ├── AppModel+Workspace.swift
    ├── AppModel+Sessions.swift
    ├── AppModel+Runtime.swift
    ├── AppModel+Inspector.swift
    ├── Domain/
    │   ├── Session/                   # ChatSession、SessionStore（sqlite）
    │   └── Workspace/                 # 文件树与 @ 补全用的索引
    ├── Harness/                       # 各家启动命令与协议偏差
    ├── ACP/                           # JSON-RPC、会话模型、fs / terminal
    ├── Quota/                         # QuotaStore、各家额度源
    ├── ComposerAttachment.swift
    ├── MarkdownFile.swift
    ├── Localization.swift
    ├── Localizable.xcstrings
    ├── AppIcon.icon/
    └── Assets.xcassets/
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
- `MARKETING_VERSION = 0.2.4`，`CURRENT_PROJECT_VERSION = 17`
- `PRODUCT_BUNDLE_IDENTIFIER = ai.aureways.client`
- App Sandbox 未开启（要拉起 CLI、读写工作区）
- Debug：`CODE_SIGN_IDENTITY = "-"`，`ENABLE_DEBUG_DYLIB = NO`，`ENABLE_PREVIEWS = NO`

Swift 包只有 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.0。它带一个 build tool 插件，`Makefile` 用 `-skipPackagePluginValidation` 跳过命令行确认。`swift-argument-parser` 是该插件的依赖。

## 运行时生成物（不入库）

| 路径 | 说明 |
| --- | --- |
| `.derived/` | Makefile 的 DerivedData |
| `.derived/Build/Products/Debug/Aureways.app` | `make open` 打开的包 |
| UserDefaults | 工作区、自定义 Agent、外观、菜单栏开关、额度源覆盖、MCP |
| `~/Library/Application Support/ai.aureways.client/aureways.sqlite` | 会话链接与工作区目录 |

`.gitignore` 忽略 `.derived`、`DerivedData`、`xcuserdata`、`.build`。`WebApp/node_modules` 不入库。

## 源码职责

| 路径 | 职责 |
| --- | --- |
| `AurewaysApp.swift` | 窗口场景、菜单栏场景、菜单快捷键 |
| `WebShellView.swift` | 玻璃、主 WebView、输入框浮层的位置 |
| `WebShellBridge.swift` | 状态快照、转录补丁、命令、浮层高度 |
| `AppModel.swift` 及 `AppModel+*` | 会话、发送、工作区、检查器草稿 |
| `Harness/` | 启动参数、PATH、工具卡片形状 |
| `ACP/` | JSON-RPC 与 Client 被调用的方法 |
| `Quota/` | 与会话无关的额度缓存和限流 |
| `Domain/Session/SessionStore.swift` | sqlite：`session_links`、`workspaces` |
