// The leftmost workspace column is reserved for chat. Changes, the file
// browser, files, diffs, and terminals share the workbench to its right. Documents is a separate shelf for
// Markdown opened outside the current workspace. File buffers are global.
import { batch, effect, signal, type Signal } from '@preact/signals'
import { inApp, onMessage, post } from '../bridge'
import { rpc, type FileRead } from '../rpc'
import type { DiffFile } from '../types'
import { app, route } from '../store'
import { t } from '../i18n'
import { prefs, prefsReady } from '../prefs'
import { canonicalPath } from '../reader/paths'
import { terminalSessions } from './terminalSessions'

export type Tab =
  | { kind: 'chat'; id: 'chat' }
  | { kind: 'changes'; id: 'changes' }
  | { kind: 'explorer'; id: 'explorer' }
  | { kind: 'file'; id: string; path: string }
  | { kind: 'diff'; id: string; file: DiffFile }
  | { kind: 'term'; id: string; termId: string; title: string; exited?: boolean }

export interface Column {
  id: string
  tabs: Tab[]
  active: string
  /** Relative flex grow. Dragging preserves the adjacent pair's total weight. */
  size: number
}

interface PaneState {
  columns: Column[]
  focus: number
  workbenchCollapsed: boolean
  /** Restore the previously focused column without changing tabs or widths. */
  workbenchFocus?: string
}

/** Shelf key that cannot collide with a workspace path. */
const DOCUMENTS = '\0documents'

const panes = new Map<string, PaneState>()
export const paneVersion = signal(0)
let columnSeq = 1

function bump() {
  paneVersion.value++
  persistDocuments()
}

function newColumn(tabs: Tab[], active: string): Column {
  return { id: 'col' + columnSeq++, tabs, active, size: 1 }
}

function freshWorkspace(): PaneState {
  const chat = newColumn([{ kind: 'chat', id: 'chat' }], 'chat')
  const workbench = newColumn([{ kind: 'changes', id: 'changes' }, { kind: 'explorer', id: 'explorer' }], 'explorer')
  workbench.size = 1.9
  // Closed until asked for: the chat opens alone, the toggle brings the workbench back.
  return { columns: [chat, workbench], focus: 0, workbenchCollapsed: true, workbenchFocus: workbench.id }
}

function workspaceKey() {
  const path = app.peek()?.workspacePath ?? ''
  return path ? canonicalPath(path) : ''
}

function normalizeFile(path: string) {
  return path.startsWith('/') ? canonicalPath(path) : path
}

function insideWorkspace(path: string) {
  const root = workspaceKey()
  return !!root && (path === root || path.startsWith(root + '/'))
}

export function currentPane(): PaneState {
  void paneVersion.value
  const key = route.peek().name === 'documents' ? DOCUMENTS : workspaceKey()
  return ensurePane(key)
}

function ensurePane(key: string): PaneState {
  let pane = panes.get(key)
  if (!pane?.columns?.length) {
    pane = key === DOCUMENTS ? { columns: [newColumn([], '')], focus: 0, workbenchCollapsed: false } : freshWorkspace()
    panes.set(key, pane)
  }
  if (key !== DOCUMENTS) {
    const home = pane.columns[0]
    if (!home.tabs.some((t) => t.id === 'chat')) home.tabs.unshift({ kind: 'chat', id: 'chat' })
    if (!home.tabs.some((t) => t.id === home.active)) home.active = home.tabs[0]?.id ?? 'chat'
  }
  if (pane.focus >= pane.columns.length) pane.focus = pane.columns.length - 1
  return pane
}

export function homeIsChat() {
  const pane = currentPane()
  return pane.columns[0]?.active === 'chat'
}

function activateAfterRemoval(col: Column, at: number) {
  const prev = col.tabs[at - 1]
  col.active = prev?.id ?? col.tabs.find((t) => t.id === 'chat')?.id ?? col.tabs[0]?.id ?? ''
}

