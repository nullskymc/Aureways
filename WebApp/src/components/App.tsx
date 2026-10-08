import type { ComponentChildren } from 'preact'
import { useSignal } from '@preact/signals'
import { useEffect, useLayoutEffect, useRef } from 'preact/hooks'
import { nativeMenu, post, type MenuItem } from '../bridge'
import { t } from '../i18n'
import { app, composerH, composerTotal, route, setTicking, uiCommand } from '../store'
import { prefs } from '../prefs'
import { currentPane, homeIsChat, openTerminal, resizeColumns, selectTab, showInspector, splitFocused, type Column } from '../inspector/state'
import { ColumnBody, TabStrip } from '../inspector/Inspector'
import { FileTree } from '../inspector/FileTree'
import '../reader/state'
import { lazy } from './Lazy'
import { installGlass } from '../glass'

const SettingsContent = lazy(() => import('../settings/Settings').then((m) => m.SettingsContent))
import { BackgroundRequests } from './Cards'
import type { AppState, Session } from '../types'
import { PermissionCard, PlanApprovalCard, QuestionCard } from './Cards'
import { Composer } from './Composer'
import { HarnessIcon, Icon } from './Icon'
import { Sidebar } from './Sidebar'
import { Transcript } from './Transcript'

const DRAG_SELECTOR = 'button, input, textarea, a, select, [data-no-drag]'

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
        if (route.peek().name === 'documents' || !app.peek()?.selectedSessionId) break
        prefs.inspectorOpen.value = !prefs.inspectorOpen.value
        break
      case 'showFiles':
        if (route.peek().name === 'documents' || !app.peek()?.selectedSessionId) break
        prefs.inspectorOpen.value = true
        queueMicrotask(() => document.getElementById('file-tree-filter')?.focus())
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
      case 'openSettings':
        route.value = { name: 'settings' }
        break
      case 'newChat':
        route.value = { name: 'main' }
        selectTab('chat')
        break
    }
  }, [uiCommand.value])

  const r = route.value
  const isSettings = r.name === 'settings'
  const documents = r.name === 'documents'
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
    reportDragRegions(headH)
  })
  useEffect(() => {
    const onResize = () => reportDragRegions(headerHeight(app.peek()))
    window.addEventListener('resize', onResize)
    return () => window.removeEventListener('resize', onResize)
  }, [])

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
      class={'app' + (isSettings ? ' settings-mode' : '') + (sidebarOpen.value ? '' : ' no-sidebar')}
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
      {!isSettings && !documents && !!state.selectedSessionId && prefs.inspectorOpen.value && (
        <aside class="inspector" style={{ width: prefs.inspectorWidth.value }}>
          <InspectorResizer width={prefs.inspectorWidth} />
          <FileTree root={state.inspectorRoot} onHide={() => (prefs.inspectorOpen.value = false)} />
        </aside>
      )}
      </div>
    </div>
  )
}

function EditorColumns({ state, session, sidebarOpen, attention, overlay, glass, dock, dockHeight }: {
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
  const treeOpen = prefs.inspectorOpen.value
  return (
    <div class="editors">
      {pane.columns.map((column, index) => (
        <ColumnFrame key={column.id} column={column} index={index}>
          <TabStrip
            state={state}
            sidebarOpen={sidebarOpen}
            session={session}
            column={column}
            index={index}
            treeToggle={!!session && !documents && !treeOpen && index === pane.columns.length - 1}
            documents={documents}
          />
          {index === 0 && column.active === 'chat' && (session ? (
            <Transcript streaming={session.streaming} padBottom={dockHeight + 24} jumpBottom={overlay ? dockHeight + 12 + Math.max(0, composerTotal.value - composerH.value) : undefined} padTop={glass ? 12 : 64} />
          ) : index === 0 && column.active === 'chat' ? (
            <Landing state={state} />
          ) : null)}
          {index === 0 && column.active === 'chat' && (
            <div ref={dock} class={'dock' + (session ? '' : ' landing-dock')}>
              {overlay ? <div class="composer-slot" data-glass="slot" style={{ height: composerH.value }} /> : <Composer state={state} session={session} />}
            </div>
          )}
          <ColumnBody column={column} hidden={column.active === 'chat'} />
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

function ColumnFrame({ column, index, children }: { column: Column; index: number; children: ComponentChildren }) {
  const pane = currentPane()
  return (
    <>
      {index > 0 && <ColumnResizer index={index - 1} />}
      <section
        class={'column' + (pane.focus === index ? ' focused' : '')}
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
          const nextLeft = Math.min(width - 160, Math.max(160, left + ev.clientX - startX))
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

function InspectorResizer({ width }: { width: { value: number } }) {
  return (
    <div
      class="insp-resizer"
      onMouseDown={(e) => {
        e.preventDefault()
        const startX = e.clientX
        const start = width.value
        const move = (ev: MouseEvent) => (width.value = Math.round(Math.max(240, Math.min(640, start + startX - ev.clientX))))
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

/** Header rows are vertically centred on the traffic lights, like native toolbars. */
function headerHeight(state: AppState | null): number {
  const l = state?.chrome.trafficLights
  if (!l || !l.h || state?.chrome.fullscreen) return 44
  return Math.round(Math.max(34, (l.y + l.h / 2) * 2))
}

let lastRegions = ''
function reportDragRegions(height: number) {
  requestAnimationFrame(() => {
    const rects: { x: number; y: number; w: number; h: number }[] = []
    document.querySelectorAll(DRAG_SELECTOR).forEach((el) => {
      const r = el.getBoundingClientRect()
      if (r.width === 0 || r.top >= height || r.bottom <= 0) return
      rects.push({ x: Math.floor(r.left) - 2, y: Math.floor(r.top) - 2, w: Math.ceil(r.width) + 4, h: Math.ceil(r.height) + 4 })
    })
    // Resizers must stay grabbable all the way up.
    document.querySelectorAll('.sidebar-resizer, .col-resizer, .insp-resizer').forEach((el) => {
      const r = el.getBoundingClientRect()
      rects.push({ x: r.left, y: 0, w: r.width, h: height })
    })
    const json = JSON.stringify(rects)
    if (json !== lastRegions) {
      lastRegions = json
      post('dragRegions', { rects, height })
    }
  })
}
