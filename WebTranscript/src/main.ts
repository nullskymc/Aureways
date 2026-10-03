import './style.css'
import DOMPurify from 'dompurify'
import { Marked, Renderer, type Token, type Tokens } from 'marked'
import { post } from './bridge'
import { canonicalLang, highlight } from './highlight'
import { patchStreamingTail } from './streaming'

// ---------------------------------------------------------------------------
// Markdown -> HTML (marked lexer per top-level block, DOMPurify on output)
// ---------------------------------------------------------------------------

const escapeHTML = (s: string) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

const marked = new Marked({ gfm: true, breaks: false, async: false })
marked.use({
  renderer: {
    code({ text, lang }: Tokens.Code) {
      const label = (lang ?? '').trim().split(/\s+/)[0]
      return (
        `<div class="code-block" data-lang="${escapeHTML(label)}">` +
        `<div class="code-head"><span class="code-lang">${escapeHTML(label || 'text')}</span>` +
        `<button class="code-copy" type="button" tabindex="-1">Copy</button></div>` +
        `<pre><code>${escapeHTML(text.replace(/\n$/, ''))}</code></pre></div>`
      )
    },
    table(token: Tokens.Table) {
      // Tables scroll inside their own box; width never propagates to the host.
      const html = Renderer.prototype.table.call(this, token)
      return `<div class="table-wrap">${html}</div>`
    },
  },
})

const purify = (html: string) =>
  DOMPurify.sanitize(html, { ADD_ATTR: ['target'], FORBID_TAGS: ['style', 'form', 'input'] })

// ---------------------------------------------------------------------------
// Message model
// ---------------------------------------------------------------------------

interface Block {
  raw: string
  el: HTMLElement | null // null for whitespace-only tokens
  highlighted: boolean
}

interface Message {
  id: string
  raw: string
  streaming: boolean
  root: HTMLElement
  blocks: Block[]
  /** Blocks [0, stableCount) are frozen while streaming; only the tail re-lexes. */
  stableCount: number
  stableLen: number
}

const root = document.getElementById('root')!
const messages = new Map<string, Message>()
const dirty = new Set<string>()
let frame = 0

function ensureMessage(id: string): Message {
  let m = messages.get(id)
  if (!m) {
    const el = document.createElement('article')
    el.className = 'message'
    el.dataset.id = id
    root.appendChild(el)
    m = { id, raw: '', streaming: false, root: el, blocks: [], stableCount: 0, stableLen: 0 }
    messages.set(id, m)
  }
  return m
}

function resetIncremental(m: Message) {
  m.stableCount = 0
  m.stableLen = 0
}

function schedule(id: string) {
  dirty.add(id)
  if (!frame) frame = requestAnimationFrame(flush)
}

function flush() {
  frame = 0
  for (const id of dirty) {
    const m = messages.get(id)
    if (m) render(m)
  }
  dirty.clear()
  reportHeight()
}

function renderToken(token: Token, links: Tokens.Generic['links']): HTMLElement | null {
  if (token.type === 'space') return null
  const list = [token] as Token[] & { links: unknown }
  list.links = links ?? {}
  const div = document.createElement('div')
  div.className = 'blk'
  div.innerHTML = purify(marked.parser(list as never))
  return div
}

function render(m: Message) {
  if (!m.streaming) resetIncremental(m) // full pass on finish: memo-by-raw keeps it cheap
  const src = m.streaming ? patchStreamingTail(m.raw) : m.raw
  const tail = src.slice(m.stableLen)
  const tokens = marked.lexer(tail)
  const links = (tokens as unknown as { links: Tokens.Generic['links'] }).links

  const next: Block[] = m.blocks.slice(0, m.stableCount)
  tokens.forEach((token, i) => {
    const index = m.stableCount + i
    const prev = m.blocks[index]
    if (prev && prev.raw === token.raw) {
      next.push(prev)
      return
    }
    next.push({ raw: token.raw, el: renderToken(token, links), highlighted: false })
  })

  // Reconcile DOM in order without touching unchanged nodes.
  const keep = new Set(next.map((b) => b.el).filter(Boolean))
  for (const b of m.blocks) if (b.el && !keep.has(b.el)) b.el.remove()
  let cursor: ChildNode | null = m.root.firstChild
  for (const b of next) {
    if (!b.el) continue
    if (b.el !== cursor) m.root.insertBefore(b.el, cursor)
    else cursor = cursor.nextSibling
  }
  m.blocks = next

  // Freeze everything but the last real block while streaming.
  if (m.streaming) {
    let lastReal = next.length - 1
    while (lastReal > 0 && !next[lastReal].el) lastReal--
    for (let i = m.stableCount; i < lastReal; i++) m.stableLen += next[i].raw.length
    m.stableCount = Math.max(m.stableCount, lastReal)
  }

  // Highlight only finished code blocks; the streaming tail stays plain mono.
  const finishedUpTo = m.streaming ? m.stableCount : next.length
  for (let i = 0; i < finishedUpTo; i++) {
    const b = next[i]
    if (b.el && !b.highlighted) {
      b.highlighted = true
      b.el.querySelectorAll<HTMLElement>('.code-block').forEach(highlightBlock)
    }
  }
}

