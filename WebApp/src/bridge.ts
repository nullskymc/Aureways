// JS <-> Swift. `aureways` is registered on the WKUserContentController;
// Swift calls `window.__aw.receive(obj)`. Outside the app (vite dev) messages
// go to the console and a demo state is loaded.
import type { Incoming } from './types'

declare global {
  interface Window {
    webkit?: { messageHandlers?: { aureways?: { postMessage(m: unknown): void } } }
    __aw: { receive(m: Incoming): void }
  }
}

export const inApp = !!window.webkit?.messageHandlers?.aureways

export function post(type: string, payload: Record<string, unknown> = {}) {
  const handler = window.webkit?.messageHandlers?.aureways
  const message = { type, ...payload }
  if (handler) handler.postMessage(message)
  else console.debug('[aureways →]', message)
}

type Listener = (m: Incoming) => void
const listeners = new Set<Listener>()
export function onMessage(fn: Listener) {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

window.__aw = {
  receive(m) {
    for (const fn of listeners) {
      try {
        fn(m)
      } catch (e) {
        post('log', { message: String((e as Error)?.stack ?? e) })
      }
    }
  },
}

// ---- Native NSMenu popups -------------------------------------------------

export type MenuItem =
  | { id: string; title: string; subtitle?: string; checked?: boolean; disabled?: boolean; icon?: string }
  | { type: 'separator' }
  | { type: 'header'; title: string }

let menuToken = 0
const pendingMenus = new Map<number, (id: string | null) => void>()
onMessage((m) => {
  if (m.type !== 'menuResult') return
  pendingMenus.get(m.token)?.(m.id)
  pendingMenus.delete(m.token)
})

/** Pops a native menu under `anchor` (or at a point); resolves with the chosen id. */
export function nativeMenu(items: MenuItem[], anchor: Element | { x: number; y: number }): Promise<string | null> {
  let x: number, y: number
  if (anchor instanceof Element) {
    const r = anchor.getBoundingClientRect()
    x = r.left
    y = r.bottom + 4
  } else {
    ;({ x, y } = anchor)
  }
  const token = ++menuToken
  if (!inApp) {
    console.debug('[menu]', items)
    return Promise.resolve(null)
  }
  return new Promise((resolve) => {
    pendingMenus.set(token, resolve)
    post('menu', { token, x, y, items })
  })
}

window.addEventListener('error', (e) => post('log', { message: `${e.message} @ ${e.filename}:${e.lineno}` }))
window.addEventListener('unhandledrejection', (e) => post('log', { message: `unhandled: ${String(e.reason)}` }))
