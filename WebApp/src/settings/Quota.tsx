import { rpc } from '../rpc'
import { t, relativeTime } from '../i18n'
import type { QuotaSnapshot, QuotaWindow, SettingsAgent } from '../types'
import { HarnessIcon, Icon, Spinner } from '../components/Icon'

/** Product rows that add up to the shared window are shares of that pool, even on a cache written before `pooled` existed. */
function asShares(snapshot: QuotaSnapshot) {
  const items = snapshot.usageBreakdown ?? []
  if (items.some((b) => b.pooled)) return items.map((b) => ({ ...b, pooled: true }))
  const total = snapshot.primaryWindow?.usedPercent
  if (total == null || items.length < 2) return items
  const sum = items.reduce((n, b) => n + b.usedPercent, 0)
  if (Math.abs(sum - total) > 1) return items
  return items.map((b) => ({ ...b, pooled: true }))
}

export function QuotaCard({ agent, snapshot, compact = false }: { agent: SettingsAgent | { id: string; title: string; quotaRefreshing?: boolean; quotaSupported?: boolean; available?: boolean }; snapshot?: QuotaSnapshot; compact?: boolean }) {
  const windows = snapshot ? [snapshot.primaryWindow, snapshot.secondaryWindow, ...(snapshot.extraWindows ?? [])].filter(Boolean) as QuotaWindow[] : []
  const breakdown = snapshot ? asShares(snapshot) : []
  const pooled = breakdown.filter((b) => b.pooled)
  const separate = breakdown.filter((b) => !b.pooled)
  const poolWindow = pooled.length > 0 ? windows[0] : undefined
  const restWindows = poolWindow ? windows.slice(1) : windows
  return (
    <div class={'quota-card' + (compact ? ' compact' : '')}>
      <div class="quota-head">
        <HarnessIcon id={agent.id} size={compact ? 13 : 14} />
        <span class="quota-title">{agent.title}</span>
        {snapshot?.planType && <span class="badge">{snapshot.planType}</span>}
        <div class="flex1" />
        <button class="icon-btn tiny" title={t('refresh')} onClick={() => rpc('quota.refresh', { id: agent.id })}>
          {agent.quotaRefreshing ? <Spinner size={compact ? 9 : 10} /> : <Icon name="refresh" size={compact ? 10 : 11} />}
        </button>
      </div>
      {!snapshot ? (
        <div class="quota-empty">{agent.available === false ? t('notInstalled') : agent.quotaSupported ? t('quotaErr_notConfigured') : t('noQuota')}</div>
      ) : snapshot.error && windows.length === 0 && snapshot.creditsRemaining == null && !snapshot.usageBreakdown?.length ? (
        <div class="quota-empty bad">{quotaError(snapshot.error)}</div>
      ) : (
        <>
          {snapshot.error && <div class="quota-warn">{quotaError(snapshot.error)} · {t('quotaStale')}</div>}
          {poolWindow && <QuotaPool w={poolWindow} shares={pooled} />}
          {restWindows.map((w) => <QuotaBar key={w.id} w={w} />)}
          {separate.map((b) => <QuotaBar key={b.id} w={{ id: b.id, title: b.title, usedPercent: b.usedPercent }} />)}
          {(snapshot.creditsRemaining != null || snapshot.resetCreditsAvailable != null) && (
            <div class="quota-meta">
              {snapshot.creditsRemaining != null && <span>{t('creditsLeft')} {snapshot.creditsRemaining.toFixed(2)} {snapshot.creditsUnit ?? ''}</span>}
              {snapshot.resetCreditsAvailable != null && <span>{t('freeResets', snapshot.resetCreditsAvailable)}</span>}
            </div>
          )}
          {!compact && (
            <div class="quota-foot">
              {snapshot.accountEmail && <span>{snapshot.accountEmail}</span>}
              {snapshot.supplement && <span>{t('quotaSession', tokens(snapshot.supplement.usedTokens), tokens(snapshot.supplement.contextTokens))}</span>}
              <span title={snapshot.sourceId}>
                {snapshot.sourceKind ? t('quotaSource_' + snapshot.sourceKind) + ' · ' : ''}
                {t('updated', relativeTime(snapshot.fetchedAt ?? snapshot.updatedAt))}
              </span>
            </div>
          )}
        </>
      )}
    </div>
  )
}

/** One shared limit. Left segments are each product's share of the pool; the right side is what remains. */
function QuotaPool({ w, shares }: { w: QuotaWindow; shares: { id: string; title: string; usedPercent: number }[] }) {
  const remaining = Math.max(0, Math.min(100, 100 - w.usedPercent))
  const used = 100 - remaining
  const sum = shares.reduce((n, s) => n + Math.max(0, s.usedPercent), 0)
  const scale = sum > 0 ? used / sum : 0
  const sev = remaining <= 10 ? 'critical' : remaining <= 30 ? 'warning' : 'healthy'
  const reset = w.resetsAt ? resetIn(w.resetsAt) : w.resetDescription
  return (
    <div class="quota-bar">
      <div class="quota-bar-label">
        <span>{w.title}</span>
        <span class="quota-pct">{Math.round(remaining)}%</span>
      </div>
      <div class="quota-track pool">
        {shares.map((s, i) => {
          const width = Math.max(0, s.usedPercent) * scale
          if (width <= 0) return null
          return <div key={s.id} class={'quota-seg s' + (i % 3)} style={{ width: width + '%' }} />
        })}
        {remaining > 0 && <div class={'quota-fill ' + sev} style={{ width: remaining + '%' }} />}
      </div>
      <div class="quota-legend">
        <span class="quota-legend-k">{t('quotaUsed')}</span>
        {shares.map((s, i) => (
          <span key={s.id} class="quota-legend-item">
            <i class={'quota-swatch s' + (i % 3)} />
            {s.title}
            <span class="quota-pct">{Math.round(Math.max(0, s.usedPercent))}%</span>
          </span>
        ))}
      </div>
      {reset && <div class="quota-reset">{t('resetsIn', reset)}</div>}
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

const quotaErrorKinds = ['rateLimited', 'unauthorized', 'notConfigured', 'network', 'unavailable']

function quotaError(kind: string): string {
  return quotaErrorKinds.includes(kind) ? t('quotaErr_' + kind) : t('quotaErr_generic', kind)
}

function tokens(n: number): string {
  return n >= 1000 ? `${Math.round(n / 100) / 10}k` : String(n)
}
