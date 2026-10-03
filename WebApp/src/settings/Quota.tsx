import { rpc } from '../rpc'
import { t, relativeTime } from '../i18n'
import type { QuotaSnapshot, QuotaWindow, SettingsAgent } from '../types'
import { HarnessIcon, Icon, Spinner } from '../components/Icon'

export function QuotaCard({ agent, snapshot, compact = false }: { agent: SettingsAgent | { id: string; title: string; quotaRefreshing?: boolean; available?: boolean }; snapshot?: QuotaSnapshot; compact?: boolean }) {
  const windows = snapshot ? [snapshot.primaryWindow, snapshot.secondaryWindow, ...(snapshot.extraWindows ?? [])].filter(Boolean) as QuotaWindow[] : []
  return (
    <div class={'quota-card' + (compact ? ' compact' : '')}>
      <div class="quota-head">
        <HarnessIcon id={agent.id} size={14} />
        <span class="quota-title">{agent.title}</span>
        {snapshot?.planType && <span class="badge">{snapshot.planType}</span>}
        <div class="flex1" />
        <button class="icon-btn tiny" title={t('refresh')} onClick={() => rpc('quota.refresh', { id: agent.id })}>
          {agent.quotaRefreshing ? <Spinner size={10} /> : <Icon name="refresh" size={11} />}
        </button>
      </div>
      {!snapshot ? (
        <div class="quota-empty">{agent.available === false ? t('notInstalled') : t('noQuota')}</div>
      ) : snapshot.error ? (
        <div class="quota-empty bad">{snapshot.error}</div>
      ) : (
        <>
          {windows.map((w) => <QuotaBar key={w.id} w={w} />)}
          {snapshot.usageBreakdown?.map((b) => <QuotaBar key={b.id} w={{ id: b.id, title: b.title, usedPercent: b.usedPercent }} />)}
          {(snapshot.creditsRemaining != null || snapshot.resetCreditsAvailable != null) && (
            <div class="quota-meta">
              {snapshot.creditsRemaining != null && <span>{t('creditsLeft')} {snapshot.creditsRemaining.toFixed(2)} {snapshot.creditsUnit ?? ''}</span>}
              {snapshot.resetCreditsAvailable != null && <span>{t('freeResets', snapshot.resetCreditsAvailable)}</span>}
            </div>
          )}
          {!compact && (
            <div class="quota-foot">
              {snapshot.accountEmail && <span>{snapshot.accountEmail}</span>}
              <span>{t('updated', relativeTime(snapshot.updatedAt))}</span>
            </div>
          )}
        </>
      )}
    </div>
  )
}

function QuotaBar({ w }: { w: QuotaWindow }) {
  const remaining = Math.max(0, Math.min(100, 100 - w.usedPercent))
  const sev = remaining <= 10 ? 'critical' : remaining <= 30 ? 'warning' : 'healthy'
  const reset = w.resetsAt ? resetIn(w.resetsAt) : w.resetDescription
  return (
    <div class="quota-bar">
      <div class="quota-bar-label">
        <span>{w.title}</span>
        <span class="quota-pct">{Math.round(remaining)}%</span>
      </div>
      <div class="quota-track"><div class={'quota-fill ' + sev} style={{ width: remaining + '%' }} /></div>
      {reset && <div class="quota-reset">{t('resetsIn', reset)}</div>}
    </div>
  )
}

function resetIn(ms: number): string {
  const d = Math.max(0, ms - Date.now())
  const m = Math.round(d / 60000)
  if (m < 60) return `${m}m`
  const h = Math.floor(m / 60)
  if (h < 48) return `${h}h ${m % 60}m`
  return `${Math.floor(h / 24)}d ${h % 24}h`
}
