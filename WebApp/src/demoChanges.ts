// Demo-only fixture for the Changes tab (#changes): a real `git diff HEAD -M`
// covering modified, added, deleted, renamed and same-named files.
import type { DiffFile } from './types'

export const DEMO_GIT_DIFF: string = "diff --git a/Aureways/Views/RootView.swift b/Aureways/Views/WebShellRoot.swift\nsimilarity index 100%\nrename from Aureways/Views/RootView.swift\nrename to Aureways/Views/WebShellRoot.swift\ndiff --git a/docs/guide.md b/docs/guide.md\nindex bab081f..3f32aaa 100644\n--- a/docs/guide.md\n+++ b/docs/guide.md\n@@ -1,6 +1,6 @@\n line 1\n line 2\n-line 3\n+line three\n line 4\n line 5\n line 6\n@@ -32,7 +32,7 @@ line 31\n line 32\n line 33\n line 34\n-line 35\n+line thirty-five\n line 36\n line 37\n line 38\ndiff --git a/docs/old-notes.md b/docs/old-notes.md\ndeleted file mode 100644\nindex a000c8f..0000000\n--- a/docs/old-notes.md\n+++ /dev/null\n@@ -1,4 +0,0 @@\n-# Notes\n-\n-Old notes that will be removed.\n-Line two.\ndiff --git a/config.yml b/settings.yml\nsimilarity index 50%\nrename from config.yml\nrename to settings.yml\nindex f4fb2f2..4e399fd 100644\n--- a/config.yml\n+++ b/settings.yml\n@@ -1,2 +1,2 @@\n name: demo\n-version: 1\n+version: 2\ndiff --git a/src/components/Badge.tsx b/src/components/Badge.tsx\nnew file mode 100644\nindex 0000000..6cfc92d\n--- /dev/null\n+++ b/src/components/Badge.tsx\n@@ -0,0 +1,5 @@\n+import { h } from \"preact\"\n+\n+export function Badge() {\n+  return <span class=\"badge\" />\n+}\ndiff --git a/src/components/index.ts b/src/components/index.ts\nindex c1a57be..18b4a2a 100644\n--- a/src/components/index.ts\n+++ b/src/components/index.ts\n@@ -1,5 +1,6 @@\n export const a = 1\n-export const b = 2\n+export const b = 3\n+export const c = 4\n export function sum() {\n-  return a + b\n+  return a + b + c\n }\ndiff --git a/src/inspector/index.ts b/src/inspector/index.ts\nindex e795743..f49319d 100644\n--- a/src/inspector/index.ts\n+++ b/src/inspector/index.ts\n@@ -1,2 +1,3 @@\n export * from \"./Changes\"\n export * from \"./DiffPane\"\n+export * from \"./FileTree\"\ndiff --git a/src/styles.css b/src/styles.css\nindex 44e9953..541b6f7 100644\n--- a/src/styles.css\n+++ b/src/styles.css\n@@ -1,2 +1,3 @@\n-body { color: red; }\n+body { color: var(--text); }\n .a { margin: 0; }\n+.b { padding: 4px; }\n"

export const DEMO_UNTRACKED = ['scratch.txt', 'src/inspector/__snapshots__/Changes.snap']

const root = '/Users/demo/Aureways/'
const PATHS_TS = [
  '/** Workspace-relative helpers for reader links. */',
  'export function fragment(href: string): string {',
  "  const i = href.indexOf('#')",
  "  if (i < 0) return ''",
  '  const raw = href.slice(i + 1)',
  '  try {',
  '    return decodeURIComponent(raw)',
  '  } catch {',
  '    return raw',
  '  }',
  '}',
  '',
  '/** GitHub-style heading slug: lowercase, drop punctuation, spaces become hyphens. */',
  'export function githubSlug(text: string): string {',
  '  return text',
  '    .trim()',
  '    .toLowerCase()',
  "    .replace(/[^\\p{L}\\p{N}\\s_-]/gu, '')",
  "    .replace(/\\s+/g, '-')",
  '}',
  '',
  'export function uniqueId(text: string, used: Map<string, number>): string {',
  "  let id = githubSlug(text) || 'section'",
  '  const n = used.get(id) ?? 0',
  '  used.set(id, n + 1)',
  '  return n ? `${id}-${n}` : id',
  '}',
]
export const DEMO_SESSION_EDITS: DiffFile[] = [
  { path: root + 'WebApp/src/reader/paths.ts', added: PATHS_TS.length, removed: 0, truncated: false, isNew: true, hunks: [{ header: `@@ -0,0 +1,${PATHS_TS.length} @@`, oldStart: 0, newStart: 1, lines: PATHS_TS.map((line) => '+' + line) }] },
  { path: root + 'src/components/index.ts', added: 2, removed: 1, truncated: false, isNew: false, hunks: [{ header: '@@ -1,3 +1,4 @@', oldStart: 1, newStart: 1, lines: [' export const a = 1', '-export const b = 2', '+export const b = 3', '+export const c = 4'] }] },
  { path: root + 'src/inspector/index.ts', added: 1, removed: 0, truncated: false, isNew: false, hunks: [{ header: '@@ -1,2 +1,3 @@', oldStart: 1, newStart: 1, lines: [' export * from "./Changes"', ' export * from "./DiffPane"', '+export * from "./FileTree"'] }] },
  { path: root + 'src/components/Badge.tsx', added: 5, removed: 0, truncated: false, isNew: true, hunks: [{ header: '@@ -0,0 +1,5 @@', oldStart: 0, newStart: 1, lines: ['+import { h } from "preact"', '+', '+export function Badge() {', '+  return <span class="badge" />', '+}'] }] },
]

/** A small project tree for the file navigator in #changes. */
const TREE: Record<string, string[]> = {
  '': ['Aureways/', 'WebApp/', 'docs/', 'Makefile', 'README.md', 'settings.yml'],
  'Aureways': ['Views/', 'WebShell/', 'AurewaysApp.swift'],
  'WebApp': ['src/', 'tests/', 'package.json'],
  'docs': ['guide.md', 'web-shell.md'],
}
export function demoListing(path: string) {
  const rel = path.startsWith(root) ? path.slice(root.length).replace(/\/+$/, '') : path === root.slice(0, -1) ? '' : path
  return (TREE[rel] ?? []).map((name) => {
    const dir = name.endsWith('/')
    const clean = dir ? name.slice(0, -1) : name
    return { name: clean, path: root + (rel ? rel + '/' : '') + clean, dir }
  })
}
