// UI state that survives relaunch. The website data store is non-persistent,
// so values round-trip through Swift (UserDefaults "webShellUIPrefs").
import { effect, signal, type Signal } from '@preact/signals'
import { post } from './bridge'
import { onMessage } from './bridge'

const registry = new Map<string, Signal<unknown>>()
let loaded = false

function pref<T>(key: string, initial: T): Signal<T> {
  const s = signal<T>(initial)
  registry.set(key, s as Signal<unknown>)
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
  inspectorOpen: pref('inspectorOpen', false),
  inspectorWidth: pref('inspectorWidth', 420),
  collapsedGroups: pref<string[]>('collapsedGroups', []),
  showHidden: pref('showHidden', false),
}

onMessage((m) => {
  if (m.type !== 'state' || loaded) return
  const stored = (m.state.uiPrefs ?? {}) as Record<string, unknown>
  for (const [key, s] of registry) {
    if (key in stored && stored[key] !== null) s.value = stored[key]
  }
  loaded = true
})
