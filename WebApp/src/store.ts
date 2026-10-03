import { batch, signal } from '@preact/signals'
import { onMessage } from './bridge'
import type { AppState, Item } from './types'

export const app = signal<AppState | null>(null)

/** Top-level route: the main chat or the settings page (⌘,). */
export const route = signal<{ name: 'main' } | { name: 'settings'; section?: string }>({ name: 'main' })

// Debug/inspection hook (used by the Debug-build eval notification).
;(window as unknown as { __awState: () => unknown }).__awState = () => ({ app: app.peek(), items: transcript.items.length })

/** Selected session transcript. Items are replaced (never mutated) on change. */
export const transcript = {
  sessionId: signal<string | null>(null),
  version: signal(0),
  items: [] as Item[],
  index: new Map<string, number>(),
}

function reindex() {
  transcript.index.clear()
  transcript.items.forEach((it, i) => transcript.index.set(it.id, i))
}

export type UICommand = { name: string; seq: number; paths?: string[]; data?: Record<string, unknown> }
export const uiCommand = signal<UICommand | null>(null)
let commandSeq = 0

onMessage((m) => {
  switch (m.type) {
    case 'state':
      app.value = m.state
      applyColorScheme(m.state.appearance)
      if (!m.state.selectedSessionId && transcript.sessionId.peek()) {
        batch(() => {
          transcript.items = []
          transcript.index.clear()
          transcript.sessionId.value = null
          transcript.version.value++
        })
      }
      break
    case 'transcript':
      batch(() => {
        transcript.items = m.items
        reindex()
        transcript.sessionId.value = m.sessionId
        transcript.version.value++
      })
      break
    case 'patch': {
      if (m.sessionId !== transcript.sessionId.peek()) return
      const items = transcript.items
      let structural = false
      for (const op of m.ops) {
        if (op.op === 'remove') {
          const i = transcript.index.get(op.id)
          if (i !== undefined) {
            items.splice(i, 1)
            reindex()
          }
        } else if (op.op === 'upsert') {
          const i = transcript.index.get(op.item.id)
          if (i !== undefined) items[i] = op.item
          else {
            const at = Math.min(op.index, items.length)
            items.splice(at, 0, op.item)
            if (at === items.length - 1) transcript.index.set(op.item.id, at)
            else structural = true
          }
        } else {
          const i = transcript.index.get(op.id)
          if (i === undefined) continue
          const it = items[i]
          if ('text' in it) items[i] = { ...it, text: it.text + op.delta } as Item
        }
        if (structural) {
          reindex()
          structural = false
        }
      }
      transcript.version.value++
      break
    }
    case 'command':
      uiCommand.value = { name: m.name, seq: ++commandSeq, paths: m.paths, data: m as unknown as Record<string, unknown> }
      break
  }
})

/** Ticks once a second while something live is on screen. */
export const now = signal(Date.now())
let ticker = 0
export function setTicking(on: boolean) {
  if (on && !ticker) ticker = window.setInterval(() => (now.value = Date.now()), 1000)
  if (!on && ticker) {
    clearInterval(ticker)
    ticker = 0
  }
}

/** light-dark() tokens follow `color-scheme`; pin it when the user forces an appearance. */
function applyColorScheme(appearance: string) {
  const value = appearance === 'dark' || appearance === 'light' ? appearance : 'light dark'
  const root = document.documentElement.style
  if (root.colorScheme !== value) root.colorScheme = value
}
