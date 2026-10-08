<div align="center">

<img src="design/app-icon/logo_default_1024.png" width="128" height="128" alt="Aureways — A-orbit mark" />

# Aureways

**A macOS client for agentic coding.**

Built with a hybrid native shell and web architecture: the window is a seamless macOS native shell, while the interface inside (sidebar, chat and file tabs, composer, settings) is an ultra-fast Preact application hosted in a dedicated `WKWebView`. Choose a workspace and engage in real-time streaming conversations with any local CLI agent installed on your Mac.

[![Release](https://github.com/nullskymc/Aureways/actions/workflows/release.yml/badge.svg)](https://github.com/nullskymc/Aureways/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg)](https://apple.com)

[中文说明](README.zh-CN.md) · [Documentation](docs/README.md)

</div>

Aureways fully implements the [Agent Client Protocol (ACP)](https://agentclientprotocol.com). It spawns local CLI agents as child processes and communicates over standard I/O via bidirectional NDJSON. There is no remote backend, no separate HTTP daemon, and zero telemetry—running entirely locally on your Mac.

---

## Key Highlights (v0.3)

- **Liquid Glass Hybrid Shell**
  - Immersive frameless window design with traffic lights inset into the glass sidebar; appearance follows system light/dark mode (or custom override).
  - **Dual-Layer Glass Composer Overlay**: The composer is mounted as a second transparent `WKWebView` placed directly above native system Liquid Glass (`NSGlassEffectView`). Streaming transcripts scroll smoothly underneath the glass with genuine macOS optical vibrancy.
  - **Persistent Menu Bar Resident**: Closing the window or pressing `⌘Q` keeps the process alive in the macOS status menu bar for instant summon; quitting the app is handled cleanly via the menu bar's "Quit".

- **Full-Featured ACP Client & Session Continuity**
  - Ten built-in agent harnesses, plus the ability to configure arbitrary custom ACP agents in Settings.
  - Sessions are categorized by workspace and persisted in local SQLite; agents declaring `session/load` automatically restore previous conversations across app restarts.
  - Comprehensive protocol conformance: tool call coalescing by `toolCallId`, streaming updates, permission prompts, plan approval workflows, and multiple-choice user questions.

- **High-Performance Streaming Transcript**
  - Virtualized windowed listing for large conversation histories.
  - DOMPurify sanitization, Marked parsing, and on-demand asynchronous syntax highlighting with Shiki.
  - Collapsible `<thinking>` blocks and intelligent pinned scroll behavior.

- **Multimodal Composer**
  - `Return` to send, `Shift+Return` for a new line; fast autocompletion for `/` slash commands and `@` workspace files.
  - Drag-and-drop & clipboard support: automatic image attachment optimization and oversized text paste cards.

- **Main-area tabs**
  - **Chat, changes, files, and terminals share the center tabs**, up to three columns. The file tree stays on the right once a session is open; `⌥⌘I` shows or hides it. Markdown opened outside the current workspace is kept in Documents, a row under the workspace list.
  - **Workspace file tree and editor**: browse the tree, edit in place, `⌘S` to save, with `mtime` conflict checks.
  - **Changes**: a compact list, with diffs in their own tabs.
  - **Terminals (`⌃``` `)**: xterm.js, driven by a native headless PTY.
  - **Markdown (`⌘O`)**: can be the default Markdown app. A file inside the current workspace opens there. Anything outside is kept in Documents. The tab has an outline, local images, and links between documents. A window that is already visible is not moved onto the file's screen.

- **Decoupled Quota Monitoring (`QuotaStore`)**
  - Independent `QuotaStore` architecture completely isolated from ACP session lifecycles.
  - Smart per-vendor throttling, exponential backoff, and local disk caching.
  - Live quota snapshots and reset countdowns synchronized across the Menu Bar and Settings page.

---

## Interface Layout

```
┌──────────────┬──────────────────────────────────────────────────────────┐
│ Sidebar      │  Tabs: Chat · Files · Changes · open files · Terminals   │
│  • New chat  ├──────────────────────────────────────────────────────────┤
│  • Workspace │  Active tab (chat column 768px, virtualized stream)      │
│    sessions  │  Markdown tabs include an outline                        │
│    ⌘1 … ⌘9   ├──────────────────────────────────────────────────────────┤
│              │  Liquid Glass composer, on the Chat tab                  │
└──────────────┴──────────────────────────────────────────────────────────┘
```

## Built-in Agents

| Agent | Default Launch Command | Quota Source | Description |
| :--- | :--- | :--- | :--- |
| **Grok Build** | `grok agent stdio` | Billing API | xAI official coding agent |
| **Codex** | `npx -y @agentclientprotocol/codex-acp` | Usage API / session logs | OpenAI official ACP bridge |
| **Claude Code** | `npx -y @agentclientprotocol/claude-agent-acp` | OAuth usage (file credentials) | Anthropic ACP bridge |
| **Antigravity** | `agy_acp_server` | Cloud Code quota | Google official ACP extension |
| **GitHub Copilot** | `copilot --acp --stdio` | — | GitHub official CLI |
| **Cursor Agent** | `cursor-agent acp` | — | Cursor official CLI |
| **OpenCode** | `opencode acp` | — | Open-source ACP agent |
| **Oh My Pi** | `omp acp` | — | Bun-based agent supporting `--yolo` |
| **Qoder** | `qoder --acp` / `qoderclicn --acp` | — | Auto-detects global and CN CLIs |
| **Hermes** | `hermes acp` (fallback `hermes-acp`) | — | Nous Research; model and approval are session settings |

> **Note**: Each CLI tool must be installed and signed in via its vendor CLI beforehand. Credentials and API keys are managed by each tool independently. Custom agents can be configured in Settings (`⌘,`).

### Agent Setup Tips

- **Oh My Pi**: Requires Bun (`>= 1.3.14`). Install: `bun install -g @oh-my-pi/pi-coding-agent`, authenticate via `omp`. Enabling auto-approve in Settings launches `omp acp --yolo`.
- **Qoder**: Supports both the international CLI (`qoder`, package `@qoder-ai/qodercli`) and mainland China CLI (`qoderclicn`, package `@qodercn-ai/qoderclicn`). Aureways will pick whichever binary is present on `PATH`.
- **Hermes**: Requires Hermes Agent (`hermes` or `hermes-acp` on `PATH`; `~/.local/bin` is already searched). Configure the provider and model with `hermes setup` / `hermes model`. Auto-approve answers permission prompts and does not pass `--yolo` or `--accept-hooks`. Edit approval is the session mode (`Default` / `Accept Edits` / `Don't Ask`).
- **Antigravity**: Google's ACP release provides `agy_acp_server.par`. Place it in a directory together with `localharness_external` (e.g. `~/.local/share/antigravity-acp`), and create a launcher script on `PATH`. Initial connect authenticates via Google `oauth-personal`.

---

## Getting Started

### Installation
Download the latest `.dmg` installer from [Releases](https://github.com/nullskymc/Aureways/releases), and drag `Aureways.app` into your `Applications` folder.

> **Gatekeeper Notice**: The binary is ad-hoc signed. If macOS Gatekeeper blocks opening on first launch, run:
> ```bash
> xattr -dr com.apple.quarantine /Applications/Aureways.app
> ```

### Building from Source
- **Requirements**: macOS 26+, Xcode 26+ (Xcode 27+ recommended), and Node.js to compile the window UI.

Run from the repository root:
```bash
# Build and launch Aureways.app
make open

# Run full unit test suite (160+ unit tests)
make test

# Compile release build
make release

# Rebuild only the web UI (build / open / test / release do this first)
make web
```

`make` compiles `WebApp/` into `Aureways/WebAppBundle/` before the native app. That directory is build output and is not committed. Dependencies install only when `package-lock.json` changes.

To run from Xcode, run `make web` once at the repo root first, then open `Aureways.xcodeproj`, select scheme **Aureways** and destination **My Mac**, and press `⌘R`. After editing `WebApp/src`, run `make web` again. Xcode does not build the web app.

---

## Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `⌘N` | New chat session |
| `⌘O` | Open Markdown as a main-area tab |
| `⌘1` … `⌘9` | Select recent session |
| `⌃⌘S` | Toggle sidebar |
| `⌥⌘I` | Show or hide the file tree |
| `⌘\` | Move the current file, diff, or terminal into the column on the right |
| `⇧⌘E` | Show the file tree and focus its filter |
| `⇧⌘G` | Show the Changes tab |
| `⌃``` ` | New terminal tab |
| `⌘F` | Find in page |
| `⌘,` | Settings |
| `Return` | Send message |
| `⇧Return` | Insert line break |
| `⌘.` | Cancel agent generation |
| `⌘Q` | Close window (keep process in menu bar) |
| `/` in composer | Trigger slash command menu |
| `@` in composer | Trigger workspace file mention menu |

---

## Technical Documentation

Detailed architectural and developer guides are available in `docs/`:

| Guide | Description |
| :--- | :--- |
| [Documentation Index (README.md)](docs/README.md) | Reading order and overview of system documentation |
| [Directory Architecture (directory.md)](docs/directory.md) | Source tree organization and component responsibilities |
| [Architecture (architecture.md)](docs/architecture.md) | Native shell, Web UI, and ACP protocol layering |
| [Web Shell (web-shell.md)](docs/web-shell.md) | Native window, dual glass views, and bridge protocol |
| [Frontend (frontend.md)](docs/frontend.md) | Preact state management, virtual list, and UI components |
| [Backend Services (backend.md)](docs/backend.md) | Process spawning, SwiftTerm PTYs, filesystem, and QuotaStore |
| [Protocol Specification (protocol.md)](docs/protocol.md) | ACP client implementation and extension catalog |
| [Development Guide (development.md)](docs/development.md) | Build toolchain, test runner, and troubleshooting |

---

## Releases

Releases are triggered by pushing a Git tag matching `v*`:

```bash
git tag v0.3.2
git push origin v0.3.2
```

The GitHub Actions workflow executes `make test`, builds the Release package, bundles `Aureways-v0.3.2.dmg`, and publishes a GitHub Release.

---

## License

This project is licensed under the [MIT License](LICENSE).
