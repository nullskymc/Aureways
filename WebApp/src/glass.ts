// Native Liquid Glass under the web view (WebShellView.swift → GlassLayerView).
// Elements marked `data-glass="sidebar|control|composer"` get an
// NSGlassEffectView at the same rect; the page keeps those areas transparent.
// Rects go out only when they change, coalesced to one per frame; a short
// burst of frames after each trigger follows CSS transitions.
import { post } from './bridge'

const INSET: Record<string, number> = { sidebar: 8 }
let last = ''
let frames = 0
let scheduled = false

function measure() {
  const rects: Record<string, number | string>[] = []
  // `slot`: where the native composer overlay goes (no glass of its own here).
  document.querySelectorAll<HTMLElement>('[data-glass]').forEach((el) => {
    const kind = el.dataset.glass!
    const b = el.getBoundingClientRect()
    if (b.width < 1 || b.height < 1) return
    const inset = INSET[kind] ?? 0
    const radius = kind === 'sidebar' ? 16 : kind === 'control' ? b.height / 2 : parseFloat(getComputedStyle(el).borderTopLeftRadius) || 12
    const rect: Record<string, number | string> = { k: kind, x: Math.round(b.left + inset), y: Math.round(b.top + inset), w: Math.round(b.width - inset * 2), h: Math.round(b.height - inset * 2), r: radius }
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
    rects.push(rect as never)
  })
  const json = JSON.stringify(rects)
  if (json !== last) {
    last = json
    post('glass', { rects })
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
  watch()
  scheduleGlass()
}