function highlightBlock(block: HTMLElement) {
  const lang = block.dataset.lang ?? ''
  if (!canonicalLang(lang)) return
  const code = block.querySelector('code')
  if (!code) return
  const text = code.textContent ?? ''
  highlight(text, lang)
    .then((inner) => {
      if (inner !== null && block.isConnected) {
        code.innerHTML = purify(inner)
        code.classList.add('shiki')
      }
    })
    .catch((e) => console.warn('highlight failed', e))
}

// ---------------------------------------------------------------------------
// Height reporting (per-message host sizes its frame from this)
// ---------------------------------------------------------------------------

let lastHeight = -1
function reportHeight() {
  const h = Math.ceil(root.getBoundingClientRect().height)
  if (h !== lastHeight) {
    lastHeight = h
    post({ type: 'height', height: h })
  }
}
new ResizeObserver(() => reportHeight()).observe(root)

// ---------------------------------------------------------------------------
// Interaction: links go native, copy via native pasteboard
// ---------------------------------------------------------------------------

document.addEventListener('click', (e) => {
  const target = e.target as HTMLElement
  const copy = target.closest<HTMLButtonElement>('.code-copy')
  if (copy) {
    e.preventDefault()
    const code = copy.closest('.code-block')?.querySelector('code')?.textContent ?? ''
    post({ type: 'copy', text: code })
    copy.textContent = 'Copied'
    copy.classList.add('done')
    setTimeout(() => {
      copy.textContent = 'Copy'
      copy.classList.remove('done')
    }, 1500)
    return
  }
  const a = target.closest<HTMLAnchorElement>('a[href]')
  if (a) {
    e.preventDefault()
    post({ type: 'link', href: a.getAttribute('href') ?? '' })
  }
})

// ---------------------------------------------------------------------------
// Swift -> JS API (window.aureways.*), all payloads JSON-serialisable
// ---------------------------------------------------------------------------

interface MessageInput {
  id: string
  text: string
  streaming?: boolean
}

const api = {
  /** Replace the whole document with these messages, in order. */
  setMessages(list: MessageInput[]) {
    const ids = new Set(list.map((x) => x.id))
    for (const [id, m] of messages) {
      if (!ids.has(id)) {
        m.root.remove()
        messages.delete(id)
      }
    }
    for (const input of list) {
      const m = ensureMessage(input.id)
      root.appendChild(m.root) // enforce order
      const streaming = !!input.streaming
      if (!input.text.startsWith(m.raw) || m.streaming !== streaming) resetIncremental(m)
      if (m.raw !== input.text || m.streaming !== streaming) {
        m.raw = input.text
        m.streaming = streaming
        schedule(m.id)
      }
    }
    if (!frame) reportHeight()
  },
  appendDelta(id: string, delta: string) {
    const m = ensureMessage(id)
    m.streaming = true
    m.raw += delta
    schedule(id)
  },
  finishMessage(id: string, fullText?: string) {
    const m = ensureMessage(id)
    if (typeof fullText === 'string') m.raw = fullText
    m.streaming = false
    schedule(id)
  },
  setFontScale(scale: number) {
    document.documentElement.style.setProperty('--scale', String(scale))
  },
}

declare global {
  interface Window {
    aureways: typeof api
  }
}
window.aureways = api
post({ type: 'ready' })

// vite dev convenience: `?demo` streams a sample message.
if (location.search.includes('demo')) {
  const sample =
    '## Demo\n\nSome **bold** text, `inline code`, and a [link](https://example.com).\n\n' +
    '| col a | col b | a very long column header to force horizontal scrolling |\n|---|---|---|\n| 1 | 2 | 3 |\n\n' +
    '```swift\nstruct Foo: View {\n    var body: some View { Text("hi") }\n}\n```\n\n- one\n- two\n  - nested\n\n> quote\n'
  let i = 0
  const tick = () => {
    if (i >= sample.length) return api.finishMessage('demo')
    api.appendDelta('demo', sample.slice(i, i + 7))
    i += 7
    setTimeout(tick, 16)
  }
  tick()
}
