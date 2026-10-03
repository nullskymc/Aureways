// Variable-height windowed list, bottom-anchored. Only rows near the viewport
// are mounted; heights are measured with one ResizeObserver and cached by row
// id (ids are globally unique, so the cache survives session switches).
// While pinned to the bottom, growth keeps the view pinned; otherwise height
// changes above the viewport are compensated so the reading position holds.
import type { ComponentChildren } from 'preact'
import { useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState } from 'preact/hooks'

const heightCache = new Map<string, number>()
const OVERSCAN = 900
const PIN_SLOP = 32

/** Scroll so the tail, including the bottom inset, sits at the viewport bottom. */
function pinToEnd(el: HTMLElement) {
  const target = Math.max(0, el.scrollHeight - el.clientHeight)
  if (Math.abs(el.scrollTop - target) > 1) el.scrollTop = target
}

export interface VirtualListHandle {
  scrollToIndex(i: number, align?: 'start' | 'center'): void
  scrollToBottom(): void
  isAtBottom(): boolean
}

interface Props<T> {
  rows: T[]
  rowKey(row: T): string
  estimate(row: T): number
  render(row: T, index: number): ComponentChildren
  padTop: number
  padBottom: number
  handle?: { current: VirtualListHandle | null }
  onPinnedChange?(pinned: boolean): void
  class?: string
}

function lowerBound(tops: Float64Array, n: number, y: number) {
  let lo = 0
  let hi = n
  while (lo < hi) {
    const mid = (lo + hi) >> 1
    if (tops[mid + 1] <= y) lo = mid + 1
    else hi = mid
  }
  return lo
}

