import assert from 'node:assert/strict'
import { test } from 'node:test'

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
  state.moveTabRight(file('a.md'))
  return state.currentPane()
}
const tabIds = (column) => column.tabs.map(t => t.id)

test('a workspace starts with pinned chat and a wider, tabbed workbench', () => {
  workspace()
  const pane = state.currentPane()
  assert.deepEqual(tabIds(pane.columns[0]), ['chat'])
  assert.deepEqual(tabIds(pane.columns[1]), ['changes', 'explorer'])
  assert.equal(pane.columns[1].active, 'explorer')
  assert.ok(pane.columns[1].size > pane.columns[0].size)
  // Closed until asked for; the toggle opens it focused on the workbench.
  assert.equal(pane.workbenchCollapsed, true)
  assert.equal(pane.focus, 0)
  state.toggleWorkbench()
  assert.equal(pane.workbenchCollapsed, false)
  assert.equal(pane.focus, 1)
})

test('opening or switching to a session starts with the workbench closed; the toggle still works within it', async () => {
  workspace()
  const path = app.peek().workspacePath
  app.value = { workspacePath: path, selectedSessionId: 's1' }
  const pane = state.currentPane()
  assert.equal(pane.workbenchCollapsed, true)
  state.toggleWorkbench()
  assert.equal(pane.workbenchCollapsed, false, 'manual toggle opens it')
  // Further state pushes for the same session leave it alone.
  app.value = { workspacePath: path, selectedSessionId: 's1', streaming: true }
  assert.equal(pane.workbenchCollapsed, false)
  const id = file('notes.md')
  assert.equal(pane.workbenchCollapsed, false, 'opening a file keeps it open')
  // Another session: closed again, tabs kept.
  app.value = { workspacePath: path, selectedSessionId: 's2' }
  assert.equal(pane.workbenchCollapsed, true)
  assert.ok(pane.columns.slice(1).some(col => col.tabs.some(tab => tab.id === id)), 'tabs stay alive')
  // New chat (no session) does not touch it; reopening restores the workbench focus.
  state.toggleWorkbench()
  app.value = { workspacePath: path, selectedSessionId: null }
  assert.equal(pane.workbenchCollapsed, false)
  app.value = { workspacePath: path, selectedSessionId: 's1' }
  assert.equal(pane.workbenchCollapsed, true)
  state.toggleWorkbench()
  assert.ok(pane.focus >= 1)
})

test('opening files or changes from chat never replaces the chat pane', () => {
  workspace()
  state.selectTab('chat')
  const id = file('a.md')
  const pane = state.currentPane()
  assert.equal(pane.columns[0].active, 'chat')
  assert.equal(pane.columns[1].active, id)
  state.showInspector('changes')
  assert.equal(pane.columns[1].active, 'changes')
  assert.equal(state.homeIsChat(), true)
  state.openFile(id.slice(5))
  assert.equal(tabIds(pane.columns[1]).filter(tab => tab === id).length, 1)
})

test('resizing preserves the pair total and unrelated column weight', () => {
  const pane = threeColumns()
  const before = pane.columns.map(c => c.size)
  state.resizeColumns(0, 320, 280)
  const sizes = pane.columns.map(c => c.size)
  assert.equal(sizes[2], before[2])
  assert.ok(Math.abs(sizes[0] + sizes[1] - before[0] - before[1]) < 1e-10)
  assert.ok(Math.abs(sizes[0] / sizes[1] - 320 / 280) < 1e-10)
  state.resizeColumns(1, 200, 400)
  assert.equal(pane.columns[0].size, sizes[0])
  assert.ok(Math.abs(pane.columns.reduce((sum, c) => sum + c.size, 0) - before.reduce((sum, size) => sum + size, 0)) < 1e-10)
})

test('splitting after resizing creates a usable column, and never a fourth', () => {
  workspace()
  const id = file('a.md')
  state.resizeColumns(0, 500, 300)
  state.moveTabRight(id)
  const pane = state.currentPane()
  assert.equal(pane.columns.length, 3)
  assert.ok(pane.columns.every(c => c.size >= 0.5 && c.size <= 2))
  state.moveTabRight(id)
  assert.equal(pane.columns.length, 3)
  assert.equal(pane.columns[2].active, id)
})

test('invalid drag measurements leave the layout untouched', () => {
  const pane = threeColumns()
  const before = pane.columns.map(c => c.size)
  for (const [left, right] of [[0, 0], [-1, 10], [NaN, 10], [10, Infinity]]) {
    state.resizeColumns(0, left, right)
    assert.deepEqual(pane.columns.map(c => c.size), before)
  }
})

