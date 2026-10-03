<div align="center">

<img src="design/app-icon/logo_default_1024.png" width="128" height="128" alt="Aureways — A-orbit mark" />

# Aureways

**A macOS client for agentic coding.** The window is a native shell. The interface inside it — sidebar, transcript, composer, inspector, settings — is one Preact app in a `WKWebView`. Pick a workspace and talk to an agent that is already installed on the Mac.

[![Release](https://github.com/nullskymc/Aureways/actions/workflows/release.yml/badge.svg)](https://github.com/nullskymc/Aureways/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[中文说明](README.zh-CN.md) · [Documentation](docs/README.md)

</div>

Aureways speaks the [Agent Client Protocol](https://agentclientprotocol.com). It launches the local CLI agent as a child process and talks stdio NDJSON. There is no remote backend and no separate HTTP service.

With a session open, the composer is a second transparent web view sitting on system Liquid Glass, so the transcript can scroll underneath the input. Glass is `NSGlassEffectView` only.

## Features

- **Shell** — hidden title bar, traffic lights inset into the sidebar, system light/dark (overridable in Settings). Closing the window or pressing `⌘Q` leaves the process in the menu bar. Quit is the menu-bar item.
- **Any ACP agent** — nine agents ship built in, or add a launch command in Settings. Sessions are grouped by workspace and restore across launches when the agent supports `session/load`.
- **Streaming transcript** — Markdown (marked, DOMPurify, lazy Shiki), collapsible thinking, tool rows merged by `toolCallId`, plan steps. The list is windowed. At rest the last line sits above the composer.
- **Composer** — Return sends, Shift+Return inserts a newline. `/` commands, `@` workspace files, images and file attachments. Permission, plan-approval, and question cards sit above the input.
- **Inspector** (`⌥⌘I`) — file tree, text editor (`⌘S`, mtime conflict check), git changes, and interactive terminals. Terminals are xterm.js fed by headless SwiftTerm PTYs. Each file and terminal keeps its own tab.
- **Markdown** — Finder, Dock, `open -a`, and File → Open Markdown (`⌘O`) open `.md` files as inspector tabs. Set Aureways as the default Markdown app in Settings to use it on double-click.
- **Usage** — account quota is a separate, cached, throttled read (`QuotaStore`). It is not taken from the ACP session. The settings Usage page and the menu bar show the same snapshot.

```
┌──────────────┬────────────────────────────────────────────┬──────────────┐
│ Sidebar      │  Header: workspace · session · agent       │ Inspector    │
│  • New chat  │                                            │  • Files     │
│  • Workspace ├────────────────────────────────────────────┤  • Editor    │
│    sessions  │  Transcript (column 768px, streaming)      │  • Changes   │
│    ⌘1 … ⌘9   │                                            │  • Terminal  │
│              ├────────────────────────────────────────────┤              │
│              │  Glass composer (Return to send)           │              │
└──────────────┴────────────────────────────────────────────┴──────────────┘
```

## Built-in agents

| Agent | Launch command |
| --- | --- |
| Grok Build | `grok agent stdio` |
| Codex | `npx -y @agentclientprotocol/codex-acp` |
| Claude Code | `npx -y @agentclientprotocol/claude-agent-acp` |
| Antigravity | `agy_acp_server` (official Google ACP zip; not `agy --acp`) |
| GitHub Copilot | `copilot --acp --stdio` |
| Cursor Agent | `cursor-agent acp` |
| OpenCode | `opencode acp` |
| Oh My Pi | `omp acp` |
| Qoder | `qoder --acp` / `qoderclicn --acp` |

Install and sign in with each vendor's own CLI. Login and API keys do not go through Aureways. Custom agents are added in Settings (`⌘,`).

Oh My Pi is a Bun CLI (`engines.bun >= 1.3.14`). Install with `bun install -g @oh-my-pi/pi-coding-agent`, then authenticate inside `omp`. Auto-approve launches `omp acp --yolo`.

Qoder supports the international CLI (`qoder`, package `@qoder-ai/qodercli`) and the mainland-China CLI (`qoderclicn`, package `@qodercn-ai/qoderclicn`). Aureways uses whichever binary is on `PATH`. Run `qoder login` or `qoderclicn login` first. Auto-approve adds `--yolo`.

Antigravity's `agy` CLI has no `--acp` mode. Google ships a separate ACP server (`agy_acp_server.par` and `localharness_external` in the same directory). On Apple Silicon:

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

Do not symlink only the `.par` onto `PATH` — the server looks for `localharness_external` next to the executable. The first connect authenticates with Google (`oauth-personal`). Override the binary with `AGY_ACP_BIN`.

Quota readers exist for Grok (billing API), Codex (usage API, then local session logs), Claude (OAuth usage, file credentials only), and Antigravity (Cloud Code). Claude on macOS usually keeps its token in the Keychain; Aureways does not read the Keychain, so that source reports not configured. Copilot, Cursor, OpenCode, Oh My Pi, and Qoder have no quota source.

## Getting started

**Install** — download the `.dmg` from [Releases](https://github.com/nullskymc/Aureways/releases) and drag `Aureways.app` into `Applications`. Builds are ad-hoc signed and not notarized. If Gatekeeper blocks the first launch:

```bash
xattr -dr com.apple.quarantine /Applications/Aureways.app
```

**Build from source** — macOS 26 or later, Xcode 26 or later (developed on Xcode 27). The app sandbox is off. Run from the repository root (the directory that contains `Makefile` and `Aureways.xcodeproj`):

```bash
make open
```

Or open `Aureways.xcodeproj`, select scheme **Aureways** and destination **My Mac**, then press `⌘R`.

`make` uses `xcode-select -p`. If that path is still Command Line Tools, it looks for a full Xcode in this order: `/Applications/Xcode.app`, `/Applications/Xcode-beta.app`, `/Volumes/app/Applications/Xcode.app`, `/Volumes/app/Applications/Xcode-beta.app`, then Spotlight. To force one toolchain:

```bash
make open DEVELOPER_DIR=/Volumes/app/Applications/Xcode.app/Contents/Developer
```

| Command | What it does |
| --- | --- |
| `make build` | Debug build |
| `make open` | Build and open the `.app` |
| `make test` | Run `AurewaysTests` |
| `make release` | Release build |
| `make clean` | Remove `.derived` |
| `make web` | Rebuild `WebApp/` into `Aureways/WebAppBundle/` |

The web bundle is committed, so an app build does not need Node. Run `make web` only after editing `WebApp/src`. If the first command-line build reports a missing Metal toolchain:

```bash
xcodebuild -downloadComponent MetalToolchain
```

## Keyboard shortcuts

| Keys | Action |
| --- | --- |
| `⌘N` | New chat |
| `⌘O` | Open Markdown |
| `⌘1` … `⌘9` | Select session |
| `⌃⌘S` | Toggle sidebar |
| `⌥⌘I` | Toggle inspector |
| `⇧⌘E` | Inspector: files |
| `⇧⌘G` | Inspector: changes |
| `⌃\`` | New terminal |
| `⌘F` | Find |
| `⌘,` | Settings |
| `Return` | Send |
| `⇧Return` | New line |
| `⌘.` | Stop generation |
| `⌘Q` | Close the window and stay in the menu bar |
| `/` in the composer | Slash commands |
| `@` in the composer | Reference a workspace file |

## Documentation

The in-depth docs are in Chinese.

| Document | Covers |
| --- | --- |
| [Index](docs/README.md) | Reading order |
| [Directory](docs/directory.md) | Repository tree |
| [Architecture](docs/architecture.md) | Shell, web app, ACP |
| [Web shell](docs/web-shell.md) | Window, glass, bridge |
| [Frontend](docs/frontend.md) | Preact UI |
| [Backend](docs/backend.md) | Process, files, terminal, quota |
| [Protocol](docs/protocol.md) | ACP methods in this client |
| [Development](docs/development.md) | Toolchain, tests, connection failures |

## Releasing

Only a `v*` tag triggers CI. Branches and pull requests do not build. See [`.github/workflows/release.yml`](.github/workflows/release.yml).

```bash
git tag v0.2.0
git push origin v0.2.0
```

The pipeline runs `make test`, a Release build, packages `Aureways-<tag>.dmg`, and publishes a GitHub Release.

## License

MIT. See [LICENSE](LICENSE).
