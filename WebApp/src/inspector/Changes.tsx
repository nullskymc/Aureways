import { useSignal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { t } from '../i18n'
import { rpc, type GitDiff } from '../rpc'
import { app, transcript } from '../store'
import { prefs } from '../prefs'
import type { DiffFile } from '../types'
import { Icon, Spinner } from '../components/Icon'
import { filesVersion, openFile } from './state'
import { DiffFileHead, DiffHunks, DiffStat, FileLabel, StatusBadge } from './DiffPane'
import { WorkspaceSidebar } from './WorkspaceSidebar'
import { autoCollapsed, fileStatus, joinPath, mergeSessionEdits, parseUnifiedDiff, splitPath } from './diffModel'

export { parseUnifiedDiff } from './diffModel'

/** Collapse the jump list by default once it would push the first diff off screen. */
const INDEX_OPEN_LIMIT = 12

/**
 * Review every changed file in one scroll: each file is its own card with a
 * sticky header, so a long diff never runs into the next file. The navigator
 * (or the jump list when it is hidden) scrolls to a card instead of opening tabs.
 */
export function ChangesView() {
  const mode = useSignal<'session' | 'git'>('git')
  const data = useSignal<GitDiff | null>(null)
  const error = useSignal('')
  const loading = useSignal(false)
  const refresh = useSignal(0)
  const selected = useSignal('')
  const query = useSignal('')
  /** Per-file fold overrides; files without one use `autoCollapsed`. */
  const folds = useSignal<Record<string, boolean>>({})
  const scroller = useRef<HTMLDivElement>(null)
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
  const files = mode.value === 'git'
    ? parseUnifiedDiff(data.value?.diff ?? '', cwd)
    : mergeSessionEdits(transcript.items.flatMap((item) => item.kind === 'tool' && item.diffs ? [item.diffs] : []))
  const untracked = mode.value === 'git' ? data.value?.untracked ?? [] : []
  const added = files.reduce((n, file) => n + file.added, 0)
  const removed = files.reduce((n, file) => n + file.removed, 0)
  const navigator = prefs.inspectorOpen.value
  const needle = navigator ? query.value.toLowerCase() : ''
  const visible = files.filter((file) => splitPath(file.path, cwd).rel.toLowerCase().includes(needle))
  const visibleUntracked = untracked.filter((path) => path.toLowerCase().includes(needle))
  const groups = new Map<string, DiffFile[]>()
  for (const file of visible) {
    const dir = splitPath(file.path, cwd).dir
    groups.set(dir, [...groups.get(dir) ?? [], file])
  }
  const collapsed = (file: DiffFile) => folds.value[file.path] ?? autoCollapsed(file)
  const anyOpen = visible.some((file) => !collapsed(file))
  const setFold = (paths: string[], value: boolean) => {
    const next = { ...folds.value }
    for (const path of paths) next[path] = value
    folds.value = next
  }
  const reveal = (path: string) => {
    selected.value = path
    setFold([path], false)
    requestAnimationFrame(() => {
      const card = [...scroller.current?.querySelectorAll<HTMLElement>('.diff-card[data-path]') ?? []].find((el) => el.dataset.path === path)
      card?.scrollIntoView?.({ block: 'start', behavior: 'smooth' })
    })
  }
  const pending = mode.value === 'git' && loading.value
  const empty = mode.value === 'session' ? t('noSessionEdits') : error.value || (data.value?.repo ? t('cleanTree') : t('notRepo'))
  const count = files.length + untracked.length
  return (
    <div class="changes review">
      <div class="review-toolbar">
        <div class="seg" aria-label={t('changes')}>
          <button class={mode.value === 'git' ? 'on' : ''} onClick={() => (mode.value = 'git')}>{t('workingTree')}</button>
          <button class={mode.value === 'session' ? 'on' : ''} onClick={() => (mode.value = 'session')}>{t('sessionEdits')}</button>
        </div>
        {!!count && <span class="review-count">{t('filesChanged', count)}</span>}
        <span class="diffstat"><span class="add">+{added}</span> <span class="del">−{removed}</span></span>
        {mode.value === 'git' && data.value?.branch && <span class="review-branch" title={data.value.branch}><Icon name="branch" size={12} /><span>{data.value.branch}</span></span>}
        <div class="flex1" />
        {!!visible.length && (
          <button class="icon-btn tiny" title={t(anyOpen ? 'collapseAll' : 'expandAll')} aria-label={t(anyOpen ? 'collapseAll' : 'expandAll')}
            onClick={() => setFold(visible.map((file) => file.path), anyOpen)}>
            <Icon name="chevronUpDown" size={12} />
          </button>
        )}
        <button class="icon-btn tiny" title={t('refresh')} onClick={() => refresh.value++}>{pending ? <Spinner size={12} /> : <Icon name="refresh" size={12} />}</button>
      </div>
      <div class="workspace-content">
        <div class="workspace-editor review-editor">
          {pending ? <div class="file-empty"><Spinner size={16} /></div> : count ? (
            <div class="review-scroll" ref={scroller}>
              {!navigator && <FileIndex key={mode.value} files={files} untracked={untracked} root={cwd} onPick={reveal} />}
              {visible.map((file) => (
                <section key={file.path} data-path={file.path}
                  class={'diff-card status-' + fileStatus(file).toLowerCase() + (collapsed(file) ? ' collapsed' : '') + (file.path === selected.value ? ' selected' : '')}>
                  <DiffFileHead file={file} root={cwd} collapsed={collapsed(file)} onToggle={() => setFold([file.path], !collapsed(file))} />
                  {!collapsed(file) && <div class="diff-card-body"><DiffHunks file={file} /></div>}
                </section>
              ))}
              {!!visibleUntracked.length && (
                <section class="diff-card untracked-card">
                  <div class="file-head diff-file-head"><span class="change-badge u">U</span><span class="untracked-title">{t('untracked')}</span><span class="review-count">{visibleUntracked.length}</span></div>
                  {visibleUntracked.map((path) => (
                    <button key={path} class="untracked-row" onClick={() => openFile(joinPath(cwd, path))}>
                      <FileLabel file={stub(joinPath(cwd, path))} root={cwd} />
                    </button>
                  ))}
                </section>
              )}
              {!!needle && !visible.length && !visibleUntracked.length && <div class="tree-empty">{t('noMatches')}</div>}
            </div>
          ) : <div class="review-empty"><Icon name="gitDiff" size={27} /><span>{empty}</span></div>}
        </div>
        {navigator && <WorkspaceSidebar>
          <label class="tree-filter review-filter"><Icon name="search" size={12} /><input placeholder={t('filterFiles')} value={query.value} onInput={(e) => (query.value = e.currentTarget.value)} onKeyDown={(e) => { if (e.key === 'Escape') query.value = '' }} /></label>
          <div class="tree-list review-files">
            {[...groups].map(([dir, list]) => <details key={dir} open class="review-folder">
              <summary><Icon name="chevronRight" size={10} /><span>{dir || (cwd.split('/').pop() ?? '/')}</span></summary>
              {list.map((file) => <button key={file.path} class={'tree-row review-file' + (file.path === selected.value ? ' selected' : '')} title={splitPath(file.path, cwd).rel} aria-pressed={file.path === selected.value} onClick={() => reveal(file.path)}>
                <StatusBadge status={fileStatus(file)} /><span class="tree-name">{splitPath(file.path, cwd).name}</span><DiffStat file={file} />
              </button>)}
            </details>)}
            {!!visibleUntracked.length && <div class="untracked-head">{t('untracked')}</div>}
            {visibleUntracked.map((path) => <button key={path} class="tree-row review-file" title={path} onClick={() => openFile(joinPath(cwd, path))}><span class="change-badge u">U</span><span class="tree-name">{path}</span></button>)}
            {!!query.value && !groups.size && !visibleUntracked.length && <div class="tree-empty">{t('noMatches')}</div>}
          </div>
        </WorkspaceSidebar>}
      </div>
    </div>
  )
}

const stub = (path: string): DiffFile => ({ path, added: 0, removed: 0, truncated: false, isNew: true, hunks: [] })

/** Jump list shown above the cards while the navigator is hidden. */
function FileIndex({ files, untracked, root, onPick }: { files: DiffFile[]; untracked: string[]; root: string; onPick: (path: string) => void }) {
  if (files.length + untracked.length < 2) return null
  return (
    <details class="review-index" open={files.length <= INDEX_OPEN_LIMIT}>
      <summary><Icon name="chevronRight" size={10} /><span>{t('filesChanged', files.length + untracked.length)}</span></summary>
      {files.map((file) => (
        <button key={file.path} class="review-index-row" onClick={() => onPick(file.path)}>
          <StatusBadge status={fileStatus(file)} />
          <FileLabel file={file} root={root} />
          <DiffStat file={file} />
        </button>
      ))}
      {untracked.map((path) => (
        <button key={path} class="review-index-row" onClick={() => openFile(joinPath(root, path))}>
          <span class="change-badge u">U</span>
          <FileLabel file={stub(joinPath(root, path))} root={root} />
        </button>
      ))}
    </details>
  )
}
