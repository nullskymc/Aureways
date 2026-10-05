# Aureways 文档

Aureways 是 ACP 的 macOS 客户端。SwiftUI 只提供窗口和菜单栏。窗口里的界面是一个 Preact 应用，跑在 `WKWebView` 中。同进程的 `ACPConnection` 拉起本机 harness，收发 JSON-RPC。

```
用户 ──► Preact（WKWebView）──► WebShellBridge ──► AppModel
                                                      │
                                                      ▼
                                            ACPConnection（actor）
                                                      │
                                                      ▼
                                            harness 子进程（stdio）
```

| 文档 | 说明 |
| --- | --- |
| [directory.md](directory.md) | 仓库目录、Xcode target、生成物 |
| [architecture.md](architecture.md) | 分层、一次会话、持久化 |
| [web-shell.md](web-shell.md) | 窗口壳、Liquid Glass、输入框浮层、Swift ↔ JS |
| [frontend.md](frontend.md) | 侧栏、对话、输入框、检查器、设置、菜单栏 |
| [backend.md](backend.md) | 进程、PATH、文件、两套终端、额度 |
| [protocol.md](protocol.md) | 实现了哪些 ACP 方法、各家偏差 |
| [development.md](development.md) | 编译、Web 包、测试、连接失败 |
| [brand/app-icon.md](brand/app-icon.md) | A 轨道标志的图形规范 |
| [vision.md](vision.md) | 还没做的远期设想：远端机器、离机控制 |

阅读顺序：目录 → 架构 → Web shell → 前端 / 后端 → 协议 → 开发。改界面先看 [frontend.md](frontend.md) 和 [web-shell.md](web-shell.md)。改协议兼容先看 [protocol.md](protocol.md)。图标出稿看品牌规范。

版本：0.3.2（build 20）。最低系统 macOS 26。Bundle ID `ai.aureways.client`。
