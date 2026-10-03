import { useLayoutEffect, useRef, useState } from 'preact/hooks'
import { post } from '../bridge'
import { duration, t } from '../i18n'
import { MarkdownView } from '../markdown/render'
import { app, now } from '../store'
import { openFile } from '../inspector/state'
import type { Attachment, DiffFile, Item, ToolFields } from '../types'
import { Icon, Spinner } from './Icon'
import { memo, shallowEqual } from './memo'

// ---------------------------------------------------------------------------
// Grouping: consecutive thought / tool / plan items form one activity block.
// ---------------------------------------------------------------------------

type ActivityItem = Extract<Item, { kind: 'thought' | 'tool' | 'plan' }>
export type Block =
  | { type: 'user'; key: string; item: Extract<Item, { kind: 'user' }> }
  | { type: 'agent'; key: string; item: Extract<Item, { kind: 'agent' }>; streaming: boolean }
  | { type: 'activity'; key: string; items: ActivityItem[]; live: boolean }
  | { type: 'status'; key: string; item: Extract<Item, { kind: 'status' }> }

const noise = (text: string) => /^(stop:|mode:)/i.test(text)

export function groupBlocks(items: Item[], streaming: boolean): Block[] {
  const blocks: Block[] = []
  let activity: ActivityItem[] | null = null
  const flush = () => {
    if (activity) blocks.push({ type: 'activity', key: activity[0].id, items: activity, live: false })
    activity = null
  }
  for (const it of items) {
    switch (it.kind) {
      case 'thought':
      case 'tool':
      case 'plan':
        ;(activity ??= []).push(it)
        break
      case 'status':
        if (noise(it.text)) break
        flush()
        blocks.push({ type: 'status', key: it.id, item: it })
        break
      case 'user':
        flush()
        blocks.push({ type: 'user', key: it.id, item: it })
        break
      case 'agent':
        flush()
        blocks.push({ type: 'agent', key: it.id, item: it, streaming: false })
        break
    }
  }
  flush()
  if (streaming && blocks.length) {
    const last = blocks[blocks.length - 1]
    if (last.type === 'agent') last.streaming = true
    if (last.type === 'activity') last.live = true
  }
  return blocks
}

