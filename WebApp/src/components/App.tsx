import type { ComponentChildren } from 'preact'
import { useSignal } from '@preact/signals'
import { useEffect, useLayoutEffect, useRef } from 'preact/hooks'
import { nativeMenu, post, type MenuItem } from '../bridge'
import { t } from '../i18n'
import { app, composerH, composerTotal, route, setTicking, uiCommand } from '../store'
import { prefs } from '../prefs'
import { currentPane, homeIsChat, openTerminal, resizeColumns, selectTab, showInspector, splitFocused, toggleWorkbench, type Column } from '../inspector/state'
import { ColumnBody, TabStrip } from '../inspector/Inspector'
import '../reader/state'
import { lazy } from './Lazy'
import { installGlass } from '../glass'
import { headerHeight, observeTitlebar } from '../chrome'

const SettingsContent = lazy(() => import('../settings/Settings').then((m) => m.SettingsContent))
import { BackgroundRequests } from './Cards'
import type { AppState, Session } from '../types'
import { PermissionCard, PlanApprovalCard, QuestionCard } from './Cards'
import { Composer } from './Composer'
import { HarnessIcon, Icon } from './Icon'
import { Sidebar } from './Sidebar'
import { Transcript } from './Transcript'

export function App() {
  const state = app.value
  const sidebarOpen = prefs.sidebarOpen
  const sidebarWidth = prefs.sidebarWidth
  const dockHeight = useSignal(140)
  const dock = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const c = uiCommand.value
    switch (c?.name) {
      case 'toggleSidebar':
        sidebarOpen.value = !sidebarOpen.value
        break
      case 'toggleInspector':
        toggleWorkbench()
        break
      case 'showFiles':
        showInspector()
        queueMicrotask(() => document.querySelector<HTMLInputElement>('.focused .tree-filter input')?.focus())
        break
      case 'showChanges':
        route.value = { name: 'main' }
        showInspector('changes')
        break
      case 'splitRight':
        splitFocused()
        break
      case 'newTerminal':
        void openTerminal()
        break
      case 'openMarkdown':
        void import('../inspector/open').then((m) => m.pickMarkdown())
        break
      case 'openSettings': {
        const section = typeof c.data?.section === 'string' ? c.data.section : undefined
        route.value = section ? { name: 'settings', section } : { name: 'settings' }
        break
      }
      case 'newChat':
        route.value = { name: 'main' }
        selectTab('chat')
        break
    }
  }, [uiCommand.value])

  const r = route.value
  const isSettings = r.name === 'settings'
  const settingsSection = r.name === 'settings' ? r.section : undefined
  const onChat = !isSettings && homeIsChat()

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const field = e.target instanceof HTMLElement && !!e.target.closest('textarea, input')
      if (e.key === '\\' && e.metaKey && !e.shiftKey && !e.altKey && !e.ctrlKey) {
        if (field) return
        e.preventDefault()
        splitFocused()
        return
      }
      if (e.key !== 'Escape' || e.metaKey || e.ctrlKey || e.altKey) return
      if (field) return
      if (route.peek().name !== 'main') return
      selectTab('chat')
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  useEffect(() => {
    const el = dock.current
    if (!el) return
    const measure = () => {
      const h = Math.ceil(el.getBoundingClientRect().height)
      if (h >= 40) dockHeight.value = h
    }
    measure()
    const ro = new ResizeObserver(measure)
    ro.observe(el)
    return () => ro.disconnect()
  }, [state?.selectedSessionId == null, isSettings, onChat])

  const glass = !!state?.chrome.glass
  useEffect(() => {
    if (glass) installGlass()
  }, [glass])
  // With a session open the composer is a native overlay (its own web view on
  // glass) and the transcript scrolls underneath it to the window bottom.
  const overlay = !!state?.chrome.composerOverlay && !!state?.selectedSessionId && onChat
  useLayoutEffect(() => {
    document.documentElement.classList.toggle('composer-overlay', overlay)
  }, [overlay])

  const headH = headerHeight(state)
  useLayoutEffect(() => {
    const root = document.querySelector<HTMLElement>('.app')
    if (root) return observeTitlebar(root, headH)
  }, [headH, !!state])

  const anyLive = !!state?.sessions.some((s) => s.streaming)
  useEffect(() => setTicking(anyLive), [anyLive])

  if (!state) return <div class="boot" />
  const session = state.sessions.find((s) => s.id === state.selectedSessionId) ?? null
  const attention =
    !!state.error ||
    session?.phase === 'failed' ||
    !!state.permission ||
    !!state.planApproval ||
    !!state.question ||
    state.sessions.some((s) => s.id !== state.selectedSessionId && (s.permission || s.pendingKind))

  return (
    <div
      class={'app' + (state.chrome.nativeTitlebar ? ' native-titlebar' : '') + (isSettings ? ' settings-mode' : '') + (sidebarOpen.value ? '' : ' no-sidebar')}
      style={{
        '--sidebar-w': `${sidebarWidth.value}px`,
        '--head-h': `${headH}px`,
      }}
    >
      {sidebarOpen.value && (
        <>
          <Sidebar state={state} onToggle={() => (sidebarOpen.value = false)} />
          <SidebarResizer width={sidebarWidth} />
        </>
      )}
      <div class="stage">
      <main class={'main' + (isSettings ? ' settings-main' : '')} style={{ '--dock-h': `${dockHeight.value}px` }}>
        {isSettings ? (
          <>
            <header
              class="main-head"
              style={{
                paddingLeft:
                  sidebarOpen.value || state.chrome.fullscreen
                    ? 16
                    : Math.max(76, state.chrome.trafficLights.x + state.chrome.trafficLights.w + 14),
              }}
            >
              {!sidebarOpen.value && (
                <span class="head-tools" data-glass="control">
                  <button class="icon-btn" title={t('toggleSidebar')} onClick={() => (sidebarOpen.value = !sidebarOpen.value)}>
                    <Icon name="sidebar" size={15} />
                  </button>
                </span>
              )}
              <div class="head-titles">
                <span class="head-title">{t('settings_' + (settingsSection ?? 'general'))}</span>
              </div>
            </header>
            <SettingsContent state={state} section={settingsSection} />
          </>
        ) : (
          <EditorColumns
            state={state}
            session={session}
            sidebarOpen={sidebarOpen.value}
            attention={attention}
            overlay={overlay}
            glass={glass}
            dock={dock}
            dockHeight={dockHeight.value}
          />
        )}
      </main>
      </div>
    </div>
  )
}

