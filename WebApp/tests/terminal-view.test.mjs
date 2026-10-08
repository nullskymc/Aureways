import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseHTML } from 'linkedom'
import { h, render } from 'preact'
import { act } from 'preact/test-utils'
import { instances } from './fixtures/xterm.mjs'

const { window, document } = parseHTML('<html><body><div id="app"></div></body></html>')
globalThis.window = window
globalThis.document = document
globalThis.requestAnimationFrame = callback => setTimeout(callback, 0)
globalThis.cancelAnimationFrame = clearTimeout
globalThis.getComputedStyle = () => ({ color: 'rgb(0, 0, 0)' })
globalThis.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} })
globalThis.ResizeObserver = class { observe() {} disconnect() {} }
globalThis.MutationObserver = class { observe() {} disconnect() {} }
const messages = []
window.webkit = { messageHandlers: { aureways: { postMessage(m) { messages.push(m) } } } }

const { TerminalView } = await import('../src/inspector/Terminal.tsx')
const state = await import('../src/inspector/state.ts')
const { app, route } = await import('../src/store.ts')
const root = document.getElementById('app')
async function flush(callback = () => {}) {
  await act(async () => { callback(); await new Promise(resolve => setTimeout(resolve, 10)) })
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 10)) })
}
function columns(right) {
  return h('div', {}, [
    h('section', { key: 'left' }, right ? null : h(TerminalView, { key: 'term', id: 't1', visible: true, exited: false })),
    h('section', { key: 'right' }, right ? h(TerminalView, { key: 'term', id: 't1', visible: true, exited: false }) : null),
  ])
}
function output(text) { window.__aw.receive({ type: 'termData', id: 't1', data: Buffer.from(text).toString('base64') }) }

test('real view remounts preserve terminal history, DOM, scroll and subscription until tab close', async () => {
  app.value = { workspacePath: '/repo', inspectorRoot: '/repo' }
  route.value = { name: 'main' }
  const opened = state.openTerminal()
  const request = messages.findLast(m => m.method === 'term.open')
  window.__aw.receive({ type: 'rpcResult', id: request.id, result: { id: 't1', shell: 'zsh', index: 1 } })
  await opened
  await flush(() => render(columns(false), root))
  assert.equal(instances.length, 1)
  const terminal = instances[0]
  const element = terminal.element
  output('before move\n')
  terminal.scrollTop = 42

  state.moveTabRight('term:t1')
  await flush(() => render(columns(true), root))
  assert.equal(instances.length, 1, 'moving must not recreate xterm')
  assert.equal(terminal.disposals, 0)
  assert.equal(terminal.scrollTop, 42)
  assert.equal(root.querySelectorAll('section')[1].contains(element), true)
  assert.equal(terminal.output, 'before move\n')
  output('after move\n')

  // Settings / another workspace temporarily unmounts all columns.
  await flush(() => render(null, root))
  output('while hidden\n')
  await flush(() => render(columns(false), root))
  assert.equal(instances.length, 1)
  assert.equal(terminal.output, 'before move\nafter move\nwhile hidden\n')
  assert.equal(terminal.scrollTop, 42)
  window.__aw.receive({ type: 'termExit', id: 't1', code: 0 })
  assert.match(terminal.output, /0/)

  await state.closeTab('term:t1')
  await flush(() => render(null, root))
  assert.equal(terminal.disposals, 1)
  assert.equal(element.isConnected, false)
  assert.equal(messages.filter(m => m.type === 'term.close').length, 1)
})

test('a pending terminal stays in its originating workspace', async () => {
  app.value = { workspacePath: '/origin', inspectorRoot: '/origin' }
  route.value = { name: 'main' }
  state.selectTab('chat')
  const origin = state.currentPane()
  const opened = state.openTerminal()
  const request = messages.findLast(m => m.method === 'term.open')
  app.value = { workspacePath: '/other', inspectorRoot: '/other' }
  const other = state.currentPane()
  window.__aw.receive({ type: 'rpcResult', id: request.id, result: { id: 't2', shell: 'zsh', index: 2 } })
  await opened
  assert.equal(origin.columns[0].active, 'chat')
  assert.equal(origin.columns[1].active, 'term:t2')
  assert.equal(origin.columns[1].tabs.find(t => t.id === 'term:t2').title, 'origin')
  assert.equal(other.columns.some(c => c.tabs.some(t => t.id === 'term:t2')), false)
  app.value = { workspacePath: '/origin', inspectorRoot: '/origin' }
  await state.closeTab('term:t2')
})
