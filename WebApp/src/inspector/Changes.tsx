import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { t } from '../i18n'
import { rpc, type GitDiff } from '../rpc'
import { app, transcript } from '../store'
import { prefs } from '../prefs'
import type { DiffFile } from '../types'
import { Icon, Spinner } from '../components/Icon'
import { filesVersion, openFile } from './state'
import { DiffPane } from './DiffPane'
import { WorkspaceSidebar } from './WorkspaceSidebar'

/** Keep review inside its tab: selecting a changed file does not open another tab. */
export function ChangesView() {
  const mode = useSignal<'session' | 'git'>('git')
  const data = useSignal<GitDiff | null>(null)
  const error = useSignal('')
  const loading = useSignal(false)
  const refresh = useSignal(0)
  const selected = useSignal('')
  const query = useSignal('')
  const cwd = app.value?.inspectorRoot ?? ''
  useEffect(() => {
    let live = true
    loading.value = true
    data.value = null
    error.value = ''
    void rpc<GitDiff>('git.diff', { cwd }).then((result) => {
      if (live) data.value = result
    }).catch((e: Error) => {
      if (live) error.value = e.message
    }).finally(() => { if (live) loading.value = false })
    return () => { live = false }
  }, [cwd, filesVersion.value, refresh.value])

  void transcript.version.value
  const sessionFiles = new Map<string, DiffFile>()
  for (const item of transcript.items) {
    if (item.kind !== 'tool') continue
    for (const file of item.diffs ?? []) {
      const prev = sessionFiles.get(file.path)
      sessionFiles.set(file.path, prev ? {
        ...file, isNew: prev.isNew || file.isNew,
        added: prev.added + file.added, removed: prev.removed + file.removed,
        hunks: file.hunks.length ? file.hunks : prev.hunks,
      } : file)
    }
  }
  const files = mode.value === 'git' ? parseUnifiedDiff(data.value?.diff ?? '', cwd) : [...sessionFiles.values()]
  const untracked = mode.value === 'git' ? data.value?.untracked ?? [] : []
  const active = files.find((file) => file.path === selected.value) ?? files[0]
  const added = files.reduce((n, file) => n + file.added, 0)
  const removed = files.reduce((n, file) => n + file.removed, 0)
  const groups = new Map<string, DiffFile[]>()
  for (const file of files) {
    const relative = file.path.startsWith(cwd + '/') ? file.path.slice(cwd.length + 1) : file.path
    if (!relative.toLowerCase().includes(query.value.toLowerCase())) continue
    const dir = relative.split('/').slice(0, -1).join('/')
    groups.set(dir, [...groups.get(dir) ?? [], file])
  }
  const visibleUntracked = untracked.filter((path) => path.toLowerCase().includes(query.value.toLowerCase()))
  const pending = mode.value === 'git' && loading.value
  const empty = mode.value === 'session' ? t('noSessionEdits') : error.value || (data.value?.repo ? t('cleanTree') : t('notRepo'))
  return (
    <div class="changes review">
      <div class="review-toolbar">
        <div class="seg" aria-label={t('changes')}>
          <button class={mode.value === 'git' ? 'on' : ''} onClick={() => (mode.value = 'git')}>{t('workingTree')}</button>
          <button class={mode.value === 'session' ? 'on' : ''} onClick={() => (mode.value = 'session')}>{t('sessionEdits')}</button>
        </div>
        <span class="diffstat"><span class="add">+{added}</span> <span class="del">−{removed}</span></span>
        {mode.value === 'git' && data.value?.branch && <span class="review-branch"><Icon name="branch" size={12} />{data.value.branch}</span>}
        <div class="flex1" />
        <button class="icon-btn tiny" title={t('refresh')} onClick={() => refresh.value++}>{pending ? <Spinner size={12} /> : <Icon name="refresh" size={12} />}</button>
      </div>
      <div class="workspace-content">
        <div class="workspace-editor review-editor">
          {pending ? <div class="file-empty"><Spinner size={16} /></div> : active ? <DiffPane key={active.path} file={active} /> : <div class="review-empty"><Icon name="gitDiff" size={27} /><span>{empty}</span>{!!untracked.length && <span>{t('untracked')} · {untracked.length}</span>}</div>}
        </div>
        {prefs.inspectorOpen.value && <WorkspaceSidebar>
          <label class="tree-filter review-filter"><Icon name="search" size={12} /><input placeholder={t('filterFiles')} value={query.value} onInput={(e) => (query.value = e.currentTarget.value)} onKeyDown={(e) => { if (e.key === 'Escape') query.value = '' }} /></label>
          <div class="tree-list review-files">
            {[...groups].map(([dir, list]) => <details key={dir} open class="review-folder">
              <summary><Icon name="chevronRight" size={10} /><span>{dir || (cwd.split('/').pop() ?? '/')}</span></summary>
              {list.map((file) => <button key={file.path} class={'tree-row review-file' + (file.path === active?.path ? ' selected' : '')} title={file.path} aria-pressed={file.path === active?.path} onClick={() => (selected.value = file.path)}>
                <Icon name="gitDiff" size={12} /><span class="tree-name">{file.path.split('/').pop()}</span><span class="diffstat"><span class="add">{file.added > 0 ? '+' + file.added : ''}</span> <span class="del">{file.removed > 0 ? '−' + file.removed : ''}</span></span>
              </button>)}
            </details>)}
            {!!visibleUntracked.length && <div class="untracked-head">{t('untracked')}</div>}
            {visibleUntracked.map((path) => <button key={path} class="tree-row" title={path} onClick={() => openFile(joinPath(cwd, path))}><Icon name="file" size={12} /><span class="tree-name">{path}</span><span class="change-badge untracked">U</span></button>)}
            {!!query.value && !groups.size && !visibleUntracked.length && <div class="tree-empty">{t('noMatches')}</div>}
          </div>
        </WorkspaceSidebar>}
      </div>
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
