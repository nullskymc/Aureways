// Browser-only visual fixture. The actual Preact shell uses a fake native bridge;
// no real files, shell processes, Git commands, or native menus are touched.
const root = '/Users/demo/Aureways'
const source = 'import SwiftUI\n\nstruct WorkspaceView: View {\n    var body: some View {\n        HStack(spacing: 0) {\n            ChatView()\n            WorkbenchView()\n        }\n    }\n}\n'
const files = new Map([
  [root + '/Aureways/WorkspaceView.swift', source],
  [root + '/docs/development.md', '# Development\n\nChat stays on the left. Files and terminals open in the workbench.\n\n## Build\n\nRun `make web`.\n'],
  [root + '/README.md', '# Aureways\n\nA native workspace for coding agents.\n'],
  [root + '/WebApp/package.json', '{\n  "name": "aureways-webapp"\n}\n'],
])
const diff = [...files].slice(0, 2).map(([path, text]) => {
  const rel = path.slice(root.length + 1)
  return `diff --git a/${rel} b/${rel}\nnew file mode 100644\n--- /dev/null\n+++ b/${rel}\n@@ -0,0 +1,${text.trimEnd().split('\n').length} @@\n${text.trimEnd().split('\n').map(line => '+' + line).join('\n')}\n`
}).join('')
let termIndex = 0
window.webkit = { messageHandlers: { aureways: { postMessage(message) {
  if (message.type === 'rpc') {
    const { id, method, params } = message
    let result
    if (method === 'fs.list') {
      const entries = new Map()
      for (const path of files.keys()) {
        if (!path.startsWith(params.path + '/')) continue
        const rel = path.slice(params.path.length + 1)
        const name = rel.split('/')[0]
        entries.set(name, { name, path: params.path + '/' + name, dir: rel.includes('/') })
      }
      result = [...entries.values()].sort((a, b) => Number(b.dir) - Number(a.dir) || a.name.localeCompare(b.name))
    } else if (method === 'fs.search') result = [...files.keys()].filter(path => path.toLowerCase().includes(params.query.toLowerCase())).map(path => ({ path, rel: path.slice(root.length + 1) }))
    else if (method === 'fs.read') result = { path: params.path, text: files.get(params.path) ?? '', size: 100, mtime: 1 }
    else if (method === 'git.diff') result = { repo: true, branch: 'main', diff, untracked: [] }
    else if (method === 'term.open') {
      result = { id: 'fixture-' + ++termIndex, shell: 'zsh', index: termIndex }
      const termId = result.id
      setTimeout(() => window.__aw.receive({ type: 'termData', id: termId, data: btoa('demo@MacBook Aureways % ') }), 50)
    } else if (method === 'fs.write') { files.set(params.path, params.text); result = { mtime: 2 } }
    else if (method === 'ui.confirm') result = false
    else result = []
    queueMicrotask(() => window.__aw.receive({ type: 'rpcResult', id, result }))
  } else if (message.type === 'menu') {
    const menu = document.createElement('div')
    menu.setAttribute('role', 'menu')
    Object.assign(menu.style, { position: 'fixed', zIndex: '99', left: Math.min(message.x, innerWidth - 210) + 'px', top: message.y + 'px', padding: '6px', borderRadius: '9px', background: 'var(--surface)', boxShadow: 'var(--shadow)' })
    for (const item of message.items) {
      if (!item.id) continue
      const button = document.createElement('button')
      button.setAttribute('role', 'menuitem')
      button.textContent = item.title
      Object.assign(button.style, { display: 'block', padding: '6px 12px', minWidth: '180px' })
      button.onclick = () => { menu.remove(); window.__aw.receive({ type: 'menuResult', token: message.token, id: item.id }) }
      menu.append(button)
    }
    document.body.append(menu)
  }
} } } }
await import('../../src/main.tsx')
const receive = window.__aw.receive
window.__aw.receive = message => {
  if (message.type === 'state') {
    message.state.locale = 'zh'
    message.state.selectedSessionId = null
    message.state.uiPrefs = { sidebarWidth: 250, inspectorOpen: true, inspectorWidth: 230 }
    message.state.appearance = location.search.includes('dark') ? 'dark' : 'light'
  }
  receive(message)
}
const { loadDemo } = await import('../../src/demo.ts')
loadDemo()
const { openTerminal, openExplorer } = await import('../../src/inspector/state.ts')
await openTerminal()
openExplorer()