export function EditorColumns({ state, session, sidebarOpen, attention, overlay, glass, dock, dockHeight }: {
  state: AppState
  session: Session | null
  sidebarOpen: boolean
  attention: boolean
  overlay: boolean
  glass: boolean
  dock: { current: HTMLDivElement | null }
  dockHeight: number
}) {
  const pane = currentPane()
  const documents = route.value.name === 'documents'
  return (
    <div class={'editors' + (!documents && pane.workbenchCollapsed ? ' workbench-collapsed' : '')}>
      {pane.columns.map((column, index) => (
        <ColumnFrame key={column.id} column={column} index={index} concealed={!documents && pane.workbenchCollapsed && index > 0}>
          <TabStrip
            state={state}
            sidebarOpen={sidebarOpen}
            session={session}
            column={column}
            index={index}
            documents={documents}
          />
          {index === 0 && column.active === 'chat' && (
            <div class="chat-panel" id={'panel-' + column.id} role="tabpanel" aria-label={t('chat')}>
              {session ? (
                <Transcript streaming={session.streaming} padBottom={dockHeight + 24} jumpBottom={overlay ? dockHeight + 12 + Math.max(0, composerTotal.value - composerH.value) : undefined} padTop={glass ? 12 : 64} />
              ) : <Landing state={state} />}
              <div ref={dock} class={'dock' + (session ? '' : ' landing-dock')}>
                {overlay ? <div class="composer-slot" data-glass="slot" style={{ height: composerH.value }} /> : <Composer state={state} session={session} />}
              </div>
            </div>
          )}
          <ColumnBody column={column} hidden={column.active === 'chat'} visible={documents || !pane.workbenchCollapsed || index === 0} />
        </ColumnFrame>
      ))}
      {attention && (
        <div class="dock editors-alerts">
          <Alerts state={state} session={session} />
        </div>
      )}
    </div>
  )
}