test('closing the last split tab removes only that column', async () => {
  workspace()
  const id = file('a.md')
  state.moveTabRight(id)
  const pane = state.currentPane()
  assert.equal(pane.columns.length, 3)
  await state.closeTab(id)
  assert.equal(pane.columns.length, 2)
  assert.equal(pane.focus, 1)
  assert.deepEqual(tabIds(pane.columns[0]), ['chat'])
  assert.deepEqual(tabIds(pane.columns[1]), ['changes', 'explorer'])
})

test('all workbench tabs can close and reopen without closing chat', async () => {
  workspace()
  const pane = state.currentPane()
  await state.closeTab('changes')
  await state.closeTab('explorer')
  await state.closeTab('chat')
  state.moveTabRight('chat')
  assert.equal(pane.columns.length, 1)
  assert.deepEqual(tabIds(pane.columns[0]), ['chat'])
  state.showInspector('changes')
  assert.equal(pane.columns[1].active, 'changes')
  state.openExplorer()
  assert.equal(pane.columns[1].active, 'explorer')
})

test('changes and explorer tabs belong independently to each workspace', () => {
  workspace()
  const first = state.currentPane()
  workspace()
  state.openExplorer()
  state.showInspector('changes')
  assert.deepEqual(tabIds(first.columns[1]), ['changes', 'explorer'])
})

test('a failed discard confirmation keeps unsaved buffers and tabs', async () => {
  workspace()
  const id = file('draft.md')
  const buffer = state.buffers.get(id.slice(5))
  buffer.draft.value = '# Unsaved'
  buffer.dirty.value = true
  await state.closeTab(id)
  assert.ok(tabIds(state.currentPane().columns[1]).includes(id))
  assert.equal(buffer.draft.value, '# Unsaved')
  state.selectTab('changes')
  state.selectTab(id)
  assert.equal(buffer.dirty.value, true)
})

test('Documents remains a standalone shelf rather than gaining chat', () => {
  workspace()
  const workspacePane = state.currentPane()
  state.seedDemoText('/outside/guide.md', '# Guide')
  state.openExternal('/outside/guide.md')
  assert.equal(route.value.name, 'documents')
  assert.equal(state.currentPane().columns.length, 1)
  assert.deepEqual(tabIds(state.currentPane().columns[0]), ['file:/outside/guide.md'])
  route.value = { name: 'main' }
  assert.equal(state.currentPane(), workspacePane)
  assert.equal(state.homeIsChat(), true)
})

test('collapsing keeps every tab, dirty buffer, active selection and split width', () => {
  const pane = threeColumns()
  const tab = pane.columns[2].tabs[0]
  const buffer = state.buffers.get(tab.path)
  buffer.draft.value = '# Unsubmitted edits'
  buffer.dirty.value = true
  state.resizeColumns(0, 420, 280)
  const columns = JSON.stringify(pane.columns)
  state.toggleWorkbench()
  assert.equal(pane.workbenchCollapsed, true)
  assert.equal(pane.focus, 0)
  assert.equal(JSON.stringify(pane.columns), columns)
  state.selectTab('chat')
  assert.equal(pane.workbenchCollapsed, true)
  state.toggleWorkbench()
  assert.equal(pane.workbenchCollapsed, false)
  assert.equal(pane.focus, 2)
  assert.equal(JSON.stringify(pane.columns), columns)
  assert.equal(buffer.draft.value, '# Unsubmitted edits')
  assert.equal(buffer.dirty.value, true)
})

test('hidden workspace reopens for selected tabs, file links, changes and split commands', () => {
  workspace()
  const id = file('open.txt')
  const pane = state.currentPane()
  for (const show of [() => state.selectTab(id), () => state.openFile(id.slice(5)), () => state.showInspector('changes'), () => state.openExplorer(), () => state.splitFocused()]) {
    state.toggleWorkbench()
    assert.equal(pane.workbenchCollapsed, true)
    show()
    assert.equal(pane.workbenchCollapsed, false)
    assert.equal(pane.columns[0].active, 'chat')
  }
})

test('collapse is workspace-local, never hides Documents, and can reopen an empty workbench', async () => {
  workspace()
  const path = app.peek().workspacePath
  const first = state.currentPane()
  state.toggleWorkbench()
  assert.equal(first.workbenchCollapsed, false)
  workspace()
  assert.equal(state.currentPane().workbenchCollapsed, true, 'a new workspace starts closed')
  app.value = { workspacePath: path }
  assert.equal(state.currentPane().workbenchCollapsed, false, 'the first one kept its own state')
  route.value = { name: 'documents' }
  const docs = state.currentPane()
  state.toggleWorkbench()
  assert.equal(route.value.name, 'documents')
  assert.equal(docs.workbenchCollapsed, false)
  route.value = { name: 'main' }
  await state.closeTab('changes')
  await state.closeTab('explorer')
  assert.equal(first.columns.length, 1)
  state.toggleWorkbench()
  assert.equal(first.columns.length, 2)
  assert.equal(first.workbenchCollapsed, false)
  assert.equal(first.columns[1].active, 'explorer')
})
