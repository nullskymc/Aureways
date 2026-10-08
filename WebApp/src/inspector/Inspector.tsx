import { useEffect, useRef } from 'preact/hooks'
import { nativeMenu, post } from '../bridge'
import { t } from '../i18n'
import { prefs } from '../prefs'
import { app, route } from '../store'
import { Icon, Spinner } from '../components/Icon'
import { ChangesView } from './Changes'
import { FileView } from './FileView'
import { DiffPane } from './DiffPane'
import { FileTree } from './FileTree'
import { WorkspaceSidebar } from './WorkspaceSidebar'
import { closeTab, createNote, currentPane, moveTabRight, openExplorer, openTerminal, paneVersion, selectTab, showInspector, toggleWorkbench, buffers, type Column, type Tab } from './state'
import { TerminalView } from './Terminal'
import type { AppState, Session } from '../types'

export function TabStrip({ state, sidebarOpen, session, column, index, documents }: {
  state: AppState
  sidebarOpen: boolean
  session: Session | null
  column: Column
  index: number
  documents?: boolean
}) {
  const pane = currentPane()
  const chat = column.active === 'chat'
  const workbenchVisible = pane.columns.length > 1 && !pane.workbenchCollapsed
  const navigatorVisible = prefs.inspectorOpen.value && column.tabs.find((tab) => tab.id === column.active)?.kind !== 'term'
  const strip = useRef<HTMLDivElement>(null)
  const lights = state.chrome.trafficLights
  const pad = index > 0 || sidebarOpen || state.chrome.fullscreen ? 6 : Math.max(76, lights.x + lights.w + 14)
  useEffect(() => {
    const element = strip.current
    if (!element) return
    const reveal = () => element.querySelector('[aria-selected="true"]')?.scrollIntoView?.({ block: 'nearest', inline: 'nearest' })
    reveal()
    // Window resizing and restoring a collapsed workbench can otherwise leave
    // the selected tab outside the horizontal viewport until it is reselected.
    const observer = new ResizeObserver(() => { if (element.clientWidth > 0) reveal() })
    observer.observe(element)
    return () => observer.disconnect()
  }, [column.active])

  const addTab = async (element: Element) => {
    // Focus the target column before opening anything from its + menu.
    if (column.active) selectTab(column.active)
    const id = await nativeMenu(documents ? [
      { id: 'note', title: t('newNote'), icon: 'square.and.pencil' },
      { id: 'md', title: t('openMarkdown'), icon: 'doc.text' },
    ] : [
      { id: 'files', title: t('openFileTab'), icon: 'doc' },
      { id: 'term', title: t('newTerminal'), icon: 'terminal' },
      { id: 'changes', title: t('changes'), icon: 'square.split.diagonal' },
      { type: 'separator' },
      { id: 'md', title: t('openMarkdown'), icon: 'doc.text' },
    ], element)
    if (id === 'files') openExplorer()
    if (id === 'term') void openTerminal()
    if (id === 'changes') showInspector('changes')
    if (id === 'note') void createNote()
    if (id === 'md') void import('./open').then((m) => m.pickMarkdown())
  }

  return (
    <header class={'main-head tab-strip' + (chat ? ' chat-head' : '')} style={{ paddingLeft: pad }}>
      {index === 0 && !sidebarOpen && (
        <span class="head-tools" data-no-drag>
          <button class="icon-btn" title={t('toggleSidebar')} onClick={() => (prefs.sidebarOpen.value = !prefs.sidebarOpen.value)}>
            <Icon name="sidebar" size={15} />
          </button>
          <button class="icon-btn" title={t('newChat')} onClick={() => { route.value = { name: 'main' }; selectTab('chat'); post('newSession') }}>
            <Icon name="compose" size={15} />
          </button>
        </span>
      )}
      <div ref={strip} class="insp-tab-strip" role="tablist" aria-label={chat ? t('chat') : t('workspaceTabs')} data-no-drag onKeyDown={(e) => {
        if (!(e.target instanceof HTMLElement) || !e.target.matches('[role="tab"]')) return
        const tabs = [...(strip.current?.querySelectorAll<HTMLButtonElement>('[role="tab"]') ?? [])]
        const at = tabs.indexOf(e.target as HTMLButtonElement)
        let next = at
        if (e.key === 'ArrowRight') next = (at + 1) % tabs.length
        else if (e.key === 'ArrowLeft') next = (at + tabs.length - 1) % tabs.length
        else if (e.key === 'Home') next = 0
        else if (e.key === 'End') next = tabs.length - 1
        else return
        e.preventDefault()
        tabs[next]?.click()
        tabs[next]?.focus()
      }}>
        {column.tabs.map((tab) => <TabButton key={tab.id} tab={tab} active={tab.id === column.active} panelId={'panel-' + column.id} />)}
      </div>
      {chat && session?.phase === 'connecting' && <span class="head-status" title={t('connecting', session.agentTitle)}><Spinner size={12} /></span>}
      {chat && session?.phase === 'idle' && <button class="btn small" onClick={() => post('selectSession', { id: session.id })}>{t('open')}</button>}
      {(!chat || !workbenchVisible) && (
        <button class="icon-btn small tab-add" title={t('addTab')} onClick={(e) => void addTab(e.currentTarget)}><Icon name="plus" size={14} /></button>
      )}
      {chat && !documents && (
        <button class={'icon-btn small workbench-toggle' + (workbenchVisible ? ' on' : '')}
          title={t(workbenchVisible ? 'hideWorkbench' : 'showWorkbench') + ' · ⌥⌘I'}
          aria-label={t(workbenchVisible ? 'hideWorkbench' : 'showWorkbench')}
          aria-expanded={workbenchVisible}
          aria-controls={pane.columns.slice(1).map((col) => 'column-' + col.id).join(' ') || undefined}
          onMouseDown={(e) => e.stopPropagation()} onClick={toggleWorkbench}><Icon name="panelRight" size={15} /></button>
      )}
      {!chat && <div class="tab-head-spacer" />}
      {!chat && (
        <span class="tab-head-actions" data-no-drag>
          <button class="icon-btn small" title={t('splitRight')} disabled={index === pane.columns.length - 1 && pane.columns.length >= 3} onClick={() => moveTabRight(column.active)}><Icon name="split" size={14} /></button>
          {!documents && column.tabs.find((tab) => tab.id === column.active)?.kind !== 'changes' && <button class={'icon-btn small' + (navigatorVisible ? ' on' : '')} title={t('toggleFileTree')} aria-label={t('toggleFileTree')} aria-pressed={navigatorVisible} onClick={() => {
            if (column.tabs.find((tab) => tab.id === column.active)?.kind === 'term') openExplorer()
            else prefs.inspectorOpen.value = !prefs.inspectorOpen.value
          }}><Icon name="folder" size={14} /></button>}
        </span>
      )}
    </header>
  )
}

