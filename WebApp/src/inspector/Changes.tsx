import { signal, useSignal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { t } from '../i18n'
import { rpc, type GitDiff } from '../rpc'
import { app, transcript } from '../store'
import type { DiffFile } from '../types'
import { Icon, Spinner } from '../components/Icon'
import { filesVersion, openDiff, openFile } from './state'
import { DiffStat, StatusBadge } from './DiffPane'
import { fileIcon, fileStatus, joinPath, mergeSessionEdits, parseUnifiedDiff, splitPath } from './diffModel'

export { parseUnifiedDiff } from './diffModel'

/** Folded folders, keyed by workspace + folder. Survives refreshes and reopening the tab. */
const foldedDirs = signal<Record<string, boolean>>({})
/** Selected row per workspace and mode, kept while the file is still changed. */
const selections = signal<Record<string, string>>({})

const typing = (target: EventTarget | null) =>
  target instanceof HTMLElement && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName))

interface Row { path: string; file?: DiffFile }

/**
 * The Changes tab is the change list only: one tree grouped by folder.
 * Opening a file shows its diff in that file's own diff tab, focused if open.
 */
export function ChangesView() {
  const mode = useSignal<'session' | 'git'>('git')
  const data = useSignal<GitDiff | null>(null)
  const error = useSignal('')
  const loading = useSignal(false)
  const refresh = useSignal(0)
  const query = useSignal('')
  const rootEl = useRef<HTMLDivElement>(null)
  const list = useRef<HTMLDivElement>(null)
  const cwd = app.value?.inspectorRoot ?? ''
  const lastCwd = useRef(cwd)
  useEffect(() => {
    let live = true
    if (lastCwd.current !== cwd) { lastCwd.current = cwd; data.value = null }
    loading.value = true
    error.value = ''
    // The old list stays up while refreshing so the selection does not jump.
    void rpc<GitDiff>('git.diff', { cwd }).then((result) => {
      if (live) data.value = result
    }).catch((e: Error) => {
      if (live) { data.value = null; error.value = e.message }
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
  const needle = query.value.toLowerCase()
  const groups = new Map<string, Row[]>()
  for (const file of files) {
    const { rel, dir } = splitPath(file.path, cwd)
    if (!rel.toLowerCase().includes(needle)) continue
    groups.set(dir, [...groups.get(dir) ?? [], { path: file.path, file }])
  }
  const untrackedRows: Row[] = untracked.filter((rel) => rel.toLowerCase().includes(needle)).map((rel) => ({ path: joinPath(cwd, rel) }))
  const dirKey = (dir: string) => cwd + '\0' + dir
  const folded = (dir: string) => !!foldedDirs.value[dirKey(dir)]
  const setFolded = (dirs: string[], value: boolean) => {
    const next = { ...foldedDirs.value }
    for (const dir of dirs) next[dirKey(dir)] = value
    foldedDirs.value = next
  }
  const dirs = [...groups.keys()]
  const anyOpen = dirs.some((dir) => !folded(dir))
  // Rows in screen order, skipping folded folders: what ↑/↓ walk.
  const ordered = [...[...groups].flatMap(([dir, rows]) => folded(dir) ? [] : rows), ...untrackedRows]
  const selectionKey = mode.value + '\0' + cwd
  const active = ordered.find((row) => row.path === selections.value[selectionKey]) ?? ordered[0]
  const select = (path: string) => { selections.value = { ...selections.value, [selectionKey]: path } }
  const open = (row: Row) => {
    select(row.path)
    if (row.file) openDiff(row.file)
    else openFile(row.path)
  }
  const reveal = (path: string) => requestAnimationFrame(() => {
    [...list.current?.querySelectorAll<HTMLElement>('.change-row[data-path]') ?? []].find((el) => el.dataset.path === path)?.scrollIntoView?.({ block: 'nearest' })
  })
  const onKeyDown = (e: KeyboardEvent) => {
    if (typing(e.target) || e.metaKey || e.ctrlKey || e.altKey || !ordered.length) return
    const step = e.key === 'ArrowDown' || e.key === 'j' ? 1 : e.key === 'ArrowUp' || e.key === 'k' ? -1 : 0
    if (step) {
      e.preventDefault()
      const at = active ? ordered.indexOf(active) : -1
      const next = ordered[Math.max(0, Math.min(ordered.length - 1, at + step))]
      select(next.path)
      reveal(next.path)
    } else if (e.key === 'Enter' && active) {
      e.preventDefault()
      open(active)
    }
  }

  const pending = mode.value === 'git' && loading.value && !data.value
  const empty = mode.value === 'session' ? t('noSessionEdits') : error.value || (data.value?.repo ? t('cleanTree') : t('notRepo'))
  const count = files.length + untracked.length
  const row = (item: Row) => {
    const { name, rel, dir } = splitPath(item.path, cwd)
    const from = item.file?.oldPath ? splitPath(item.file.oldPath, cwd).rel : ''
    const selected = item.path === active?.path
    return (
      <button key={item.path} data-path={item.path} class={'change-row' + (selected ? ' selected' : '')} aria-selected={selected} role="option"
        title={from ? `${from} → ${rel}` : rel}
        onClick={() => { rootEl.current?.focus({ preventScroll: true }); open(item) }}>
        <StatusBadge status={item.file ? fileStatus(item.file) : 'U'} />
        <Icon name={fileIcon(name)} size={13} class="tree-icon" />
        <span class="change-name">{name}</span>
        {from && <span class="change-from">← {from}</span>}
        {!item.file && dir && <span class="change-from">{dir}</span>}
        <span class="flex1" />
        {item.file && <DiffStat file={item.file} />}
      </button>
    )
  }
  return (
    <div class="changes review" ref={rootEl} tabIndex={-1} onKeyDown={onKeyDown}>
      <div class="review-toolbar">
        <div class="seg" aria-label={t('changes')}>
          <button class={mode.value === 'git' ? 'on' : ''} onClick={() => (mode.value = 'git')}>{t('workingTree')}</button>
          <button class={mode.value === 'session' ? 'on' : ''} onClick={() => (mode.value = 'session')}>{t('sessionEdits')}</button>
        </div>
        {!!count && <span class="review-count">{t('filesChanged', count)}</span>}
        <span class="diffstat"><span class="add">+{added}</span> <span class="del">−{removed}</span></span>
        {mode.value === 'git' && data.value?.branch && <span class="review-branch" title={data.value.branch}><Icon name="branch" size={12} /><span>{data.value.branch}</span></span>}
        <div class="flex1" />
        {!!dirs.length && (
          <button class="icon-btn tiny" title={t(anyOpen ? 'collapseAll' : 'expandAll')} aria-label={t(anyOpen ? 'collapseAll' : 'expandAll')}
            onClick={() => setFolded(dirs, anyOpen)}>
            <Icon name="chevronUpDown" size={12} />
          </button>
        )}
        <button class="icon-btn tiny" title={t('refresh')} onClick={() => refresh.value++}>{loading.value ? <Spinner size={12} /> : <Icon name="refresh" size={12} />}</button>
      </div>
      {pending ? <div class="file-empty"><Spinner size={16} /></div> : count ? <>
        <label class="tree-filter review-filter"><Icon name="search" size={12} /><input placeholder={t('filterFiles')} value={query.value} onInput={(e) => (query.value = e.currentTarget.value)} onKeyDown={(e) => { if (e.key === 'Escape') query.value = '' }} /></label>
        <div class="change-tree" ref={list} role="listbox" aria-label={t('changes')}>
          {[...groups].map(([dir, rows]) => (
            <div key={dir} class={'change-group' + (folded(dir) ? ' folded' : '')}>
              <button class="change-dir" aria-expanded={!folded(dir)} onClick={() => setFolded([dir], !folded(dir))}>
                <Icon name="chevronRight" size={10} class="tree-chev" />
                <Icon name="folder" size={13} class="tree-icon dir" />
                <span class="change-dir-name" title={dir || cwd}>{dir || (cwd.split('/').pop() ?? '/')}</span>
                <span class="review-count">{rows.length}</span>
              </button>
              {!folded(dir) && rows.map(row)}
            </div>
          ))}
          {!!untrackedRows.length && (
            <div class="change-group">
              <div class="change-dir static"><span class="tree-chev-pad" /><span class="change-dir-name">{t('untracked')}</span><span class="review-count">{untrackedRows.length}</span></div>
              {untrackedRows.map(row)}
            </div>
          )}
          {!!needle && !groups.size && !untrackedRows.length && <div class="tree-empty">{t('noMatches')}</div>}
        </div>
      </> : <div class="review-empty"><Icon name="gitDiff" size={27} /><span>{empty}</span></div>}
    </div>
  )
}
