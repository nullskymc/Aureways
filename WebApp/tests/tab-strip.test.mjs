import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseHTML } from 'linkedom'
import { h, render } from 'preact'
import { act } from 'preact/test-utils'
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
const resizeObservers = []
globalThis.ResizeObserver = class {
  constructor(callback) { this.callback = callback; resizeObservers.push(this) }
  observe(element) { this.element = element }
  disconnect() { this.disconnected = true }
}
const { TabStrip } = await import('../src/inspector/Inspector.tsx')
const state = await import('../src/inspector/state.ts')
const { app, route } = await import('../src/store.ts')
const root = document.getElementById('app')
const model = { workspacePath: '/tabs', sessions: [], locale: 'en', chrome: { trafficLights: { x: 12, w: 54 }, fullscreen: false } }
async function flush(callback) {
  await act(async () => { callback(); await new Promise(resolve => setTimeout(resolve, 5)) })
}

test('workbench tabs expose selection and support arrow/Home/End navigation', async () => {
  app.value = model
  route.value = { name: 'main' }
  const pane = state.currentPane()
  await flush(() => render(h(TabStrip, { state: model, sidebarOpen: true, session: null, column: pane.columns[1], index: 1 }), root))
  const tabs = () => [...root.querySelectorAll('[role="tab"]')]
  assert.equal(root.querySelector('[role="tablist"]').getAttribute('aria-label'), 'Workspace tabs')
  assert.deepEqual(tabs().map(tab => tab.getAttribute('aria-selected')), ['false', 'true'])
  assert.deepEqual(tabs().map(tab => tab.getAttribute('tabIndex')), ['-1', '0'])
  for (const [key, expected] of [['ArrowRight', 'changes'], ['End', 'explorer'], ['Home', 'changes'], ['ArrowLeft', 'explorer']]) {
    await flush(() => {
      const event = new window.Event('keydown', { bubbles: true, cancelable: true })
      event.key = key
      root.querySelector('[aria-selected="true"]').dispatchEvent(event)
    })
    assert.equal(pane.columns[1].active, expected)
    assert.equal(pane.columns[0].active, 'chat')
  }
  await flush(() => root.querySelector('[aria-label="Close Changes"]').click())
  assert.deepEqual(tabs().map(tab => tab.textContent), ['Open file'])
  assert.equal(pane.columns[1].active, 'explorer')
  await flush(() => render(null, root))
})

test('resizing or restoring the tab strip keeps its selection in view', async () => {
  app.value = { ...model, workspacePath: '/tabs-resize' }
  const pane = state.currentPane()
  await flush(() => render(h(TabStrip, { state: app.value, sidebarOpen: true, session: null, column: pane.columns[1], index: 1 }), root))
  const observer = resizeObservers.at(-1)
  const selected = root.querySelector('[aria-selected="true"]')
  let reveals = 0
  selected.scrollIntoView = () => reveals++
  Object.defineProperty(observer.element, 'clientWidth', { configurable: true, value: 130 })
  observer.callback()
  assert.equal(reveals, 1)
  Object.defineProperty(observer.element, 'clientWidth', { configurable: true, value: 0 })
  observer.callback()
  assert.equal(reveals, 1, 'hidden workbench must not scroll the page')
  Object.defineProperty(observer.element, 'clientWidth', { configurable: true, value: 350 })
  observer.callback()
  assert.equal(reveals, 2)
  await flush(() => render(null, root))
  assert.equal(observer.disconnected, true)
})

