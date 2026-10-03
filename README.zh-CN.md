<div align="center">

<img src="design/app-icon/logo_default_1024.png" width="128" height="128" alt="Aureways — A 轨道标志" />

# Aureways

**面向 Agentic Coding 的 macOS 桌面客户端。**

采用原生外壳 + 现代 Web 混合架构：窗口是无缝 macOS 原生 Shell，界面（侧边栏、对话流、输入框、检查器、设置）由高性能 Preact 应用承载于独立的 `WKWebView`。选定工作区，直接与本机安装的各类 CLI Agent 展开流式交互。

[![Release](https://github.com/nullskymc/Aureways/actions/workflows/release.yml/badge.svg)](https://github.com/nullskymc/Aureways/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg)](https://apple.com)

[English](README.md) · [文档中心](docs/README.md)

</div>

Aureways 完全实现 [Agent Client Protocol (ACP)](https://agentclientprotocol.com)，以子进程形式直接拉起本地命令行 Agent，通过标准输入输出（stdio NDJSON）双向通信。无需远程中间代理，不设独立 HTTP 守护进程，零网络遥测，完全本地运行。

---

## 核心亮点 (v0.3)

- **原生液态玻璃架构 (Liquid Glass Shell)**
  - 沉浸式无标题栏设计，红绿灯精确内嵌于侧边栏；深浅外观与系统实时同步（可在设置中自定）。
  - **双层 WebView 输入框浮层**：输入框作为第二层透明 WebView 悬浮于原生 `NSGlassEffectView`（Liquid Glass）之上，长对话流可优雅地从玻璃层下方滑动流过，兼备原生材质的光学质感与 Web 组件的高交互响应。
  - **常驻菜单栏模式**：关闭窗口或按下 `⌘Q` 仅收起窗口并保留在系统状态栏，随时点击或快捷键唤回；退出应用仅需点击菜单栏中的「退出」。

- **全能力 ACP 客户端与会话恢复**
  - 内置 9 家主流编码 Agent 支持，亦可在设置面板随时添加自定义 ACP 启动命令。
  - 会话依工作区隔离并持久化于本地 SQLite；Agent 声明 `session/load` 能力时可无缝跨会话与跨启动恢复。
  - 完整协议支持：自动合并工具调用（按 `toolCallId`）、流式更新、权限决策卡、计划审批模式（Plan Mode）、交互选择题等。

- **高性能流式对话流**
  - 基于虚拟窗口化列表（Virtual List）渲染海量上下文；DOMPurify 全面防御，Marked 语法解析，按需异步加载 Shiki 高亮。
  - 自动折叠与展开思维链过程（`<thinking>` 块）；底部智能吸附，流式更新不卡顿。

- **多模态与多功能输入框**
  - `Return` 快捷发送，`⇧Return` 换行；支持 `/` 快捷指令与 `@` 工作区文件极速补全。
  - 拖拽与剪贴板支持：图片附件自动缩放，超大文本自动转换为草稿卡片（Paste Card）发送。

- **全能集成式检查器 (Inspector · `⌥⌘I`)**
  - **工作区文件树与代码编辑器**：快速浏览目录文件，支持即时代码查看与编辑（`⌘S` 保存，基于 `mtime` 严格冲突校验）。
  - **变更审查 (Changes)**：全新重构的紧凑型变更文件清单，支持独立标签页查看双栏/单栏差异比对（Diff）。
  - **多标签终端 (Terminal · `⌃``` `)**：集成 xterm.js 并由原生无头 SwiftTerm PTY 实时驱动，每个终端与文件拥有独立 Tab。
  - **Markdown 阅读与系统关联 (`⌘O`)**：可设为 macOS 默认 Markdown 查看器，Finder 双击或 `open -a` 即可在检查器内秒开浏览。

- **解耦的独立额度监控系统 (QuotaStore)**
  - 全新独立的 `QuotaStore` 调度架构，与 ACP 会话生命周期彻底解耦。
  - 智能限流与退避：按供应商独立节流，支持磁盘持久化缓存，开箱即查。
  - 菜单栏托盘与设置用量页共享最新用量快照与额度重置倒计时。

---

## 界面示意

```
┌──────────────┬────────────────────────────────────────────┬──────────────┐
│ 侧边栏       │  顶栏：工作区 · 会话 · Agent                │ 检查器       │
│  • 新对话    │                                            │  • 文件树    │
│  • 工作区    ├────────────────────────────────────────────┤  • 编辑器    │
│    会话 ⌘1…9 │  对话流（栏宽 768px，虚拟窗口化流式渲染）  │  • 代码变更  │
│              │                                            │  • PTY 终端  │
│              ├────────────────────────────────────────────┤              │
│              │  液态玻璃浮层输入框（Return 发送，@ 补全） │              │
└──────────────┴────────────────────────────────────────────┴──────────────┘
```

## 内置 Agent 支持

| Agent | 默认启动命令 | 额度监控源 | 说明 |
| :--- | :--- | :--- | :--- |
| **Grok Build** | `grok agent stdio` | Billing API | xAI 官方编码 Agent |
| **Codex** | `npx -y @agentclientprotocol/codex-acp` | Usage API / 会话日志 | OpenAI 官方 ACP 桥接 |
| **Claude Code** | `npx -y @agentclientprotocol/claude-agent-acp` | OAuth 用量 (文件凭证) | Anthropic ACP 桥接 |
| **Antigravity** | `agy_acp_server` | Cloud Code 配额 | Google 官方 ACP 扩展服务 |
| **GitHub Copilot** | `copilot --acp --stdio` | — | GitHub 官方 CLI |
| **Cursor Agent** | `cursor-agent acp` | — | Cursor 官方 CLI |
| **OpenCode** | `opencode acp` | — | 开源 ACP Agent |
| **Oh My Pi** | `omp acp` | — | 基于 Bun 的 Agent，支持 `--yolo` |
| **Qoder** | `qoder --acp` / `qoderclicn --acp` | — | 自动识别国际版与国内版 CLI |

> **提示**：命令行需事先在终端安装并完成登录认证，各 Agent 的登录态与 API Key 由各家 CLI 独立管理。自定义 Agent 可随时在「设置 (`⌘,`)」中自由配置。

### 部分 Agent 快速配置指南

- **Oh My Pi**：需 Bun (`>= 1.3.14`)。安装：`bun install -g @oh-my-pi/pi-coding-agent`，运行 `omp` 登录。设置中开启「自动批准」将自动带上 `--yolo`。
- **Qoder**：同时适配国际版 (`qoder`，包名 `@qoder-ai/qodercli`) 与国内版 (`qoderclicn`，包名 `@qodercn-ai/qoderclicn`)。Aureways 会自动使用当前 `PATH` 中的可用程序。
- **Antigravity**：Google 官方 ACP 服务包提供独立的 `agy_acp_server.par`，请将其与 `localharness_external` 置于同级目录（例如 `~/.local/share/antigravity-acp`），并通过启动脚本软链至 PATH。初次连接使用 Google 账号完成 `oauth-personal` 认证。

---

## 快速上手

### 下载安装
前往 [Releases 页面](https://github.com/nullskymc/Aureways/releases) 下载最新版本的 `.dmg` 安装包，将 `Aureways.app` 拖入 `Applications` 目录即可。

> **Gatekeeper 提示**：社区版安装包使用 ad-hoc 签名。若首次打开时系统提示拦截，请在终端执行：
> ```bash
> xattr -dr com.apple.quarantine /Applications/Aureways.app
> ```

### 从源码编译构建
- **开发要求**：macOS 26+，Xcode 26+（推荐 Xcode 27+）。
- **零 Node 依赖**：前端产物 `Aureways/WebAppBundle/` 已随仓库预编译提交，拉取代码后无需配置 Node.js 环境即可直接构建原生 App。

在仓库根目录下运行：
```bash
# 编译并启动应用
make open

# 运行单元测试套件（160+ 项测试用例）
make test

# 构建 Release 正式版本
make release

# （可选）修改 WebApp/src 后重新编译打包 Web 资源
make web
```

若使用 Xcode 运行：直接双击打开 `Aureways.xcodeproj`，Scheme 选择 **Aureways**，Destination 选择 **My Mac**，按下 `⌘R` 即可。

---

## 常用快捷键

| 快捷键 | 功能 |
| :--- | :--- |
| `⌘N` | 新建对话 |
| `⌘O` | 打开 Markdown 文件并进入检查器 |
| `⌘1` … `⌘9` | 快速切换会话 |
| `⌃⌘S` | 显示 / 隐藏左侧栏 |
| `⌥⌘I` | 显示 / 隐藏右侧检查器 |
| `⇧⌘E` | 检查器：切换至文件树 |
| `⇧⌘G` | 检查器：切换至 Git 变更审查 |
| `⌃``` ` | 检查器：新建集成 PTY 终端 |
| `⌘F` | 在页面中查找 |
| `⌘,` | 打开偏好设置 |
| `Return` | 发送消息 |
| `⇧Return` | 消息换行 |
| `⌘.` | 终止 Agent 回答生成 |
| `⌘Q` | 关闭主窗口（应用常驻系统菜单栏） |
| 输入框内输入 `/` | 唤出斜杠指令菜单 |
| 输入框内输入 `@` | 唤出工作区文件引用选择器 |

---

## 工程文档

深入技术文档请参阅 `docs/` 目录：

| 文档 | 内容说明 |
| :--- | :--- |
| [文档导航 (README.md)](docs/README.md) | 总体技术文档索引与推荐阅读顺序 |
| [目录架构 (directory.md)](docs/directory.md) | 仓库源码树、物理分层与职责梳理 |
| [系统架构 (architecture.md)](docs/architecture.md) | 原生外壳、Web UI 与 ACP 协议栈分层设计 |
| [Web Shell (web-shell.md)](docs/web-shell.md) | 窗口、双层玻璃层与 JS-Native 桥接细节 |
| [前端实现 (frontend.md)](docs/frontend.md) | Preact 状态流、虚拟滚动与界面组件 |
| [后端服务 (backend.md)](docs/backend.md) | 子进程管理、PTY 终端、文件系统与 QuotaStore |
| [协议规范 (protocol.md)](docs/protocol.md) | 客户端实现的 ACP 方法与扩展定义 |
| [开发指南 (development.md)](docs/development.md) | 工具链调优、自动化测试与连接调试技巧 |

---

## 发布与发版

只有推送形如 `v*` 的 Git Tag 时才会触发 GitHub Actions 持续集成与打包发布：

```bash
git tag v0.3.0
git push origin v0.3.0
```

自动化流水线将自动运行 `make test` 全量验证，执行 Release 构建并封装生成 `Aureways-v0.3.0.dmg`，同步发布至 GitHub Releases。

---

## 开源协议

本项目基于 [MIT 协议](LICENSE) 开源。
