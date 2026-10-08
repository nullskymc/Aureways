import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseHTML } from 'linkedom'
import { h, render } from 'preact'
import { act } from 'preact/test-utils'
import { instances } from './fixtures/xterm.mjs'

const { window, document } = parseHTML('<html><body><div id="app"></div></body></html>')
// Linkedom omits the browser's onkeydown property used by Preact's event normalization.
window.HTMLElement.prototype.onkeydown = null
// Linkedom calls bubbling listeners with event.target as `this`; browsers use
// currentTarget. Bind listeners to their registration target for Preact.
const addListener = window.EventTarget.prototype.addEventListener
const removeListener = window.EventTarget.prototype.removeEventListener
const boundListeners = new WeakMap()
window.EventTarget.prototype.addEventListener = function(type, listener, options) {
  let bindings = boundListeners.get(this)
  if (!bindings) boundListeners.set(this, bindings = new Map())
  if (!bindings.has(listener)) bindings.set(listener, typeof listener === 'function' ? listener.bind(this) : listener)
  addListener.call(this, type, bindings.get(listener), options)
}
window.EventTarget.prototype.removeEventListener = function(type, listener, options) {
  removeListener.call(this, type, boundListeners.get(this)?.get(listener) ?? listener, options)
}
Object.assign(globalThis, { window, document, HTMLElement: window.HTMLElement, Element: window.Element })
globalThis.requestAnimationFrame = callback => setTimeout(callback, 0)
globalThis.cancelAnimationFrame = clearTimeout

globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} }
globalThis.MutationObserver = class { observe() {} disconnect() {} }
globalThis.getComputedStyle = () => ({ color: 'rgb(0, 0, 0)' })
globalThis.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} })
const messages = []
window.webkit = { messageHandlers: { aureways: { postMessage(m) {
  messages.push(m)
  if (m.type !== 'rpc') return
  const result = m.method === 'term.open' ? { id: 'collapse-term', shell: 'zsh', index: 1 }
    : m.method === 'fs.read' ? { path: m.params.path, text: 'Original', size: 8, mtime: 1 }
    : m.method === 'git.diff' ? { repo: true, diff: '', untracked: [] } : []
  queueMicrotask(() => window.__aw.receive({ type: 'rpcResult', id: m.id, result }))
} } } }
const { EditorColumns } = await import('../src/components/App.tsx')
const state = await import('../src/inspector/state.ts')
const { app, route } = await import('../src/store.ts')
const { prefs } = await import('../src/prefs.ts')
const root = document.getElementById('app')
const model = { workspacePath: '/collapse', inspectorRoot: '/collapse', workspaceName: 'Aureways', sessions: [], locale: 'en', chrome: { trafficLights: { x: 20, w: 54 }, fullscreen: false } }
async function flush(callback = () => {}) {
  await act(async () => { callback(); await new Promise(resolve => setTimeout(resolve, 20)) })
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 10)) })
}
function output(text) { window.__aw.receive({ type: 'termData', id: 'collapse-term', data: Buffer.from(text).toString('base64') }) }

test('collapse hides both right columns without unmounting editors or stopping a terminal', async () => {
  app.value = model
  route.value = { name: 'main' }
  prefs.inspectorOpen.value = false
  state.openFile('/collapse/draft.txt')
  const buffer = state.buffers.get('/collapse/draft.txt')
  buffer.draft.value = 'Unsaved draft'
  buffer.dirty.value = true
  await state.openTerminal()
  state.moveTabRight('term:collapse-term')
  state.selectTab('file:/collapse/draft.txt')
  await flush(() => render(h(EditorColumns, { state: model, session: null, sidebarOpen: true, attention: false, overlay: true, glass: true, dock: { current: null }, dockHeight: 100 }), root))
  const columns = [...root.querySelectorAll('section.column')]
  assert.equal(columns.length, 3)
  const editor = columns[1].querySelector('textarea')
  assert.ok(editor)
  editor.scrollTop = 90
  const terminal = instances[0]
  assert.ok(terminal)
  output('before hide\n')
  terminal.scrollTop = 42
  const focuses = terminal.focusCalls
  await flush(() => root.querySelector('[aria-label="Hide workspace tabs"]').click())
  assert.equal(root.querySelectorAll('section.column[hidden]').length, 2)
  assert.equal(root.querySelectorAll('.col-resizer').length, 0)
  assert.equal(root.querySelector('[aria-label="Show workspace tabs"]').getAttribute('aria-expanded'), 'false')
  assert.equal(messages.filter(m => m.type === 'term.close').length, 0)
  assert.equal(messages.filter(m => m.type === 'focusComposer').length, 1)
  assert.equal(terminal.disposals, 0)
  assert.equal(terminal.focusCalls, focuses)
  output('while hidden\n')
  await flush(() => root.querySelector('[aria-label="Show workspace tabs"]').click())
  assert.equal(root.querySelectorAll('section.column[hidden]').length, 0)
  assert.equal(root.querySelectorAll('.col-resizer').length, 2)
  assert.equal(columns[1].querySelector('textarea'), editor)
  assert.equal(editor.scrollTop, 90)
  assert.equal(buffer.draft.value, 'Unsaved draft')
  assert.equal(buffer.dirty.value, true)
  assert.equal(instances.length, 1)
  assert.equal(terminal.scrollTop, 42)
  assert.equal(terminal.output, 'before hide\nwhile hidden\n')
  assert.equal(terminal.disposals, 0)
  // The file-tree control is separate from whole-workbench collapse.
  await flush(() => columns[1].querySelector('[aria-label="Toggle file tree"]').click())
  assert.equal(prefs.inspectorOpen.value, true)
  assert.equal(state.currentPane().workbenchCollapsed, false)
  await state.closeTab('term:collapse-term')
  await flush(() => render(null, root))
})

test('the project file tree and its toggle stay available while the Changes tab is active', async () => {
  app.value = { ...model, workspacePath: '/changes-nav', inspectorRoot: '/changes-nav' }
  route.value = { name: 'main' }
  prefs.inspectorOpen.value = true
  state.showInspector('changes')
  await flush(() => render(h(EditorColumns, { state: app.value, session: null, sidebarOpen: true, attention: false, overlay: true, glass: true, dock: { current: null }, dockHeight: 100 }), root))
  const column = () => [...root.querySelectorAll('section.column')].find(col => col.querySelector('.changes'))
  assert.ok(column(), 'Changes tab is rendered')
  const toggle = () => column().querySelector('[aria-label="Toggle file tree"]')
  assert.ok(toggle(), 'toggle shown on the Changes tab')
  assert.equal(toggle().getAttribute('aria-pressed'), 'true')
  const tree = () => column().querySelector('.workspace-sidebar .tree')
  assert.ok(tree(), 'project navigator beside the change list')
  assert.ok(tree().querySelector('.tree-filter input'), 'navigator keeps its own filter')
  await flush(() => toggle().click())
  assert.equal(prefs.inspectorOpen.value, false)
  assert.equal(tree(), null)
  assert.ok(column().querySelector('.changes'))
  await flush(() => toggle().click())
  assert.ok(tree())
  await flush(() => render(null, root))
})
