<div align="center">

<img src="design/app-icon/logo_default_1024.png" width="128" height="128" alt="Aureways — A 轨道标志" />

# Aureways

**面向 agentic coding 的 macOS 客户端。** 窗口是原生壳。侧栏、对话、输入框、检查器、设置都在同一个 `WKWebView` 里，由 Preact 绘制。选定工作区，和本机已经安装的 Agent 对话。

[![Release](https://github.com/nullskymc/Aureways/actions/workflows/release.yml/badge.svg)](https://github.com/nullskymc/Aureways/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) · [文档目录](docs/README.md)

</div>

它实现 [Agent Client Protocol](https://agentclientprotocol.com)，把本机命令行 Agent 作为子进程拉起，走 stdio NDJSON。没有远程后端，也没有单独的 HTTP 服务。

会话打开后，输入框是叠在系统 Liquid Glass 上的第二个透明 WebView，对话可以在玻璃下面滚过。玻璃只用 `NSGlassEffectView`。

## 能做什么

- **窗口壳**：隐藏标题栏，红绿灯嵌进侧栏，浅色 / 深色跟随系统（可在设置里覆盖）。关窗口或按 `⌘Q` 只收到菜单栏，进程还在。真正退出是菜单栏里的「退出」。
- **任意 ACP Agent**：内置九家，也可以在设置里添加启动命令。会话按工作区排列；Agent 声明 `session/load` 时，下次启动可以恢复。
- **流式对话**：Markdown（marked、DOMPurify、按需加载的 Shiki）、可折叠的思考、按 `toolCallId` 合并的工具行、计划步骤。列表按窗口绘制。停在底部时，最后一行在输入框上方。
- **输入框**：Return 发送，Shift+Return 换行。支持 `/` 命令、`@` 工作区文件、图片和文件附件。权限、计划审批、选择题出现在输入框上方。
- **检查器**（`⌥⌘I`）：文件树、文本编辑器（`⌘S`，按 mtime 检查冲突）、Git 变更、交互终端。终端是 xterm.js，背后是无界面的 SwiftTerm PTY。每个文件和终端各占一个标签。
- **Markdown**：Finder、Dock、`open -a` 和「文件 → 打开 Markdown」（`⌘O`）会在检查器里打开 `.md`。要双击打开，在设置里把 Aureways 设为默认 Markdown 应用。
- **用量**：账号额度由单独的 `QuotaStore` 缓存并限流读取，不从 ACP 会话里算。设置里的用量页和菜单栏看的是同一份快照。

```
┌──────────────┬────────────────────────────────────────────┬──────────────┐
│ 侧栏          │  顶栏：工作区 · 会话 · Agent               │ 检查器        │
│  • 新对话     │                                            │  • 文件      │
│  • 工作区      ├────────────────────────────────────────────┤  • 编辑器    │
│    会话 ⌘1…⌘9 │  对话流（栏宽 768px，流式）                │  • 变更      │
│               │                                            │  • 终端      │
│               ├────────────────────────────────────────────┤              │
│               │  玻璃输入框（Return 发送）                 │              │
└──────────────┴────────────────────────────────────────────┴──────────────┘
```

## 内置 Agent

| 名称 | 启动命令 |
| --- | --- |
| Grok Build | `grok agent stdio` |
| Codex | `npx -y @agentclientprotocol/codex-acp` |
| Claude Code | `npx -y @agentclientprotocol/claude-agent-acp` |
| Antigravity | `agy_acp_server`（Google 官方 ACP zip，不是 `agy --acp`） |
| GitHub Copilot | `copilot --acp --stdio` |
| Cursor Agent | `cursor-agent acp` |
| OpenCode | `opencode acp` |
| Oh My Pi | `omp acp` |
| Qoder | `qoder --acp` / `qoderclicn --acp` |

对应命令行需事先安装并完成登录。登录和密钥由各 Agent 自己的 CLI 管理。自定义 Agent 在设置（`⌘,`）里添加。

Oh My Pi 依赖 Bun（`>= 1.3.14`）。安装：`bun install -g @oh-my-pi/pi-coding-agent`，登录在 `omp` 里完成。自动批准会启动 `omp acp --yolo`。

Qoder 同时支持国际版（`qoder`，包 `@qoder-ai/qodercli`）与国内版（`qoderclicn`，包 `@qodercn-ai/qoderclicn`）。Aureways 使用 PATH 上已有的那个二进制。登录分别在 `qoder login` 或 `qoderclicn login` 中完成。自动批准会加上 `--yolo`。

Antigravity 的 `agy` CLI 没有 `--acp`。Google 另发一个 ACP 包：`agy_acp_server.par` 和 `localharness_external` 必须放在同一目录。Apple Silicon：

```bash
mkdir -p ~/.local/share/antigravity-acp ~/.local/bin
curl -fsSL -o /tmp/agy-acp.zip \
  https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-agy_acp_server_1.1.1-darwin-arm64.zip
unzip -o /tmp/agy-acp.zip -d ~/.local/share/antigravity-acp
chmod +x ~/.local/share/antigravity-acp/agy_acp_server.par \
         ~/.local/share/antigravity-acp/localharness_external
cat > ~/.local/bin/agy_acp_server <<'EOF'
#!/bin/sh
exec "$HOME/.local/share/antigravity-acp/agy_acp_server.par" "$@"
EOF
chmod +x ~/.local/bin/agy_acp_server
```

不要只把 `.par` 软链到 `PATH`——进程会在可执行文件旁边找 `localharness_external`。首次连接走 Google 登录（`oauth-personal`）。可用 `AGY_ACP_BIN` 指定二进制路径。

额度读取器：Grok（billing API）、Codex（用量 API，失败再读本地会话日志）、Claude（OAuth 用量，只认文件里的凭据）、Antigravity（Cloud Code）。macOS 上 Claude 的令牌通常在钥匙串里；Aureways 不读钥匙串，这时会显示未配置。Copilot、Cursor、OpenCode、Oh My Pi、Qoder 没有额度源。

## 运行

**安装**——从 [Releases](https://github.com/nullskymc/Aureways/releases) 下载 `.dmg`，把 `Aureways.app` 拖进 `Applications`。产物是 ad-hoc 签名、未经公证。首次启动若被 Gatekeeper 拦截：

```bash
xattr -dr com.apple.quarantine /Applications/Aureways.app
```

**源码编译**——macOS 26+、Xcode 26+（本仓库用 Xcode 27 开发）。应用未开启 App Sandbox。在**仓库根目录**操作（能看到 `Makefile` 和 `Aureways.xcodeproj` 的那一层）：

```bash
make open
```

或打开 `Aureways.xcodeproj`，选 scheme **Aureways**、目的地 **My Mac**，按 `⌘R`。

`make` 使用 `xcode-select -p`。若该路径仍是 Command Line Tools，会按这个顺序找完整 Xcode：`/Applications/Xcode.app`、`/Applications/Xcode-beta.app`、`/Volumes/app/Applications/Xcode.app`、`/Volumes/app/Applications/Xcode-beta.app`，最后再用 Spotlight。指定某一个：

```bash
make open DEVELOPER_DIR=/Volumes/app/Applications/Xcode.app/Contents/Developer
```

| 命令 | 作用 |
| --- | --- |
| `make build` | Debug 编译 |
| `make open` | 编译并打开 `.app` |
| `make test` | 跑 `AurewaysTests` |
| `make release` | Release 构建 |
| `make clean` | 删除 `.derived` |
| `make web` | 把 `WebApp/` 重新打进 `Aureways/WebAppBundle/` |

Web 产物已提交，编 App 不需要 Node。只有改了 `WebApp/src` 才跑 `make web`。首次命令行构建若提示缺少 Metal 工具链：

```bash
xcodebuild -downloadComponent MetalToolchain
```

## 快捷键

| 按键 | 作用 |
| --- | --- |
| `⌘N` | 新对话 |
| `⌘O` | 打开 Markdown |
| `⌘1` … `⌘9` | 选择会话 |
| `⌃⌘S` | 切换侧栏 |
| `⌥⌘I` | 切换检查器 |
| `⇧⌘E` | 检查器：文件 |
| `⇧⌘G` | 检查器：变更 |
| `⌃\`` | 新建终端 |
| `⌘F` | 查找 |
| `⌘,` | 设置 |
| `Return` | 发送 |
| `⇧Return` | 换行 |
| `⌘.` | 停止生成 |
| `⌘Q` | 关闭窗口，留在菜单栏 |
| 输入框 `/` | Slash 命令 |
| 输入框 `@` | 引用工作区文件 |

## 文档

| 文档 | 内容 |
| --- | --- |
| [文档目录](docs/README.md) | 索引与阅读顺序 |
| [目录结构](docs/directory.md) | 仓库与源码树 |
| [架构](docs/architecture.md) | 窗口壳、Web 界面、ACP |
| [Web shell](docs/web-shell.md) | 窗口、玻璃、桥 |
| [前端](docs/frontend.md) | Preact 界面 |
| [后端](docs/backend.md) | 进程、文件、终端、额度 |
| [协议](docs/protocol.md) | 本客户端实现的 ACP 方法 |
| [开发与运行](docs/development.md) | 工具链、测试、连接失败 |

## 发版

只有打 `v*` tag 才触发 CI，分支和 PR 不构建。工作流见 [`.github/workflows/release.yml`](.github/workflows/release.yml)。

```bash
git tag v0.2.0
git push origin v0.2.0
```

流程：`make test` → Release 构建 → 打包 `Aureways-<tag>.dmg` → 创建 GitHub Release。

## License

MIT。见 [LICENSE](LICENSE)。
