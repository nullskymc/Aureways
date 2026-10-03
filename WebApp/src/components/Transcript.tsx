import { useComputed, useSignal } from '@preact/signals'
import { useCallback, useEffect, useRef } from 'preact/hooks'
import { t } from '../i18n'
import { transcript, uiCommand } from '../store'
import type { Item } from '../types'
import { BlockView, estimateBlock, groupBlocks, type Block } from './Blocks'
import { Icon } from './Icon'
import { VirtualList, type VirtualListHandle } from './VirtualList'

const rowKey = (b: Block) => b.key
const render = (b: Block) => <BlockView block={b} />

export function Transcript({ streaming, padBottom }: { streaming: boolean; padBottom: number }) {
  const version = transcript.version.value
  const sessionId = transcript.sessionId.value
  const blocks = useComputed(() => {
    void transcript.version.value
    return groupBlocks(transcript.items, false)
  })
  // Recompute the streaming tail flags without regrouping.
  const rows = withStreaming(blocks.value, streaming)
  const handle = useRef<VirtualListHandle | null>(null)
  const pinned = useSignal(true)
  void version

  return (
    <div class="transcript">
      {sessionId && (
        <VirtualList
          key={sessionId}
          rows={rows}
          rowKey={rowKey}
          estimate={estimateBlock}
          render={render}
          padTop={64}
          padBottom={padBottom}
          handle={handle}
          onPinnedChange={(p) => (pinned.value = p)}
          class="transcript-scroll"
        />
      )}
      {!pinned.value && rows.length > 0 && (
        <button class="jump-bottom" onClick={() => handle.current?.scrollToBottom()} title={t('jumpBottom')} style={{ bottom: padBottom + 8 }}>
          <Icon name="arrowDown" size={14} />
        </button>
      )}
      <FindBar rows={rows} handle={handle} />
    </div>
  )
}

let lastBlocks: Block[] = []
let lastRows: Block[] = []
let lastStreaming = false
function withStreaming(blocks: Block[], streaming: boolean): Block[] {
  if (blocks === lastBlocks && streaming === lastStreaming) return lastRows
  lastBlocks = blocks
  lastStreaming = streaming
  if (!streaming || !blocks.length) return (lastRows = blocks)
  const rows = blocks.slice()
  const last = rows[rows.length - 1]
  if (last.type === 'agent') rows[rows.length - 1] = { ...last, streaming: true }
  if (last.type === 'activity') rows[rows.length - 1] = { ...last, live: true }
  return (lastRows = rows)
}

// ---------------------------------------------------------------------------
// ⌘F: search the whole transcript model (not just mounted rows), jump the
// virtualizer to each hit, and paint hits with the CSS Custom Highlight API.
// ---------------------------------------------------------------------------

function blockText(b: Block): string {
  const text = (it: Item) => {
    switch (it.kind) {
      case 'user':
      case 'agent':
      case 'thought':
      case 'status':
        return it.text
      case 'tool':
        return `${it.title}\n${it.command ?? ''}\n${it.output ?? ''}`
      case 'plan':
        return it.entries.map((e) => e.content).join('\n')
    }
  }
  if (b.type === 'activity') return b.items.map(text).join('\n')
  return text(b.item)
}

declare const Highlight: { new (...ranges: Range[]): unknown }
declare global {
  interface CSS {
    highlights?: Map<string, unknown>
  }
}

function FindBar({ rows, handle }: { rows: Block[]; handle: { current: VirtualListHandle | null } }) {
  const open = useSignal(false)
  const query = useSignal('')
  const current = useSignal(0)
  const input = useRef<HTMLInputElement>(null)

  useEffect(() => {
    const cmd = uiCommand.value
    if (cmd?.name === 'find') {
      open.value = true
      requestAnimationFrame(() => input.current?.select())
    }
  }, [uiCommand.value])

  const q = query.value.trim().toLowerCase()
  const matches = open.value && q ? rows.map((b, i) => (blockText(b).toLowerCase().includes(q) ? i : -1)).filter((i) => i >= 0) : []

  const paint = useCallback(() => {
    const reg = (CSS as unknown as CSS).highlights
    if (!reg) return
    reg.delete('find')
    if (!open.value || !q) return
    const root = document.querySelector('.transcript-scroll')
    if (!root) return
    const ranges: Range[] = []
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
    for (let n = walker.nextNode(); n && ranges.length < 500; n = walker.nextNode()) {
      const s = n.nodeValue!.toLowerCase()
      let at = s.indexOf(q)
      while (at >= 0 && ranges.length < 500) {
        const r = new Range()
        r.setStart(n, at)
        r.setEnd(n, at + q.length)
        ranges.push(r)
        at = s.indexOf(q, at + q.length)
      }
    }
    reg.set('find', new Highlight(...ranges))
  }, [q, open.value])

  useEffect(() => {
    if (!open.value) return paint()
    paint()
    const id = setInterval(paint, 400)
    return () => clearInterval(id)
  }, [paint, open.value])

  const go = (delta: number) => {
    if (!matches.length) return
    current.value = (current.value + delta + matches.length) % matches.length
    handle.current?.scrollToIndex(matches[current.value])
  }

  if (!open.value) return null
  return (
    <div class="findbar" data-no-drag>
      <Icon name="search" size={13} />
      <input
        ref={input}
        value={query.value}
        placeholder={t('find')}
        onInput={(e) => {
          query.value = (e.target as HTMLInputElement).value
          current.value = -1
        }}
        onKeyDown={(e) => {
          if (e.key === 'Enter') go(e.shiftKey ? -1 : 1)
          if (e.key === 'Escape') {
            open.value = false
            query.value = ''
          }
        }}
      />
      <span class="find-count">{q ? (matches.length ? `${Math.max(0, current.value) + 1}/${matches.length}` : t('noResults')) : ''}</span>
      <button class="icon-btn small" onClick={() => go(-1)}>
        <Icon name="chevronDown" size={12} class="flip" />
      </button>
      <button class="icon-btn small" onClick={() => go(1)}>
        <Icon name="chevronDown" size={12} />
      </button>
      <button
        class="icon-btn small"
        onClick={() => {
          open.value = false
          query.value = ''
        }}
      >
        <Icon name="x" size={12} />
      </button>
    </div>
  )
}