export function estimateBlock(b: Block): number {
  switch (b.type) {
    case 'user':
      return 56 + Math.ceil(b.item.text.length / 70) * 22 + (b.item.attachments.length ? 72 : 0)
    case 'agent': {
      const lines = b.item.text.split('\n').length + b.item.text.length / 95
      return 24 + lines * 21
    }
    case 'activity':
      return b.live ? 40 + b.items.length * 30 : 40
    case 'status':
      return 34
  }
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

export function BlockView({ block }: { block: Block }) {
  switch (block.type) {
    case 'user':
      return <UserBubble item={block.item} />
    case 'agent':
      return <AgentMessage item={block.item} streaming={block.streaming} />
    case 'activity':
      return <ActivityGroup items={block.items} live={block.live} groupKey={block.key} />
    case 'status':
      return <StatusRow text={block.item.text} />
  }
}

const UserBubble = memo(function UserBubble({ item }: { item: Extract<Item, { kind: 'user' }> }) {
  return (
    <div class="turn user-turn">
      {item.attachments.length > 0 && (
        <div class="user-attachments">
          {item.attachments.map((a) => (
            <AttachmentChip key={a.id} a={a} />
          ))}
        </div>
      )}
      {item.text && <div class="user-bubble">{item.text}</div>}
    </div>
  )
}, shallowEqual)

export function AttachmentChip({ a, onRemove }: { a: Attachment | { id: string; name: string; kind: string; src?: string; chars?: number; path?: string }; onRemove?: () => void }) {
  if (a.kind === 'image' && a.src) {
    return (
      <div class="att-image" title={a.name}>
        <img src={a.src} alt={a.name} />
        {onRemove && (
          <button class="att-remove" onClick={onRemove} data-no-drag>
            <Icon name="x" size={10} />
          </button>
        )}
      </div>
    )
  }
  const pasted = a.kind === 'pastedText'
  return (
    <div class="att-chip" title={(a as Attachment).path ?? a.name} onClick={() => (a as Attachment).path && openFile((a as Attachment).path!)}>
      <Icon name={pasted ? 'text' : a.kind === 'image' ? 'image' : 'file'} size={13} />
      <span class="att-name">{pasted && (a as Attachment).chars ? t('pastedText', (a as Attachment).chars!) : a.name}</span>
      {onRemove && (
        <button class="att-x" onClick={onRemove}>
          <Icon name="x" size={10} />
        </button>
      )}
    </div>
  )
}

const AgentMessage = memo(function AgentMessage({ item, streaming }: { item: Extract<Item, { kind: 'agent' }>; streaming: boolean }) {
  const ref = useRef<HTMLDivElement>(null)
  const view = useRef<MarkdownView | null>(null)
  const [copied, setCopied] = useState(false)
  useLayoutEffect(() => {
    view.current = new MarkdownView(ref.current!)
    return () => view.current?.dispose()
  }, [])
  useLayoutEffect(() => {
    // First paint and the final (non-streaming) pass are synchronous so the
    // virtualizer measures real heights; streaming ticks batch per frame.
    const first = !ref.current!.childElementCount
    view.current!.set(item.text, streaming, first || !streaming)
  }, [item.text, streaming])
  return (
    <div class="turn agent-turn">
      <div ref={ref} class="agent-body" />
      {!streaming && item.text && (
        <div class="msg-actions">
          <button
            class="icon-btn small"
            title={t('copy')}
            onClick={() => {
              post('copy', { text: item.text })
              setCopied(true)
              setTimeout(() => setCopied(false), 1400)
            }}
          >
            <Icon name={copied ? 'check' : 'copy'} size={13} />
          </button>
        </div>
      )}
    </div>
  )
}, shallowEqual)

function StatusRow({ text }: { text: string }) {
  const [open, setOpen] = useState(false)
  const nl = text.indexOf('\n')
  const first = nl >= 0 ? text.slice(0, nl) : text
  const rest = nl >= 0 ? text.slice(nl + 1).trim() : ''
  return (
    <div class="turn status-row">
      <button class="status-line" onClick={() => rest && setOpen(!open)} disabled={!rest}>
        <Icon name="info" size={12} />
        <span>{first}</span>
        {rest && <Icon name={open ? 'chevronDown' : 'chevronRight'} size={11} />}
      </button>
      {open && <pre class="status-detail">{rest}</pre>}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Activity (thinking / tools / plan)
// ---------------------------------------------------------------------------

const groupOpen = new Map<string, boolean>()
const stepOpen = new Map<string, boolean>()

function runSpan(items: ActivityItem[]): { start: number; end: number | null } | null {
  let start = Infinity
  let end = 0
  let open = false
  for (const it of items) {
    if (!it.run) continue
    start = Math.min(start, it.run.s)
    if (it.run.e == null) open = true
    else end = Math.max(end, it.run.e)
  }
  if (start === Infinity) return null
  return { start, end: open ? null : end }
}

function ActivityGroup({ items, live, groupKey }: { items: ActivityItem[]; live: boolean; groupKey: string }) {
  const [, rerender] = useState(0)
  const open = groupOpen.get(groupKey) ?? live
  const span = runSpan(items)
  const tools = items.filter((i) => i.kind === 'tool').length
  let label: string
  if (live) {
    label = span ? `${t('working')} · ${duration(now.value - span.start)}` : t('working')
  } else if (span && span.end && span.end - span.start >= 1000) {
    label = t('workedFor', duration(span.end - span.start))
  } else {
    label = tools > 0 ? t('usedTools') : t('steps', items.length)
  }
  const toggle = () => {
    groupOpen.set(groupKey, !open)
    rerender((x) => x + 1)
  }
  return (
    <div class={'turn activity' + (live ? ' live' : '')}>
      <button class="activity-head" onClick={toggle}>
        {live ? <Spinner size={11} /> : <Icon name={open ? 'chevronDown' : 'chevronRight'} size={12} />}
        <span class={live ? 'shimmer' : ''}>{label}</span>
        {!open && tools > 0 && <span class="activity-count">{t(tools === 1 ? 'toolCount1' : 'toolCount', tools)}</span>}
      </button>
      {open && (
        <div class="activity-steps">
          {items.map((it, i) => (
            <Step key={it.id} item={it} last={live && i === items.length - 1} />
          ))}
        </div>
      )}
    </div>
  )
}

const Step = memo(function Step({ item, last }: { item: ActivityItem; last: boolean }) {
  if (item.kind === 'thought') return <ThoughtStep item={item} live={last} />
  if (item.kind === 'plan') return <PlanStep entries={item.entries} />
  return <ToolStep tool={item} />
}, shallowEqual)

function ThoughtStep({ item, live }: { item: Extract<Item, { kind: 'thought' }>; live: boolean }) {
  const [open, setOpen] = useState(stepOpen.get(item.id) ?? false)
  const secs = item.run?.e ? duration(item.run.e - item.run.s) : null
  return (
    <div class="step">
      <button
        class="step-head"
        onClick={() => {
          stepOpen.set(item.id, !open)
          setOpen(!open)
        }}
      >
        <Icon name="brain" size={13} class="step-icon" />
        <span class={'step-title' + (live ? ' shimmer' : '')}>{live ? t('thinking') : secs ? t('thoughtFor', secs) : t('thought')}</span>
        <Icon name={open ? 'chevronDown' : 'chevronRight'} size={11} class="step-chev" />
      </button>
      {open && <div class="thought-text">{item.text}</div>}
    </div>
  )
}

function PlanStep({ entries }: { entries: { content: string; status: string }[] }) {
  return (
    <div class="step plan">
      <div class="step-head static">
        <Icon name="list" size={13} class="step-icon" />
        <span class="step-title">{t('plan')}</span>
        <span class="step-meta">
          {entries.filter((e) => e.status === 'completed').length}/{entries.length}
        </span>
      </div>
      <ul class="plan-list">
        {entries.map((e, i) => (
          <li key={i} class={'plan-' + e.status}>
            <span class="plan-mark">{e.status === 'completed' ? <Icon name="check" size={11} /> : e.status === 'in_progress' ? <Spinner size={9} /> : null}</span>
            <span>{e.content}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}

const TOOL_ICON: Record<string, string> = {
  command: 'terminal',
  edit: 'pencil',
  file: 'file',
  search: 'search',
  fetch: 'globe',
  other: 'wrench',
}
const failed = (s: string) => ['failed', 'error', 'cancelled', 'denied', 'rejected'].includes(s)

export function ToolStep({ tool, defaultOpen = false }: { tool: ToolFields & { id?: string }; defaultOpen?: boolean }) {
  const key = tool.id ?? tool.callId
  const [open, setOpen] = useState(stepOpen.get(key) ?? defaultOpen)
  const added = tool.diffs?.reduce((n, d) => n + d.added, 0) ?? 0
  const removed = tool.diffs?.reduce((n, d) => n + d.removed, 0) ?? 0
  const hasDetail = !!(tool.command || tool.output || tool.diffs?.length || tool.input)
  return (
    <div class={'step tool' + (failed(tool.status) ? ' failed' : '')}>
      <button
        class="step-head"
        disabled={!hasDetail}
        title={tool.fullTitle}
        onClick={() => {
          stepOpen.set(key, !open)
          setOpen(!open)
        }}
      >
        <Icon name={TOOL_ICON[tool.layout] ?? 'wrench'} size={13} class="step-icon" />
        <span class={'step-title' + (tool.progress ? ' shimmer' : '')}>{tool.title}</span>
        {tool.diffs?.length ? (
          <span class="diffstat">
            <span class="add">+{added}</span> <span class="del">−{removed}</span>
          </span>
        ) : null}
        {tool.exitCode != null && tool.exitCode !== 0 && <span class="step-meta bad">{t('exit', tool.exitCode)}</span>}
        {tool.progress ? <Spinner size={10} /> : failed(tool.status) ? <Icon name="x" size={12} class="bad" /> : null}
        {hasDetail && <Icon name={open ? 'chevronDown' : 'chevronRight'} size={11} class="step-chev" />}
      </button>
      {open && hasDetail && <ToolDetail tool={tool} />}
    </div>
  )
}

function ToolDetail({ tool }: { tool: ToolFields }) {
  if (tool.diffs?.length) {
    return (
      <div class="tool-detail">
        {tool.diffs.map((d, i) => (
          <DiffView key={i} file={d} />
        ))}
      </div>
    )
  }
  return (
    <div class="tool-detail mono-block">
      {tool.command && (
        <pre class="cmd">
          <span class="prompt">$ </span>
          {tool.command}
        </pre>
      )}
      {tool.output && <pre class="out">{tool.output}</pre>}
      {!tool.output && !tool.command && tool.input && <pre class="out">{tool.input}</pre>}
    </div>
  )
}

const stripPrivate = (p: string) => (p.startsWith('/private/') ? p.slice(8) : p)

/** Path shown in diff headers: relative to the session workspace when inside it. */
export function displayPath(raw: string): string {
  const state = app.peek()
  const path = stripPrivate(raw.replace(/\/+$/, ''))
  const session = state?.sessions.find((s) => s.id === state.selectedSessionId)
  for (const root of [session?.cwd, session?.ws]) {
    if (!root) continue
    const r = stripPrivate(root.replace(/\/+$/, ''))
    if (path.startsWith(r + '/')) return path.slice(r.length + 1)
  }
  const home = state?.homePath?.replace(/\/+$/, '')
  if (home && path.startsWith(home + '/')) return '~' + path.slice(home.length)
  return path
}

/** Drops the phantom empty line TextDiff emits for a trailing newline. */
function trimHunkLines(lines: string[], last: boolean): string[] {
  if (last && lines.length > 1) {
    const tail = lines[lines.length - 1]
    if (tail === '+' || tail === '-') return lines.slice(0, -1)
  }
  return lines
}

export function DiffView({ file, collapsible = false }: { file: DiffFile; collapsible?: boolean }) {
  const [open, setOpen] = useState(true)
  return (
    <div class="diff">
      <div class="diff-head">
        {collapsible && (
          <button class="icon-btn tiny" onClick={() => setOpen(!open)}>
            <Icon name={open ? 'chevronDown' : 'chevronRight'} size={11} />
          </button>
        )}
        <span class="diff-path" title={file.path} onClick={() => openFile(file.path)}>
          {displayPath(file.path)}
        </span>
        {file.isNew && <span class="diff-tag">{t('newFile')}</span>}
        <span class="diffstat">
          <span class="add">+{file.added}</span> <span class="del">−{file.removed}</span>
        </span>
      </div>
      {open && (
        <div class="diff-body">
          {file.hunks.map((h, i) => {
            let o = h.oldStart
            let n = h.newStart
            return (
              <div key={i} class="hunk">
                <div class="hunk-head">{h.header}</div>
                {trimHunkLines(h.lines, i === file.hunks.length - 1).map((l, j) => {
                  const sign = l[0]
                  const on = sign === '+' ? '' : o++
                  const nn = sign === '-' ? '' : n++
                  return (
                    <div key={j} class={'dl ' + (sign === '+' ? 'ins' : sign === '-' ? 'del' : 'ctx')}>
                      <span class="dl-no">{on}</span>
                      <span class="dl-no">{nn}</span>
                      <span class="dl-sign">{sign === ' ' ? '' : sign}</span>
                      <span class="dl-text">{l.slice(1) || ' '}</span>
                    </div>
                  )
                })}
              </div>
            )
          })}
          {file.truncated && <div class="hunk-head">…</div>}
        </div>
      )}
    </div>
  )
}
