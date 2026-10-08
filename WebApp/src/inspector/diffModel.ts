// Pure helpers behind the Changes tab: parse `git diff`, classify each file and
// decide how it is presented. Kept free of Preact so it can be unit tested.
import type { DiffFile } from '../types'

export type ChangeStatus = 'M' | 'A' | 'D' | 'R' | 'U'

export const joinPath = (root: string, rel: string) => (rel.startsWith('/') || !root ? rel : root.replace(/\/+$/, '') + '/' + rel)

/** Minimal `git diff` parser → DiffFile[] (paths made absolute against cwd). */
export function parseUnifiedDiff(text: string, cwd: string): DiffFile[] {
  const files: DiffFile[] = []
  let file: DiffFile | null = null
  let hunk: DiffFile['hunks'][number] | null = null
  for (const line of text.split('\n')) {
    if (line.startsWith('diff --git ')) {
      const m = / b\/(.*)$/.exec(line)
      file = { path: joinPath(cwd, m?.[1] ?? ''), added: 0, removed: 0, truncated: false, isNew: false, hunks: [], status: 'M' }
      files.push(file)
      hunk = null
    } else if (!file) continue
    else if (hunk && (line[0] === '+' || line[0] === '-' || line[0] === ' ')) {
      if (hunk.lines.length > 2000) {
        file.truncated = true
        continue
      }
      hunk.lines.push(line)
      if (line[0] === '+') file.added++
      else if (line[0] === '-') file.removed++
    } else if (line.startsWith('new file mode')) {
      file.isNew = true
      file.status = 'A'
    } else if (line.startsWith('deleted file mode')) file.status = 'D'
    else if (line.startsWith('rename from ')) {
      file.oldPath = joinPath(cwd, line.slice(12))
      file.status = 'R'
    } else if (line.startsWith('rename to ')) file.path = joinPath(cwd, line.slice(10))
    else if (line.startsWith('Binary files ')) file.binary = true
    else if (line.startsWith('+++ b/')) file.path = joinPath(cwd, line.slice(6))
    else if (line.startsWith('@@')) {
      const m = /@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)/.exec(line)
      hunk = { header: line, oldStart: Number(m?.[1] ?? 1), newStart: Number(m?.[2] ?? 1), lines: [] }
      file.hunks.push(hunk)
    }
  }
  return files
}

export function fileStatus(file: DiffFile): ChangeStatus {
  return file.status ?? (file.isNew ? 'A' : 'M')
}

/** Workspace-relative path split into the bold name and the dimmed parent folder. */
export function splitPath(path: string, root: string): { rel: string; name: string; dir: string } {
  const base = root.replace(/\/+$/, '')
  const rel = base && path.startsWith(base + '/') ? path.slice(base.length + 1) : path
  const at = rel.lastIndexOf('/')
  return { rel, name: rel.slice(at + 1), dir: at > 0 ? rel.slice(0, at) : '' }
}

/** Text shown in place of hunks when a file has none. */
export function emptyBodyKey(file: DiffFile): string {
  if (file.binary) return 'binaryFile'
  const status = fileStatus(file)
  if (status === 'R') return 'renamedOnly'
  if (status === 'A') return 'emptyNewFile'
  if (status === 'D') return 'deletedFile'
  return 'noTextChanges'
}

export const statusTitleKey: Record<ChangeStatus, string> = {
  M: 'statusModified', A: 'statusAdded', D: 'statusDeleted', R: 'statusRenamed', U: 'untracked',
}

const CODE = /\.(tsx?|jsx?|mjs|cjs|swift|m|mm|h|c|cc|cpp|rs|go|py|rb|java|kt|sh|zsh|css|scss|html?|json|ya?ml|toml|xml|plist|sql)$/i
const TEXT = /\.(md|markdown|txt|rst|log|csv)$/i
const IMAGE = /\.(png|jpe?g|gif|webp|svg|ico|icns|heic|pdf)$/i
export function fileIcon(name: string): string {
  if (IMAGE.test(name)) return 'image'
  if (TEXT.test(name)) return 'text'
  if (CODE.test(name)) return 'code'
  return 'file'
}

/** Merges the edits a chat made to the same path into one reviewable file. */
export function mergeSessionEdits(lists: DiffFile[][]): DiffFile[] {
  const files = new Map<string, DiffFile>()
  for (const list of lists) for (const file of list) {
    const prev = files.get(file.path)
    files.set(file.path, prev ? {
      ...file, isNew: prev.isNew || file.isNew,
      added: prev.added + file.added, removed: prev.removed + file.removed,
      hunks: [...prev.hunks, ...file.hunks], truncated: prev.truncated || file.truncated,
    } : file)
  }
  return [...files.values()]
}

/** `@@ -a,b +c,d @@ context` → the range part and the enclosing function/context text. */
export function splitHunkHeader(header: string): { range: string; context: string } {
  const m = /^(@@ [^@]*@@)\s?(.*)$/.exec(header)
  return m ? { range: m[1], context: m[2].trim() } : { range: header, context: '' }
}

/**
 * Unchanged lines skipped before each hunk (old-file numbering). Unknown or
 * overlapping ranges (e.g. separate edits merged from a chat) count as 0.
 */
export function unchangedBefore(hunks: DiffFile['hunks']): number[] {
  let end = 1
  return hunks.map((hunk, i) => {
    const gap = hunk.oldStart > 0 ? hunk.oldStart - end : 0
    end = hunk.oldStart + hunk.lines.filter((line) => line[0] !== '+').length
    if (hunk.oldStart === 0) end = 1
    return i === 0 && hunk.oldStart <= 1 ? 0 : Math.max(0, gap)
  })
}
