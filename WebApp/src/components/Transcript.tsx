import { useSignal } from '@preact/signals'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef } from 'preact/hooks'
import { t } from '../i18n'
import { transcript, uiCommand } from '../store'
import type { Item } from '../types'
import { BlockView, estimateBlock, groupBlocks, type Block } from './Blocks'
import { Icon } from './Icon'
import { VirtualList, type VirtualListHandle } from './VirtualList'

const rowKey = (b: Block) => b.key
const render = (b: Block) => <BlockView block={b} />

/** `jumpBottom`: where the ↓ button sits when the composer is a native
 *  overlay (above its card and any open popup); defaults to above the dock. */
export function Transcript({ streaming, padBottom, padTop = 64, jumpBottom }: { streaming: boolean; padBottom: number; padTop?: number; jumpBottom?: number }) {
  // version bumps after every transcript replace or patch. streaming is a
  // prop, so a turn that ends without a new item still recomputes and drops the pin.
  const version = transcript.version.value
  const sessionId = transcript.sessionId.value
  const laid = useMemo(() => groupBlocks(transcript.items, streaming), [version, streaming])
  const rows = laid.blocks
  const plan = laid.pinned
  const handle = useRef<VirtualListHandle | null>(null)
  const pinRef = useRef<HTMLDivElement>(null)
  const pinH = useSignal(0)
  const pinned = useSignal(true)
  const planKey = plan ? plan.id + plan.entries.map((e) => e.status).join('') : ''
  useLayoutEffect(() => {
    pinH.value = pinRef.current?.offsetHeight ?? 0
  }, [planKey])
  const bottom = padBottom + pinH.value

  return (
    <div class="transcript">
      {sessionId && (
        <VirtualList
          key={sessionId}
          rows={rows}
          rowKey={rowKey}
          estimate={estimateBlock}
          render={render}
          padTop={padTop}
          padBottom={bottom}
          handle={handle}
          onPinnedChange={(p) => (pinned.value = p)}
          class="transcript-scroll"
        />
      )}
      {plan && (
        <div class="plan-pin" ref={pinRef}>
          <BlockView block={{ type: 'plan', key: plan.id, item: plan, live: true }} />
        </div>
      )}
      {!pinned.value && rows.length > 0 && (
        <button class="jump-bottom" onClick={() => handle.current?.scrollToBottom()} title={t('jumpBottom')} style={{ bottom: (jumpBottom ?? padBottom + 8) + pinH.value }}>
          <Icon name="arrowDown" size={14} />
        </button>
      )}
      <FindBar rows={rows} handle={handle} />
    </div>
  )
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
  if (b.type === 'plan') return text(b.item)
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
    } else if (cmd?.name === 'escape' && open.value) {
      // Esc from the composer overlay page, which the composer didn't consume.
      open.value = false
      query.value = ''
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
