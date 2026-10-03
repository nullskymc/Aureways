import { useLayoutEffect, useRef } from 'preact/hooks'
import { post } from '../bridge'
import { app } from '../store'
import { Composer } from './Composer'

/**
 * `#composer` entry: the composer alone, hosted by a small transparent
 * WKWebView above the main page (WebShellView.swift → ComposerOverlay) with
 * native glass under the card. Reports its height and the card/popup rects
 * (measured from the bottom, since the viewport follows the reported height).
 * With no session selected it renders nothing; the new-chat landing keeps the
 * in-page composer.
 */
export function ComposerOverlay() {
  const state = app.value
  const root = useRef<HTMLDivElement>(null)
  const session = state?.sessions.find((s) => s.id === state.selectedSessionId) ?? null

  useLayoutEffect(() => {
    let last = ''
    // Timers, not rAF: the overlay web view starts hidden, and hidden web
    // views get no animation frames.
    let timer = 0
    const report = () => {
      timer = 0
      const el = root.current
      const card = el?.querySelector<HTMLElement>('.composer')
      if (!el || !card) {
        if (last !== 'none') post('composerLayout', { h: 0 })
        last = 'none'
        return
      }
      const base = el.getBoundingClientRect().bottom
      const rect = (r: DOMRect) => ({ x: Math.floor(r.left), w: Math.ceil(r.width), h: Math.ceil(r.height), b: Math.round(base - r.bottom) })
      const c = card.getBoundingClientRect()
      const menu = el.querySelector<HTMLElement>('.slash-menu')?.getBoundingClientRect()
      const top = Math.min(c.top, menu ? menu.top : c.top)
      const msg = {
        h: Math.ceil(base - top),
        vw: window.innerWidth,
        card: { ...rect(c), r: parseFloat(getComputedStyle(card).borderTopLeftRadius) || 22 },
        popup: menu ? rect(menu) : undefined,
      }
      const json = JSON.stringify(msg)
      if (json !== last) {
        last = json
        post('composerLayout', msg)
      }
    }
    const schedule = () => {
      if (!timer) timer = window.setTimeout(report, 0)
    }
    const ro = new ResizeObserver(schedule)
    const mo = new MutationObserver(() => {
      root.current?.querySelectorAll('.composer, .slash-menu').forEach((n) => ro.observe(n))
      schedule()
    })
    if (root.current) {
      ro.observe(root.current)
      mo.observe(root.current, { childList: true, subtree: true })
      root.current.querySelectorAll('.composer, .slash-menu').forEach((n) => ro.observe(n))
    }
    window.addEventListener('resize', schedule)
    schedule()
    return () => {
      ro.disconnect()
      mo.disconnect()
      window.removeEventListener('resize', schedule)
      if (timer) clearTimeout(timer)
    }
  }, [session?.id ?? null])

  if (!state || !session) return <div ref={root} class="overlay-root" />
  return (
    <div ref={root} class="overlay-root">
      <Composer state={state} session={session} />
    </div>
  )
}