export function ColumnBody({ column, hidden, visible = true }: { column: Column; hidden: boolean; visible?: boolean }) {
  void paneVersion.value
  const active = column.tabs.find((tab) => tab.id === column.active)
  const terms = column.tabs.filter((tab): tab is Extract<Tab, { kind: 'term' }> => tab.kind === 'term')
  const documents = route.value.name === 'documents'
  if (hidden) return null
  const tree = !documents && prefs.inspectorOpen.value && active && ['explorer', 'file', 'diff'].includes(active.kind)
  return (
    <div class="workbench" id={'panel-' + column.id} role="tabpanel" aria-label={t('workspaceTabs')}>
      <div class="workspace-content">
        <div class="workspace-editor">
          {!active && <div class="file-empty">{t('documentsEmpty')}</div>}
          {active?.kind === 'explorer' && <FileExplorer />}
          {column.tabs.some((tab) => tab.kind === 'changes') && <div class="workspace-tab-content" style={{ display: active?.kind === 'changes' ? 'flex' : 'none' }}><ChangesView /></div>}
          {active?.kind === 'file' && <FileView key={active.path} path={active.path} />}
          {active?.kind === 'diff' && <DiffPane key={active.file.path} file={active.file} />}
          {terms.map((tab) => <TerminalView key={tab.termId} id={tab.termId} visible={visible && tab.id === active?.id} exited={!!tab.exited} />)}
        </div>
        {tree && <WorkspaceSidebar><FileTree root={app.value?.inspectorRoot ?? ''} filterId={'file-tree-filter-' + column.id} /></WorkspaceSidebar>}
      </div>
    </div>
  )
}

