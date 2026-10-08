import { useSignal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { post } from '../bridge'
import { relativeTime, t } from '../i18n'
import { app } from '../store'
import { ago, hasReading, lastUpdated, panelProviders, percentText, resetText, statusNote, windowLabel } from '../quota'
import type { ProviderQuota, QuotaWindow } from '../types'
import { HarnessIcon, Icon, Spinner } from './Icon'

/** Menu bar extra (same bundle, `#menubar`): one provider's quota at a time,
 * picked from a bar of harness icons, then 3 recent chats. The panel's height
 * follows its content (`menuBarHeight`, see `naturalHeight`); native resizes
 * the window, top-anchored and animated. */
export function MenuBar() {
  const state = app.value
  const picked = useSignal<string | null>(null)
  const leaving = useSignal<{ p: ProviderQuota; dir: number; key: number } | null>(null)
  const panel = useRef<HTMLDivElement>(null)
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
  useEffect(() => (panel.current ? observeHeight(panel.current) : undefined), [!!state])
  const all = state ? panelProviders(state.quota, state.settings.agents) : []
  const current = state ? selectedProvider(all, picked.value ?? initialSelection() ?? state.menuBarProvider) : undefined
  const select = (id: string) => {
    if (!current || id === current.harnessId) return
    const from = all.indexOf(current)
    const to = all.findIndex((p) => p.harnessId === id)
    if (to < 0) return
    leaving.value = reduceMotion() ? null : { p: current, dir: to > from ? 1 : -1, key: Date.now() }
    picked.value = id
    post('menuBarProvider', { id })
  }
  const step = (delta: number) => {
    if (!current || all.length < 2) return
    const at = all.indexOf(current)
    const next = all[at + delta]
    if (next) select(next.harnessId)
  }
  // ←/→ anywhere in the panel (it has no text fields).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return
      if (e.key === 'ArrowRight') { e.preventDefault(); step(1) }
      else if (e.key === 'ArrowLeft') { e.preventDefault(); step(-1) }
      else return
      queueMicrotask(() => panel.current?.querySelector<HTMLElement>('.mb-tab[aria-selected="true"]')?.focus())
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  })
  const swipe = useRef(swipeTracker((dir) => step(dir)))
  swipe.current.onStep = (dir) => step(dir)
  if (!state) return null
  const updated = lastUpdated(all)
  const refreshing = all.some((p) => p.refreshing)
  const recent = [...state.sessions].sort((a, b) => b.createdAt - a.createdAt).slice(0, 3)
  const out = leaving.value
  return (
    <div class="menubar" ref={panel}>
      <div class="mb-head">
        <span class="mb-title">Aureways</span>
        <div class="flex1" />
        {updated != null && <span class="mb-updated">{t('updated', ago(updated))}</span>}
        <button class="icon-btn tiny" title={t('refresh')} aria-label={t('refresh')} disabled={refreshing} onClick={() => post('refreshQuota')}>
          {refreshing ? <Spinner size={10} /> : <Icon name="refresh" size={11} />}
        </button>
      </div>
      {all.length > 0 && (
        <div class="mb-bar" role="tablist" aria-label={t('quotaProviders')}>
          {all.map((p) => {
            const on = p.harnessId === current?.harnessId
            const dim = p.status === 'notSignedIn' || p.status === 'unsupported'
            const label = dim ? `${p.providerTitle} · ${statusNote(p)}` : p.providerTitle
            return (
              <button key={p.harnessId} role="tab" class={'mb-tab' + (on ? ' on' : '') + (dim ? ' dim' : '')}
                id={'mb-tab-' + p.harnessId} aria-selected={on} aria-controls="mb-detail" tabIndex={on ? 0 : -1}
                title={label} aria-label={label} onClick={() => select(p.harnessId)}>
                <HarnessIcon id={p.harnessId} size={15} />
              </button>
            )
          })}
        </div>
      )}
      <div class="mb-pager" onWheel={(e) => swipe.current.wheel(e)}>
        {out && (
          <div key={'out-' + out.key} class={'mb-page leaving ' + (out.dir > 0 ? 'to-left' : 'to-right')} aria-hidden="true"
            onAnimationEnd={() => { if (leaving.peek()?.key === out.key) leaving.value = null }}>
            <ProviderDetail p={out.p} />
          </div>
        )}
        {current
          ? (
            <div key={current.harnessId} id="mb-detail" role="tabpanel" aria-labelledby={'mb-tab-' + current.harnessId}
              class={'mb-page' + (out ? (out.dir > 0 ? ' from-right' : ' from-left') : '')}>
              <ProviderDetail p={current} />
            </div>
          )
          : <div class="mb-page"><div class="mb-empty">{t('sumNoData')}</div></div>}
      </div>
      <div class="mb-spacer" />
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

/** Demo / screenshot hook: `#menubar?select=codex` picks a provider. */
function initialSelection(): string | null {
  const m = /[?&]select=([\w-]+)/.exec(location.hash)
  return m ? m[1] : null
}

function reduceMotion(): boolean {
  return typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches
}

/**
 * The remembered provider if it is still listed, else the first signed-in
 * one (numbers first, then anything not signed-out / unsupported), else the first.
 */
export function selectedProvider(providers: ProviderQuota[], remembered?: string | null): ProviderQuota | undefined {
  return providers.find((p) => p.harnessId === remembered)
    ?? providers.find(hasReading)
    ?? providers.find((p) => p.status !== 'notSignedIn' && p.status !== 'unsupported')
    ?? providers[0]
}

/**
 * Trackpad horizontal swipe: one step per gesture. Horizontal wheel deltas add
 * up until they pass a threshold; the gesture then stays spent until the
 * wheel goes quiet (momentum included).
 */
export function swipeTracker(onStep: (dir: number) => void, threshold = 36, quietMs = 180) {
  let sum = 0
  let spent = false
  let timer: ReturnType<typeof setTimeout> | undefined
  const tracker = {
    onStep,
    wheel(e: { deltaX: number; deltaY: number; preventDefault?: () => void }) {
      clearTimeout(timer)
      timer = setTimeout(() => { sum = 0; spent = false }, quietMs)
      if (Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return
      e.preventDefault?.()
      if (spent) return
      sum += e.deltaX
      if (Math.abs(sum) >= threshold) {
        spent = true
        tracker.onStep(sum > 0 ? 1 : -1)
        sum = 0
      }
    },
  }
  return tracker
}

/**
 * The panel's height at its natural size: the column is laid out to the
 * window's height with the quota pager able to shrink and a spacer taking any
 * slack, so the natural height is the laid-out height minus the slack plus
 * whatever the pager has to clip.
 */
export function naturalHeight(m: { panel: number; pager: number; page: number; spacer: number }): number {
  return Math.ceil(m.panel - m.spacer - m.pager + m.page)
}

/** Report the natural height to native when it changes (a content change, never per frame). */
export function observeHeight(panel: HTMLElement) {
  let last = 0
  let frame = 0
  const measure = () => {
    frame = 0
    const pager = panel.querySelector<HTMLElement>('.mb-pager')
    const page = pager?.querySelector<HTMLElement>('.mb-page:not(.leaving)')
    const spacer = panel.querySelector<HTMLElement>('.mb-spacer')
    if (!pager || !page) return
    const height = naturalHeight({
      panel: panel.getBoundingClientRect().height,
      pager: pager.getBoundingClientRect().height,
      page: page.getBoundingClientRect().height,
      spacer: spacer?.getBoundingClientRect().height ?? 0,
    })
    if (height > 0 && Math.abs(height - last) >= 1) {
      last = height
      post('menuBarHeight', { height })
    }
  }
  const schedule = () => { if (!frame) frame = requestAnimationFrame(measure) }
  const resize = new ResizeObserver(schedule)
  const watch = () => {
    resize.disconnect()
    resize.observe(panel)
    panel.querySelectorAll('.mb-page:not(.leaving), .mb-section').forEach((el) => resize.observe(el))
  }
  const mutations = new MutationObserver(() => { watch(); schedule() })
  mutations.observe(panel, { childList: true, subtree: true })
  watch()
  schedule()
  return () => {
    cancelAnimationFrame(frame)
    resize.disconnect()
    mutations.disconnect()
  }
}

/** The selected provider: name, plan, every limit with what's LEFT, then where the numbers came from. */
function ProviderDetail({ p }: { p: ProviderQuota }) {
  const reading = hasReading(p)
  const note = statusNote(p)
  return (
    <div class="mb-q">
      <div class="mb-q-line">
        <span class="mb-q-name">{p.providerTitle}</span>
        {p.plan && <span class="badge">{p.plan}</span>}
        <div class="flex1" />
        {p.refreshing && !reading && <Spinner size={9} />}
      </div>
      {reading && <QuotaDetail p={p} />}
      {note && (
        <div class="mb-q-note">
          <span>{note}</span>
          {p.status === 'notSignedIn' && (
            <>
              <span aria-hidden="true"> · </span>
              <button class="mb-inline-link" onClick={() => post('openSettings', { section: 'usage' })}>{t('goSettings')}</button>
            </>
          )}
          {p.status === 'error' && (
            <>
              <span aria-hidden="true"> · </span>
              <button class="mb-inline-link" onClick={() => post('refreshQuota', { id: p.harnessId })}>{t('retry')}</button>
              <span aria-hidden="true"> · </span>
              <button class="mb-inline-link" onClick={() => post('openSettings', { section: 'usage' })}>{t('goSettings')}</button>
            </>
          )}
        </div>
      )}
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
      <div class="mb-q-track"><div class={'mb-q-fill ' + w.level} style={{ width: `${w.remainingPercent}%` }} /></div>
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
