import { signal, useSignal } from '@preact/signals'
import { useEffect, useLayoutEffect, useRef } from 'preact/hooks'
import { nativeMenu, post, type MenuItem } from '../bridge'
import { t } from '../i18n'
import { app, uiCommand } from '../store'
import { rpc, type SearchHit } from '../rpc'
import type { AppState, Picker, Session } from '../types'
import { AttachmentChip } from './Blocks'
import { HarnessIcon, Icon } from './Icon'

const INLINE_LIMIT = 2000 // matches ComposerOverflow.inlineUTF16Limit

const drafts = new Map<string, string>()

/** Text inserted by other panes (file tree "mention"), consumed by the live composer. */
const insertQueue = signal<{ text: string; seq: number } | null>(null)
let insertSeq = 0

/** `@path` mention of a workspace file; the path is also attached for the agent. */
export function mentionFile(path: string, root: string) {
  const r = root.replace(/\/+$/, '')
  const rel = path.startsWith(r + '/') ? path.slice(r.length + 1) : path
  // With a session open the composer lives in the native overlay page.
  if (document.documentElement.classList.contains('composer-overlay')) post('composerInsert', { text: '@' + rel + ' ' })
  else queueInsert('@' + rel + ' ')
  post('attachPaths', { paths: [path] })
}

export function queueInsert(text: string) {
  insertQueue.value = { text, seq: ++insertSeq }
}

/** Overlay page: the viewport is only as tall as the composer, so cap by a fixed height. */
function maxAreaHeight() {
  return document.documentElement.classList.contains('in-composer') ? 300 : Math.round(window.innerHeight * 0.4)
}

interface Mention { start: number; query: string }

function mentionAt(value: string, caret: number): Mention | null {
  const before = value.slice(0, caret)
  const m = /(^|\s)@([^\s@]*)$/.exec(before)
  if (!m) return null
  return { start: caret - m[2].length - 1, query: m[2] }
}

