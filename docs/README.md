# Aureways 文档

Aureways 是 ACP 协议的 macOS 客户端雏形：SwiftUI 负责界面，同进程的 `ACPConnection` 负责拉起 harness、收发 JSON-RPC。

```
用户 ──► SwiftUI（前端） ──► AppModel ──► ACPConnection（后端）
                                              │
                                              ▼
                                    harness 子进程（stdio）
                                    Grok / Codex / Claude Code / …
```

| 文档 | 说明 |
| --- | --- |
| [directory.md](directory.md) | 仓库目录、Xcode target、生成物 |
| [architecture.md](architecture.md) | 分层、会话生命周期、状态 |
| [frontend.md](frontend.md) | 窗口、侧栏、会话区、权限、设置 |
| [backend.md](backend.md) | 进程启动、PATH、JSON-RPC、fs/terminal |
| [protocol.md](protocol.md) | 实现了哪些 ACP 方法、尚未做的 |
| [development.md](development.md) | 编译、运行、测试、常见路径错误 |
| [brand/app-icon.md](brand/app-icon.md) | A 轨道标志、App Icon 分层与交付 |

阅读顺序建议：目录 → 架构 → 前端 / 后端 → 协议 → 开发。图标出稿看品牌规范。
