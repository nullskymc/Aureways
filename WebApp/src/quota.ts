// Pure helpers over the unified quota model (types.ts ProviderQuota). The menu
// bar panel and the Usage settings page both format through here, so "remaining"
// reads the same everywhere.
import { t } from './i18n'
import type { ProviderQuota, QuotaLevel, QuotaWindow } from './types'

/** Same bands as native QuotaLevel: >50 green, 20–50 orange, <20 red. */
export function levelFor(remaining: number | null | undefined): QuotaLevel {
  if (remaining == null) return 'unknown'
  return remaining > 50 ? 'ample' : remaining >= 20 ? 'moderate' : 'low'
}

/** The window that runs out first (the one a collapsed row shows). */
export function tightestWindow(p: ProviderQuota): QuotaWindow | undefined {
  const rated = p.windows.filter((w) => w.remainingPercent != null)
  return rated.find((w) => w.id === p.tightestId)
    ?? rated.reduce<QuotaWindow | undefined>((min, w) => (min == null || (w.remainingPercent ?? 100) < (min.remainingPercent ?? 100) ? w : min), undefined)
}

/** Has a reading the UI can show as numbers. */
export function hasReading(p: ProviderQuota): boolean {
  return (p.status === 'ok' || p.status === 'stale') && p.windows.length > 0
}

/** "38%", or "约 38%" / "~38%" for estimates. */
export function percentText(remaining: number, estimated: boolean): string {
  const n = `${Math.round(Math.max(0, Math.min(100, remaining)))}%`
  return estimated ? t('approx', n) : n
}

/** Adapters send short English tokens; localize the known ones, keep model names as-is. */
export function windowLabel(label: string): string {
  const tokens: [RegExp, string][] = [
    [/\bCode review\b/, 'qwin_codeReview'],
    [/\bWeekly\b/, 'qwin_weekly'],
    [/\bDaily\b/, 'qwin_daily'],
    [/\bMonthly\b/, 'qwin_monthly'],
    [/\bCredits\b/, 'qwin_credits'],
    [/\b5h\b/, 'qwin_5h'],
  ]
  let out = label
  for (const [re, key] of tokens) out = out.replace(re, t(key))
  return out
}

/** Compact countdown: "2h 14m" / "3d 4h" (zh: "2 小时 14 分" / "3 天 4 小时"). */
export function countdown(ms: number, now = Date.now()): string {
  const m = Math.max(1, Math.round((ms - now) / 60000))
  if (m < 60) return t('dur_m', m)
  const h = Math.floor(m / 60)
  if (h < 48) return m % 60 ? t('dur_hm', h, m % 60) : t('dur_h', h)
  const d = Math.floor(h / 24)
  return h % 24 ? t('dur_dh', d, h % 24) : t('dur_d', d)
}

/** "2h 14m 后重置" / "resets in 2h 14m" / "已重置", or the provider's own description. */
export function resetText(w: QuotaWindow, now = Date.now()): string | undefined {
  if (w.resetsAt != null) return w.resetsAt <= now ? t('quotaWasReset') : t('resetsIn', countdown(w.resetsAt, now))
  return w.resetDescription || undefined
}

const errorKinds = ['rateLimited', 'unauthorized', 'notConfigured', 'network', 'unavailable', 'invalidResponse']

export function errorText(kind?: string): string {
  if (!kind) return t('quotaErr_unavailable')
  return errorKinds.includes(kind) ? t('quotaErr_' + kind) : t('quotaErr_generic', kind)
}

/** Gray inline note for a row without numbers, or with numbers that may be old. */
export function statusNote(p: ProviderQuota): string | undefined {
  switch (p.status) {
    case 'notSignedIn': return p.statusDetail === 'unauthorized' ? t('quotaLoginExpired') : t('quotaNotSignedIn')
    case 'unsupported': return t('quotaUnsupported')
    case 'error': return errorText(p.statusDetail)
    case 'stale': return p.statusDetail ? t('quotaStaleBecause', errorText(p.statusDetail)) : t('quotaStaleOld')
    default: return p.windows.length ? undefined : p.refreshing ? t('quotaLoading') : t('quotaNotFetched')
  }
}

/** Newest reading across providers (for 更新于 …). */
export function lastUpdated(providers: ProviderQuota[]): number | undefined {
  const times = providers.map((p) => p.lastUpdated).filter((x): x is number => x != null)
  return times.length ? Math.max(...times) : undefined
}

/** Rows for the panel: enabled + installed agents, in settings order. */
export function panelProviders(quota: Record<string, ProviderQuota>, agents: { id: string; enabled: boolean; available: boolean }[]): ProviderQuota[] {
  return agents.filter((a) => a.enabled && a.available && quota[a.id]).map((a) => quota[a.id])
}

/** "3 分钟前" / "3 min ago". */
export function ago(ts: number, now = Date.now()): string {
  const m = Math.floor((now - ts) / 60000)
  if (m < 1) return t('ago_now')
  if (m < 60) return t('ago_m', m)
  const h = Math.floor(m / 60)
  if (h < 48) return t('ago_h', h)
  return t('ago_d', Math.floor(h / 24))
}
