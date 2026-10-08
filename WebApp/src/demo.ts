// Loaded only outside the app (vite dev / headless checks): fake state + a
// streaming transcript so the UI can be styled without the Swift side.
import type { AppState, Item } from './types'
import { seedDemoText } from './inspector/state'

const READER_GUIDE = `/Users/demo/Aureways/docs/guide.md`
const READER_NOTES = `/Users/demo/Aureways/docs/notes.md`

const GUIDE_MD = `# Guide

A short document for the reader. It uses the same Markdown engine as the chat.

${Array.from({ length: 24 }, (_, i) => `Paragraph ${i + 1}. The reader keeps a narrow column so a long page can scroll to a heading.`).join('\n\n')}

## Install

Run \`make web\`, then open a \`.md\` file.

- [x] Rendering engine
- [ ] Read it without the chat in the way

See [notes](notes.md) or jump to [Install](#install).

| Layer | Owner |
| --- | --- |
| Chrome | AppKit |
| Page | Preact |

> The column stays narrow so lines stay readable.

\`\`\`swift
WebShellRoot(model: model)
\`\`\`

![dot](data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7)

![missing](./missing.png)
`

const NOTES_MD = `# Notes

Hello from the other file.

## Back

The toolbar returns to the chat and leaves this tab open.
`

const KEPT = '/Users/demo/kept.md'
const KEPT_MD = `# Kept

A note that lives outside the workspace.

See [other](/Users/demo/other.md).
`