function FileExplorer() {
  const root = app.value?.inspectorRoot ?? ''
  return (
    <div class="file-explorer">
      <div class="file-head explorer-head"><span class="explorer-root" title={root}>/</span></div>
      <div class="explorer-empty">
        <button class="explorer-open" onClick={() => { prefs.inspectorOpen.value = true; queueMicrotask(() => document.querySelector<HTMLInputElement>('.focused .tree-filter input')?.focus()) }}>
          <Icon name="folderOpen" size={27} />
          <strong>{t('openFileTab')}</strong>
          <span>{t('openFileHint')}</span>
        </button>
      </div>
    </div>
  )
}

function TabButton({ tab, active, panelId }: { tab: Tab; active: boolean; panelId: string }) {
  let icon = 'file'
  let label = ''
  let dirty = false
  switch (tab.kind) {
    case 'chat': label = t('chat'); break
    case 'changes': icon = 'gitDiff'; label = t('changes'); break
    case 'explorer': label = t('openFileTab'); break
    case 'file': label = tab.path.split('/').pop() ?? tab.path; dirty = !!buffers.get(tab.path)?.dirty.value; break
    case 'diff': icon = 'gitDiff'; label = (tab.file.path.split('/').pop() ?? tab.file.path) + ' · Diff'; break
    case 'term': icon = 'terminal'; label = tab.exited ? `${tab.title} ✕` : tab.title; break
  }
  const closable = tab.kind !== 'chat'
  return (
    <div class={'insp-tab' + (active ? ' active' : '') + (tab.kind === 'chat' ? ' chat-tab' : '')} data-no-drag title={tab.kind === 'file' ? tab.path : tab.kind === 'diff' ? tab.file.path : label}
      onMouseDown={(e) => { if (e.button === 1 && closable) { e.preventDefault(); e.stopPropagation(); void closeTab(tab.id) } }}
      onContextMenu={closable ? async (e) => {
        e.preventDefault()
        const columns = currentPane().columns
        const from = columns.findIndex((col) => col.tabs.some((item) => item.id === tab.id))
        const canMove = from >= 0 && (from < columns.length - 1 || columns.length < 3)
        const id = await nativeMenu([
          ...(canMove ? [{ id: 'right', title: t('moveRight'), icon: 'rectangle.split.2x1' }] : []),
          { id: 'close', title: t('closeDocument'), icon: 'xmark' },
        ], { x: e.clientX, y: e.clientY })
        if (id === 'right') moveTabRight(tab.id)
        if (id === 'close') void closeTab(tab.id)
      } : undefined}>
      <button class="insp-tab-main" role="tab" aria-selected={active} aria-controls={panelId} tabIndex={active ? 0 : -1} onClick={() => selectTab(tab.id)}>
        {tab.kind !== 'chat' && <Icon name={icon} size={12} />}
        <span class="insp-tab-label">{label}</span>
        {dirty && <span class="dirty-dot" />}
      </button>
      {closable && <button class="insp-tab-x" title={t('closeDocument')} aria-label={`${t('closeDocument')} ${label}`} onMouseDown={(e) => e.stopPropagation()} onClick={(e) => { e.stopPropagation(); void closeTab(tab.id) }}><Icon name="x" size={10} /></button>}
    </div>
  )
}
