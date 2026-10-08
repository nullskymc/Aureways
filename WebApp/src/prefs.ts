// UI state that survives relaunch. The website data store is non-persistent,
// so values round-trip through Swift (UserDefaults "webShellUIPrefs").
import { effect, signal, type Signal } from '@preact/signals'
import { post } from './bridge'
import { onMessage } from './bridge'

const registry = new Map<string, { signal: Signal<unknown>; initial: unknown }>()
let loaded = false
/** Flips after the first state snapshot applies stored preferences. */
export const prefsReady = signal(false)

function pref<T>(key: string, initial: T): Signal<T> {
  const s = signal<T>(initial)
  registry.set(key, { signal: s as Signal<unknown>, initial })
  let first = true
  let timer = 0
  effect(() => {
    const value = s.value
    if (first) {
      first = false
      return
    }
    if (!loaded) return
    clearTimeout(timer)
    timer = window.setTimeout(() => post('uiPrefs', { prefs: { [key]: value } }), 250)
  })
  return s
}

export const prefs = {
  sidebarOpen: pref('sidebarOpen', true),
  sidebarWidth: pref('sidebarWidth', 272),
  inspectorOpen: pref('inspectorOpen', true),
  inspectorWidth: pref('inspectorWidth', 240),
  collapsedGroups: pref<string[]>('collapsedGroups', []),
  showHidden: pref('showHidden', false),
  /** Markdown paths kept in the Documents shelf. Workspace tabs are not saved. */
  documentPaths: pref<string[]>('documentPaths', []),
}

/**
 * Stored values come back from UserDefaults, which may hold 0/1 for a flag
 * (e.g. written with `defaults write … -int 0`). Keep each value the type of
 * its default: a numeric 0 would otherwise render as text in `{flag && …}`.
 */
export function coercePref(initial: unknown, value: unknown): unknown {
  if (typeof initial === 'boolean') {
    if (typeof value === 'boolean') return value
    if (typeof value === 'number') return value !== 0
    if (value === 'true' || value === 'false') return value === 'true'
    return initial
  }
  if (typeof initial === 'number') return typeof value === 'number' && Number.isFinite(value) ? value : initial
  if (Array.isArray(initial)) return Array.isArray(value) ? value : initial
  return value
}

onMessage((m) => {
  if (m.type !== 'state' || loaded) return
  const stored = (m.state.uiPrefs ?? {}) as Record<string, unknown>
  for (const [key, { signal, initial }] of registry) {
    if (key in stored && stored[key] !== null) signal.value = coercePref(initial, stored[key])
  }
  loaded = true
  prefsReady.value = true
})
