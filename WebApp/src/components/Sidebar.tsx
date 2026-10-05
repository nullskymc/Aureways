import { useSignal } from '@preact/signals'
import { nativeMenu, post } from '../bridge'
import { relativeTime, t } from '../i18n'
import { route } from '../store'
import { prefs } from '../prefs'
import type { AppState, Session } from '../types'
import { HarnessIcon, Icon, Spinner } from './Icon'
import { lazy } from './Lazy'

const SettingsNav = lazy(() => import('../settings/Settings').then((m) => m.SettingsNav))

export function Sidebar({ state, onToggle }: { state: AppState; onToggle(): void }) {
  const r = route.value
  const isSettings = r.name === 'settings'
  const settingsSection = r.name === 'settings' ? r.section : undefined
  const query = useSignal('')
  const q = query.value.trim().toLowerCase()
  const filtered = q
    ? state.sessions.filter((s) => s.title.toLowerCase().includes(q) || s.agentTitle.toLowerCase().includes(q) || s.cwd.toLowerCase().includes(q))
    : state.sessions

  const known = new Set(state.workspaces.map((w) => w.path))
  const groups = state.workspaces
    .map((w) => ({ key: w.path, name: w.name, path: w.path, sessions: filtered.filter((s) => s.ws === w.path) }))
    .filter((g) => !q || g.sessions.length)
  const orphans = filtered.filter((s) => !known.has(s.ws))
  if (orphans.length) groups.push({ key: '__other', name: t('other'), path: '', sessions: orphans })

  const lights = state.chrome.trafficLights
  const headPad = state.chrome.fullscreen ? 12 : Math.max(76, lights.x + lights.w + 14)
  const showNewChatSelected = !isSettings && state.selectedSessionId === null

  return (
    <aside class={'sidebar' + (isSettings ? ' settings-nav' : '')} data-glass="sidebar">
      <div class="sidebar-head" style={{ paddingLeft: headPad }}>
        <div class="flex1" />
        <button class="icon-btn" title={t('toggleSidebar')} onClick={onToggle} data-no-drag>
          <Icon name="sidebar" size={15} />
        </button>
      </div>
      {isSettings ? (
        <SettingsNav state={state} current={settingsSection ?? 'general'} />
      ) : (
        <>
          <div class="sidebar-actions">
        <button class={'nav-row' + (showNewChatSelected ? ' selected' : '')} onClick={() => post('newSession')}>
          <Icon name="compose" size={15} />
          <span>{t('newChat')}</span>
          <kbd>⌘N</kbd>
        </button>
        <label class="search-row">
          <Icon name="search" size={14} />
          <input
            value={query.value}
            placeholder={t('search')}
            onInput={(e) => (query.value = (e.target as HTMLInputElement).value)}
            onKeyDown={(e) => e.key === 'Escape' && (query.value = '')}
          />
        </label>
      </div>
      <div class="sidebar-list">
        {groups.map((g) => {
          const collapsed = prefs.collapsedGroups.value.includes(g.key) && !q
          return (
            <section key={g.key} class="ws-group">
              <div class="ws-head">
                <button
                  class="ws-title"
                  onClick={() => {
                    const cur = prefs.collapsedGroups.value
                    prefs.collapsedGroups.value = collapsed ? cur.filter((k) => k !== g.key) : [...cur, g.key]
                  }}
                >
                  <Icon name={collapsed ? 'chevronRight' : 'folder'} size={14} class="ws-icon" />
                  <span>{g.name}</span>
                </button>
                {g.path && (
                  <span class="ws-tools">
                    <button
                      class="icon-btn small"
                      title={t('newChatIn', g.name)}
                      onClick={() => post('newSession', { workspace: g.path })}
                    >
                      <Icon name="plus" size={13} />
                    </button>
                    <button
                      class="icon-btn small"
                      onClick={async (e) => {
                        const id = await nativeMenu(
                          [
                            { id: 'new', title: t('newChatIn', g.name), icon: 'square.and.pencil' },
                            { id: 'reveal', title: 'Finder', icon: 'folder' },
                          ],
                          e.currentTarget as Element,
                        )
                        if (id === 'new') post('newSession', { workspace: g.path })
                        if (id === 'reveal') post('revealWorkspace', { path: g.path })
                      }}
                    >
                      <Icon name="more" size={13} />
                    </button>
                  </span>
                )}
              </div>
              {!collapsed &&
                g.sessions.map((s) => <SessionRow key={s.id} s={s} selected={s.id === state.selectedSessionId} />)}
            </section>
          )
        })}
        {!state.sessions.length && <div class="sidebar-empty">{t('noSessions')}</div>}
      </div>
      <div class="sidebar-foot">
        <button class="nav-row" onClick={() => (route.value = { name: 'settings' })}>
          <Icon name="gear" size={15} />
          <span>{t('settings')}</span>
        </button>
        <button class="icon-btn" title={t('addWorkspace')} onClick={() => post('addWorkspace')}>
          <Icon name="folderPlus" size={15} />
        </button>
      </div>
        </>
      )}
    </aside>
  )
}

function SessionRow({ s, selected }: { s: Session; selected: boolean }) {
  const busy = s.streaming || s.phase === 'connecting'
  return (
    <button
      class={'session-row' + (selected ? ' selected' : '')}
      onClick={() => post('selectSession', { id: s.id })}
      onContextMenu={(e) => {
        e.preventDefault()
        post('sessionMenu', { id: s.id, x: e.clientX, y: e.clientY })
      }}
      title={`${s.title}\n${s.agentTitle} · ${s.cwd}`}
    >
      <span class="session-harness">
        <HarnessIcon id={s.agentId} size={13} />
      </span>
      <span class="session-title">{s.title}</span>
      <span class="session-meta">
        {s.attention ? (
          <span class="attention-dot" />
        ) : busy ? (
          <Spinner size={11} />
        ) : s.phase === 'failed' ? (
          <Icon name="alert" size={12} class="bad" />
        ) : (
          <span class="session-time">{relativeTime(s.createdAt)}</span>
        )}
      </span>
    </button>
  )
}
