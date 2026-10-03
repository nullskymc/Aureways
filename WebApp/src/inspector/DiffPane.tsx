import { post } from '../bridge'
import { t } from '../i18n'
import { Icon } from '../components/Icon'
import { mentionFile } from '../components/Composer'
import { displayPath } from '../components/Blocks'
import { app } from '../store'
import type { DiffFile } from '../types'
import { openFile } from './state'

function trimHunkLines(lines: string[], last: boolean): string[] {
  if (last && lines.length > 1) {
    const tail = lines[lines.length - 1]
    if (tail === '+' || tail === '-') return lines.slice(0, -1)
  }
  return lines
}

export function DiffPane({ file }: { file: DiffFile }) {
  return (
    <div class="diff-pane">
      <div class="file-head">
        <Icon name="gitDiff" size={13} class="tree-icon" />
        <span class="file-path" title={file.path}>{displayPath(file.path)}</span>
        {file.isNew && <span class="diff-tag">{t('newFile')}</span>}
        <span class="diffstat">
          <span class="add">+{file.added}</span> <span class="del">−{file.removed}</span>
        </span>
        <div class="flex1" />
        <button class="icon-btn tiny" title={t('edit')} onClick={() => openFile(file.path)}>
          <Icon name="pencil" size={12} />
        </button>
        <button class="icon-btn tiny" title={t('mention')} onClick={() => mentionFile(file.path, app.peek()?.inspectorRoot ?? '')}>
          <Icon name="at" size={12} />
        </button>
        <button class="icon-btn tiny" title={t('revealInFinder')} onClick={() => post('openPath', { path: file.path })}>
          <Icon name="external" size={12} />
        </button>
      </div>
      <div class="diff-pane-body">
        {file.hunks.length === 0 ? (
          <div class="changes-empty">{file.isNew ? t('newFile') : t('cleanTree')}</div>
        ) : (
          file.hunks.map((h, i) => {
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
          })
        )}
        {file.truncated && <div class="hunk-head">…</div>}
      </div>
    </div>
  )
}