export function Composer({ state, session }: { state: AppState; session: Session | null }) {
  const draftKey = session?.id ?? 'new'
  const text = useSignal(drafts.get(draftKey) ?? '')
  const area = useRef<HTMLTextAreaElement>(null)
  const slashIndex = useSignal(0)
  const mention = useSignal<Mention | null>(null)
  const hits = useSignal<SearchHit[]>([])
  const hitIndex = useSignal(0)
  const dropping = useSignal(false)
  const composer = state.composer
  const streaming = !!session?.streaming
  const connecting = session?.phase === 'connecting'

  useEffect(() => {
    text.value = drafts.get(draftKey) ?? ''
    area.current?.focus()
  }, [draftKey])

  useEffect(() => {
    const c = uiCommand.value
    if (c?.name === 'focusComposer') area.current?.focus()
    if (c?.name === 'dropHover') dropping.value = true
    if (c?.name === 'dropEnd') dropping.value = false
    if (c?.name === 'insertText' && typeof c.data?.text === 'string') queueInsert(c.data.text)
  }, [uiCommand.value])

  // Insertions from the file tree / file view.
  useEffect(() => {
    const ins = insertQueue.value
    const el = area.current
    if (!ins || !el) return
    insertQueue.value = null
    el.focus()
    const at = el.selectionStart ?? text.value.length
    const pre = text.value.slice(0, at)
    const sep = pre && !/\s$/.test(pre) ? ' ' : ''
    text.value = pre + sep + ins.text + text.value.slice(el.selectionEnd ?? at)
    drafts.set(draftKey, text.value)
    const caret = at + sep.length + ins.text.length
    requestAnimationFrame(() => el.setSelectionRange(caret, caret))
  }, [insertQueue.value])

  // @-file completion against the workspace index (Swift WorkspaceFileIndex).
  useEffect(() => {
    const m = mention.value
    if (!m) {
      hits.value = []
      return
    }
    let live = true
    const timer = setTimeout(async () => {
      const res = await rpc<SearchHit[]>('fs.search', { root: app.peek()?.inspectorRoot, query: m.query, limit: 12 }).catch(() => [])
      if (live) {
        hits.value = res
        hitIndex.value = 0
      }
    }, 60)
    return () => {
      live = false
      clearTimeout(timer)
    }
  }, [mention.value?.query, mention.value?.start])

  const updateMention = () => {
    const el = area.current
    if (!el) return
    mention.value = el.selectionStart === el.selectionEnd ? mentionAt(el.value, el.selectionStart) : null
  }

  const pickHit = (hit: SearchHit) => {
    const m = mention.value
    const el = area.current
    if (!m || !el) return
    const end = m.start + 1 + m.query.length
    const insert = '@' + hit.rel + ' '
    text.value = text.value.slice(0, m.start) + insert + text.value.slice(end)
    drafts.set(draftKey, text.value)
    mention.value = null
    post('attachPaths', { paths: [hit.path] })
    const caret = m.start + insert.length
    requestAnimationFrame(() => {
      el.focus()
      el.setSelectionRange(caret, caret)
    })
  }

  useLayoutEffect(() => {
    const el = area.current
    if (!el) return
    el.style.height = 'auto'
    el.style.height = Math.min(el.scrollHeight, maxAreaHeight()) + 'px'
  }, [text.value])

  const canSend = (text.value.trim().length > 0 || composer.attachments.length > 0) && !connecting
  const send = () => {
    if (!canSend) return
    post('send', { text: text.value })
    text.value = ''
    drafts.delete(draftKey)
  }

  // Slash commands advertised by the agent.
  const slash = text.value.startsWith('/') && !text.value.includes(' ') && !text.value.includes('\n')
    ? (composer.commands ?? []).filter((c) => c.name.toLowerCase().startsWith(text.value.slice(1).toLowerCase())).slice(0, 8)
    : []
  const pickSlash = (name: string) => {
    text.value = `/${name} `
    area.current?.focus()
  }

  const agent = state.agents.find((a) => a.id === (session?.agentId ?? state.selectedAgentId))
  const agentTitle = session?.agentTitle ?? agent?.title ?? 'Agent'

  return (
    <div class="composer-wrap">
      {mention.value && hits.value.length > 0 && (
        <div class="slash-menu mention-menu">
          {hits.value.map((h, i) => (
            <button key={h.path} class={'slash-item' + (i === hitIndex.value % hits.value.length ? ' active' : '')} onMouseDown={(e) => { e.preventDefault(); pickHit(h) }}>
              <Icon name="file" size={13} class="slash-icon" />
              <span class="slash-name">{h.rel.split('/').pop()}</span>
              <span class="slash-desc">{h.rel.split('/').slice(0, -1).join('/')}</span>
            </button>
          ))}
        </div>
      )}
      {slash.length > 0 && (
        <div class="slash-menu">
          {slash.map((c, i) => (
            <button key={c.name} class={'slash-item' + (i === slashIndex.value % slash.length ? ' active' : '')} onMouseDown={(e) => { e.preventDefault(); pickSlash(c.name) }}>
              <span class="slash-name">/{c.name}</span>
              <span class="slash-desc">{c.description}</span>
            </button>
          ))}
        </div>
      )}
      <div class={'composer' + (streaming ? ' busy' : '') + (dropping.value ? ' dropping' : '')} data-glass="composer">
        {dropping.value && <div class="drop-hint">{t('dropToAttach')}</div>}
        {composer.attachments.length > 0 && (
          <div class="composer-attachments">
            {composer.attachments.map((a) => (
              <AttachmentChip key={a.id} a={a} onRemove={() => post('removeAttachment', { id: a.id })} />
            ))}
          </div>
        )}
        <textarea
          ref={area}
          rows={1}
          value={text.value}
          placeholder={session ? t('placeholderFollow') : t('placeholder')}
          onInput={(e) => {
            text.value = (e.target as HTMLTextAreaElement).value
            drafts.set(draftKey, text.value)
            slashIndex.value = 0
            updateMention()
          }}
          onClick={updateMention}
          onKeyUp={(e) => (e.key === 'ArrowLeft' || e.key === 'ArrowRight') && updateMention()}
          onBlur={() => setTimeout(() => (mention.value = null), 120)}
          onPaste={(e) => {
            const data = e.clipboardData
            if (!data) return
            // Images / Finder files: let AppKit read the pasteboard natively.
            const types = Array.from(data.types)
            if (types.includes('Files') || Array.from(data.items).some((i) => i.kind === 'file')) {
              e.preventDefault()
              post('pasteNative')
              return
            }
            const pasted = data.getData('text/plain')
            if (pasted && pasted.length > INLINE_LIMIT) {
              e.preventDefault()
              post('pasteText', { text: pasted })
            }
          }}
          onKeyDown={(e) => {
            const list = mention.value ? hits.value : []
            if (list.length && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
              e.preventDefault()
              hitIndex.value += e.key === 'ArrowDown' ? 1 : list.length - 1
              return
            }
            if (list.length && (e.key === 'Tab' || (e.key === 'Enter' && !e.shiftKey && !e.isComposing))) {
              e.preventDefault()
              pickHit(list[hitIndex.value % list.length])
              return
            }
            if (list.length && e.key === 'Escape') {
              mention.value = null
              return
            }
            if (slash.length && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
              e.preventDefault()
              slashIndex.value += e.key === 'ArrowDown' ? 1 : slash.length - 1
              return
            }
            if (slash.length && (e.key === 'Tab' || (e.key === 'Enter' && !e.shiftKey))) {
              e.preventDefault()
              pickSlash(slash[slashIndex.value % slash.length].name)
              return
            }
            if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && e.keyCode !== 229) {
              e.preventDefault()
              if (!streaming) send()
            }
            if (e.key === 'Escape') {
              if (streaming) post('cancel')
              // Overlay page: hand unconsumed Esc to the main page (find bar…).
              else if (document.documentElement.classList.contains('in-composer')) post('composerEscape')
            }
          }}
        />
        <div class="composer-bar">
          <button class="icon-btn" title={t('attach')} onClick={() => post('attach')}>
            <Icon name="paperclip" size={15} />
          </button>
          <AgentChip state={state} session={session} title={agentTitle} />
          {composer.model && <PickerChip picker={composer.model} icon="cpu" onPick={(v) => post('setConfig', { configId: composer.model!.configId, value: v })} />}
          {composer.effort && <PickerChip picker={composer.effort} icon="gauge" onPick={(v) => post('setConfig', { configId: composer.effort!.configId, value: v })} />}
          {composer.mode && <PickerChip picker={composer.mode} icon="layers" onPick={(v) => (composer.mode!.configId ? post('setConfig', { configId: composer.mode!.configId, value: v }) : post('setMode', { modeId: v }))} />}
          <div class="composer-actions">
            {state.usage && state.usage.size > 0 && <ContextRing used={state.usage.used} size={state.usage.size} />}
            {streaming ? (
              <button class="send-btn stop" title={t('stop') + ' (⌘.)'} onClick={() => post('cancel')}>
                <Icon name="stop" size={12} />
              </button>
            ) : (
              <button class="send-btn" title={t('send') + ' (↩)'} disabled={!canSend} onClick={send}>
                <Icon name="arrowUp" size={15} />
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}

function AgentChip({ state, session, title }: { state: AppState; session: Session | null; title: string }) {
  const agentId = session?.agentId ?? state.selectedAgentId
  if (session) {
    return (
      <span class="chip static" title={title}>
        <HarnessIcon id={agentId} size={13} />
        <span>{title}</span>
      </span>
    )
  }
  return (
    <button
      class="chip"
      onClick={async (e) => {
        const items: MenuItem[] = state.agents.map((a) => ({
          id: a.id,
          title: a.title,
          subtitle: a.available ? undefined : t('harnessUnavailable'),
          checked: a.id === state.selectedAgentId,
        }))
        const id = await nativeMenu(items, e.currentTarget as Element)
        if (id) post('selectAgent', { id })
      }}
    >
      <HarnessIcon id={agentId} size={13} />
      <span>{title}</span>
      <Icon name="chevronUpDown" size={11} class="chev" />
    </button>
  )
}

function PickerChip({ picker, icon, onPick }: { picker: Picker; icon: string; onPick(v: string): void }) {
  const current = picker.options.find((o) => o.id === picker.current)
  return (
    <button
      class="chip"
      title={current?.description ?? undefined}
      onClick={async (e) => {
        const items: MenuItem[] = []
        let lastGroup: string | null | undefined = undefined
        for (const o of picker.options) {
          if (o.group !== lastGroup && o.group) {
            if (items.length) items.push({ type: 'separator' })
            items.push({ type: 'header', title: o.group })
          }
          lastGroup = o.group
          items.push({ id: o.id, title: o.name, checked: o.id === picker.current })
        }
        const id = await nativeMenu(items, e.currentTarget as Element)
        if (id && id !== picker.current) onPick(id)
      }}
    >
      <Icon name={icon} size={12} class="chip-icon" />
      <span>{current?.name ?? picker.current ?? '—'}</span>
      <Icon name="chevronUpDown" size={11} class="chev" />
    </button>
  )
}

function ContextRing({ used, size }: { used: number; size: number }) {
  const pct = Math.min(1, used / size)
  const r = 6
  const c = 2 * Math.PI * r
  return (
    <span class="context-ring" title={t('context', Math.round(pct * 100)) + ` · ${used.toLocaleString()} / ${size.toLocaleString()}`}>
      <svg width="16" height="16" viewBox="0 0 16 16">
        <circle cx="8" cy="8" r={r} class="ring-bg" />
        <circle cx="8" cy="8" r={r} class="ring-fg" stroke-dasharray={`${c * pct} ${c}`} transform="rotate(-90 8 8)" />
      </svg>
    </span>
  )
}
