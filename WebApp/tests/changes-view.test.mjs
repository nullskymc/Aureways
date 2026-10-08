import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseHTML } from 'linkedom'
import { h, render } from 'preact'
import { act } from 'preact/test-utils'

const { window, document } = parseHTML('<html><body><div id="app"></div></body></html>')
window.HTMLElement.prototype.onkeydown = null
// Linkedom calls bubbling listeners with event.target as `this`; bind to the registration target like browsers.
const addListener = window.EventTarget.prototype.addEventListener
const removeListener = window.EventTarget.prototype.removeEventListener
const bound = new WeakMap()
window.EventTarget.prototype.addEventListener = function(type, listener, options) {
  let map = bound.get(this)
  if (!map) bound.set(this, map = new Map())
  if (!map.has(listener)) map.set(listener, typeof listener === 'function' ? listener.bind(this) : listener)
  addListener.call(this, type, map.get(listener), options)
}
window.EventTarget.prototype.removeEventListener = function(type, listener, options) {
  removeListener.call(this, type, bound.get(this)?.get(listener) ?? listener, options)
}
Object.assign(globalThis, { window, document, HTMLElement: window.HTMLElement, Element: window.Element })
globalThis.requestAnimationFrame = callback => setTimeout(callback, 0)
globalThis.cancelAnimationFrame = clearTimeout
globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} }
globalThis.MutationObserver = class { observe() {} disconnect() {} }
globalThis.getComputedStyle = () => ({ color: 'rgb(0, 0, 0)' })
globalThis.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} })

const { DEMO_GIT_DIFF, DEMO_UNTRACKED } = await import('../src/demoChanges.ts')
window.webkit = { messageHandlers: { aureways: { postMessage(m) {
  if (m.type !== 'rpc') return
  const result = m.method === 'git.diff' ? { repo: true, root: '/repo', branch: 'main', diff: DEMO_GIT_DIFF, untracked: DEMO_UNTRACKED } : []
  queueMicrotask(() => window.__aw.receive({ type: 'rpcResult', id: m.id, result }))
} } } }
const { ChangesView } = await import('../src/inspector/Changes.tsx')
const { DiffPane } = await import('../src/inspector/DiffPane.tsx')
const state = await import('../src/inspector/state.ts')
const { app, route } = await import('../src/store.ts')
const { prefs } = await import('../src/prefs.ts')
const root = document.getElementById('app')

async function flush(callback = () => {}) {
  await act(async () => { callback(); await new Promise(resolve => setTimeout(resolve, 20)) })
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 10)) })
}
async function mount(navigator, cwd = '/repo') {
  app.value = { workspacePath: cwd, inspectorRoot: cwd, sessions: [], locale: 'en', chrome: { trafficLights: { x: 20, w: 54 }, fullscreen: false } }
  route.value = { name: 'main' }
  prefs.inspectorOpen.value = navigator
  render(null, root)
  await flush(() => render(h(ChangesView, {}), root))
}
const rows = () => [...root.querySelectorAll('.change-tree .change-row')]
const rowFor = rel => rows().find(el => el.dataset.path === '/repo/' + rel)
const selected = () => rows().filter(el => el.classList.contains('selected')).map(el => el.dataset.path)
const diffTabs = () => state.currentPane().columns.flatMap(col => col.tabs).filter(tab => tab.kind === 'diff')
const activeTab = () => { const pane = state.currentPane(); return pane.columns[pane.focus]?.active }
const press = (key, target = root.querySelector('.changes')) => {
  const event = new window.Event('keydown', { bubbles: true, cancelable: true })
  Object.defineProperty(event, 'key', { value: key })
  target.dispatchEvent(event)
}

test('the Changes tab is only a tree: folder groups, badges, icons, names and counts — no inline diffs', async () => {
  await mount(true)
  assert.equal(root.querySelector('.hunk, .diff-pane, .workspace-sidebar'), null, 'no diff body and no second navigator')
  assert.deepEqual([...root.querySelectorAll('.change-dir-name')].map(el => el.textContent),
    ['Aureways/Views', 'docs', 'repo', 'src/components', 'src/inspector', 'src', 'Untracked'])
  assert.deepEqual(rows().map(el => el.querySelector('.change-badge').textContent), ['R', 'M', 'D', 'R', 'A', 'M', 'M', 'M', 'U', 'U'])
  assert.deepEqual(rows().map(el => el.querySelector('.change-name').textContent).slice(5, 7), ['index.ts', 'index.ts'])
  assert.match(rowFor('settings.yml').querySelector('.change-from').textContent, /← config\.yml/)
  assert.equal(rowFor('docs/guide.md').querySelector('.diffstat').textContent, '+2−2')
  assert.equal(rowFor('docs/old-notes.md').querySelector('.diffstat').textContent, '−4')
  assert.ok(rowFor('src/components/Badge.tsx').querySelector('.icon'))
  assert.equal(rowFor('src/inspector/__snapshots__/Changes.snap').querySelector('.change-from').textContent, 'src/inspector/__snapshots__')
  assert.match(root.querySelector('.review-count').textContent, /10 files/)
})

