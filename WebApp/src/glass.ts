// Native surfaces under WKWebView (WebShellView.swift → GlassLayerView,
// TitlebarGlass.swift → TabCapsuleLayer).
// Sidebar uses flat window chrome; floating controls keep NSGlassEffectView.
// The page keeps both transparent and reports their exact, edge-to-edge rects.
// Rects go out only when they change, coalesced to one per frame; a short
// burst of frames after each trigger follows CSS transitions.
// Tab strips are reported resize-invariant (x and width as base + share *
// window width, see TabCapsule in Swift), so live window resize sends nothing;
// native moves and stretches them.
import { post } from './bridge'
import { prefs } from './prefs'

type GlassRect = Record<string, number | string>

/**
 * Columns split the free width in fixed proportions, so a strip's x and its
 * width both move by a fixed share per px of window width (f, fw). The active
 * tab goes out as an index of equal-width tabs while they fit (ai/n), so it
 * also follows resize natively; as pixels (ax/aw) once the strip scrolls.
 */
function tabCapsule(el: HTMLElement, b: DOMRect, rect: GlassRect) {
  const column = el.closest('.column')
  const columns = [...document.querySelectorAll<HTMLElement>('.editors > .column:not([hidden])')]
  let before = 0
  let own = 0
  let total = 0
  let passed = false
  for (const col of columns) {
    const w = col.getBoundingClientRect().width
    if (col === column) { passed = true; own = w }
    if (!passed) before += w
    total += w
  }
  const share = total > 0 ? before / total : 0
  const widthShare = total > 0 ? own / total : 0
  rect.f = Math.round(share * 10000) / 10000
  rect.x = Math.round((b.left - share * window.innerWidth) * 100) / 100
  rect.fw = Math.round(widthShare * 10000) / 10000
  rect.wb = Math.round((b.width - widthShare * window.innerWidth) * 100) / 100
  const strip = el.querySelector<HTMLElement>('.insp-tab-strip')
  const tabs = [...el.querySelectorAll<HTMLElement>('.insp-tab')]
  const at = tabs.findIndex((tab) => tab.classList.contains('active'))
  // A lone tab needs no selection layer.
  if (tabs.length < 2 || at < 0) return
  if (strip && strip.scrollWidth <= strip.clientWidth + 1) {
    rect.ai = at
    rect.n = tabs.length
  } else {
    const a = tabs[at].getBoundingClientRect()
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
      // A strip's pixel width is derived (wb + fw * window width): resize alone must not re-send.
      if (r.k === 'tabs' && key === 'w') continue
      const x = r[key]
      const y = o[key]
      if (typeof x === 'number' && typeof y === 'number') {
        // Shares to 0.002, pixels to 1 px; tab index / count exactly.
        const tolerance = r.k !== 'tabs' || key === 'ai' || key === 'n' ? 0 : key === 'f' || key === 'fw' ? 0.002 : 1
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
