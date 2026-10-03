// Right-hand inspector: per-session tab lists (files browser, changes review,
// open files, terminals). File buffers and terminals are keyed globally so a
// file opened from two sessions shares one buffer.
import { batch, computed, signal, type Signal } from '@preact/signals'
import { onMessage, post } from '../bridge'
import { prefs } from '../prefs'
import { rpc, type FileRead } from '../rpc'
import { app } from '../store'
import { t } from '../i18n'

export type Tab =
  | { kind: 'files'; id: 'files' }
  | { kind: 'changes'; id: 'changes' }
  | { kind: 'file'; id: string; path: string }
  | { kind: 'term'; id: string; termId: string; title: string; exited?: boolean }

interface PaneState { tabs: Tab[]; active: string }

const FIXED: Tab[] = [
  { kind: 'files', id: 'files' },
  { kind: 'changes', id: 'changes' },
]

const panes = new Map<string, PaneState>()
export const paneVersion = signal(0)

export const paneKey = computed(() => app.value?.selectedSessionId ?? 'new')

export function currentPane(): PaneState {
  const key = paneKey.value
  void paneVersion.value
  let pane = panes.get(key)
  if (!pane) {
    pane = { tabs: [...FIXED], active: 'files' }
    panes.set(key, pane)
  }
  return pane
}

function bump() {
  paneVersion.value++
}

export function selectTab(id: string) {
  currentPane().active = id
  bump()
}

export function showInspector(tabId?: string) {
  batch(() => {
    prefs.inspectorOpen.value = true
    if (tabId) selectTab(tabId)
  })
}

export function openFile(path: string) {
  const pane = currentPane()
  const id = 'file:' + path
  if (!pane.tabs.some((t) => t.id === id)) pane.tabs.push({ kind: 'file', id, path })
  ensureBuffer(path)
  showInspector(id)
}

export async function openTerminal(cwd?: string) {
  const root = cwd ?? app.peek()?.inspectorRoot
  try {
    const res = await rpc<{ id: string; index: number; shell: string }>('term.open', { cwd: root, cols: 80, rows: 24 })
    const pane = currentPane()
    const id = 'term:' + res.id
    pane.tabs.push({ kind: 'term', id, termId: res.id, title: `${res.shell} ${res.index}` })
    showInspector(id)
  } catch (e) {
    post('log', { message: 'term.open failed: ' + e })
  }
}

export async function closeTab(id: string) {
  const pane = currentPane()
  const index = pane.tabs.findIndex((t) => t.id === id)
  if (index < 0) return
  const tab = pane.tabs[index]
  if (tab.kind === 'files' || tab.kind === 'changes') return
  if (tab.kind === 'file') {
    const buffer = buffers.get(tab.path)
    if (buffer?.dirty.value) {
      const name = tab.path.split('/').pop() ?? tab.path
      const ok = await rpc<boolean>('ui.confirm', { message: t('unsavedClose', name), ok: t('discard'), cancel: t('cancel') }).catch(() => true)
      if (!ok) return
    }
    if (![...panes.values()].some((p) => p !== pane && p.tabs.some((t) => t.id === id))) buffers.delete(tab.path)
  }
  if (tab.kind === 'term') {
    post('term.close', { id: tab.termId })
    terminalClosed(tab.termId)
  }
  pane.tabs.splice(index, 1)
  if (pane.active === id) pane.active = pane.tabs[Math.max(0, index - 1)]?.id ?? 'files'
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

export async function loadBuffer(b: Buffer) {
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
  return () => termListeners.delete(id)
}

function terminalClosed(id: string) {
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
      for (const tab of pane.tabs) if (tab.kind === 'term' && tab.termId === m.id) tab.exited = true
    }
    bump()
  }
})