test('native title bar: the workbench strip is full width with equal-width tabs; chat has no strip or +', async () => {
  const native = { ...model, chrome: { trafficLights: { x: 20, y: 19, w: 52, h: 14 }, fullscreen: false, titlebarHeight: 52, nativeTitlebar: true, glass: true, leadingInset: 122, trailingInset: 126, addInset: 50 } }
  app.value = { ...native, workspacePath: '/tabs-native' }
  const pane = state.currentPane()
  await flush(() => render(h(TabStrip, { state: native, sidebarOpen: true, session: null, column: pane.columns[1], index: 1 }), root))
  const capsule = root.querySelector('.tab-capsule')
  assert.equal(capsule.dataset.glass, 'tabs')
  assert.equal(capsule.querySelector('.tab-add'), null, 'no + inside the strip')
  const tabs = [...capsule.querySelectorAll('.insp-tab')]
  assert.ok(tabs.length >= 2)
  assert.ok(tabs.every(tab => tab.parentElement.matches('.insp-tab-strip')))
  // Safari style: tabs share the row equally down to a minimum, then the strip scrolls.
  const css = readFileSync(join(process.cwd(), 'src/styles.css'), 'utf8')
  const rule = css.match(/\.glass-tabs \.tab-capsule \.insp-tab \{([^}]*)\}/)[1]
  assert.match(rule, /flex: 1 1 0;/)
  assert.match(rule, /min-width: \d+px;/)
  assert.match(css.match(/\.glass-tabs \.tab-capsule \.insp-tab-strip \{([^}]*)\}/)[1], /overflow-x: auto;/)
  assert.match(css.match(/\.glass-tabs \.tab-capsule \{([^}]*)\}/)[1], /flex: 1 1 auto;.*height: 26px;/)
  const chat = state.currentPane().columns[0]
  await flush(() => render(h(TabStrip, { state: native, sidebarOpen: true, session: null, column: chat, index: 0 }), root))
  assert.equal(root.querySelector('.tab-capsule, [role="tab"], .tab-add'), null)
  assert.equal(root.querySelector('.chat-title').textContent, 'New chat')
  await flush(() => render(null, root))
})

test('glass report: each strip carries its native Split right circle (offset, size, disabled)', async () => {
  const sent = []
  window.webkit = { messageHandlers: { aureways: { postMessage(m) { sent.push(m) } } } }
  const native = { ...model, chrome: { trafficLights: { x: 20, y: 19, w: 52, h: 14 }, fullscreen: false, titlebarHeight: 52, nativeTitlebar: true, glass: true, leadingInset: 122, newChatInset: 160, trailingInset: 126, addInset: 50 } }
  app.value = { ...native, workspacePath: '/tabs-split' }
  const pane = state.currentPane()
  const editors = document.createElement('div')
  editors.className = 'editors'
  const column = document.createElement('div')
  column.className = 'column'
  editors.appendChild(column)
  root.appendChild(editors)
  await flush(() => render(h(TabStrip, { state: native, sidebarOpen: true, session: null, column: pane.columns[1], index: 1 }), column))
  const box = (left, top, width, height) => () => ({ left, top, width, height, right: left + width, bottom: top + height, x: left, y: top })
  column.getBoundingClientRect = box(500, 0, 700, 600)
  const capsule = column.querySelector('.tab-capsule')
  const split = column.querySelector('button.tab-split')
  capsule.getBoundingClientRect = box(506, 13, 520, 26)
  split.getBoundingClientRect = box(1032, 13, 26, 26)
  window.innerWidth = 1200
  const { scheduleGlass } = await import('../src/glass.ts')
  scheduleGlass(1)
  await new Promise(resolve => setTimeout(resolve, 5))
  const tabs = sent.filter(m => m.type === 'glass').at(-1).rects.find(r => r.k === 'tabs')
  assert.equal(tabs.so, 6, 'circle starts 6 px after the strip')
  assert.equal(tabs.ss, 26)
  assert.equal(tabs.sd, undefined, 'enabled')
  split.disabled = true
  scheduleGlass(1)
  await new Promise(resolve => setTimeout(resolve, 5))
  assert.equal(sent.filter(m => m.type === 'glass').at(-1).rects.find(r => r.k === 'tabs').sd, 1, 'disabled state is re-sent exactly')
  await flush(() => render(null, column))
  editors.remove()
  delete window.webkit
})
