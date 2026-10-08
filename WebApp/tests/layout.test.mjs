import assert from 'node:assert/strict'
import { test } from 'node:test'

// State tests need only the bridge's browser globals, not a native application.
globalThis.window = { addEventListener() {}, setTimeout, setInterval }
globalThis.document = { documentElement: { style: {} } }
const state = await import('../src/inspector/state.ts')
const { app, route } = await import('../src/store.ts')
let seq = 0
function workspace() {
  app.value = { workspacePath: `/test-${++seq}` }
  route.value = { name: 'main' }
}
function file(name) {
  const path = app.peek().workspacePath + '/' + name
  state.seedDemoText(path, '# Test')
  state.openFile(path)
  return 'file:' + path
}
function threeColumns() {
  workspace()
  const first = file('a.md')
  state.moveTabRight(first)
  const second = file('b.md')
  state.moveTabRight(second)
  return state.currentPane()
}

test('resizing one divider preserves the pair total and unrelated column weight', () => {
  const pane = threeColumns()
  state.resizeColumns(0, 320, 280)
  const sizes = pane.columns.map(c => c.size)
  assert.equal(sizes[2], 1)
  assert.ok(Math.abs(sizes[0] + sizes[1] - 2) < 1e-10)
  assert.ok(Math.abs(sizes[0] / sizes[1] - 320 / 280) < 1e-10)
  state.resizeColumns(1, 200, 400)
  assert.equal(pane.columns[0].size, sizes[0])
  assert.ok(Math.abs(pane.columns.reduce((sum, c) => sum + c.size, 0) - 3) < 1e-10)
})

test('splitting after a resize does not create a nearly zero-width column', () => {
  workspace()
  const first = file('a.md')
  state.moveTabRight(first)
  state.resizeColumns(0, 500, 300)
  const second = file('b.md')
  state.moveTabRight(second)
  assert.equal(state.currentPane().columns.length, 3)
  assert.ok(state.currentPane().columns.every(c => c.size >= 0.5 && c.size <= 1.5))
})

test('invalid drag measurements leave the layout untouched', () => {
  const pane = threeColumns()
  for (const [left, right] of [[0, 0], [-1, 10], [NaN, 10], [10, Infinity]]) {
    state.resizeColumns(0, left, right)
    assert.deepEqual(pane.columns.map(c => c.size), [1, 1, 1])
  }
})

test('moving and closing the last side tab removes only that column', async () => {
  workspace()
  const id = file('a.md')
  state.moveTabRight(id)
  const pane = state.currentPane()
  assert.equal(pane.columns.length, 2)
  assert.equal(pane.columns[0].active, 'chat')
  await state.closeTab(id)
  assert.equal(pane.columns.length, 1)
  assert.equal(pane.focus, 0)
  assert.deepEqual(pane.columns[0].tabs.map(t => t.id), ['chat', 'changes'])
})
