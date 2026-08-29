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

本仓库用 **Xcode 27** 开发，但 `Makefile` 不钉死 beta 路径，默认走 `xcode-select -p`。需要指定某个 Xcode 时覆盖：

```bash
make open DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
make open DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

系统许可未同意时：

```bash
sudo xcodebuild -license
```

## 用 Makefile

```bash
cd /path/to/Aureways          # 仓库根

make open                     # 编译 Debug 并打开 .app
make build                    # 只编译
make test                     # 跑 AurewaysTests
make clean                    # 删除 .derived
```

产物：

```
.derived/Build/Products/Debug/Aureways.app
```

只打开已编译包：

```bash
open .derived/Build/Products/Debug/Aureways.app
```

改过代码必须重新 `make open` 或 Xcode Run，已打开的窗口不会热更新。

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

## 使用应用

1. 工具栏选 workspace（agent 的 `cwd`）
2. 侧栏绿点 harness 可点；灰点 = 启动器不在 PATH
3. 等状态条变为就绪再输入
4. 失败时看状态条原文，点 Retry；或打开右侧日志看 stderr

Harness 要自己安装并登录，例如：

- Grok Build：`grok` 在 PATH 且已 auth
- Codex / Claude：Node.js + `npx`，以及各自 CLI 登录

## 测试

测试 target **不**把 `.app` 当 TEST_HOST（SwiftUI 宿主会挂起）。它单独编译 ACP 源文件 + `ProtocolTests.swift`。

```bash
make test
```

## 调试连接失败

1. 终端确认同一条命令能跑，例如 `grok agent stdio`、`npx -y @agentclientprotocol/codex-acp`
2. GUI PATH 不含 nvm：把 `node`/`npx` 链到 `/opt/homebrew/bin`，或自定义 agent 填绝对路径
3. 打开 Inspector 看 agent stderr
4. `initialize` 卡死：确认对方 stdout 只有 NDJSON，没有横幅日志

## 版本与标识

| 项 | 值 |
| --- | --- |
| Marketing version | 0.1.0 |
| Bundle ID | `ai.aureways.client` |
| 协议 | ACP v1 |
| 最低系统 | macOS 14.4 |
