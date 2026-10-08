import { useSignal } from '@preact/signals'
import { useEffect, useLayoutEffect, useRef } from 'preact/hooks'
import { post } from '../bridge'
import { t } from '../i18n'
import { MarkdownView } from '../markdown/render'
import { hydrateImages } from './assets'
import { classifyLink, hashCandidates, uniqueId } from './paths'
import { openDocuments, pendingHash } from './state'

const scrollMemory = new Map<string, number>()

/** Full-width Markdown document for a file tab: outline, local images, links. */
export function MarkdownPane({ text, path }: { text: string; path: string }) {
  const outline = useSignal<{ id: string; level: number; text: string }[]>([])
  const current = useSignal('')
  const scrollRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const root = scrollRef.current
    if (!root) return
    const save = () => scrollMemory.set(path, root.scrollTop)
    root.addEventListener('scroll', save, { passive: true })
    return () => root.removeEventListener('scroll', save)
  }, [path])

  const onClick = (e: MouseEvent) => {
    const a = (e.target as HTMLElement).closest('a[href]')
    if (!a) return
    const action = classifyLink(path, a.getAttribute('href') ?? '')
    if (!action) return
    e.preventDefault()
    e.stopPropagation()
    if (action.type === 'anchor') scrollToFragment(scrollRef.current, action.id)
    else if (action.type === 'markdown') openDocuments([action.path], action.hash)
    else if (action.type === 'file') post('openLink', { href: action.path })
  }

  return (
    <div class="reader-body">
      <div class="reader-scroll" ref={scrollRef} onClick={onClick}>
        <Document text={text} path={path} onOutline={(heads) => (outline.value = heads)} onCurrent={(id) => (current.value = id)} />
      </div>
      {outline.value.length > 1 && (
        <nav class="reader-outline" aria-label={t('readerOutline')}>
          {outline.value.map((h) => (
            <a
              key={h.id}
              href={'#' + h.id}
              data-level={h.level}
              class={current.value === h.id ? 'on' : ''}
              onClick={(e) => {
                e.preventDefault()
                e.stopPropagation()
                scrollToFragment(scrollRef.current, h.id)
                current.value = h.id
              }}
            >
              {h.text}
            </a>
          ))}
        </nav>
      )}
    </div>
  )
}

function Document({ text, path, onOutline, onCurrent }: { text: string; path: string; onOutline(heads: { id: string; level: number; text: string }[]): void; onCurrent(id: string): void }) {
  const ref = useRef<HTMLDivElement>(null)
  const view = useRef<MarkdownView | null>(null)
  const placed = useRef(false)
  useLayoutEffect(() => {
    const root = ref.current!
    view.current = new MarkdownView(root, 'document')
    return () => view.current?.dispose()
  }, [])
  useLayoutEffect(() => {
    const root = ref.current!
    view.current?.set(text, false, true)
    const heads = stampHeadings(root)
    const token = { cancelled: false }
    queueMicrotask(() => {
      if (!token.cancelled) onOutline(heads)
    })
    void hydrateImages(root, path, token)
    const scroller = root.closest('.reader-scroll')
    if (!scroller) return () => { token.cancelled = true }
    const obs = new IntersectionObserver(
      (entries) => {
        const hit = entries.filter((e) => e.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0]
        if (hit?.target.id) onCurrent(hit.target.id)
      },
      { root: scroller, rootMargin: '-8% 0px -75% 0px' },
    )
    root.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach((h) => obs.observe(h))
    return () => {
      token.cancelled = true
      obs.disconnect()
    }
  }, [text, path])
  const hash = pendingHash.value
  useLayoutEffect(() => {
    const scroller = ref.current?.closest('.reader-scroll') as HTMLElement | null
    if (!scroller) return
    if (hash) {
      placed.current = true
      pendingHash.value = ''
      scrollToFragment(scroller, hash)
      return
    }
    if (placed.current) {
      placed.current = false
      return
    }
    scroller.scrollTop = scrollMemory.get(path) ?? 0
  }, [text, path, hash])
  return (
    <article class="reader-column">
      <div class="md-reader" ref={ref} />
    </article>
  )
}

function stampHeadings(root: HTMLElement) {
  const used = new Map<string, number>()
  const heads: { id: string; level: number; text: string }[] = []
  root.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach((h) => {
    const text = (h.textContent ?? '').trim()
    if (!text) return
    const id = uniqueId(text, used)
    h.id = id
    heads.push({ id, level: Number(h.tagName[1]), text })
  })
  return heads
}

function scrollToFragment(root: HTMLElement | null, hash: string): boolean {
  if (!root) return false
  for (const id of hashCandidates(hash)) {
    const el = root.querySelector<HTMLElement>('#' + CSS.escape(id))
    if (el) {
      // scrollIntoView aligns to the window, so a nested overflow box stops short of the heading.
      const top = el.getBoundingClientRect().top - root.getBoundingClientRect().top + root.scrollTop
      root.scrollTop = Math.max(0, top - 12)
      return true
    }
  }
  return false
}
