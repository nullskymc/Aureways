import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseHTML } from 'linkedom'
import { h, render } from 'preact'
import { act } from 'preact/test-utils'

const { window, document } = parseHTML('<html><body><div id="app"></div></body></html>')
window.HTMLElement.prototype.onkeydown = null
Object.assign(globalThis, { window, document, HTMLElement: window.HTMLElement, Element: window.Element })
globalThis.requestAnimationFrame = callback => setTimeout(callback, 0)
globalThis.cancelAnimationFrame = clearTimeout
globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} }
globalThis.MutationObserver = class { observe() {} disconnect() {} }
globalThis.getComputedStyle = () => ({ color: 'rgb(0, 0, 0)', paddingLeft: '0', paddingRight: '0', maxWidth: 'none' })
globalThis.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} })
window.webkit = { messageHandlers: { aureways: { postMessage() {} } } }

const { App } = await import('../src/components/App.tsx')
const { prefs, coercePref } = await import('../src/prefs.ts')

test('stored prefs keep the type of their default', () => {
  assert.equal(coercePref(true, 0), false)
  assert.equal(coercePref(true, 1), true)
  assert.equal(coercePref(false, 'true'), true)
  assert.equal(coercePref(true, { bad: 1 }), true)
  assert.equal(coercePref(272, 'wide'), 272)
  assert.deepEqual(coercePref([], 'x'), [])
  assert.deepEqual(coercePref([], ['/a.md']), ['/a.md'])
})

test('a sidebar flag stored as 0 closes the sidebar without printing "0" in the header', async () => {
  const root = document.getElementById('app')
  await act(async () => { render(h(App, {}), root) })
  const state = {
    locale: 'en', appearance: 'system', selectedSessionId: null, selectedAgentId: 'codex',
    workspacePath: '/w', workspaceName: 'w', branch: null, homePath: '/Users/demo', error: null,
    chrome: { trafficLights: { x: 20, y: 19, w: 52, h: 14 }, fullscreen: false, titlebarHeight: 52, leadingInset: 122, trailingInset: 88, nativeTitlebar: true, glass: true, composerOverlay: true },
    workspaces: [], agents: [], sessions: [], composer: { sessionId: null, attachments: [] },
    inspectorRoot: '/w',
    // UserDefaults handed back integers instead of booleans.
    uiPrefs: { sidebarOpen: 0, inspectorOpen: 0, sidebarWidth: 300 },
  }
  await act(async () => {
    window.__aw.receive({ type: 'state', state })
    await new Promise(resolve => setTimeout(resolve, 20))
  })
  const app = root.querySelector('.app')
  assert.ok(app, 'app rendered')
  assert.ok(app.className.includes('no-sidebar'))
  assert.equal(root.querySelector('.sidebar'), null)
  const stray = [...app.childNodes].filter(node => node.nodeType === 3 && node.textContent.trim() !== '')
  assert.deepEqual(stray.map(node => node.textContent), [], 'no bare text at the top of the window')
  assert.ok(!/^\s*0/.test(app.textContent), 'window text must not start with a stray 0')
  assert.equal(prefs.sidebarOpen.value, false)
  assert.equal(prefs.inspectorOpen.value, false)
  assert.equal(prefs.sidebarWidth.value, 300)
  await act(async () => { render(null, root) })
})