export function loadDemo() {
  // Restore runs while the first state message is applied, so the text has to
  // be seeded before that message. A dynamic import afterwards is too late.
  if (location.hash.includes('kept')) {
    seedDemoText(KEPT, KEPT_MD)
    seedDemoText('/Users/demo/other.md', '# Other\n\nStill in Documents.\n')
  }
  if (location.hash.includes('reader')) {
    void Promise.all([import('./inspector/state'), import('./reader/state')]).then(([files, reader]) => {
      files.seedDemoText(READER_GUIDE, GUIDE_MD)
      files.seedDemoText(READER_NOTES, NOTES_MD)
      reader.openDocuments([READER_GUIDE])
    })
  } else if (location.hash.includes('settings')) void import('./store').then((m) => (m.route.value = { name: 'settings', section: location.hash.split('settings-')[1] }))
  const now = Date.now()
  const state: AppState = {
    locale: 'en',
    appearance: 'system',
    selectedSessionId: location.hash.includes('landing') ? null : 's1',
    selectedAgentId: 'codex',
    workspacePath: '/Users/demo/Aureways',
    workspaceName: 'Aureways',
    branch: 'proto/web-shell',
    homePath: '/Users/demo',
    error: null,
    chrome: { trafficLights: { x: 13, y: 12, w: 54, h: 16 }, fullscreen: false, titlebarHeight: 46 },
    workspaces: [
      { path: '/Users/demo/Aureways', name: 'Aureways' },
      { path: '/Users/demo/site', name: 'site' },
    ],
    agents: [
      { id: 'grok-build', title: 'Grok Build', subtitle: '', available: true },
      { id: 'codex', title: 'Codex', subtitle: '', available: true },
      { id: 'claude', title: 'Claude Code', subtitle: '', available: true },
      { id: 'cursor', title: 'Cursor', subtitle: '', available: false },
    ],
    sessions: [
      { id: 's1', title: 'Rearchitect window as web shell', agentId: 'codex', agentTitle: 'Codex', cwd: '/Users/demo/Aureways', ws: '/Users/demo/Aureways', phase: 'ready', streaming: true, attention: false, createdAt: now - 3600e3 },
      { id: 's2', title: 'Fix layout loop crash', agentId: 'claude', agentTitle: 'Claude Code', cwd: '/Users/demo/Aureways', ws: '/Users/demo/Aureways', phase: 'idle', streaming: false, attention: true, createdAt: now - 86400e3 },
      { id: 's3', title: 'Landing page copy', agentId: 'grok-build', agentTitle: 'Grok Build', cwd: '/Users/demo/site', ws: '/Users/demo/site', phase: 'idle', streaming: false, attention: false, createdAt: now - 5 * 86400e3 },
    ],
    composer: {
      sessionId: 's1',
      attachments: [],
      model: { configId: 'model', current: 'gpt-5', options: [{ id: 'gpt-5', name: 'GPT-5', group: null, description: null }] },
      effort: { configId: 'effort', current: 'high', options: [{ id: 'high', name: 'High', group: null, description: null }] },
    },
    usage: { used: 42000, size: 200000 },
    inspectorRoot: '/Users/demo/Aureways',
    uiPrefs: {
      inspectorOpen: location.hash.includes('insp'),
      ...(location.hash.includes('kept') ? { documentPaths: [KEPT] } : {}),
    },
    settings: {
      appearance: 'system', language: 'en', systemLanguage: 'system', showMenuBar: true, markdownDefault: false,
      autoApprove: false, defaultAgentId: 'codex', version: '0.3.3',
      agents: [
        { id: 'grok-build', title: 'Grok Build', subtitle: '', builtIn: true, launchLine: 'grok agent stdio', notes: '', enabled: true, available: true, quotaRefreshing: false },
        { id: 'codex', title: 'Codex', subtitle: '', builtIn: true, launchLine: 'npx @zed-industries/codex-acp', notes: '', enabled: true, available: true, quotaRefreshing: false },
        { id: 'claude', title: 'Claude Code', subtitle: '', builtIn: true, launchLine: 'npx @zed-industries/claude-code-acp', notes: '', enabled: true, available: true, quotaRefreshing: false },
        { id: 'cursor', title: 'Cursor', subtitle: '', builtIn: true, launchLine: 'cursor-agent acp', notes: '', enabled: false, available: false, quotaRefreshing: false },
      ],
      workspaces: [{ path: '/Users/demo/Aureways', name: 'Aureways' }, { path: '/Users/demo/site', name: 'site' }],
      defaultWorkspace: '/Users/demo/Aureways',
      mcpServers: [{ id: 'm1', name: 'filesystem', transport: 'stdio', summary: 'npx -y @modelcontextprotocol/server-filesystem ~', enabled: true }],
      reportedMcp: [],
      mcpCaps: { http: true, sse: false },
    },
    quota: {
      codex: {
        harnessId: 'codex', providerTitle: 'OpenAI', planType: 'Plus', updatedAt: now - 120e3, severity: 'warning', summary: '5h 38%',
        primaryWindow: { id: 'p', title: '5 hours', usedPercent: 62, resetsAt: now + 2.4 * 3600e3 },
        secondaryWindow: { id: 's', title: 'Weekly', usedPercent: 21, resetsAt: now + 4 * 86400e3 },
      },
    },
  }
  if (location.hash.includes('perm')) {
    state.permission = {
      title: 'Run npm test',
      options: [
        { id: 'a', name: 'Allow once', kind: 'allow_once', allow: true },
        { id: 'b', name: 'Always allow', kind: 'allow_always', allow: true },
        { id: 'c', name: 'Reject', kind: 'reject_once', allow: false },
      ],
      tool: { callId: 'x', title: 'npm test', fullTitle: 'npm test', toolKind: 'execute', status: 'pending', layout: 'command', progress: false, command: 'npm test -- --watch=false' },
    }
  }
  const items: Item[] = []
  for (let i = 0; i < Number(new URLSearchParams(location.search).get('turns') ?? 3); i++) {
    items.push({ kind: 'user', id: `u${i}`, text: 'Make the main window a single WKWebView and keep SwiftUI as a thin shell.', attachments: [] })
    items.push({ kind: 'thought', id: `t${i}`, text: 'Need to look at RootView and the split view…', run: { s: now - 50e3, e: now - 46e3 } })
    items.push({ kind: 'tool', id: `x${i}`, callId: 'c', title: 'rg NavigationSplitView', fullTitle: 'rg', toolKind: 'execute', status: 'completed', layout: 'command', progress: false, command: 'rg -n NavigationSplitView Aureways', output: 'Aureways/Views/RootView.swift:9:        NavigationSplitView {', run: { s: now - 46e3, e: now - 40e3 } })
    items.push({ kind: 'tool', id: `e${i}`, callId: 'd', title: 'Edited AurewaysApp.swift', fullTitle: '', toolKind: 'edit', status: 'completed', layout: 'edit', progress: false, diffs: [{ path: '/Users/demo/Aureways/Aureways/AurewaysApp.swift', added: 2, removed: 1, truncated: false, isNew: false, hunks: [{ header: '@@ -60,3 +60,4 @@', oldStart: 60, newStart: 60, lines: [' Window("Aureways") {', '-    RootView()', '+    WebShellRoot(model: model)', '+        .ignoresSafeArea()', ' }'] }] }] })
    items.push({ kind: 'agent', id: `a${i}`, text: '## Done\n\nThe window now hosts **one** `WKWebView`.\n\n| Layer | Owner |\n|---|---|\n| Chrome | AppKit |\n| UI | Preact |\n\n```swift\nWebShellRoot(model: model)\n    .ignoresSafeArea()\n```\n\n- sidebar\n- transcript (virtualized)\n- composer\n' })
  }
  window.__aw.receive({ type: 'state', state })
  window.__aw.receive({ type: 'transcript', sessionId: 's1', items })
  const id = 'live'
  window.__aw.receive({ type: 'patch', sessionId: 's1', ops: [{ op: 'upsert', index: items.length, item: { kind: 'user', id: 'ulive', text: 'Now stream something long.', attachments: [] } }, { op: 'upsert', index: items.length + 1, item: { kind: 'agent', id, text: '' } }] })
  const sample = 'Streaming a reply with `code`, **bold** and a list:\n\n1. first\n2. second\n\n```ts\nconst x = 1\n```\n\nAll good.'
  let i = 0
  const tick = () => {
    if (i >= sample.length) return
    window.__aw.receive({ type: 'patch', sessionId: 's1', ops: [{ op: 'append', id, delta: sample.slice(i, i + 5) }] })
    i += 5
    setTimeout(tick, 30)
  }
  tick()
}
