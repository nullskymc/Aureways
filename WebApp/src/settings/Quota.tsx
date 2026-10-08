import { rpc } from '../rpc'
import { t } from '../i18n'
import { ago, hasReading, percentText, resetText, statusNote, windowLabel } from '../quota'
import type { ProviderQuota, QuotaWindow, SettingsAgent } from '../types'
import { HarnessIcon, Icon, Spinner } from '../components/Icon'

/** Usage settings card: every limit of one provider, read from the unified quota model. Always shows what's LEFT. */
export function QuotaCard({ agent, quota }: { agent: SettingsAgent; quota?: ProviderQuota }) {
  const reading = quota ? hasReading(quota) : false
  const note = quota ? (agent.available === false && !reading ? t('notInstalled') : statusNote(quota)) : t('notInstalled')
  const meta = quota ? [
    quota.account,
    quota.supplement && t('quotaSession', tokens(quota.supplement.usedTokens), tokens(quota.supplement.contextTokens)),
    quota.sourceKind && t('quotaSource_' + quota.sourceKind),
    quota.lastUpdated != null && t('updated', ago(quota.lastUpdated)),
  ].filter(Boolean) as string[] : []
  const supported = quota?.status !== 'unsupported'
  return (
    <div class="quota-card">
      <div class="quota-head">
        <HarnessIcon id={agent.id} size={14} />
        <span class="quota-title">{agent.title}</span>
        {quota?.plan && <span class="badge">{quota.plan}</span>}
        <div class="flex1" />
        {supported && (
          <button class="icon-btn tiny" title={t('refresh')} aria-label={t('refresh')} onClick={() => rpc('quota.refresh', { id: agent.id })}>
            {quota?.refreshing ? <Spinner size={10} /> : <Icon name="refresh" size={11} />}
          </button>
        )}
      </div>
      {reading && quota!.windows.map((w) => <QuotaBar key={w.id} w={w} />)}
      {note && <div class={'quota-empty' + (quota?.status === 'error' ? ' bad' : '')}>{note}</div>}
      {reading && quota!.resetCreditsAvailable != null && quota!.resetCreditsAvailable > 0 && (
        <div class="quota-meta"><span>{t('freeResets', quota!.resetCreditsAvailable)}</span></div>
      )}
      {reading && meta.length > 0 && <div class="quota-foot"><span>{meta.join(' · ')}</span></div>}
    </div>
  )
}

function QuotaBar({ w }: { w: QuotaWindow }) {
  if (w.remainingPercent == null) {
    return (
      <div class="quota-bar">
        <div class="quota-bar-label">
          <span>{windowLabel(w.label)}</span>
          <span class="quota-pct">{w.balance != null ? `${w.balance.toFixed(2)} ${w.unit ?? ''}` : '—'}</span>
        </div>
      </div>
    )
  }
  const reset = resetText(w)
  return (
    <div class="quota-bar">
      <div class="quota-bar-label">
        <span>{windowLabel(w.label)}</span>
        <span class="quota-pct">{t('quotaLeft')} {percentText(w.remainingPercent, w.estimated)}</span>
      </div>
      <div class="quota-track"><div class={'quota-fill ' + w.level} style={{ width: w.remainingPercent + '%' }} /></div>
      {w.shares && w.shares.length > 0 && (
        <div class="quota-legend">
          <span class="quota-legend-k">{t('quotaUsed')}</span>
          {w.shares.map((s) => (
            <span key={s.id} class="quota-legend-item">{s.title}<span class="quota-pct">{Math.round(Math.max(0, s.usedPercent))}%</span></span>
          ))}
        </div>
      )}
      {reset && <div class="quota-reset">{reset}</div>}
    </div>
  )
}

function tokens(n: number): string {
  return n >= 1000 ? `${Math.round(n / 100) / 10}k` : String(n)
}
