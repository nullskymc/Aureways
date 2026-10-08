import assert from 'node:assert/strict'
import { test } from 'node:test'
import { DEMO_GIT_DIFF, DEMO_SESSION_EDITS } from '../src/demoChanges.ts'
import { splitHunkHeader, unchangedBefore, emptyBodyKey, fileIcon, fileStatus, parseUnifiedDiff, splitPath, withLineOffset } from '../src/inspector/diffModel.ts'

const root = '/repo'
const files = parseUnifiedDiff(DEMO_GIT_DIFF, root)
const byPath = (rel) => files.find(file => file.path === root + '/' + rel)

test('git diff parser classifies every kind of change', () => {
  assert.deepEqual(files.map(file => [splitPath(file.path, root).rel, fileStatus(file)]), [
    ['Aureways/Views/WebShellRoot.swift', 'R'],
    ['docs/guide.md', 'M'],
    ['docs/old-notes.md', 'D'],
    ['settings.yml', 'R'],
    ['src/components/Badge.tsx', 'A'],
    ['src/components/Sidebar.tsx', 'M'],
    ['src/components/index.ts', 'M'],
    ['src/inspector/index.ts', 'M'],
    ['src/styles.css', 'M'],
  ])
  assert.equal(byPath('Aureways/Views/WebShellRoot.swift')?.oldPath, '/repo/Aureways/Views/RootView.swift')
  assert.equal(byPath('Aureways/Views/WebShellRoot.swift')?.hunks.length, 0)
  assert.equal(byPath('settings.yml')?.oldPath, '/repo/config.yml')
  assert.deepEqual([byPath('settings.yml')?.added, byPath('settings.yml')?.removed], [1, 1])
  assert.deepEqual([byPath('docs/old-notes.md')?.added, byPath('docs/old-notes.md')?.removed], [0, 4])
  assert.equal(byPath('docs/guide.md')?.hunks.length, 2)
  assert.ok(byPath('src/components/Badge.tsx')?.isNew)
})

test('binary changes are flagged instead of looking clean', () => {
  const [file] = parseUnifiedDiff('diff --git a/icon.png b/icon.png\nindex 1..2 100644\nBinary files a/icon.png and b/icon.png differ\n', root)
  assert.equal(file.binary, true)
  assert.equal(emptyBodyKey(file), 'binaryFile')
})

test('same-named files are told apart by their parent folder', () => {
  const labels = files.filter(file => file.path.endsWith('/index.ts')).map(file => splitPath(file.path, root))
  assert.deepEqual(labels.map(({ name, dir }) => [name, dir]), [['index.ts', 'src/components'], ['index.ts', 'src/inspector']])
  assert.deepEqual(splitPath('/repo/README.md', root), { rel: 'README.md', name: 'README.md', dir: '' })
  assert.deepEqual(splitPath('/elsewhere/a/b.ts', root), { rel: '/elsewhere/a/b.ts', name: 'b.ts', dir: '/elsewhere/a' })
})

test('empty bodies explain renames', () => {
  assert.equal(emptyBodyKey(byPath('Aureways/Views/WebShellRoot.swift')), 'renamedOnly')
})

test('file icons follow the file type', () => {
  assert.deepEqual(['a.swift', 'b.md', 'c.png', 'Makefile'].map(fileIcon), ['code', 'text', 'image', 'file'])
})

test('hunk headers split into range and context; skipped lines are counted between hunks', () => {
  const sidebar = byPath('src/components/Sidebar.tsx')
  assert.deepEqual(sidebar.hunks.map(h => splitHunkHeader(h.header)), [
    { range: '@@ -3,12 +3,13 @@', context: "import { t } from '../i18n'" },
    { range: '@@ -67,5 +68,5 @@', context: 'function SessionRow({ s, selected }: { s: Session; selected: boolean }) {' },
  ])
  assert.deepEqual(unchangedBefore(sidebar.hunks), [2, 52])
  assert.deepEqual(unchangedBefore(byPath('docs/guide.md').hunks), [0, 25])
  assert.deepEqual(unchangedBefore(byPath('src/components/Badge.tsx').hunks), [0])
  // Separate chat edits whose snippets each start at line 1 never show a negative gap.
  const h = (oldStart, lines) => ({ header: '@@', oldStart, newStart: oldStart, lines })
  assert.deepEqual(unchangedBefore([h(1, [' a', '-b', '+c']), h(1, [' x'])]), [0, 0])
  assert.deepEqual(splitHunkHeader('not a header'), { range: 'not a header', context: '' })
})

test('chat edits move to whole-file line numbers with their native lineOffset', () => {
  const edit = { path: '/r/a.ts', added: 1, removed: 1, truncated: false, isNew: false, lineOffset: 41,
    hunks: [{ header: '@@ -1,3 +1,3 @@ fn', oldStart: 1, newStart: 1, lines: [' a', '-b', '+B', ' c'] }] }
  const shifted = withLineOffset(edit)
  assert.equal(shifted.hunks[0].header, '@@ -42,3 +42,3 @@ fn')
  assert.equal(shifted.hunks[0].oldStart, 42)
  assert.equal(shifted.hunks[0].newStart, 42)
  assert.equal(shifted.lineOffset, undefined, 'applied once')
  assert.equal(edit.hunks[0].oldStart, 1, 'input is not mutated')
  // Not located (or new file): snippet-relative numbers are kept as they are.
  const plain = { ...edit, lineOffset: undefined }
  assert.equal(withLineOffset(plain), plain)
  assert.equal(withLineOffset({ ...edit, lineOffset: 0 }).hunks[0].header, '@@ -1,3 +1,3 @@ fn')
  assert.equal(withLineOffset({ ...edit, hunks: [{ header: '@@ -1 +1 @@', oldStart: 1, newStart: 1, lines: ['-b', '+B'] }] }).hunks[0].header, '@@ -42 +42 @@')

  const located = DEMO_SESSION_EDITS.filter(f => f.path.endsWith('/src/inspector/state.ts')).map(withLineOffset)
  assert.deepEqual(located.map(f => f.hunks[0].header), ['@@ -42,5 +42,6 @@', '@@ -118,4 +118,4 @@'])
})
