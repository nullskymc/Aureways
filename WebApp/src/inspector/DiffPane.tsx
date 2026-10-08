import { signal } from '@preact/signals'
import { post } from '../bridge'
import { t } from '../i18n'
import { Icon } from '../components/Icon'
import { mentionFile } from '../components/Composer'
import { app } from '../store'
import type { DiffFile } from '../types'
import { openFile } from './state'
import { emptyBodyKey, fileIcon, fileStatus, splitHunkHeader, splitPath, statusTitleKey, unchangedBefore, type ChangeStatus } from './diffModel'

const WRAP_KEY = 'aureways.diffWrap'
function storedWrap(): boolean {
  try { return globalThis.localStorage?.getItem(WRAP_KEY) !== '0' } catch { return true }
}
/** Soft wrap in diff tabs; on by default, remembered in this web view. */
export const diffWrap = signal(storedWrap())
export function setDiffWrap(on: boolean) {
  diffWrap.value = on
  try { globalThis.localStorage?.setItem(WRAP_KEY, on ? '1' : '0') } catch { /* private mode */ }
}

function trimHunkLines(lines: string[], last: boolean): string[] {
  if (last && lines.length > 1) {
    const tail = lines[lines.length - 1]
    if (tail === '+' || tail === '-') return lines.slice(0, -1)
  }
  return lines
}

export function StatusBadge({ status }: { status: ChangeStatus }) {
  return <span class={'change-badge ' + status.toLowerCase()} title={t(statusTitleKey[status])} aria-label={t(statusTitleKey[status])}>{status}</span>
}

/** Bold file name, dimmed parent folder; a rename shows where it came from. */
export function FileLabel({ file, root }: { file: DiffFile; root: string }) {
  const { rel, name, dir } = splitPath(file.path, root)
  const from = file.oldPath ? splitPath(file.oldPath, root).rel : ''
  return (
    <span class="file-label" title={from ? `${from} → ${rel}` : rel}>
      <Icon name={fileIcon(name)} size={13} class="tree-icon" />
      <span class="file-label-name">{name}</span>
      {dir && <span class="file-label-dir">{dir}</span>}
      {from && <span class="file-label-from">← {from}</span>}
    </span>
  )
}

export function DiffStat({ file }: { file: Pick<DiffFile, 'added' | 'removed'> }) {
  return (
    <span class="diffstat">
      {file.added > 0 && <span class="add">+{file.added}</span>}
      {file.removed > 0 && <span class="del">−{file.removed}</span>}
    </span>
  )
}

/** Pinned header of a diff tab. */
export function DiffFileHead({ file, root }: { file: DiffFile; root: string }) {
  const status = fileStatus(file)
  return (
    <div class="file-head diff-file-head">
      <StatusBadge status={status} />
      <FileLabel file={file} root={root} />
      <DiffStat file={file} />
      <div class="flex1" />
      <span class="diff-actions">
        <button class={'icon-btn tiny' + (diffWrap.value ? ' on' : '')} title={t('wrapLines')} aria-label={t('wrapLines')} aria-pressed={diffWrap.value}
          onClick={() => setDiffWrap(!diffWrap.value)}>
          <Icon name="text" size={12} />
        </button>
        {status !== 'D' && (
          <button class="icon-btn tiny" title={t('edit')} onClick={() => openFile(file.path)}>
            <Icon name="pencil" size={12} />
          </button>
        )}
        <button class="icon-btn tiny" title={t('mention')} onClick={() => mentionFile(file.path, app.peek()?.inspectorRoot ?? '')}>
          <Icon name="at" size={12} />
        </button>
        {status !== 'D' && (
          <button class="icon-btn tiny" title={t('revealInFinder')} onClick={() => post('openPath', { path: file.path })}>
            <Icon name="external" size={12} />
          </button>
        )}
      </span>
    </div>
  )
}

export function DiffHunks({ file }: { file: DiffFile }) {
  if (file.hunks.length === 0) return <div class="diff-note">{t(emptyBodyKey(file))}</div>
  const gaps = unchangedBefore(file.hunks)
  return (
    <div class={'diff-lines' + (diffWrap.value ? ' wrap' : '')}>
      {file.hunks.map((h, i) => {
        let o = h.oldStart
        let n = h.newStart
        const { range, context } = splitHunkHeader(h.header)
        return (
          <div key={i} class="hunk">
            {gaps[i] > 0 && <div class="diff-gap"><span class="diff-sticky"><Icon name="more" size={12} />{t(gaps[i] === 1 ? 'lineUnchanged' : 'linesUnchanged', gaps[i])}</span></div>}
            <div class="hunk-head"><span class="diff-sticky"><span class="hunk-range">{range}</span>{context && <span class="hunk-ctx">{context}</span>}</span></div>
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
      {file.truncated && <div class="diff-note">{t('diffTruncated')}</div>}
    </div>
  )
}

/** A single file's diff in its own tab. */
export function DiffPane({ file }: { file: DiffFile }) {
  const root = app.value?.inspectorRoot ?? ''
  return (
    <div class={'diff-pane status-' + fileStatus(file).toLowerCase()}>
      <DiffFileHead file={file} root={root} />
      <div class="diff-pane-body">
        <DiffHunks file={file} />
      </div>
    </div>
  )
}
