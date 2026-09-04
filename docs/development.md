# 开发与运行

## 工作目录

必须在**仓库根**执行命令（能 `ls Makefile Aureways.xcodeproj`）。

```
…/Aureways/                 ← 在这里 make / open xcodeproj
├── Makefile
├── Aureways.xcodeproj
└── Aureways/               ← 源码，这里没有 Makefile
```

提示符若是 `…/Aureways/Aureways`，先 `cd ..`。在内层跑 `make open` 会得到 `No rule to make target 'open'`。

## 工具链

本仓库用 **Xcode 27** 开发。`make` 默认走 `xcode-select -p`。若该路径仍是 **Command Line Tools**（`/Library/Developer/CommandLineTools`），`xcodebuild` 会报：

```
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance
```

这不代表没装 Xcode。CLT 和完整 Xcode.app 是两套工具链；只装过 `xcode-select --install` 或装完 Xcode 没切过去，就会这样。本机若有 `/Applications/Xcode.app` 或 `Xcode-beta.app`，`Makefile` 会自动改用那个。也可一次切到系统默认：

```bash
sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer
sudo xcodebuild -license accept   # 若尚未同意许可
```

需要指定某个 Xcode 时覆盖：

```bash
make open DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
make open DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## 用 Makefile

```bash
cd /path/to/Aureways          # 仓库根

make open                     # 编译 Debug 并打开 .app
make build                    # 只编译（Debug）
make release                  # Release 构建（CI 发版用）
make test                     # 跑 AurewaysTests
make clean                    # 删除 .derived
```

产物：

```
.derived/Build/Products/Debug/Aureways.app     # make open
.derived/Build/Products/Release/Aureways.app   # make release
```

只打开已编译包：

```bash
open .derived/Build/Products/Debug/Aureways.app
```

改过代码必须重新 `make open` 或 Xcode Run，已打开的窗口不会热更新。

### Dock 仍是空图标

同一 bundle id `ai.aureways.client` 只能有一个「官方」图标。若 `/Applications/Aureways.app` 是更早、没有 App Icon 的包，Launch Services 会用它的空白占位，即使刚 `make open` 的 `.derived` 包图标是对的。`make open` 发现 Applications 里已有同名包时会先换上这次编出来的包再打开。仍不刷新时：

```bash
killall Dock
```

## 用 Xcode

```bash
open Aureways.xcodeproj
```

若弹出选择 Xcode，选本机已安装的 Xcode（开发时用过 Xcode-beta）。

1. 顶部 scheme：**Aureways**
2. 目的地：**My Mac**
3. `Cmd + R` 运行，`Cmd + U` 测试
4. 停掉用 `Cmd + .`

签名是 “Sign to Run Locally”，仅本机调试。

## Swift 包

| 包 | 用途 |
| --- | --- |
| [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) 2.4.1 | Agent 正文 Markdown 渲染 |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 右侧面板交互终端（真实 PTY + 终端模拟） |

版本锁在 `Aureways.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。命令行第一次编译会拉 `swift-markdown-ui`、`cmark-gfm`、`NetworkImage`、`SwiftTerm` 及其传递依赖。

两个命令行构建的坑（Makefile 已处理第一个）：

- **SwiftTerm 带 build tool 插件**（生成构建信息），`xcodebuild` 默认要交互式确认。Makefile 统一加了 `-skipPackagePluginValidation`；在 Xcode IDE 里首次构建按提示允许即可。
- **SwiftTerm 的 Metal 渲染着色器**需要 Metal Toolchain。Xcode beta 默认不带，首次报 `cannot execute tool 'metal' due to missing Metal Toolchain` 时执行一次：

```bash
xcodebuild -downloadComponent MetalToolchain
```

## 使用应用

1. 工具栏选 workspace（agent 的 `cwd`）
2. 侧栏绿点 harness 可点；灰点 = 启动器不在 PATH
3. 等状态条变为就绪再输入
4. 失败时看状态条原文，点 Retry；stderr 仍在会话 `logs` 里记录，但暂不提供面板展示

Harness 要自己安装并登录，例如：

- Grok Build：`grok` 在 PATH 且已 auth
- Codex / Claude：Node.js + `npx`，以及各自 CLI 登录
- Antigravity：`agy`（或 `npx`，走 `agy-acp`）。Gemini CLI 已停维，不再作为内置项

## 测试

测试 target **不**把 `.app` 当 TEST_HOST（SwiftUI 宿主会挂起）。它单独编译 ACP / Harness 源文件 + `ProtocolTests.swift`。

```bash
make test
```

## 调试连接失败

1. 终端确认同一条命令能跑，例如 `grok agent stdio`、`npx -y @agentclientprotocol/codex-acp`、`agy --acp`
2. GUI PATH 不含 nvm：把 `node`/`npx` 链到 `/opt/homebrew/bin`，或自定义 agent 填绝对路径
3. 右侧面板开一个交互终端，直接复现命令看输出
4. `initialize` 卡死：确认对方 stdout 只有 NDJSON，没有横幅日志

## CI 与发版

工作流：`.github/workflows/release.yml`。**约定只有打 tag 才构建**——分支 push 与 PR 不触发。

```bash
git tag v0.2.0
git push origin v0.2.0
```

Runner（`macos-26`）上自动选取最新 Xcode，然后：

1. `make test`（失败即中止发版）
2. `make release`（Release 构建）
3. `diskutil image create from` 生成 `Aureways-<tag>.dmg`（含 `/Applications` 快捷方式，挂载自检 app 可执行文件与快捷方式，产物异常即中止发版）
4. 创建 GitHub Release 附产物，并保留 Actions artifact

产物为 ad-hoc 签名（`CODE_SIGN_IDENTITY = "-"`），未经 Apple 公证；他人下载后首次打开可能需要 `xattr -dr com.apple.quarantine`。

## 版本与标识

| 项 | 值 |
| --- | --- |
| Marketing version | 0.1.1 |
| Bundle ID | `ai.aureways.client` |
| 协议 | ACP v1 |
| 最低系统 | macOS 26 |
