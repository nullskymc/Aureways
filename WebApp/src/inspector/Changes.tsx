import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { t } from '../i18n'
import { rpc, type GitDiff } from '../rpc'
import { app, transcript } from '../store'
import type { DiffFile } from '../types'
import { DiffView } from '../components/Blocks'
import { Icon, Spinner } from '../components/Icon'
import { filesVersion, openFile } from './state'

/** Review: edits made in this session (from tool calls) and the working tree vs HEAD. */
export function ChangesView() {
  const mode = useSignal<'session' | 'git'>('session')
  return (
    <div class="changes">
      <div class="seg" data-no-drag>
        <button class={mode.value === 'session' ? 'on' : ''} onClick={() => (mode.value = 'session')}>{t('sessionEdits')}</button>
        <button class={mode.value === 'git' ? 'on' : ''} onClick={() => (mode.value = 'git')}>{t('workingTree')}</button>
      </div>
      {mode.value === 'session' ? <SessionEdits /> : <GitChanges />}
    </div>
  )
}

function SessionEdits() {
  void transcript.version.value
  // Last diff per path wins its hunks; counts accumulate.
  const files = new Map<string, DiffFile & { edits: number }>()
  for (const it of transcript.items) {
    if (it.kind !== 'tool' || !it.diffs) continue
    for (const d of it.diffs) {
      const prev = files.get(d.path)
      if (prev) {
        files.set(d.path, { ...d, isNew: prev.isNew, added: prev.added + d.added, removed: prev.removed + d.removed, hunks: [...prev.hunks, ...d.hunks], edits: prev.edits + 1 })
      } else files.set(d.path, { ...d, edits: 1 })
    }
  }
  const list = [...files.values()]
  if (!list.length) return <div class="changes-empty">{t('noSessionEdits')}</div>
  const added = list.reduce((n, f) => n + f.added, 0)
  const removed = list.reduce((n, f) => n + f.removed, 0)
  return (
    <div class="changes-list">
      <div class="changes-summary">
        {t('filesChanged', list.length)} <span class="diffstat"><span class="add">+{added}</span> <span class="del">−{removed}</span></span>
      </div>
      {list.map((f) => <DiffView key={f.path} file={f} collapsible />)}
    </div>
  )
}

function GitChanges() {
  const data = useSignal<GitDiff | null>(null)
  const loading = useSignal(false)
  const cwd = app.value?.inspectorRoot ?? ''
  const load = async () => {
    loading.value = true
    data.value = await rpc<GitDiff>('git.diff', { cwd }).catch(() => ({ repo: false }))
    loading.value = false
  }
  useEffect(() => void load(), [cwd, filesVersion.value])
  const d = data.value
  if (!d) return <div class="changes-empty"><Spinner size={13} /></div>
  if (!d.repo) return <div class="changes-empty">{t('notRepo')}</div>
  const files = parseUnifiedDiff(d.diff ?? '', cwd)
  return (
    <div class="changes-list">
      <div class="changes-summary">
        <Icon name="gitDiff" size={12} /> {d.branch} · {t('filesChanged', files.length + (d.untracked?.length ?? 0))}
        <div class="flex1" />
        <button class="icon-btn tiny" title={t('refresh')} onClick={load}>{loading.value ? <Spinner size={10} /> : <Icon name="refresh" size={12} />}</button>
      </div>
      {files.map((f) => <DiffView key={f.path} file={f} collapsible />)}
      {!!d.untracked?.length && (
        <div class="untracked">
          <div class="untracked-head">{t('untracked')}</div>
          {d.untracked.map((rel) => (
            <button key={rel} class="tree-row" onClick={() => openFile(joinPath(cwd, rel))}>
              <Icon name="file" size={12} class="tree-icon" />
              <span class="tree-name">{rel}</span>
            </button>
          ))}
        </div>
      )}
      {!files.length && !d.untracked?.length && <div class="changes-empty">{t('cleanTree')}</div>}
    </div>
  )
}

const joinPath = (root: string, rel: string) => (rel.startsWith('/') ? rel : root.replace(/\/+$/, '') + '/' + rel)

/** Minimal `git diff` parser → DiffFile[] (paths made absolute against cwd). */
export function parseUnifiedDiff(text: string, cwd: string): DiffFile[] {
  const files: DiffFile[] = []
  let file: DiffFile | null = null
  let hunk: DiffFile['hunks'][number] | null = null
  for (const line of text.split('\n')) {
    if (line.startsWith('diff --git ')) {
      const m = / b\/(.*)$/.exec(line)
      file = { path: joinPath(cwd, m?.[1] ?? ''), added: 0, removed: 0, truncated: false, isNew: false, hunks: [] }
      files.push(file)
      hunk = null
    } else if (!file) continue
    else if (line.startsWith('new file mode')) file.isNew = true
    else if (line.startsWith('+++ b/')) file.path = joinPath(cwd, line.slice(6))
    else if (line.startsWith('@@')) {
      const m = /@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)/.exec(line)
      hunk = { header: line, oldStart: Number(m?.[1] ?? 1), newStart: Number(m?.[2] ?? 1), lines: [] }
      file.hunks.push(hunk)
    } else if (hunk && (line[0] === '+' || line[0] === '-' || line[0] === ' ')) {
      if (hunk.lines.length > 2000) {
        file.truncated = true
        continue
      }
      hunk.lines.push(line)
      if (line[0] === '+') file.added++
      else if (line[0] === '-') file.removed++
    }
  }
  return files
}