function columnOf(pane: PaneState, id: string) {
  return pane.columns.findIndex((col) => col.tabs.some((tab) => tab.id === id))
}

export function selectTab(id: string) {
  const pane = currentPane()
  const index = columnOf(pane, id)
  if (index < 0) return
  if (index > 0) pane.workbenchCollapsed = false
  pane.columns[index].active = id
  pane.focus = index
  bump()
}

/** Hide the workbench, not its tabs: buffers, terminals and scroll state stay alive. */
export function toggleWorkbench() {
  if (route.peek().name === 'documents') return
  route.value = { name: 'main' }
  const pane = currentPane()
  if (pane.columns.length === 1) { openExplorer(); return }
  pane.workbenchCollapsed = !pane.workbenchCollapsed
  if (pane.workbenchCollapsed) {
    pane.workbenchFocus = pane.columns[Math.max(1, pane.focus)]?.id
    pane.focus = 0
    // Native keyboard focus must not remain inside a now-hidden terminal/editor.
    post('focusComposer')
  } else {
    pane.focus = Math.max(1, pane.columns.findIndex((col) => col.id === pane.workbenchFocus))
  }
  bump()
}

export function showInspector(tabId = 'explorer') {
  route.value = { name: 'main' }
  if (tabId === 'changes') placeOn(workspaceKey(), { kind: 'changes', id: 'changes' })
  else openExplorer()
}

export function openExplorer() {
  route.value = { name: 'main' }
  prefs.inspectorOpen.value = true
  placeOn(workspaceKey(), { kind: 'explorer', id: 'explorer' })
}

function detachTab(pane: PaneState, id: string) {
  const index = columnOf(pane, id)
  if (index < 0) return
  const col = pane.columns[index]
  const at = col.tabs.findIndex((tab) => tab.id === id)
  if (at < 0) return
  col.tabs.splice(at, 1)
  if (col.active === id) activateAfterRemoval(col, at)
  dropEmptySideColumn(pane, index)
}

/** One tab per file across shelves. An open copy is moved, not duplicated. */
function placeOn(key: string, tab: Tab) {
  if (tab.kind === 'file') {
    for (const [other, pane] of panes) if (other !== key) detachTab(pane, tab.id)
  }
  const pane = ensurePane(key)
  if (key !== DOCUMENTS) pane.workbenchCollapsed = false
  const existing = columnOf(pane, tab.id)
  if (existing >= 0) {
    const col = pane.columns[existing]
    const prior = col.tabs.find((t) => t.id === tab.id)
    if (prior && tab.kind === 'diff' && prior.kind === 'diff') prior.file = tab.file
    col.active = tab.id
    pane.focus = existing
    bump()
    return
  }
  // Opening from chat (including an agent's file link) never replaces chat.
  if (key !== DOCUMENTS && pane.columns.length === 1) {
    const workbench = newColumn([], '')
    workbench.size = 1.9
    pane.columns.push(workbench)
  }
  const index = Math.max(key === DOCUMENTS ? 0 : 1, Math.min(pane.focus, pane.columns.length - 1))
  const col = pane.columns[index]
  const picker = col.tabs.findIndex((item) => item.kind === 'explorer')
  if (picker < 0) col.tabs.push(tab)
  else col.tabs.splice(picker, 0, tab)
  col.active = tab.id
  pane.focus = pane.columns.indexOf(col)
  bump()
}

function fileTab(path: string): Tab {
  return { kind: 'file', id: 'file:' + path, path }
}

/** Open on the shelf currently on screen. Settings returns to the workspace. */
export function openFile(path: string) {
  const key = normalizeFile(path)
  ensureBuffer(key)
  if (route.peek().name === 'settings') route.value = { name: 'main' }
  const shelf = route.peek().name === 'documents' ? DOCUMENTS : workspaceKey()
  placeOn(shelf, fileTab(key))
}

