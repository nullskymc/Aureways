import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { post } from '../bridge'
import { relativeTime, t } from '../i18n'
import { app } from '../store'
import { ago, hasReading, lastUpdated, panelProviders, percentText, resetText, statusNote, tightestWindow, windowLabel } from '../quota'
import type { ProviderQuota, QuotaWindow } from '../types'
import { HarnessIcon, Icon, Spinner } from './Icon'

/** Menu bar extra (same bundle, `#menubar`): every provider's remaining quota at a glance, then 3 recent chats. */
export function MenuBar() {
  const state = app.value
  const expanded = useSignal<string | null>(initialExpanded())
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
  const all = panelProviders(state.quota, state.settings.agents)
  const rows = all.filter((p) => p.status !== 'unsupported')
  const unsupported = all.filter((p) => p.status === 'unsupported')
  const updated = lastUpdated(rows)
  const refreshing = rows.some((p) => p.refreshing)
  const recent = [...state.sessions].sort((a, b) => b.createdAt - a.createdAt).slice(0, 3)
  return (
    <div class="menubar">
      <div class="mb-head">
        <span class="mb-title">Aureways</span>
        <div class="flex1" />
        {updated != null && <span class="mb-updated">{t('updated', ago(updated))}</span>}
        <button class="icon-btn tiny" title={t('refresh')} aria-label={t('refresh')} disabled={refreshing} onClick={() => post('refreshQuota')}>
          {refreshing ? <Spinner size={10} /> : <Icon name="refresh" size={11} />}
        </button>
      </div>
      <div class="mb-quota">
        {rows.map((p) => (
          <QuotaRow key={p.harnessId} p={p} open={expanded.value === p.harnessId} onToggle={() => (expanded.value = expanded.value === p.harnessId ? null : p.harnessId)} />
        ))}
        {unsupported.length > 0 && <div class="mb-unsupported">{t('unsupportedList', unsupported.map((p) => p.providerTitle).join(' · '))}</div>}
        {all.length === 0 && <div class="mb-empty">{t('sumNoData')}</div>}
      </div>
      <section class="mb-section">
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
        <button class="mb-link" onClick={() => post('newSession')}>{t('newChat')}</button>
        <button class="mb-link" onClick={() => post('openApp')}>{t('openApp')}</button>
        <button class="mb-link" onClick={() => post('openSettings')}>{t('settings')}</button>
        <div class="flex1" />
        <button class="mb-link" onClick={() => post('quitApp')}>{t('quitApp')}</button>
      </div>
    </div>
  )
}

/** Demo / screenshot hook: `#menubar?expand=codex` opens one row. */
function initialExpanded(): string | null {
  const m = /[?&]expand=([\w-]+)/.exec(location.hash)
  return m ? m[1] : null
}

/** One provider: name, plan, the tightest limit as a thin bar with what's LEFT and when it resets. */
function QuotaRow({ p, open, onToggle }: { p: ProviderQuota; open: boolean; onToggle: () => void }) {
  const reading = hasReading(p)
  const tight = reading ? tightestWindow(p) : undefined
  const balance = reading && !tight ? p.windows.find((w) => w.balance != null) : undefined
  const note = statusNote(p)
  const remaining = tight?.remainingPercent ?? 0
  const level = tight?.level ?? 'unknown'
  const expandable = reading
  const toggle = () => { if (expandable) onToggle() }
  return (
    <div class={'mb-q' + (open ? ' open' : '') + (expandable ? ' expandable' : '')}>
      <div
        class="mb-q-main"
        role={expandable ? 'button' : undefined}
        tabIndex={expandable ? 0 : undefined}
        aria-expanded={expandable ? open : undefined}
        onClick={toggle}
        onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle() } }}
      >
        <div class="mb-q-line">
          <HarnessIcon id={p.harnessId} size={13} />
          <span class="mb-q-name">{p.providerTitle}</span>
          {p.plan && <span class="badge">{p.plan}</span>}
          <div class="flex1" />
          {tight && <span class={'mb-q-pct' + (level === 'low' ? ' low' : '')}>{percentText(remaining, tight.estimated)}</span>}
          {balance && <span class="mb-q-pct">{balanceText(balance)}</span>}
          {p.refreshing && !reading && <Spinner size={9} />}
        </div>
        {tight && (
          <>
            <div class="mb-q-track"><div class={'mb-q-fill ' + level} style={{ width: `${remaining}%` }} /></div>
            <div class="mb-q-sub">
              <span>{windowLabel(tight.label)}</span>
              <span>{resetText(tight)}</span>
            </div>
          </>
        )}
        {note && (
          <div class="mb-q-note">
            <span>{note}</span>
            {p.status === 'notSignedIn' && (
              <>
                <span aria-hidden="true"> · </span>
                <button class="mb-inline-link" onClick={(e) => { e.stopPropagation(); post('openSettings', { section: 'usage' }) }}>{t('goSettings')}</button>
              </>
            )}
            {p.status === 'error' && (
              <>
                <span aria-hidden="true"> · </span>
                <button class="mb-inline-link" onClick={(e) => { e.stopPropagation(); post('refreshQuota', { id: p.harnessId }) }}>{t('retry')}</button>
              </>
            )}
          </div>
        )}
      </div>
      {open && reading && <QuotaDetail p={p} />}
    </div>
  )
}

/** Expanded row: every limit, pooled shares, balance, and where the numbers came from. */
function QuotaDetail({ p }: { p: ProviderQuota }) {
  const meta = [
    p.account,
    p.sourceKind && t('quotaSource_' + p.sourceKind),
    p.lastUpdated != null && t('updated', ago(p.lastUpdated)),
  ].filter(Boolean) as string[]
  return (
    <div class="mb-q-detail">
      {p.windows.map((w) => <WindowLine key={w.id} w={w} />)}
      {p.resetCreditsAvailable != null && p.resetCreditsAvailable > 0 && <div class="mb-w-sub">{t('freeResets', p.resetCreditsAvailable)}</div>}
      {meta.length > 0 && <div class="mb-q-meta">{meta.join(' · ')}</div>}
    </div>
  )
}

function WindowLine({ w }: { w: QuotaWindow }) {
  if (w.remainingPercent == null) {
    return (
      <div class="mb-w">
        <div class="mb-w-line"><span>{windowLabel(w.label)}</span><span class="mb-w-pct">{w.balance != null ? balanceText(w) : '—'}</span></div>
      </div>
    )
  }
  const reset = resetText(w)
  return (
    <div class="mb-w">
      <div class="mb-w-line">
        <span>{windowLabel(w.label)}</span>
        <span class={'mb-w-pct' + (w.level === 'low' ? ' low' : '')}>{percentText(w.remainingPercent, w.estimated)}</span>
      </div>
      <div class="mb-q-track thin"><div class={'mb-q-fill ' + w.level} style={{ width: `${w.remainingPercent}%` }} /></div>
      {w.shares && w.shares.length > 0 && (
        <div class="mb-w-sub">{t('quotaUsed')} {w.shares.map((s) => `${s.title} ${Math.round(s.usedPercent)}%`).join(' · ')}</div>
      )}
      {reset && <div class="mb-w-sub">{reset}</div>}
    </div>
  )
}

function balanceText(w: QuotaWindow): string {
  const n = w.balance ?? 0
  return `${n >= 100 ? Math.round(n) : n.toFixed(2)} ${w.unit ?? ''}`.trim()
}
