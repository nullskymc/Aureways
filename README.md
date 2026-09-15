<div align="center">

<img src="design/app-icon/logo_default_1024.png" width="128" height="128" alt="Aureways — A-orbit mark" />

# Aureways

**A native macOS client for agentic coding.** A SwiftUI app — not a web view, not an Electron shell. Pick a workspace, talk to an agent that's already installed on your Mac, and let it edit files and run terminals in a native window.

[![Release](https://github.com/nullskymc/Aureways/actions/workflows/release.yml/badge.svg)](https://github.com/nullskymc/Aureways/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[中文说明](README.zh-CN.md) · [Documentation](docs/README.md)

</div>

Aureways implements the [Agent Client Protocol](https://agentclientprotocol.com) and launches your local CLI agent as a child process over stdio NDJSON. There is no remote backend and no separate HTTP service — the client runs the agent directly, in-process.

## Features

- **Native Mac surfaces** — unified toolbar, sidebar, system Settings (`⌘,`), light/dark following the system (overridable in Settings). "Reveal in Finder" and a real PTY terminal, not a web approximation.
- **Any ACP agent** — eight agents ship built in, or add any launch command from Settings. Sessions live under their workspace in the sidebar and restore across launches when the agent supports it.
- **Streaming transcript** — Markdown body, collapsible thinking, grouped tool calls, plan steps. The composer takes `/` commands, `@` workspace-file references, and image/file attachments. Long transcripts are virtualized so scrolling stays cheap.
- **Permissions** — the agent asks before reading/writing files or running commands; you can instead let the client approve on its behalf.
- **Workbench** (`⌘B`) — a file browser, a text editor (line numbers, `⌘S`, conflict handling when you and the agent edit the same file), and interactive terminals. Every open file and terminal keeps its own tab, so switching doesn't lose state.
- **Markdown documents** — Finder, Dock, `open -a`, and File → Open Markdown (`⌘O`) open `.md` files in a dedicated preview window (same renderer as the transcript). Set Aureways as the default Markdown app in Settings if you want double-click.

```
┌──────────────┬────────────────────────────────────────────┬──────────────┐
│ Sidebar      │  Unified toolbar: workspace · status · search │ Inspector ⌘B │
│  • New chat ⌘N│                                            │  • File browser│
│  • Workspace  ├────────────────────────────────────────────┤  • Text editor │
│    sessions   │  Transcript (centered, streaming)          │  • Terminal    │
│    ⌘1 … ⌘9   │   user bubble · agent message · thinking    │  • Info        │
│               │   tool cards · plan steps                  │               │
│               ├────────────────────────────────────────────┤               │
│               │  Floating composer (⌘Return to send)       │               │
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

Install and sign in to the matching CLI first. Login and API keys live in each vendor's own tool — they don't go through Aureways. Add custom agents in Settings (`⌘,`).

Oh My Pi is a Bun CLI (`engines.bun >= 1.3.14`). Install with `bun install -g @oh-my-pi/pi-coding-agent`, then authenticate inside `omp`. Auto-approve launches `omp acp --yolo`.

Antigravity's CLI (`agy`) has no `--acp` mode. Google publishes a separate ACP server (`agy_acp_server.par` + `localharness_external` in the same directory). On Apple Silicon:

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

Do not symlink only the `.par` onto `PATH` — the server looks for `localharness_external` next to the executable. First connect authenticates with Google (`oauth-personal`). Override the binary with `AGY_ACP_BIN`.

## Getting started

**Install** — grab the `.dmg` from [Releases](https://github.com/nullskymc/Aureways/releases) and drag `Aureways.app` into `Applications`. Builds are ad-hoc signed and not notarized; if Gatekeeper blocks first launch:

```bash
xattr -dr com.apple.quarantine /Applications/Aureways.app
```

**Build from source** — requires macOS 26+ and Xcode 26+ (developed against Xcode 27). The app sandbox is off. Run from the **repository root** (where `Makefile` and `Aureways.xcodeproj` live, not the inner `Aureways/` source directory):

```bash
make open
```

Or open the project in Xcode, pick scheme **Aureways** and destination **My Mac**, then press `⌘R`:

```bash
open Aureways.xcodeproj
```

To build with a specific Xcode instead of the current `xcode-select` toolchain:

```bash
make open DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

| Command | What it does |
| --- | --- |
| `make build` | Debug build |
| `make open` | Build and open the `.app` |
| `make test` | Run `AurewaysTests` |
| `make release` | Release build (for shipping) |
| `make clean` | Remove `.derived` |

If the first command-line build reports a missing Metal toolchain:

```bash
xcodebuild -downloadComponent MetalToolchain
```

## Keyboard shortcuts

| Keys | Action |
| --- | --- |
| `⌘N` | New chat |
| `⌘O` | Open Markdown |
| `⌘1` … `⌘9` | Select session |
| `⌘B` / `⌥⌘I` | Toggle the workbench |
| `⌘,` | Settings |
| `⌘Return` | Send message |
| `⌘.` | Stop generation |
| `/` in composer | Slash commands |
| `@` in composer | Reference workspace files |

## Documentation

| Document | Covers |
| --- | --- |
| [Index](docs/README.md) | Reading order |
| [Directory](docs/directory.md) | Repo and source tree |
| [Architecture](docs/architecture.md) | Front/back responsibilities, session lifecycle |
| [Frontend](docs/frontend.md) | SwiftUI UI and state |
| [Backend](docs/backend.md) | Connection, process, filesystem, terminal |
| [Protocol](docs/protocol.md) | Which ACP methods are implemented |
| [Development](docs/development.md) | Toolchain, tests, debugging connection failures |

The in-depth docs are written in Chinese.

## Releasing

By convention, only a `v*` tag triggers CI — branches and PRs don't build. See [`.github/workflows/release.yml`](.github/workflows/release.yml).

```bash
git tag v0.2.0
git push origin v0.2.0
```

Pipeline: `make test` → Release build → package `Aureways-<tag>.dmg` → create a GitHub Release with the artifact.

## License

MIT. See [LICENSE](LICENSE).
