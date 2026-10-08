import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseHTML } from 'linkedom'
import { h, render } from 'preact'
import { act } from 'preact/test-utils'

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