function ColumnFrame({ column, index, concealed, children }: { column: Column; index: number; concealed: boolean; children: ComponentChildren }) {
  const pane = currentPane()
  return (
    <>
      {index > 0 && !concealed && <ColumnResizer index={index - 1} />}
      <section
        id={'column-' + column.id}
        hidden={concealed}
        class={'column' + (pane.focus === index ? ' focused' : '') + (column.active === 'chat' ? ' chat-column' : '')}
        style={{ flex: `${column.size} 1 0` }}
        onMouseDown={() => {
          if (currentPane().focus !== index) selectTab(column.active)
        }}
      >
        {children}
      </section>
    </>
  )
}

function ColumnResizer({ index }: { index: number }) {
  return (
    <div
      class="col-resizer"
      onMouseDown={(e) => {
        e.preventDefault()
        e.stopPropagation()
        const parent = (e.currentTarget as HTMLElement).parentElement
        const cols = parent ? [...parent.querySelectorAll(':scope > .column')] : []
        const left = cols[index]?.getBoundingClientRect().width ?? 0
        const right = cols[index + 1]?.getBoundingClientRect().width ?? 0
        const startX = e.clientX
        const move = (ev: MouseEvent) => {
          const width = left + right
          const minLeft = cols[index]?.classList.contains('chat-column') ? 260 : 200
          const nextLeft = Math.min(width - 200, Math.max(minLeft, left + ev.clientX - startX))
          resizeColumns(index, nextLeft, width - nextLeft)
        }
        const up = () => {
          window.removeEventListener('mousemove', move)
          window.removeEventListener('mouseup', up)
          document.body.classList.remove('resizing')
        }
        document.body.classList.add('resizing')
        window.addEventListener('mousemove', move)
        window.addEventListener('mouseup', up)
      }}
    />
  )
}

function Alerts({ state, session }: { state: AppState; session: Session | null }) {
  return (
    <>
      {state.error && (
        <div class="banner error">
          <Icon name="alert" size={14} />
          <span class="flex1">{state.error}</span>
          <button class="btn subtle small" onClick={() => post('dismissError')}>
            {t('dismiss')}
          </button>
        </div>
      )}
      {session?.phase === 'failed' && (
        <div class="banner error">
          <Icon name="alert" size={14} />
          <span class="flex1">
            <b>{t('failed')}</b> {session.error}
          </span>
          <button class="btn small" onClick={() => post('retry', { id: session.id })}>
            {t('retry')}
          </button>
        </div>
      )}
      <BackgroundRequests state={state} />
      {state.permission && <PermissionCard p={state.permission} />}
      {state.planApproval && <PlanApprovalCard plan={state.planApproval} />}
      {state.question && <QuestionCard q={state.question} />}
    </>
  )
}

function Landing({ state }: { state: AppState }) {
  return (
    <div class="landing">
      <div class="landing-inner">
        <div class="landing-mark">
          <HarnessIcon id={state.selectedAgentId} size={28} />
        </div>
        <h1>
          {t('landingTitle', '\u0000').split('\u0000')[0]}
          <button
            class="ws-picker"
            onClick={async (e) => {
              const items: MenuItem[] = state.workspaces.map((w) => ({ id: w.path, title: w.name, subtitle: w.path.replace(state.homePath, '~'), checked: w.path === state.workspacePath }))
              items.push({ type: 'separator' }, { id: '__add', title: t('addWs'), icon: 'folder.badge.plus' })
              const id = await nativeMenu(items, e.currentTarget as Element)
              if (id === '__add') post('addWorkspace')
              else if (id) post('selectWorkspace', { path: id })
            }}
          >
            {state.workspaceName}
            <Icon name="chevronDown" size={14} />
          </button>
          {t('landingTitle', '\u0000').split('\u0000')[1]}
        </h1>
        <p class="landing-hint">{t('landingHint')}</p>
      </div>
    </div>
  )
}

function SidebarResizer({ width }: { width: { value: number } }) {
  return (
    <div
      class="sidebar-resizer"
      onMouseDown={(e) => {
        e.preventDefault()
        const startX = e.clientX
        const start = width.value
        const move = (ev: MouseEvent) => (width.value = Math.round(Math.max(220, Math.min(420, start + ev.clientX - startX))))
        const up = () => {
          window.removeEventListener('mousemove', move)
          window.removeEventListener('mouseup', up)
          document.body.classList.remove('resizing')
        }
        document.body.classList.add('resizing')
        window.addEventListener('mousemove', move)
        window.addEventListener('mouseup', up)
      }}
    />
  )
}
