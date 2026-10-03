import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { post } from '../bridge'
import { relativeTime, t } from '../i18n'
import { app } from '../store'
import { QuotaCard } from '../settings/Quota'
import { HarnessIcon, Icon, Spinner } from './Icon'

/** Menu bar extra (same bundle, `#menubar`): quota overview + recent chats. */
export function MenuBar() {
  const state = app.value
  const tab = useSignal<string | null>(null)
  // Panel shown → one stale-only quota check natively. No timers here: the menu bar never polls.
  useEffect(() => {
    const opened = () => { if (document.visibilityState === 'visible') post('menuBarOpened') }
    opened()
    document.addEventListener('visibilitychange', opened)
    window.addEventListener('focus', opened)
    return () => {
      document.removeEventListener('visibilitychange', opened)
      window.removeEventListener('focus', opened)
    }
  }, [])
  if (!state) return null
  const agents = state.settings.agents.filter((a) => a.enabled && a.available)
  const current = agents.find((a) => a.id === tab.value) ?? agents.find((a) => state.quota[a.id]) ?? agents[0]
  const recent = [...state.sessions].sort((a, b) => b.createdAt - a.createdAt).slice(0, 6)
  return (
    <div class="menubar">
      <div class="mb-head">
        <span class="mb-title">Aureways</span>
        <div class="flex1" />
        <button class="btn small" onClick={() => post('newSession')}>
          <Icon name="compose" size={12} /> {t('newChat')}
        </button>
      </div>
      {agents.length > 0 && (
        <section class="mb-section">
          <div class="mb-label">{t('settings_usage')}</div>
          <div class="mb-agents">
            {agents.map((a) => (
              <button key={a.id} class={'mb-agent' + (a.id === current?.id ? ' on' : '')} title={a.title} onClick={() => (tab.value = a.id)}>
                <HarnessIcon id={a.id} size={13} />
                {state.quota[a.id] && state.quota[a.id].severity !== 'unknown' && <span class={'mb-sev ' + state.quota[a.id].severity} />}
              </button>
            ))}
          </div>
          {current && <QuotaCard agent={current} snapshot={state.quota[current.id]} compact />}
        </section>
      )}
      <section class="mb-section grow">
        <div class="mb-label">{t('recentChats')}</div>
        {recent.length === 0 && <div class="mb-empty">{t('noSessions')}</div>}
        {recent.map((s) => (
          <button key={s.id} class="mb-row" onClick={() => post('selectSession', { id: s.id })}>
            <HarnessIcon id={s.agentId} size={12} />
            <span class="mb-row-title">{s.title}</span>
            {s.attention || s.permission ? <span class="attention-dot" /> : s.streaming ? <Spinner size={10} /> : <span class="session-time">{relativeTime(s.createdAt)}</span>}
          </button>
        ))}
      </section>
      <div class="mb-foot">
        <button class="mb-link" onClick={() => post('openApp')}>{t('openApp')}</button>
        <button class="mb-link" onClick={() => post('openSettings')}>{t('settings')}</button>
        <div class="flex1" />
        <button class="mb-link" onClick={() => post('quitApp')}>{t('quitApp')}</button>
      </div>
    </div>
  )
}
