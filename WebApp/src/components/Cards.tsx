import { useSignal } from '@preact/signals'
import { useLayoutEffect, useRef } from 'preact/hooks'
import { post } from '../bridge'
import { t } from '../i18n'
import { MarkdownView } from '../markdown/render'
import type { AppState } from '../types'
import { ToolStep } from './Blocks'
import { HarnessIcon, Icon } from './Icon'

export function PermissionCard({ p }: { p: NonNullable<AppState['permission']> }) {
  const primary = p.options.findIndex((o) => o.allow)
  return (
    <div class="card permission-card">
      <div class="card-head">
        <Icon name="shield" size={15} class="warn" />
        <div class="card-titles">
          <div class="card-kicker">{t('permission')}</div>
          <div class="card-title">{p.title}</div>
        </div>
      </div>
      {p.tool && (p.tool.command || p.tool.diffs?.length || p.tool.output || p.tool.input) && (
        <div class="card-body">
          <ToolStep tool={p.tool} defaultOpen />
        </div>
      )}
      <div class="card-actions">
        {p.options.map((o, i) => (
          <button
            key={o.id}
            class={'btn' + (i === primary ? ' primary' : o.allow ? '' : ' subtle')}
            onClick={() => post('permission', { optionId: o.id })}
          >
            {o.name}
          </button>
        ))}
        {!p.options.some((o) => !o.allow) && (
          <button class="btn subtle" onClick={() => post('permission', { optionId: null })}>
            {t('reject')}
          </button>
        )}
      </div>
    </div>
  )
}

export function PlanApprovalCard({ plan }: { plan: NonNullable<AppState['planApproval']> }) {
  const ref = useRef<HTMLDivElement>(null)
  useLayoutEffect(() => {
    const v = new MarkdownView(ref.current!)
    v.set(plan.content, false, true)
    return () => v.dispose()
  }, [plan.content])
  return (
    <div class="card plan-card">
      <div class="card-head">
        <Icon name="list" size={15} />
        <div class="card-titles">
          <div class="card-title">{t('planReady')}</div>
        </div>
      </div>
      <div class="card-body plan-content" ref={ref} />
      <div class="card-actions">
        <button class="btn primary" onClick={() => post('planApproval', { decision: 'approve' })}>
          {t('approve')}
        </button>
        <button class="btn" onClick={() => post('planApproval', { decision: 'changes' })}>
          {t('requestChanges')}
        </button>
        <button class="btn subtle" onClick={() => post('planApproval', { decision: 'quit' })}>
          {t('quit')}
        </button>
      </div>
    </div>
  )
}

export function QuestionCard({ q }: { q: NonNullable<AppState['question']> }) {
  const picks = useSignal<Record<string, string[]>>({})
  const toggle = (qid: string, label: string, multi: boolean) => {
    const cur = picks.value[qid] ?? []
    const next = multi ? (cur.includes(label) ? cur.filter((l) => l !== label) : [...cur, label]) : [label]
    picks.value = { ...picks.value, [qid]: next }
  }
  return (
    <div class="card question-card">
      <div class="card-head">
        <Icon name="info" size={15} />
        <div class="card-titles">
          <div class="card-kicker">{t('question')}</div>
        </div>
      </div>
      <div class="card-body">
        {q.questions.map((qq) => (
          <div key={qq.id} class="question">
            <div class="question-text">{qq.text}</div>
            <div class="question-options">
              {qq.options.map((o) => (
                <button
                  key={o.label}
                  class={'option' + ((picks.value[qq.id] ?? []).includes(o.label) ? ' on' : '')}
                  title={o.description ?? undefined}
                  onClick={() => toggle(qq.id, o.label, qq.multi)}
                >
                  {o.label}
                </button>
              ))}
            </div>
          </div>
        ))}
      </div>
      <div class="card-actions">
        <button class="btn primary" onClick={() => post('question', { answers: picks.value })}>
          {t('submit')}
        </button>
        <button class="btn subtle" onClick={() => post('question', { skip: true })}>
          {t('skip')}
        </button>
      </div>
    </div>
  )
}

/** Requests from sessions you aren't looking at: compact, answerable in place. */
export function BackgroundRequests({ state }: { state: AppState }) {
  const others = state.sessions.filter((s) => s.id !== state.selectedSessionId && (s.permission || s.pendingKind))
  if (!others.length) return null
  return (
    <div class="bg-requests">
      {others.slice(0, 3).map((s) => {
        const allow = s.permission?.options.find((o) => o.allow)
        const deny = s.permission?.options.find((o) => !o.allow)
        return (
          <div key={s.id} class="bg-request">
            <HarnessIcon id={s.agentId} size={13} />
            <div class="bg-request-text">
              <span class="bg-request-session">{s.title}</span>
              <span class="bg-request-what">
                {s.permission ? s.permission.title : s.pendingKind === 'plan' ? t('planReady') : t('questionWaiting')}
              </span>
            </div>
            {s.permission && allow && (
              <button class="btn small primary" onClick={() => post('permission', { sessionId: s.id, optionId: allow.id })}>
                {allow.name}
              </button>
            )}
            {s.permission && (
              <button class="btn small subtle" onClick={() => post('permission', { sessionId: s.id, optionId: deny?.id ?? null })}>
                {deny?.name ?? t('reject')}
              </button>
            )}
            <button class="btn small" onClick={() => post('selectSession', { id: s.id })}>
              {t('view')}
            </button>
          </div>
        )
      })}
    </div>
  )
}
