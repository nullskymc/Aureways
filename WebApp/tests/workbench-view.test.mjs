import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseHTML } from 'linkedom'
import { h, render } from 'preact'
import { act } from 'preact/test-utils'
import { instances } from './fixtures/xterm.mjs'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

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
let menuAnswer = null
window.webkit = { messageHandlers: { aureways: { postMessage(m) {
  messages.push(m)
  if (m.type === 'menu') { queueMicrotask(() => window.__aw.receive({ type: 'menuResult', token: m.token, id: menuAnswer })); return }
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

test('native title bar: chat is a plain title; workbench tabs fill one slim strip; + and toggles are native', async () => {
  const native = { ...model, workspacePath: '/glass', inspectorRoot: '/glass', chrome: { trafficLights: { x: 20, y: 19, w: 52, h: 14 }, fullscreen: false, titlebarHeight: 52, nativeTitlebar: true, glass: true, leadingInset: 122, newChatInset: 160, trailingInset: 126, addInset: 50 } }
  app.value = native
  route.value = { name: 'main' }
  prefs.inspectorOpen.value = true
  prefs.sidebarOpen.value = false
  state.showInspector('changes')
  state.openFile('/glass/a.txt')
  await flush(() => render(h(EditorColumns, { state: native, session: null, sidebarOpen: false, attention: false, overlay: true, glass: true, dock: { current: null }, dockHeight: 100 }), root))
  const heads = [...root.querySelectorAll('header.tab-strip')]
  assert.equal(heads.length, 2)
  assert.ok(heads.every(head => head.classList.contains('glass-tabs')))
  // Chat column: no capsule, no tabs, no "+": just the title.
  assert.equal(heads[0].querySelector('.tab-capsule, [role="tablist"], [role="tab"], .tab-add'), null)
  assert.equal(heads[0].querySelector('.chat-title').textContent, 'New chat', 'no session yet: New chat')
  // Workbench: one strip with every tab, no page "+" anywhere.
  const capsule = heads[1].querySelector('.tab-capsule')
  assert.equal(capsule.dataset.glass, 'tabs')
  assert.deepEqual([...capsule.querySelectorAll('[role="tab"]')].map(tab => tab.textContent), ['Changes', 'a.txt', 'Open file'])
  assert.equal(root.querySelector('.tab-add'), null, 'new tab is the native + circle')
  assert.equal(root.querySelector('[aria-label="Toggle file tree"], .workbench-toggle, [title="Toggle sidebar"]'), null, 'no web copies of the native toggles')
  // Split right: a transparent hit target over the strip's native glass circle.
  const split = heads[1].querySelector('button.tab-split')
  assert.equal(split.title, 'Split right')
  assert.equal(split.classList.contains('icon-btn'), false, 'not a plain web icon button')
  // Sidebar closed: sidebar toggle and New chat are native circles; the title sits 16 after them.
  assert.equal(heads[0].querySelector('.head-tools'), null)
  assert.equal(root.querySelector('header button.icon-btn, header .btn'), null, 'no plain web buttons left in the title bar')
  assert.equal(heads[0].style.paddingLeft, '168px')
  assert.equal(heads[1].style.paddingLeft, '6px')
  // The last visible column keeps clear of the native "+" and toggle capsule.
  assert.equal(heads[1].style.paddingRight, '126px')
  assert.equal(heads[0].style.paddingRight, '')
  // With the sidebar open the title sits at the content inset.
  prefs.sidebarOpen.value = true
  await flush(() => render(h(EditorColumns, { state: native, session: null, sidebarOpen: true, attention: false, overlay: true, glass: true, dock: { current: null }, dockHeight: 100 }), root))
  const chatHead = () => root.querySelector('header.tab-strip')
  assert.equal(chatHead().style.paddingLeft, '16px')
  assert.equal(chatHead().querySelector('.head-tools'), null)
  // Workbench closed: the chat column is last and only clears the single native inspector circle.
  await flush(() => state.toggleWorkbench())
  assert.equal(chatHead().style.paddingRight, '50px')
  await flush(() => state.toggleWorkbench())
  assert.equal(chatHead().style.paddingRight, '')
  await flush(() => render(null, root))
})

test('the + menu opens new tabs in the workbench, never in the chat column', async () => {
  const { newTabMenu } = await import('../src/inspector/Inspector.tsx')
  app.value = { ...model, workspacePath: '/plus', inspectorRoot: '/plus' }
  route.value = { name: 'main' }
  state.selectTab('chat')
  assert.equal(state.currentPane().focus, 0, 'chat focused')
  menuAnswer = 'changes'
  await newTabMenu({ x: 900, y: 46 })
  const menu = messages.filter(m => m.type === 'menu').at(-1)
  assert.deepEqual({ x: menu.x, y: menu.y }, { x: 900, y: 46 }, 'menu opens under the native button')
  const pane = state.currentPane()
  assert.deepEqual(pane.columns[0].tabs.map(tab => tab.kind), ['chat'])
  assert.ok(pane.columns[1].tabs.some(tab => tab.kind === 'changes'), 'opened in the workbench')
  assert.equal(pane.columns[1].active, 'changes')
  menuAnswer = null
})

test('native title bar state goes out only on change; the file tree toggle hides, shows or opens the navigator', async () => {
  const { installTitlebar, titlebarState, toggleFileTree } = await import('../src/titlebar.ts')
  app.value = { ...model, workspacePath: '/tb', inspectorRoot: '/tb' }
  route.value = { name: 'main' }
  prefs.inspectorOpen.value = true
  state.showInspector('changes')
  const sent = () => messages.filter(m => m.type === 'titlebar')
  const before = sent().length
  installTitlebar()
  assert.equal(sent().length, before + 1)
  assert.deepEqual({ ...sent().at(-1), type: undefined }, { type: undefined, sidebar: true, newChat: false, right: true, add: true, files: true, inspector: true })
  prefs.inspectorOpen.value = true
  assert.equal(sent().length, before + 1, 'unchanged state is not re-sent')
  toggleFileTree()
  assert.equal(prefs.inspectorOpen.value, false)
  assert.equal(sent().at(-1).files, false)
  toggleFileTree()
  assert.equal(prefs.inspectorOpen.value, true)
  state.toggleWorkbench()
  assert.equal(titlebarState().inspector, false)
  assert.equal(titlebarState().files, false)
  assert.equal(titlebarState().add, false, 'workbench closed: no + (native shows only the inspector toggle)')
  assert.equal(sent().at(-1).add, false)
  toggleFileTree()
  assert.equal(titlebarState().inspector, true, 'the file tree button brings the workbench back')
  assert.equal(titlebarState().files, true)
  assert.equal(titlebarState().add, true, '+ returns with the workbench')
  prefs.sidebarOpen.value = false
  assert.equal(sent().at(-1).newChat, true, 'sidebar closed: native New chat circle')
  route.value = { name: 'settings' }
  assert.equal(sent().at(-1).newChat, false, 'no New chat circle in Settings')
  assert.equal(sent().at(-1).right, false, 'no right capsule outside the main view')
  assert.equal(sent().at(-1).add, false, 'no + in settings')
  route.value = { name: 'documents' }
  assert.equal(titlebarState().add, true, 'Documents keeps the + circle')
  assert.equal(titlebarState().right, false)
  assert.equal(titlebarState().newChat, true, 'Documents keeps New chat')
  prefs.sidebarOpen.value = true
  assert.equal(titlebarState().newChat, false)
  route.value = { name: 'main' }
})

test('the chat title is the session title, live, with a tooltip; untitled chats read New chat', async () => {
  const native = { ...model, workspacePath: '/titled', inspectorRoot: '/titled', chrome: { trafficLights: { x: 20, y: 19, w: 52, h: 14 }, fullscreen: false, titlebarHeight: 52, nativeTitlebar: true, glass: true, leadingInset: 122, newChatInset: 160, trailingInset: 126, addInset: 50 } }
  app.value = native
  route.value = { name: 'main' }
  state.selectTab('chat')
  const long = 'Refactor the session store so renames persist across relaunches and agents'
  const mount = (session) => flush(() => render(h(EditorColumns, { state: native, session, sidebarOpen: true, attention: false, overlay: true, glass: true, dock: { current: null }, dockHeight: 100 }), root))
  const title = () => root.querySelector('header .chat-title')
  const session = { id: 's1', title: 'Fix login bug', agentTitle: 'Claude', cwd: '/titled', ws: '/titled', phase: 'ready', streaming: false }
  await mount(session)
  assert.equal(title().textContent, 'Fix login bug')
  assert.equal(title().title, 'Fix login bug')
  // Renamed / auto-titled: the next state carries the new title.
  await mount({ ...session, title: long })
  assert.equal(title().textContent, long, 'full text; CSS truncates with an ellipsis')
  assert.equal(title().title, long, 'tooltip shows the full title')
  await mount({ ...session, title: '  ' })
  assert.equal(title().textContent, 'New chat')
  // Ellipsis: the title shrinks inside the header instead of a fixed max width.
  const css = readFileSync(join(process.cwd(), 'src/styles.css'), 'utf8')
  assert.match(css.match(/\.head-title \{([^}]*)\}/)[1], /text-overflow: ellipsis;/)
  assert.match(css.match(/\.glass-tabs \.chat-title \{([^}]*)\}/)[1], /min-width: 0;/)
  // A disconnected session's Open button is no longer in the title bar.
  await mount({ ...session, phase: 'idle' })
  assert.equal(root.querySelector('header.chat-head button'), null)
  await flush(() => render(null, root))
})
