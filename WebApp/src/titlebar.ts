// The title bar's fixed controls are native glass buttons (TitlebarGlass.swift):
// the sidebar circle beside the traffic lights, the new-tab "+" circle and the
// file tree + inspector capsule at the right edge. The page only tells native their state, and
// only when it changes; native lays them out from the window edges itself.
import { effect } from '@preact/signals'
import { post } from './bridge'
import { prefs } from './prefs'
import { route } from './store'
import { currentPane, openExplorer } from './inspector/state'

const TREE_KINDS = ['explorer', 'file', 'diff', 'changes']

export interface TitlebarState {
  sidebar: boolean
  /** The right capsule (file tree + inspector) is shown. */
  right: boolean
  /** The "+" circle (new workbench / Documents tab) is shown. */
  add: boolean
  files: boolean
  inspector: boolean
}

/** A visible workbench column whose active tab shows the project navigator. */
function treeTabShown(): boolean {
  const pane = currentPane()
  return pane.columns.length > 1 && !pane.workbenchCollapsed &&
    pane.columns.slice(1).some((col) => TREE_KINDS.includes(col.tabs.find((tab) => tab.id === col.active)?.kind ?? ''))
}

export function titlebarState(): TitlebarState {
  const main = route.value.name === 'main'
  const pane = currentPane()
  const inspector = main && pane.columns.length > 1 && !pane.workbenchCollapsed
  return {
    sidebar: prefs.sidebarOpen.value,
    right: main,
    add: main || route.value.name === 'documents',
    files: inspector && treeTabShown() && prefs.inspectorOpen.value,
    inspector,
  }
}

/** The file tree toggle: hide/show the navigator, or bring it up with the workbench. */
export function toggleFileTree() {
  if (titlebarState().files) prefs.inspectorOpen.value = false
  else if (route.peek().name === 'main' && treeTabShown()) prefs.inspectorOpen.value = true
  else openExplorer()
}

let dispose: (() => void) | null = null
export function installTitlebar() {
  if (dispose) return
  let last = ''
  dispose = effect(() => {
    const state = titlebarState()
    const json = JSON.stringify(state)
    if (json === last) return
    last = json
    post('titlebar', { ...state })
  })
}
