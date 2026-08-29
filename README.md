# Aureways

面向 [Agent Client Protocol (ACP)](https://agentclientprotocol.com) 的原生 macOS 客户端。它作为 **ACP Client** 启动本机 harness（Grok Build、Codex、Claude Code 等），用 JSON-RPC stdio 交换消息，并把会话流画到 SwiftUI 界面上。

本仓库是单进程桌面应用：**前端是 SwiftUI，后端是同进程内的 ACP 连接层**，没有单独的 HTTP 服务。

完整说明见 [`docs/`](docs/README.md)。

## 文档

| 文档 | 内容 |
| --- | --- |
| [文档目录](docs/README.md) | 文档索引 |
| [目录结构](docs/directory.md) | 仓库与源码树 |
| [架构](docs/architecture.md) | 前后端职责、数据流 |
| [前端](docs/frontend.md) | SwiftUI 界面与状态 |
| [后端](docs/backend.md) | ACP 连接、进程、文件系统、终端 |
| [协议](docs/protocol.md) | 已实现的 ACP 方法 |
| [开发与运行](docs/development.md) | Xcode / `make open` / 测试 |

## 内置 Harness

| 名称 | 启动命令 |
| --- | --- |
| Grok Build | `grok agent stdio` |
| Codex | `npx -y @agentclientprotocol/codex-acp` |
| Claude Code | `npx -y @agentclientprotocol/claude-agent-acp` |
| Gemini CLI | `gemini --acp` |
| GitHub Copilot | `copilot --acp --stdio` |
| Cursor Agent | `cursor-agent acp` |
| OpenCode | `opencode acp` |

侧边栏可添加任意自定义 stdio ACP 命令。对应 CLI 需事先安装并完成登录。

## 快速开始

在**仓库根目录**（能看到 `Makefile` 和 `Aureways.xcodeproj` 的那一层，不是内层 `Aureways/` 源码目录）：

```bash
cd /path/to/Aureways
make open
```

或：

```bash
open Aureways.xcodeproj
```

在 Xcode 中选 scheme **Aureways**、目的地 **My Mac**，按 `Cmd + R`。

要求：macOS 14.4+，Xcode 15+（本仓库用 Xcode 27 开发）。应用未开启 App Sandbox。默认使用当前 `xcode-select` 工具链；若要用某个 Xcode.app：

```bash
make open DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

## License

MIT. See [LICENSE](LICENSE).
