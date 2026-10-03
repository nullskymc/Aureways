import { useSignal } from '@preact/signals'
import { useEffect, useLayoutEffect, useRef } from 'preact/hooks'
import { nativeMenu, post, type MenuItem } from '../bridge'
import { t } from '../i18n'
import { app, route, setTicking, uiCommand } from '../store'
import { prefs } from '../prefs'
import { openTerminal, showInspector } from '../inspector/state'
import { lazy } from './Lazy'
import { installGlass } from '../glass'

const Inspector = lazy(() => import('../inspector/Inspector').then((m) => m.Inspector))
const Settings = lazy(() => import('../settings/Settings').then((m) => m.Settings))
import { BackgroundRequests } from './Cards'
import type { AppState, Session } from '../types'
import { PermissionCard, PlanApprovalCard, QuestionCard } from './Cards'
import { Composer } from './Composer'
import { HarnessIcon, Icon, Spinner } from './Icon'
import { Sidebar } from './Sidebar'
import { Transcript } from './Transcript'

const DRAG_SELECTOR = 'button, input, textarea, a, select, [data-no-drag]'

export function App() {
  const state = app.value
  const sidebarOpen = prefs.sidebarOpen
  const sidebarWidth = prefs.sidebarWidth
  const dockHeight = useSignal(140)
  /** Card height of the native composer overlay (sessions only; see ComposerOverlay.tsx). */
  const composerH = useSignal(88)
  /** Full overlay height (card + open popups): the ↓ button stays above it. */
  const composerTotal = useSignal(88)
  const dock = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const c = uiCommand.value
    switch (c?.name) {
      case 'composerHeight':
        if (typeof c.data?.h === 'number') composerH.value = c.data.h
        if (typeof c.data?.total === 'number') composerTotal.value = c.data.total
        break
      case 'toggleSidebar':
        sidebarOpen.value = !sidebarOpen.value
        break
      case 'toggleInspector':
        prefs.inspectorOpen.value = !prefs.inspectorOpen.value
        break
      case 'showFiles':
        showInspector('files')
        break
      case 'showChanges':
        showInspector('changes')
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
        break
    }
  }, [uiCommand.value])

  useEffect(() => {
    const el = dock.current
    if (!el) return
    const ro = new ResizeObserver(() => (dockHeight.value = Math.ceil(el.getBoundingClientRect().height)))
    ro.observe(el)
    return () => ro.disconnect()
  }, [state?.selectedSessionId == null])

  const glass = !!state?.chrome.glass
  useEffect(() => {
    if (glass) installGlass()
  }, [glass])
  // With a session open the composer is a native overlay (its own web view on
  // glass) and the transcript scrolls underneath it to the window bottom.
  const overlay = !!state?.chrome.composerOverlay && !!state?.selectedSessionId && route.value.name === 'main'
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
  const inspectorOpen = prefs.inspectorOpen.value
  if (route.value.name === 'settings') {
    return (
      <div class="app settings-mode" style={{ '--head-h': `${headH}px` }}>
        <Settings state={state} section={route.value.section} />
      </div>
    )
  }

  return (
    <div class={'app' + (sidebarOpen.value ? '' : ' no-sidebar') + (inspectorOpen ? ' with-inspector' : '')} style={{ '--sidebar-w': `${sidebarWidth.value}px`, '--head-h': `${headH}px`, '--insp-w': inspectorOpen ? `${prefs.inspectorWidth.value}px` : '0px' }}>
      {sidebarOpen.value && (
        <>
          <Sidebar state={state} onToggle={() => (sidebarOpen.value = false)} />
          <SidebarResizer width={sidebarWidth} />
        </>
      )}
      <main class="main" style={{ '--dock-h': `${dockHeight.value}px` }}>
        <MainHeader state={state} session={session} sidebarOpen={sidebarOpen.value} onToggle={() => (sidebarOpen.value = !sidebarOpen.value)} />
        {session ? (
          <Transcript streaming={session.streaming} padBottom={dockHeight.value + 24} jumpBottom={overlay ? dockHeight.value + 12 + Math.max(0, composerTotal.value - composerH.value) : undefined} padTop={glass ? 12 : 64} />
        ) : (
          <Landing state={state} />
        )}
        <div ref={dock} class={'dock' + (session ? '' : ' landing-dock')}>
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
          {overlay ? <div class="composer-slot" data-glass="slot" style={{ height: composerH.value }} /> : <Composer state={state} session={session} />}
        </div>
      </main>
      {inspectorOpen && <Inspector />}
    </div>
  )
}

function MainHeader({ state, session, sidebarOpen, onToggle }: { state: AppState; session: Session | null; sidebarOpen: boolean; onToggle(): void }) {
  const lights = state.chrome.trafficLights
  const pad = sidebarOpen || state.chrome.fullscreen ? 16 : Math.max(76, lights.x + lights.w + 14)
  const ws = session ? session.cwd.split('/').filter(Boolean).pop() ?? session.cwd : state.workspaceName
  return (
    <header class="main-head" style={{ paddingLeft: pad }}>
      {!sidebarOpen && (
        <span class="head-tools" data-glass="control">
          <button class="icon-btn" title={t('toggleSidebar')} onClick={onToggle}>
            <Icon name="sidebar" size={15} />
          </button>
          <button class="icon-btn" title={t('newChat')} onClick={() => post('newSession')}>
            <Icon name="compose" size={15} />
          </button>
        </span>
      )}
      <div class="head-titles">
        <span class="head-title">{session ? session.title : t('newChat')}</span>
        <span class="head-sub">
          {ws}
          {!session && state.branch ? ` · ${state.branch}` : ''}
        </span>
      </div>
      <div class="flex1" />
      {session && (
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
      {!prefs.inspectorOpen.value && (
        <span class="head-tools right" data-glass="control">
          <button class="icon-btn" title={t('terminal')} onClick={() => void openTerminal()}>
            <Icon name="terminal" size={15} />
          </button>
          <button class="icon-btn" title={t('toggleInspector') + ' (⌥⌘I)'} onClick={() => (prefs.inspectorOpen.value = true)}>
            <Icon name="panelRight" size={15} />
          </button>
        </span>
      )}
    </header>
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
    document.querySelectorAll('.sidebar-resizer, .insp-resizer').forEach((el) => {
      const r = el.getBoundingClientRect()
      rects.push({ x: r.left, y: 0, w: r.width, h: height })
    })
    // The inspector tab strip is interactive across its whole height.
    const tabs = document.querySelector('.insp-tabs')?.getBoundingClientRect()
    if (tabs && tabs.top < height) rects.push({ x: tabs.left, y: tabs.top, w: tabs.width, h: tabs.height })
    const json = JSON.stringify(rects)
    if (json !== lastRegions) {
      lastRegions = json
      post('dragRegions', { rects, height })
    }
  })
}
