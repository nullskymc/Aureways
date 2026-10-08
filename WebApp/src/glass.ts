// Native surfaces under WKWebView (WebShellView.swift → GlassLayerView,
// TitlebarGlass.swift → TabCapsuleLayer).
// Sidebar uses flat window chrome; floating controls keep NSGlassEffectView.
// The page keeps both transparent and reports their exact, edge-to-edge rects.
// Rects go out only when they change, coalesced to one per frame; a short
// burst of frames after each trigger follows CSS transitions.
// Tab capsules are reported resize-invariant (x = base + share * width, see
// TabCapsule in Swift), so live window resize sends nothing; native moves them.
import { post } from './bridge'
import { prefs } from './prefs'

type GlassRect = Record<string, number | string>

/** Columns split the free width in fixed proportions: a strip's x moves by `share` per px of window width. */
function tabCapsule(el: HTMLElement, b: DOMRect, rect: GlassRect) {
  const column = el.closest('.column')
  const columns = [...document.querySelectorAll<HTMLElement>('.editors > .column:not([hidden])')]
  let before = 0
  let total = 0
  let passed = false
  for (const col of columns) {
    const w = col.getBoundingClientRect().width
    if (col === column) passed = true
    if (!passed) before += w
    total += w
  }
  const share = total > 0 ? before / total : 0
  rect.f = Math.round(share * 10000) / 10000
  rect.x = Math.round((b.left - share * window.innerWidth) * 100) / 100
  // A lone tab needs no selection layer.
  const active = el.querySelectorAll('.insp-tab').length > 1 ? el.querySelector<HTMLElement>('.insp-tab.active') : null
  if (active) {
    const a = active.getBoundingClientRect()
    rect.ax = Math.round((a.left - b.left) * 2) / 2
    rect.aw = Math.round(a.width * 2) / 2
  }
}

/** Equal within tolerance: sub-pixel reflow during resize must not re-send tab capsules. */
function same(a: GlassRect[], b: GlassRect[]) {
  if (a.length !== b.length) return false
  return a.every((r, i) => {
    const o = b[i]
    const keys = new Set([...Object.keys(r), ...Object.keys(o)])
    for (const key of keys) {
      const x = r[key]
      const y = o[key]
      if (typeof x === 'number' && typeof y === 'number') {
        const tolerance = r.k === 'tabs' ? (key === 'f' ? 0.002 : 1) : 0
        if (Math.abs(x - y) > tolerance) return false
      } else if (x !== y) return false
    }
    return true
  })
}

let last: GlassRect[] | null = null
let lastSidebar: boolean | null = null
let frames = 0
let scheduled = false

function measure() {
  const rects: GlassRect[] = []
  // `slot`: where the native composer overlay goes (no glass of its own here).
  document.querySelectorAll<HTMLElement>('[data-glass]').forEach((el) => {
    const kind = el.dataset.glass!
    const b = el.getBoundingClientRect()
    if (b.width < 1 || b.height < 1) return
    const radius = kind === 'sidebar' ? 0 : kind === 'control' || kind === 'tabs' ? b.height / 2 : parseFloat(getComputedStyle(el).borderTopLeftRadius) || 12
    const rect: GlassRect = { k: kind, x: Math.round(b.left), y: Math.round(b.top), w: Math.round(b.width), h: Math.round(b.height), r: radius }
    if (kind === 'tabs') tabCapsule(el, b, rect)
    if (kind === 'slot' && el.parentElement) {
      // Anchor for native layout: the dock's content box insets and the
      // column's max width, so the overlay can follow live resize itself.
      const p = el.parentElement
      const pb = p.getBoundingClientRect()
      const cs = getComputedStyle(p)
      rect.al = Math.round(pb.left + parseFloat(cs.paddingLeft))
      rect.ar = Math.round(window.innerWidth - pb.right + parseFloat(cs.paddingRight))
      rect.mw = parseFloat(getComputedStyle(el).maxWidth) || Math.round(b.width)
    }
    rects.push(rect)
  })
  const sidebar = prefs.sidebarOpen.peek()
  if (!last || sidebar !== lastSidebar || !same(rects, last)) {
    last = rects
    lastSidebar = sidebar
    post('glass', { rects, sidebar })
  }
}

function tick() {
  measure()
  if (--frames > 0) requestAnimationFrame(tick)
  else scheduled = false
}

export function scheduleGlass(burst = 12) {
  frames = Math.max(frames, burst)
  if (scheduled) return
  scheduled = true
  requestAnimationFrame(tick)
}

let installed = false
export function installGlass() {
  if (installed) return
  installed = true
  document.documentElement.classList.add('glass')
  const ro = new ResizeObserver(() => scheduleGlass())
  const watch = () => document.querySelectorAll('[data-glass], .main, .sidebar, .dock').forEach((el) => ro.observe(el))
  new MutationObserver(() => {
    watch()
    scheduleGlass()
  }).observe(document.getElementById('app')!, { childList: true, subtree: true, attributes: true, attributeFilter: ['data-glass', 'class'] })
  window.addEventListener('resize', () => scheduleGlass())
  // Scrolling tabs moves the active tab's platter; nothing else scrolls here.
  document.addEventListener('scroll', (event) => {
    if (event.target instanceof Element && event.target.closest('[data-glass="tabs"]')) scheduleGlass(2)
  }, true)
  watch()
  scheduleGlass()
}
