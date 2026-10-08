// Streaming Markdown renderer (moved from the per-message WebTranscript
// prototype). marked lexes top-level blocks; finished blocks are frozen while
// streaming so only the tail re-lexes; DOMPurify on every block; Shiki only
// for finished code blocks, lazily.
import DOMPurify from 'dompurify'
import { Marked, Renderer, type Token, type Tokens } from 'marked'
import { canonicalLang, highlight } from './highlight'
import { patchStreamingTail } from './streaming'

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
      const html = Renderer.prototype.table.call(this, token)
      return `<div class="table-wrap">${html}</div>`
    },
  },
})

const purify = (html: string) =>
  DOMPurify.sanitize(html, { ADD_ATTR: ['target'], FORBID_TAGS: ['style', 'form', 'input'] })

// Documents keep GFM checkboxes. They are forced disabled so a file cannot
// embed a working form control. Chat blocks still strip <input> entirely.
const purifyDocument = (html: string) =>
  DOMPurify.sanitize(html, {
    ADD_TAGS: ['input'],
    ADD_ATTR: ['target', 'type', 'checked', 'disabled'],
    FORBID_TAGS: ['style', 'form'],
  })

function lockInputs(root: HTMLElement) {
  root.querySelectorAll('input').forEach((el) => {
    if ((el.getAttribute('type') || '').toLowerCase() !== 'checkbox') {
      el.remove()
      return
    }
    el.disabled = true
    el.removeAttribute('formaction')
    el.removeAttribute('form')
    el.removeAttribute('name')
  })
}

interface Block {
  raw: string
  el: HTMLElement | null
  highlighted: boolean
}

const dirty = new Set<MarkdownView>()
let frame = 0
function flush() {
  frame = 0
  const views = [...dirty]
  dirty.clear()
  for (const v of views) v.render()
}

export class MarkdownView {
  private raw = ''
  private streaming = false
  private blocks: Block[] = []
  private stableCount = 0
  private stableLen = 0
  private disposed = false

  constructor(
    readonly root: HTMLElement,
    private readonly mode: 'stream' | 'document' = 'stream',
  ) {
    root.classList.add('md')
  }

  /** Synchronous first paint (so virtualized rows measure real heights). */
  set(text: string, streaming: boolean, sync = false) {
    if (!text.startsWith(this.raw) || this.streaming !== streaming) this.resetIncremental()
    if (text === this.raw && streaming === this.streaming && this.blocks.length) return
    this.raw = text
    this.streaming = streaming
    if (sync) this.render()
    else {
      dirty.add(this)
      if (!frame) frame = requestAnimationFrame(flush)
    }
  }

  dispose() {
    this.disposed = true
    dirty.delete(this)
  }

  private resetIncremental() {
    this.stableCount = 0
    this.stableLen = 0
  }

  render() {
    if (this.disposed) return
    if (!this.streaming) this.resetIncremental()
    const src = this.streaming ? patchStreamingTail(this.raw) : this.raw
    const tail = src.slice(this.stableLen)
    const tokens = marked.lexer(tail)
    const links = (tokens as unknown as { links: Tokens.Generic['links'] }).links

    const next: Block[] = this.blocks.slice(0, this.stableCount)
    tokens.forEach((token, i) => {
      const prev = this.blocks[this.stableCount + i]
      if (prev && prev.raw === token.raw) next.push(prev)
      else next.push({ raw: token.raw, el: renderToken(token, links, this.mode), highlighted: false })
    })

    const keep = new Set(next.map((b) => b.el).filter(Boolean))
    for (const b of this.blocks) if (b.el && !keep.has(b.el)) b.el.remove()
    let cursor: ChildNode | null = this.root.firstChild
    for (const b of next) {
      if (!b.el) continue
      if (b.el !== cursor) this.root.insertBefore(b.el, cursor)
      else cursor = cursor.nextSibling
    }
    this.blocks = next

    if (this.streaming) {
      let lastReal = next.length - 1
      while (lastReal > 0 && !next[lastReal].el) lastReal--
      for (let i = this.stableCount; i < lastReal; i++) this.stableLen += next[i].raw.length
      this.stableCount = Math.max(this.stableCount, lastReal)
    }

    const finishedUpTo = this.streaming ? this.stableCount : next.length
    for (let i = 0; i < finishedUpTo; i++) {
      const b = next[i]
      if (b.el && !b.highlighted) {
        b.highlighted = true
        b.el.querySelectorAll<HTMLElement>('.code-block').forEach(highlightBlock)
      }
    }
  }
}

function renderToken(token: Token, links: Tokens.Generic['links'], mode: 'stream' | 'document'): HTMLElement | null {
  if (token.type === 'space') return null
  const list = [token] as Token[] & { links: unknown }
  list.links = links ?? {}
  const div = document.createElement('div')
  div.className = 'blk'
  const html = marked.parser(list as never)
  div.innerHTML = mode === 'document' ? purifyDocument(html) : purify(html)
  if (mode === 'document') lockInputs(div)
  return div
}

function highlightBlock(block: HTMLElement) {
  const lang = block.dataset.lang ?? ''
  if (!canonicalLang(lang)) return
  const code = block.querySelector('code')
  if (!code) return
  highlight(code.textContent ?? '', lang)
    .then((inner) => {
      if (inner !== null && block.isConnected) {
        code.innerHTML = purify(inner)
        code.classList.add('shiki')
      }
    })
    .catch((e) => console.warn('highlight failed', e))
}

/** Plain code block with lazy highlighting, for tool output / diffs. */
export function highlightInto(code: HTMLElement, text: string, lang: string) {
  code.textContent = text
  if (!canonicalLang(lang)) return
  highlight(text, lang).then((inner) => {
    if (inner !== null && code.isConnected) {
      code.innerHTML = purify(inner)
      code.classList.add('shiki')
    }
  })
}
