// Shiki core + JS regex engine (no WASM). Theme and grammars are separate
// lazy chunks: nothing Shiki-related loads until the first finished code block.
import type { HighlighterCore } from '@shikijs/core'
import { hash } from './streaming'

type Loader = () => Promise<{ default: unknown }>
const GRAMMARS: Record<string, Loader> = {
  bash: () => import('@shikijs/langs/shellscript'),
  swift: () => import('@shikijs/langs/swift'),
  typescript: () => import('@shikijs/langs/typescript'),
  tsx: () => import('@shikijs/langs/tsx'),
  json: () => import('@shikijs/langs/json'),
  python: () => import('@shikijs/langs/python'),
  rust: () => import('@shikijs/langs/rust'),
  go: () => import('@shikijs/langs/go'),
  html: () => import('@shikijs/langs/html'),
  css: () => import('@shikijs/langs/css'),
  yaml: () => import('@shikijs/langs/yaml'),
  toml: () => import('@shikijs/langs/toml'),
  diff: () => import('@shikijs/langs/diff'),
  sql: () => import('@shikijs/langs/sql'),
  c: () => import('@shikijs/langs/c'),
  java: () => import('@shikijs/langs/java'),
  kotlin: () => import('@shikijs/langs/kotlin'),
  xml: () => import('@shikijs/langs/xml'),
  markdown: () => import('@shikijs/langs/markdown'),
}
const ALIASES: Record<string, string> = {
  sh: 'bash', shell: 'bash', zsh: 'bash', shellscript: 'bash', console: 'bash',
  // JS/JSX reuse the TS/TSX grammars (~180 KB each); C++ maps to C (the cpp
  // grammar alone is ~640 KB). Size over perfect fidelity.
  ts: 'typescript', js: 'typescript', javascript: 'typescript', mjs: 'typescript', cjs: 'typescript', jsx: 'tsx',
  py: 'python', rs: 'rust', golang: 'go', yml: 'yaml', md: 'markdown',
  cpp: 'c', 'c++': 'c', cc: 'c', hpp: 'c', objc: 'c', 'objective-c': 'c', h: 'c', kt: 'kotlin', htm: 'html',
  jsonc: 'json', patch: 'diff', plist: 'xml', svg: 'xml',
}

export function canonicalLang(lang: string | undefined): string | null {
  if (!lang) return null
  const l = lang.trim().toLowerCase().split(/\s+/)[0]
  const c = ALIASES[l] ?? l
  return c in GRAMMARS ? c : null
}

let highlighter: Promise<HighlighterCore> | null = null
const loaded = new Map<string, Promise<void>>()
const cache = new Map<string, string>()

function getHighlighter() {
  highlighter ??= (async () => {
    const [{ createHighlighterCore }, { createJavaScriptRegexEngine }] = await Promise.all([
      import('@shikijs/core'),
      import('@shikijs/engine-javascript'),
    ])
    return createHighlighterCore({
      themes: [import('@shikijs/themes/github-light'), import('@shikijs/themes/github-dark')],
      langs: [],
      engine: createJavaScriptRegexEngine({ forgiving: true }),
    })
  })()
  return highlighter
}

/** Returns `<span>` lines for the code (inner HTML of <code>), or null if unsupported. */
export async function highlight(code: string, lang: string): Promise<string | null> {
  const canonical = canonicalLang(lang)
  if (!canonical) return null
  const key = canonical + '|' + hash(code)
  const hit = cache.get(key)
  if (hit !== undefined) return hit
  const hl = await getHighlighter()
  if (!loaded.has(canonical)) {
    loaded.set(canonical, GRAMMARS[canonical]().then((m) => hl.loadLanguage(m.default as never)))
  }
  await loaded.get(canonical)
  const shikiName = canonical === 'bash' ? 'shellscript' : canonical
  // Keep our own <pre><code> chrome; take only the <code> children.
  const html = hl.codeToHtml(code, {
    lang: shikiName,
    themes: { light: 'github-light', dark: 'github-dark' },
    defaultColor: false,
  })
  const inner = /<code>([\s\S]*)<\/code>/.exec(html)?.[1] ?? null
  if (inner !== null) {
    if (cache.size > 400) cache.clear()
    cache.set(key, inner)
  }
  return inner
}