/** Finder and ⌘O. Paths inside the current workspace stay there; others go to Documents. */
export function openExternal(path: string) {
  const key = normalizeFile(path)
  ensureBuffer(key)
  const inside = insideWorkspace(key)
  route.value = { name: inside ? 'main' : 'documents' }
  placeOn(inside ? workspaceKey() : DOCUMENTS, fileTab(key))
}

export function openDiff(file: DiffFile) {
  if (route.peek().name !== 'main') route.value = { name: 'main' }
  placeOn(workspaceKey(), { kind: 'diff', id: 'diff:' + file.path, file })
}

export async function openTerminal(cwd?: string) {
  if (route.peek().name !== 'main') route.value = { name: 'main' }
  const root = cwd ?? app.peek()?.inspectorRoot
  const shelf = workspaceKey()
  try {
    const res = await rpc<{ id: string; index: number; shell: string }>('term.open', { cwd: root, cols: 80, rows: 24 })
    placeOn(shelf, { kind: 'term', id: 'term:' + res.id, termId: res.id, title: root?.split('/').filter(Boolean).pop() || res.shell })
  } catch (e) {
    post('log', { message: 'term.open failed: ' + e })
  }
}

function noteStamp() {
  const d = new Date()
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`
}

/** A new Markdown note under ~/.aureways, opened in Documents. Not a workspace. */
export async function createNote() {
  const home = app.peek()?.homePath
  if (!home) return
  const path = canonicalPath(home.replace(/\/+$/, '') + '/.aureways') + `/笔记 ${noteStamp()}.md`
  const text = '# 笔记\n\n'
  if (!inApp) seedDemoText(path, text)
  else {
    try {
      await rpc('fs.write', { path, text, force: true })
    } catch (e) {
      post('log', { message: 'create note failed: ' + e })
      return
    }
  }
  route.value = { name: 'documents' }
  const buffer = ensureBuffer(path)
  if (!inApp) {
    buffer.data.value = { path, size: text.length, mtime: 0, text }
    buffer.loading.value = false
    buffer.error.value = null
  }
  placeOn(DOCUMENTS, fileTab(path))
}

function documentPaths(): string[] {
  const pane = panes.get(DOCUMENTS)
  if (!pane) return []
  const paths: string[] = []
  for (const col of pane.columns) for (const tab of col.tabs) if (tab.kind === 'file') paths.push(tab.path)
  return paths
}

function samePaths(a: string[], b: string[]) {
  return a.length === b.length && a.every((p, i) => p === b[i])
}

function persistDocuments() {
  const next = documentPaths()
  const cur = prefs.documentPaths.peek()
  if (!Array.isArray(cur) || samePaths(cur, next)) return
  prefs.documentPaths.value = next
}

let documentsSeeded = false
effect(() => {
  if (!prefsReady.value || documentsSeeded) return
  const stored = prefs.documentPaths.value
  documentsSeeded = true
  if (!Array.isArray(stored)) return
  for (const path of stored) {
    if (typeof path !== 'string' || !path.startsWith('/')) continue
    ensureBuffer(path)
    placeOn(DOCUMENTS, fileTab(normalizeFile(path)))
  }
})

/**
 * Opening or switching to a session starts with the workbench closed (its
 * tabs stay alive). Within the session the toggle, file links and the "+"
 * menu open it as before.
 */
let lastSession: string | null | undefined
effect(() => {
  const id = app.value?.selectedSessionId
  if (id === undefined || id === lastSession) return
  lastSession = id
  if (id) collapseWorkbenchForSession()
})

function collapseWorkbenchForSession() {
  const pane = ensurePane(workspaceKey())
  if (pane.workbenchCollapsed || pane.columns.length < 2) return
  pane.workbenchFocus = pane.columns[Math.max(1, pane.focus)]?.id
  pane.workbenchCollapsed = true
  pane.focus = 0
  bump()
}

function tabLiveElsewhere(id: string, except: Column) {
  for (const pane of panes.values()) {
    for (const col of pane.columns) {
      if (col !== except && col.tabs.some((tab) => tab.id === id)) return true
    }
  }
  return false
}

function dropEmptySideColumn(pane: PaneState, index: number) {
  if (index <= 0) return
  if (pane.columns[index].tabs.length > 0) return
  pane.columns.splice(index, 1)
  if (pane.focus >= pane.columns.length) pane.focus = pane.columns.length - 1
  else if (pane.focus > index) pane.focus -= 1
}

export async function closeTab(id: string) {
  const pane = currentPane()
  const index = columnOf(pane, id)
  if (index < 0) return
  const col = pane.columns[index]
  const tabAt = col.tabs.findIndex((tab) => tab.id === id)
  const tab = col.tabs[tabAt]
  if (!tab || tab.kind === 'chat') return
  if (tab.kind === 'file') {
    const buffer = buffers.get(tab.path)
    if (buffer?.dirty.value) {
      const name = tab.path.split('/').pop() ?? tab.path
      const ok = await rpc<boolean>('ui.confirm', { message: t('unsavedClose', name), ok: t('discard'), cancel: t('cancel') }).catch(() => false)
      if (!ok) return
    }
    if (!tabLiveElsewhere(id, col)) buffers.delete(tab.path)
  }
  if (tab.kind === 'term') {
    post('term.close', { id: tab.termId })
    terminalClosed(tab.termId)
  }
  col.tabs.splice(tabAt, 1)
  if (col.active === id) activateAfterRemoval(col, tabAt)
  dropEmptySideColumn(pane, index)
  bump()
}

/** Move a workbench tab into the column on its right. At most three columns. */
export function moveTabRight(id: string) {
  const pane = currentPane()
  const from = columnOf(pane, id)
  if (from < 0) return
  const src = pane.columns[from]
  const tab = src.tabs.find((t) => t.id === id)
  if (!tab || tab.kind === 'chat') return
  if (from === pane.columns.length - 1 && pane.columns.length >= 3) return
  pane.workbenchCollapsed = false
  const at = src.tabs.findIndex((t) => t.id === id)
  src.tabs.splice(at, 1)
  if (src.active === id) activateAfterRemoval(src, at)
  let to = from + 1
  if (to === pane.columns.length) pane.columns.push(newColumn([], id))
  const dst = pane.columns[to]
  dst.tabs.push(tab)
  dst.active = id
  dropEmptySideColumn(pane, from)
  pane.focus = pane.columns.findIndex((col) => col.active === id && col.tabs.some((t) => t.id === id))
  if (pane.focus < 0) pane.focus = Math.min(to, pane.columns.length - 1)
  bump()
}

export function splitFocused() {
  const pane = currentPane()
  const col = pane.columns[pane.focus]
  if (!col) return
  if (col.active === 'chat') { openExplorer(); return }
  moveTabRight(col.active)
}

export function resizeColumns(index: number, left: number, right: number) {
  const pane = currentPane()
  const a = pane.columns[index]
  const b = pane.columns[index + 1]
  if (!a || !b) return
  if (!Number.isFinite(left) || !Number.isFinite(right) || left <= 0 || right <= 0) return
  const total = a.size + b.size
  a.size = total * (left / (left + right))
  b.size = total - a.size
  bump()
}

// ---- File buffers -----------------------------------------------------------

export interface Buffer {
  path: string
  loading: Signal<boolean>
  data: Signal<FileRead | null>
  error: Signal<string | null>
  /** Editor text while editing; null when showing the file as read. */
  draft: Signal<string | null>
  dirty: Signal<boolean>
  external: Signal<boolean>
  preview: Signal<boolean>
}

export const buffers = new Map<string, Buffer>()

export function ensureBuffer(path: string): Buffer {
  let b = buffers.get(path)
  if (!b) {
    b = {
      path,
      loading: signal(true),
      data: signal(null),
      error: signal(null),
      draft: signal(null),
      dirty: signal(false),
      external: signal(false),
      preview: signal(/\.(md|markdown|mdown|mkd|mkdn|mdwn)$/i.test(path)),
    }
    buffers.set(path, b)
    void loadBuffer(b)
  }
  return b
}

const demoTexts = new Map<string, string>()

/** Vite demo only. Lets the reader open without the native fs.read bridge. */
export function seedDemoText(path: string, text: string) {
  demoTexts.set(path, text)
}

export function releaseBufferIfUnused(path: string) {
  const key = path.replace(/^\/private\//, '/')
  const used = [...panes.values()].some((p) =>
    p.columns.some((col) => col.tabs.some((t) => t.kind === 'file' && t.path.replace(/^\/private\//, '/') === key)),
  )
  if (!used) buffers.delete(path)
}

export async function loadBuffer(b: Buffer) {
  if (!inApp) {
    const text = demoTexts.get(b.path)
    if (text != null && !b.data.peek()) {
      b.data.value = { path: b.path, size: text.length, mtime: 0, text }
      b.error.value = null
    } else if (!b.data.peek()) b.error.value = 'offline'
    b.loading.value = false
    return
  }
  b.loading.value = true
  try {
    const data = await rpc<FileRead>('fs.read', { path: b.path })
    batch(() => {
      b.data.value = data
      b.error.value = null
      b.external.value = false
      if (!b.dirty.value) b.draft.value = null
    })
  } catch (e) {
    b.error.value = (e as Error).message
  } finally {
    b.loading.value = false
  }
}

export async function saveBuffer(b: Buffer, force = false): Promise<boolean> {
  const text = b.draft.value
  if (text === null) return true
  try {
    const res = await rpc<{ mtime: number }>('fs.write', { path: b.path, text, mtime: b.data.peek()?.mtime, force })
    batch(() => {
      b.data.value = { ...(b.data.peek() as FileRead), text, mtime: res.mtime, size: text.length }
      b.dirty.value = false
      b.external.value = false
    })
    return true
  } catch (e) {
    if ((e as Error).message === 'conflict') b.external.value = true
    else b.error.value = (e as Error).message
    return false
  }
}

const sameFile = (a: string, b: string) => a.replace(/^\/private\//, '/') === b.replace(/^\/private\//, '/')

onMessage((m) => {
  if (m.type === 'fileChanged') {
    for (const b of buffers.values()) {
      if (!sameFile(b.path, m.path)) continue
      if (b.dirty.peek()) b.external.value = true
      else void loadBuffer(b)
    }
    filesVersion.value++
  }
  if (m.type === 'command' && m.name === 'openFiles' && m.paths) {
    route.value = { name: 'main' }
    for (const p of m.paths) openFile(p)
  }
})

/** Bumped when the agent writes files, so trees and the changes view refresh. */
export const filesVersion = signal(0)

// ---- Terminals ----------------------------------------------------------------

type TermListener = { data(b64: string): void; exit(code: number | null): void }
const termListeners = new Map<string, TermListener>()
const termBacklog = new Map<string, string[]>()

export function subscribeTerminal(id: string, l: TermListener) {
  termListeners.set(id, l)
  for (const chunk of termBacklog.get(id) ?? []) l.data(chunk)
  termBacklog.delete(id)
  return () => { if (termListeners.get(id) === l) termListeners.delete(id) }
}

function terminalClosed(id: string) {
  terminalSessions.close(id)
  termListeners.delete(id)
  termBacklog.delete(id)
}

onMessage((m) => {
  if (m.type === 'termData') {
    const l = termListeners.get(m.id)
    if (l) l.data(m.data)
    else {
      const list = termBacklog.get(m.id) ?? []
      list.push(m.data)
      termBacklog.set(m.id, list)
    }
  } else if (m.type === 'termExit') {
    termListeners.get(m.id)?.exit(m.code)
    for (const pane of panes.values()) {
      for (const col of pane.columns) {
        for (const tab of col.tabs) if (tab.kind === 'term' && tab.termId === m.id) tab.exited = true
      }
    }
    bump()
  }
})
