# 开发与运行

## 工作目录

在仓库根执行命令（能 `ls Makefile Aureways.xcodeproj`）。

```
…/Aureways-webproto/        ← 在这里 make
├── Makefile
├── Aureways.xcodeproj
├── WebApp/                 ← 页面源码。make 会先编它
└── Aureways/               ← Swift 源码，这里没有 Makefile
```

本仓库当前是 `proto/web-shell`。另一份工作区 `/Volumes/Data/DevelopProject/Aureways` 的 `main` 还不包含这套 Web shell。

## 工具链

用 Xcode 27 开发，最低部署 macOS 26。`make` 默认走 `xcode-select -p`。若该路径是 Command Line Tools，`xcodebuild` 会报：

```
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance
```

这只说明当前选中的开发者目录不是完整 Xcode。`Makefile` 在这种情况下按顺序查找：

1. `/Applications/Xcode.app`
2. `/Applications/Xcode-beta.app`
3. `/Volumes/Data/Applications/Xcode.app`
4. `/Volumes/Data/Applications/Xcode-beta.app`
5. Spotlight（`mdfind` bundle id `com.apple.dt.Xcode`）

找到就把 `DEVELOPER_DIR` 设为该 App 的 `Contents/Developer`。也可以自己指定，或一次性改掉系统默认：

```bash
make open DEVELOPER_DIR=/Volumes/Data/Applications/Xcode.app/Contents/Developer

sudo xcode-select -s /Volumes/Data/Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

## Makefile

```bash
make open          # Debug 编译并打开
make build         # 只编译 Debug
make release       # Release
make test          # 前端测试 + AurewaysTests
make clean         # 删除 .derived
make web           # 只编 WebApp → Aureways/WebAppBundle
make web-test      # 只跑前端回归测试
```

产物：

```
.derived/Build/Products/Debug/Aureways.app
.derived/Build/Products/Release/Aureways.app
```

`make open` 若发现 `/Applications/Aureways.app` 已存在，会先换成这次编出来的包再打开。同一个 bundle id 只能有一个 Dock 图标；Applications 里的旧包会盖住 `.derived` 里的新图标。仍不刷新时执行 `killall Dock`。

`make build`、`make open`、`make test`、`make release` 会先编网页，再编客户端。`Aureways/WebAppBundle/` 不入库。改过 Swift 或 `WebApp/src` 后重新 `make open`。已打开的窗口不会热更新。

在 Xcode 里 `⌘R` 之前要先 `make web`。Xcode 不会跑 Makefile，目录空着就没有页面。

`make web` 在锁文件变化时执行 `npm ci`，页面源码变化时执行 `npm run build`（类型检查、Vite、体积报告）。锁文件在 `WebApp/package-lock.json`，不在仓库根。

`make open` 会 `lsregister` 刚编出来的包，Finder「打开方式」里才会出现 Aureways。双击 `.md` 仍走系统默认应用。要改成 Aureways，用设置里的「设为默认 Markdown 打开方式」，或：

```bash
open -a Aureways README.md
```

## Xcode

打开 `Aureways.xcodeproj`，scheme 选 **Aureways**，目的地 **My Mac**，`⌘R` 运行，`⌘U` 测试。签名是 Sign to Run Locally。

SwiftTerm 带 build tool 插件。命令行构建由 Makefile 加上 `-skipPackagePluginValidation -skipMacroValidation`。在 Xcode 里第一次构建时按提示允许插件。

SwiftTerm 的 Metal 着色器需要 Metal Toolchain。缺了会报 `cannot execute tool 'metal'`：

```bash
xcodebuild -downloadComponent MetalToolchain
```

## 页面

```bash
cd WebApp
npm ci
npm run dev     # 浏览器里的演示，没有原生桥
npm run build   # 写入 Aureways/WebAppBundle/；make web 还会按锁文件安装依赖
```

演示地址可以加 `?turns=8` 看长对话，`#settings` 看设置，`#menubar` 看菜单栏页。玻璃和输入框浮层要在编出来的 App 里看。

## 使用

1. 选一个工作区作为 Agent 的 `cwd`。
2. 选一个 PATH 上找得到的 Agent。
3. 发送后等会话变为就绪。失败时看错误条，点重试。
4. 登录在各 CLI 自己的工具里完成。

安装示例见仓库根的 README。

## 测试

`make test` 先构建 WebApp，并运行前端回归测试，再运行 AurewaysTests。原生测试包单独编译被测 Swift，不把应用当 TEST_HOST。

前端也可用 `make web-test` 或在 `WebApp/` 下执行 `npm test`（建议 Node 22+）。测试覆盖本地链接/标题锚点、三栏权重、标签移动与关闭，以及终端异步初始化和组件跨栏重挂载。终端绘制和 PTY 使用替身，不启动真实 shell；输出编译到临时目录，用 Node 内置测试器运行。

`.github/workflows/ci.yml` 在 PR 和 main 分支 push 时运行：Linux 验证前端测试与生产构建，macOS 验证 `make test`。两个工作流都固定使用 Node 22。

| 文件 | 覆盖 |
| --- | --- |
| `ProtocolTests.swift` | JSON-RPC、mock agent、sqlite、会话能力 |
| `ToolCallNormalizationTests.swift` | 各 Harness 的工具 JSON |
| `TerminalHostTests.swift` | Agent 侧 `terminal/create` 与 Grok 的 shell 改写 |
| `QuotaStoreTests.swift` | 限流与退避 |
| `HarnessQuotaTests.swift` | 额度响应解析 |
| `SessionTranscriptTests.swift` | 转录合并 |
| `MenuBarCommandTests.swift` | 菜单栏页的命令名，含 `quitApp` |
| `LocalizationTests.swift` | 文案键 |
| `MarkdownFileTests.swift` | Markdown 扩展名与读盘 |
| `TextDiffTests.swift` | diff |
| `GrokExtTests.swift` | 计划审批与选择题 |

这些测试不启动真实的 Codex、Claude 或 Grok 二进制。

## 连接失败

1. 在终端用同一条命令试，例如 `grok agent stdio`、`npx -y @agentclientprotocol/codex-acp`、`agy_acp_server`、`omp acp`。
2. GUI 的 PATH 不含 nvm。把可执行文件链到 `/opt/homebrew/bin` 或 `~/.local/bin`，或写绝对路径。
3. 在主区域开一个终端标签，看同一条命令的输出。
4. `initialize` 卡住时，确认对方 stdout 只有 NDJSON，横幅不要打到 stdout。

## 发版

`.github/workflows/release.yml` 只在推送 `v*` tag 时运行。Runner 是 `macos-26`，会选 `/Applications` 下版本最新的 Xcode，然后：

1. `make test`
2. `make release`
3. `diskutil image create` 生成 `Aureways-<tag>.dmg`，挂载后检查可执行文件和 Applications 快捷方式
4. 创建 GitHub Release，并保留 Actions artifact

产物 ad-hoc 签名，未公证。

## 版本

| 项 | 值 |
| --- | --- |
| Marketing version | 0.3.2（build 20） |
| Bundle ID | `ai.aureways.client` |
| 协议 | ACP v1 |
| 最低系统 | macOS 26 |
