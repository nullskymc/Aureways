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
| [protocol-latency.md](protocol-latency.md) | 协议交互延时排查：链路、候选点、测量缺口 |
| [performance-plan.md](performance-plan.md) | 性能问题计划：任务清单、分期、验收标准 |
| [development.md](development.md) | 编译、运行、测试、常见路径错误 |
| [brand/app-icon.md](brand/app-icon.md) | A 轨道标志、App Icon 分层与交付 |
| [vision.md](vision.md) | 远期目标与愿景：远端开发机 Agent、移动端伴侣与跨跳控制链 |

阅读顺序建议：目录 → 架构 → 前端 / 后端 → 协议 → 开发。图标出稿看品牌规范。要动性能，先读 [protocol-latency.md](protocol-latency.md) 的事实，再按 [performance-plan.md](performance-plan.md) 执行。探索后续可能的功能演进看 [vision.md](vision.md)。
