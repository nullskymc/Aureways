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
const { app, route } = await import('../src/store.ts')
const { prefs } = await import('../src/prefs.ts')
const root = document.getElementById('app')

async function flush(callback = () => {}) {
  await act(async () => { callback(); await new Promise(resolve => setTimeout(resolve, 20)) })
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 10)) })
}
async function mount(navigator) {
  app.value = { workspacePath: '/repo', inspectorRoot: '/repo', sessions: [], locale: 'en', chrome: { trafficLights: { x: 20, w: 54 }, fullscreen: false } }
  route.value = { name: 'main' }
  prefs.inspectorOpen.value = navigator
  render(null, root)
  await flush(() => render(h(ChangesView, {}), root))
}
const cards = () => [...root.querySelectorAll('.review-scroll > .diff-card[data-path]')]
const card = rel => cards().find(el => el.dataset.path === '/repo/' + rel)
const label = el => [el.querySelector('.file-label-name')?.textContent, el.querySelector('.file-label-dir')?.textContent ?? '']

test('every changed file is its own card with a status badge and a header', async () => {
  await mount(false)
  assert.equal(cards().length, 8)
  assert.deepEqual(cards().map(el => el.querySelector('.change-badge').textContent), ['R', 'M', 'D', 'R', 'A', 'M', 'M', 'M'])
  for (const el of cards()) assert.ok(el.firstElementChild.classList.contains('diff-file-head'), 'header first')
  assert.deepEqual(label(card('src/components/index.ts')), ['index.ts', 'src/components'])
  assert.deepEqual(label(card('src/inspector/index.ts')), ['index.ts', 'src/inspector'])
  assert.match(card('settings.yml').querySelector('.file-label-from').textContent, /config\.yml/)
  assert.equal(card('src/components/Badge.tsx').classList.contains('status-a'), true)
  assert.equal(root.querySelector('.untracked-card').querySelectorAll('.untracked-row').length, 2)
  assert.match(root.querySelector('.review-count').textContent, /10 files/)
})

test('a file folds and unfolds from its header; deleted files start folded', async () => {
  await mount(false)
  const deleted = card('docs/old-notes.md')
  assert.ok(deleted.classList.contains('collapsed'))
  assert.equal(deleted.querySelector('.diff-card-body'), null)
  const guide = () => card('docs/guide.md')
  assert.equal(guide().querySelectorAll('.hunk').length, 2)
  const fold = guide().querySelector('.diff-fold')
  assert.equal(fold.getAttribute('aria-expanded'), 'true')
  await flush(() => fold.click())
  assert.equal(guide().querySelector('.diff-card-body'), null)
  assert.equal(guide().querySelector('.diff-fold').getAttribute('aria-expanded'), 'false')
  await flush(() => guide().querySelector('.diff-file-head').click())
  assert.equal(guide().querySelectorAll('.hunk').length, 2)
  // Actions in the header do not toggle the card.
  await flush(() => guide().querySelector('.diff-actions button').click())
  assert.equal(guide().querySelectorAll('.hunk').length, 2)
})

test('collapse all and expand all apply to every visible file', async () => {
  await mount(false)
  const toggle = () => root.querySelector('.review-toolbar [aria-label="Collapse all"], .review-toolbar [aria-label="Expand all"]')
  assert.equal(toggle().getAttribute('aria-label'), 'Collapse all')
  await flush(() => toggle().click())
  assert.equal(root.querySelectorAll('.diff-card-body').length, 0)
  assert.equal(toggle().getAttribute('aria-label'), 'Expand all')
  await flush(() => toggle().click())
  assert.equal(root.querySelectorAll('.diff-card-body').length, 8)
})

test('the jump list appears only while the navigator is hidden and reveals a folded file', async () => {
  await mount(false)
  const rows = [...root.querySelectorAll('.review-index .review-index-row')]
  assert.equal(rows.length, 10)
  await flush(() => rows.find(row => row.textContent.includes('old-notes.md')).click())
  assert.ok(!card('docs/old-notes.md').classList.contains('collapsed'))
  assert.ok(card('docs/old-notes.md').classList.contains('selected'))

  await mount(true)
  assert.equal(root.querySelector('.review-index'), null)
  const nav = [...root.querySelectorAll('.review-files .review-file')]
  assert.deepEqual(nav.slice(0, 8).map(row => row.querySelector('.change-badge').textContent), ['R', 'M', 'D', 'R', 'A', 'M', 'M', 'M'])
  await flush(() => nav.filter(row => row.textContent.includes('index.ts'))[1].click())
  assert.ok(card('src/inspector/index.ts').classList.contains('selected'))
  assert.ok(!card('src/components/index.ts').classList.contains('selected'))
})
