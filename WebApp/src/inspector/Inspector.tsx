import { nativeMenu, post } from '../bridge'
import { t } from '../i18n'
import { prefs } from '../prefs'
import { app, route } from '../store'
import { HarnessIcon, Icon, Spinner } from '../components/Icon'
import { ChangesView } from './Changes'
import { FileView } from './FileView'
import { DiffPane } from './DiffPane'
import { closeTab, createNote, currentPane, moveTabRight, openTerminal, paneVersion, selectTab, buffers, type Column, type Tab } from './state'
import { TerminalView } from './Terminal'
import type { AppState, Session } from '../types'

export function TabStrip({ state, sidebarOpen, session, column, index, treeToggle, documents }: {
  state: AppState
  sidebarOpen: boolean
  session: Session | null
  column: Column
  index: number
  treeToggle?: boolean
  documents?: boolean
}) {
  const pane = currentPane()
  const active = column.tabs.find((tab) => tab.id === column.active)
  const focused = pane.focus === index
  const lights = state.chrome.trafficLights
  const pad = index > 0 || sidebarOpen || state.chrome.fullscreen ? 10 : Math.max(76, lights.x + lights.w + 14)
  return (
    <header class="main-head tab-strip" style={{ paddingLeft: pad }}>
      {index === 0 && !sidebarOpen && (
        <span class="head-tools" data-glass="control">
          <button class="icon-btn" title={t('toggleSidebar')} onClick={() => (prefs.sidebarOpen.value = !prefs.sidebarOpen.value)}>
            <Icon name="sidebar" size={15} />
          </button>
          <button class="icon-btn" title={t('newChat')} onClick={() => { route.value = { name: 'main' }; selectTab('chat'); post('newSession') }}>
            <Icon name="compose" size={15} />
          </button>
        </span>
      )}
      <div class="insp-tab-strip" data-no-drag>
        {column.tabs.map((tab) => (
          <TabButton key={tab.id} tab={tab} active={tab.id === active?.id} focused={focused} />
        ))}
      </div>
      {index === 0 && session && active?.kind === 'chat' && (
        <span class="head-status">
          {session.phase === 'connecting' && (
            <span class="pill">
              <Spinner size={10} /> {t('connecting', session.agentTitle)}
            </span>
          )}
          {session.phase === 'idle' && (
            <button class="btn small" onClick={() => post('selectSession', { id: session.id })}>
              <Icon name="refresh" size={12} /> {t('open')}
            </button>
          )}
          <span class="pill subtle" title={session.agentTitle}>
            <HarnessIcon id={session.agentId} size={12} /> {session.agentTitle}
          </span>
        </span>
      )}
      {focused && (
      <button
        class="icon-btn small"
        title={documents ? t('newNote') : t('newTerminal')}
        data-glass="control"
        onClick={async (e) => {
          const id = await nativeMenu(
            documents
              ? [
                  { id: 'note', title: t('newNote'), icon: 'square.and.pencil' },
                  { id: 'md', title: t('openMarkdown'), icon: 'doc.text' },
                ]
              : [
                  { id: 'term', title: t('newTerminal'), icon: 'terminal' },
                  { id: 'md', title: t('openMarkdown'), icon: 'doc.text' },
                ],
            e.currentTarget as Element,
          )
          if (id === 'term') void openTerminal()
          if (id === 'note') void createNote()
          if (id === 'md') void import('./open').then((m) => m.pickMarkdown())
        }}
      >
        <Icon name="plus" size={13} />
      </button>
      )}
      {treeToggle && (
        <button class="icon-btn small" title={t('files')} data-glass="control" onClick={() => (prefs.inspectorOpen.value = true)}>
          <Icon name="panelRight" size={14} />
        </button>
      )}
    </header>
  )
}

export function ColumnBody({ column, hidden }: { column: Column; hidden: boolean }) {
  // The column object is mutated in place. Reading the version signal is what
  // makes an empty Documents column paint the file that was just opened.
  void paneVersion.value
  const active = column.tabs.find((tab) => tab.id === column.active)
  const terms = column.tabs.filter((tab): tab is Extract<Tab, { kind: 'term' }> => tab.kind === 'term')
  if (!active) {
    return (
      <div class="workbench">
        <div class="file-empty">{t('documentsEmpty')}</div>
      </div>
    )
  }
  return (
    <div class="workbench" style={{ display: hidden ? 'none' : undefined }}>
      {!hidden && active.kind === 'changes' && <ChangesView />}
      {!hidden && active.kind === 'file' && <FileView key={active.path} path={active.path} />}
      {!hidden && active.kind === 'diff' && <DiffPane key={active.file.path} file={active.file} />}
      {terms.map((tab) => (
        <TerminalView key={tab.termId} id={tab.termId} visible={!hidden && tab.id === active.id} exited={!!tab.exited} />
      ))}
    </div>
  )
}

function TabButton({ tab, active, focused }: { tab: Tab; active: boolean; focused: boolean }) {
  let icon = 'file'
  let label = ''
  let dirty = false
  switch (tab.kind) {
    case 'chat': {
      const state = app.value
      const session = state?.sessions.find((s) => s.id === state.selectedSessionId)
      icon = 'compose'
      label = session?.title || t('newChat')
      break
    }
    case 'changes':
      icon = 'gitDiff'
      label = t('changes')
      break
    case 'file':
      label = tab.path.split('/').pop() ?? tab.path
      dirty = !!buffers.get(tab.path)?.dirty.value
      break
    case 'diff':
      icon = 'gitDiff'
      label = (tab.file.path.split('/').pop() ?? tab.file.path) + ' · Diff'
      break
    case 'term':
      icon = 'terminal'
      label = tab.exited ? `${tab.title} ✕` : tab.title
      break
  }
  const closable = tab.kind === 'file' || tab.kind === 'diff' || tab.kind === 'term'
  return (
    <div
      class={'insp-tab' + (active ? ' active' : '') + (active && !focused ? ' dim' : '')}
      data-no-drag
      title={tab.kind === 'file' ? tab.path : label}
      onMouseDown={(e) => {
        if (e.button === 1 && closable) {
          e.preventDefault()
          void closeTab(tab.id)
        }
      }}
      onContextMenu={closable ? async (e) => {
        e.preventDefault()
        const columns = currentPane().columns
        const from = columns.findIndex((col) => col.tabs.some((item) => item.id === tab.id))
        if (from < 0 || (from === columns.length - 1 && columns.length >= 3)) return
        const id = await nativeMenu([{ id: 'right', title: t('moveRight'), icon: 'rectangle.split.2x1' }], { x: e.clientX, y: e.clientY })
        if (id === 'right') moveTabRight(tab.id)
      } : undefined}
    >
      <button class="insp-tab-main" onClick={() => selectTab(tab.id)}>
        <Icon name={icon} size={12} />
        <span class="insp-tab-label">{label}</span>
        {dirty && <span class="dirty-dot" />}
      </button>
      {closable && (
        <button class="insp-tab-x" title={t('closeDocument')} onClick={() => void closeTab(tab.id)}>
          <Icon name="x" size={10} />
        </button>
      )}
    </div>
  )
}
