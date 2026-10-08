import { post } from '../bridge'
import { t } from '../i18n'
import { Icon } from '../components/Icon'
import { mentionFile } from '../components/Composer'
import { app } from '../store'
import type { DiffFile } from '../types'
import { openFile } from './state'
import { emptyBodyKey, fileIcon, fileStatus, splitPath, statusTitleKey, type ChangeStatus } from './diffModel'

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
  return (
    <>
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
      {file.truncated && <div class="diff-note">{t('diffTruncated')}</div>}
    </>
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
