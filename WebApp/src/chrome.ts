// NSWindow owns titlebar geometry. In particular, fullSizeContentView does not
// give WKWebView a safe-area inset; every header must use the native height.
import { post } from './bridge'
import type { AppState, Rect } from './types'

export function headerHeight(state: AppState | null): number {
  const height = state?.chrome.titlebarHeight
  return height && Number.isFinite(height) && height > 0 ? height : 46
}

const HEADERS = '.main-head, .sidebar-head'
const CONTROLS = 'button, input, textarea, a, select, [data-no-drag]'
const RESIZERS = '.sidebar-resizer, .col-resizer'

/** Clip to the visible header, not the offscreen bounds of scrolling tabs. */
export function titlebarRegions(root: HTMLElement, height: number): Rect[] {
  const viewport = root.getBoundingClientRect()
  const rects: Rect[] = []
  const add = (r: DOMRect, left: number, right: number, top = 0, bottom = height, padding = 0) => {
    const x = Math.max(0, left, r.left - padding)
    const y = Math.max(0, top, r.top - padding)
    const endX = Math.min(viewport.right, right, r.right + padding)
    const endY = Math.min(height, bottom, r.bottom + padding)
    if (r.width > 0 && r.height > 0 && endX > x && endY > y) rects.push({ x, y, w: endX - x, h: endY - y })
  }
  root.querySelectorAll<HTMLElement>(HEADERS).forEach((header) => {
    const h = header.getBoundingClientRect()
    header.querySelectorAll<HTMLElement>(CONTROLS).forEach((control) => {
      // A no-drag parent already covers its descendants, including hidden tabs.
      if (control.parentElement?.closest('[data-no-drag]')) return
      add(control.getBoundingClientRect(), h.left, h.right, h.top, h.bottom, 2)
    })
  })
  root.querySelectorAll<HTMLElement>(RESIZERS).forEach((el) => add(el.getBoundingClientRect(), 0, viewport.right))
  return rects
}

/** Tab signals update below App, so App's render effect alone is insufficient. */
export function observeTitlebar(root: HTMLElement, height: number) {
  let frame = 0
  let last = ''
  const report = () => {
    frame = 0
    const payload = { rects: titlebarRegions(root, height), height }
    const json = JSON.stringify(payload)
    if (json !== last) { last = json; post('dragRegions', payload) }
  }
  const schedule = () => { if (!frame) frame = requestAnimationFrame(report) }
  const watched = new Set<Element>()
  const resize = new ResizeObserver(schedule)
  const watch = () => {
    const next = new Set(root.querySelectorAll(`${HEADERS}, ${RESIZERS}`))
    for (const el of watched) if (!next.has(el)) { resize.unobserve(el); watched.delete(el) }
    for (const el of next) if (!watched.has(el)) { resize.observe(el); watched.add(el) }
  }
  const mutations = new MutationObserver((records) => {
    watch()
    if (records.some((record) => record.type === 'childList' ||
      (record.target instanceof Element && (record.target.closest(HEADERS) || record.target.querySelector(HEADERS))))) schedule()
  })
  mutations.observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class', 'hidden'] })
  // Scroll does not bubble. Capture tab-strip scrolling, not every transcript tick.
  const onScroll = (event: Event) => { if (event.target instanceof Element && event.target.closest(HEADERS)) schedule() }
  root.addEventListener('scroll', onScroll, true)
  window.addEventListener('resize', schedule)
  watch()
  schedule()
  return () => {
    cancelAnimationFrame(frame)
    mutations.disconnect()
    resize.disconnect()
    root.removeEventListener('scroll', onScroll, true)
    window.removeEventListener('resize', schedule)
  }
}