export function VirtualList<T>(props: Props<T>) {
  const { rows, rowKey, estimate, padTop, padBottom } = props
  const scroller = useRef<HTMLDivElement>(null)
  const pinned = useRef(true)
  /** Set by a real pointer / wheel / key gesture. Scroll events alone are not
   * one: measuring a row grows scrollHeight and would unpin, leaving the tail
   * under the composer. */
  const gesture = useRef(false)
  const [measureVersion, force] = useReducer((x: number) => x + 1, 0)
  const [view, setView] = useState({ top: 0, height: 800 })
  const elements = useRef(new Map<Element, string>())

  const layout = useMemo(() => {
    const n = rows.length
    const tops = new Float64Array(n + 1)
    tops[0] = padTop
    for (let i = 0; i < n; i++) {
      const key = rowKey(rows[i])
      tops[i + 1] = tops[i] + (heightCache.get(key) ?? estimate(rows[i]))
    }
    return { n, tops, total: tops[n] + padBottom }
    // measureVersion invalidates when cached heights change
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows, padTop, padBottom, measureVersion])

  const layoutRef = useRef(layout)
  layoutRef.current = layout

  const ro = useMemo(
    () =>
      new ResizeObserver((entries) => {
        const el = scroller.current
        let changed = false
        let above = 0
        const { tops, n } = layoutRef.current
        const scrollTop = el?.scrollTop ?? 0
        for (const entry of entries) {
          const key = elements.current.get(entry.target)
          if (!key) continue
          const h = Math.round(entry.borderBoxSize?.[0]?.blockSize ?? (entry.target as HTMLElement).offsetHeight)
          if (h === 0) continue
          const old = heightCache.get(key)
          if (old === h) continue
          heightCache.set(key, h)
          changed = true
          const index = Number((entry.target as HTMLElement).dataset.index)
          if (!Number.isNaN(index) && index < n && tops[index + 1] <= scrollTop + 1) {
            above += h - (old ?? h)
          }
        }
        if (!changed) return
        if (el && !pinned.current && above !== 0) el.scrollTop = scrollTop + above
        force(0)
      }),
    [],
  )
  useEffect(() => () => ro.disconnect(), [ro])

  // Viewport tracking. Only a user gesture may leave the bottom. Row
  // measurement grows the scroll height without one, and that used to unpin
  // while the tail was still under the composer.
  useEffect(() => {
    const el = scroller.current!
    let raf = 0
    let restoring = false
    const arm = () => {
      gesture.current = true
    }
    const setPinned = (next: boolean) => {
      if (next === pinned.current) return
      pinned.current = next
      props.onPinnedChange?.(next)
    }
    const onScroll = () => {
      const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < PIN_SLOP
      if (gesture.current) {
        gesture.current = false
        setPinned(atBottom)
      } else if (atBottom) {
        setPinned(true)
      } else if (pinned.current && !restoring) {
        restoring = true
        pinToEnd(el)
        restoring = false
      }
      if (!raf)
        raf = requestAnimationFrame(() => {
          raf = 0
          setView({ top: el.scrollTop, height: el.clientHeight })
        })
    }
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null
      if (target?.closest('input, textarea, select, [contenteditable]')) return
      if (e.key === 'PageUp' || e.key === 'PageDown' || e.key === 'Home' || e.key === 'End' || e.key === 'ArrowUp' || e.key === 'ArrowDown' || e.key === ' ') arm()
    }
    const resize = new ResizeObserver(() => {
      setView({ top: el.scrollTop, height: el.clientHeight })
      if (pinned.current) pinToEnd(el)
    })
    resize.observe(el)
    el.addEventListener('wheel', arm, { passive: true, capture: true })
    el.addEventListener('pointerdown', arm, { capture: true })
    el.addEventListener('touchstart', arm, { passive: true, capture: true })
    window.addEventListener('keydown', onKey)
    el.addEventListener('scroll', onScroll, { passive: true })
    return () => {
      el.removeEventListener('wheel', arm, { capture: true })
      el.removeEventListener('pointerdown', arm, { capture: true })
      el.removeEventListener('touchstart', arm, { capture: true })
      window.removeEventListener('keydown', onKey)
      el.removeEventListener('scroll', onScroll)
      resize.disconnect()
      cancelAnimationFrame(raf)
    }
  }, [])

  // Keep pinned to the bottom after every render while pinned, including the
  // bottom inset under the composer (padBottom is part of scrollHeight).
  useLayoutEffect(() => {
    const el = scroller.current
    if (el && pinned.current) pinToEnd(el)
  })

  if (props.handle) {
    props.handle.current = {
      scrollToIndex(i, align = 'center') {
        const el = scroller.current
        if (!el) return
        const { tops } = layoutRef.current
        const top = tops[Math.max(0, Math.min(i, rows.length - 1))]
        const y = align === 'center' ? top - el.clientHeight / 3 : top - 12
        pinned.current = false
        props.onPinnedChange?.(false)
        el.scrollTop = Math.max(0, y)
      },
      scrollToBottom() {
        const el = scroller.current
        if (!el) return
        pinned.current = true
        props.onPinnedChange?.(true)
        pinToEnd(el)
      },
      isAtBottom: () => pinned.current,
    }
  }

  const { tops, n, total } = layout
  const effectiveTop = pinned.current ? Math.max(0, total - view.height) : view.top
  const start = Math.max(0, lowerBound(tops, n, effectiveTop - OVERSCAN))
  const end = Math.min(n, lowerBound(tops, n, effectiveTop + view.height + OVERSCAN) + 1)

  const mounted: ComponentChildren[] = []
  for (let i = start; i < end; i++) {
    const row = rows[i]
    const key = rowKey(row)
    mounted.push(
      <Row key={key} rowKey={key} index={i} top={tops[i]} ro={ro} elements={elements.current}>
        {props.render(row, i)}
      </Row>,
    )
  }

  return (
    <div ref={scroller} class={'vscroll ' + (props.class ?? '')}>
      <div class="vcontent" style={{ height: tops[n] }}>
        {mounted}
      </div>
      {/* In-flow, so the composer clearance is part of the scroll range. */}
      {padBottom > 0 && <div class="vpad" style={{ height: padBottom }} />}
    </div>
  )
}

function Row(props: {
  rowKey: string
  index: number
  top: number
  ro: ResizeObserver
  elements: Map<Element, string>
  children: ComponentChildren
}) {
  const ref = useRef<HTMLDivElement>(null)
  useLayoutEffect(() => {
    const el = ref.current!
    props.elements.set(el, props.rowKey)
    props.ro.observe(el)
    return () => {
      props.ro.unobserve(el)
      props.elements.delete(el)
    }
  }, [props.rowKey])
  return (
    <div ref={ref} class="vrow" data-index={props.index} style={{ transform: `translateY(${props.top}px)` }}>
      {props.children}
    </div>
  )
}