test('clicking a file opens its own diff tab, and clicking again focuses it instead of duplicating', async () => {
  await mount(true)
  const before = diffTabs().length
  await flush(() => rowFor('src/inspector/index.ts').click())
  assert.equal(diffTabs().length, before + 1)
  assert.equal(activeTab(), 'diff:/repo/src/inspector/index.ts')
  assert.deepEqual(selected(), ['/repo/src/inspector/index.ts'])
  await flush(() => rowFor('src/components/index.ts').click())
  assert.equal(activeTab(), 'diff:/repo/src/components/index.ts')
  await flush(() => rowFor('src/inspector/index.ts').click())
  assert.equal(diffTabs().length, before + 2, 'no duplicate tab')
  assert.equal(activeTab(), 'diff:/repo/src/inspector/index.ts')
  const tab = diffTabs().find(t => t.id === 'diff:/repo/src/inspector/index.ts')
  assert.equal(tab.file.added, 1)
  // Untracked files have no diff; they open as files.
  await flush(() => rowFor('scratch.txt').click())
  assert.equal(activeTab(), 'file:/repo/scratch.txt')
})

test('arrow keys and j/k move the selection, Enter opens it; typing in the filter is left alone', async () => {
  await mount(true, '/keys')
  const sel = () => selected()[0]?.replace('/keys/', '')
  assert.equal(sel(), 'Aureways/Views/WebShellRoot.swift', 'first file selected by default')
  await flush(() => press('ArrowDown'))
  assert.equal(sel(), 'docs/guide.md')
  await flush(() => press('j'))
  assert.equal(sel(), 'docs/old-notes.md')
  await flush(() => press('k'))
  await flush(() => press('ArrowUp'))
  await flush(() => press('ArrowUp'))
  assert.equal(sel(), 'Aureways/Views/WebShellRoot.swift', 'stops at the first file')
  await flush(() => press('ArrowDown', root.querySelector('.review-filter input')))
  assert.equal(sel(), 'Aureways/Views/WebShellRoot.swift', 'filter keeps its keys')
  await flush(() => press('ArrowDown'))
  await flush(() => press('Enter'))
  assert.equal(activeTab(), 'diff:/keys/docs/guide.md')
  // Selection survives a refresh.
  await flush(() => root.querySelector('.review-toolbar [title="Refresh"]').click())
  assert.equal(sel(), 'docs/guide.md')
})

test('folders fold one at a time or all at once, skipping folded rows for the keyboard, and stay folded on refresh', async () => {
  await mount(true, '/fold')
  const docs = () => [...root.querySelectorAll('.change-dir')].find(el => el.textContent.includes('docs'))
  await flush(() => docs().click())
  assert.equal(docs().getAttribute('aria-expanded'), 'false')
  assert.equal(rows().filter(el => el.dataset.path.startsWith('/fold/docs/')).length, 0)
  await flush(() => press('ArrowDown'))
  assert.equal(selected()[0], '/fold/settings.yml', 'skips folded docs/')
  await flush(() => root.querySelector('.review-toolbar [title="Refresh"]').click())
  assert.equal(docs().getAttribute('aria-expanded'), 'false')
  const toggle = () => root.querySelector('.review-toolbar [aria-label="Collapse all"], .review-toolbar [aria-label="Expand all"]')
  assert.equal(toggle().getAttribute('aria-label'), 'Collapse all')
  await flush(() => toggle().click())
  assert.equal(rows().filter(el => !el.querySelector('.change-badge.u')).length, 0)
  assert.equal(toggle().getAttribute('aria-label'), 'Expand all')
  await flush(() => toggle().click())
  assert.equal(rows().length, 10)
})

test('the diff tab has a pinned header with status, name, folder, counts and actions above its hunks', async () => {
  await mount(true)
  render(null, root)
  const file = { path: '/repo/src/inspector/index.ts', added: 1, removed: 0, truncated: false, isNew: false, status: 'M', hunks: [{ header: '@@ -1,2 +1,3 @@', oldStart: 1, newStart: 1, lines: [' a', ' b', '+c'] }] }
  await flush(() => render(h(DiffPane, { file }), root))
  const head = root.querySelector('.diff-pane > .diff-file-head')
  assert.ok(head, 'header sits outside the scrolling body')
  assert.ok(root.querySelector('.diff-pane > .diff-pane-body .hunk'))
  assert.equal(head.querySelector('.change-badge').textContent, 'M')
  assert.equal(head.querySelector('.file-label-name').textContent, 'index.ts')
  assert.equal(head.querySelector('.file-label-dir').textContent, 'src/inspector')
  assert.equal(head.querySelector('.diffstat').textContent, '+1')
  assert.deepEqual([...head.querySelectorAll('.diff-actions button')].map(b => b.title), ['Edit', 'Mention in composer', 'Reveal in Finder'])
  render(null, root)
  await flush(() => render(h(DiffPane, { file: { ...file, path: '/repo/a.swift', status: 'R', oldPath: '/repo/b.swift', hunks: [], added: 0 } }), root))
  assert.equal(root.querySelector('.diff-note').textContent, 'Renamed without content changes')
})
