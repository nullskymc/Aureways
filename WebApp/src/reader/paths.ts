// Local links and heading ids for the document reader. Chat markdown does not use this.

const MARKDOWN_EXT = /\.(md|markdown|mdown|mkd|mkdn|mdwn)$/i

export function isMarkdownPath(path: string): boolean {
  return MARKDOWN_EXT.test(path)
}

/** Collapse `.` / `..` and the `/private` prefix macOS adds in front of `/tmp` and `/var`. */
export function canonicalPath(path: string): string {
  const parts: string[] = []
  for (const part of path.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') parts.pop()
    else parts.push(part)
  }
  const abs = '/' + parts.join('/')
  return abs.startsWith('/private/') ? abs.slice('/private'.length) : abs
}

/** Absolute file path for a relative or root-absolute reference. Schemes return null. */
export function localFile(baseFile: string, ref: string): string | null {
  const trimmed = ref.trim()
  if (!trimmed || trimmed.startsWith('#')) return null
  if (/^[a-z][a-z0-9+.-]*:/i.test(trimmed)) return null
  const bare = trimmed.split('#')[0]?.split('?')[0] ?? ''
  if (!bare) return null
  let decoded: string
  try {
    decoded = decodeURI(bare)
  } catch {
    return null
  }
  if (decoded.includes('\0')) return null
  const combined = decoded.startsWith('/') ? decoded : baseFile.slice(0, baseFile.lastIndexOf('/')) + '/' + decoded
  const abs = canonicalPath(combined)
  return abs === '/' ? null : abs
}

export type LinkAction =
  | { type: 'anchor'; id: string }
  | { type: 'markdown'; path: string; hash: string }
  | { type: 'file'; path: string }
  | { type: 'ignore' }

/** null means the link should leave the app (http, https, mailto). */
export function classifyLink(baseFile: string, href: string): LinkAction | null {
  const trimmed = href.trim()
  if (!trimmed || /^(javascript|data|vbscript):/i.test(trimmed)) return { type: 'ignore' }
  if (trimmed.startsWith('#')) {
    let id = trimmed.slice(1)
    try {
      id = decodeURIComponent(id)
    } catch {
      /* keep the raw fragment */
    }
    return id ? { type: 'anchor', id } : { type: 'ignore' }
  }
  if (/^(https?:|mailto:)/i.test(trimmed)) return null
  const hash = fragment(trimmed)
  const path = localFile(baseFile, trimmed)
  if (!path) return { type: 'ignore' }
  if (isMarkdownPath(path)) return { type: 'markdown', path, hash }
  return { type: 'file', path }
}

function fragment(href: string): string {
  const i = href.indexOf('#')
  if (i < 0) return ''
  const raw = href.slice(i + 1)
  try {
    return decodeURIComponent(raw)
  } catch {
    return raw
  }
}

/** Ids to try for a `#fragment`, most specific first. */
export function hashCandidates(hash: string): string[] {
  let decoded = hash
  try {
    decoded = decodeURIComponent(hash)
  } catch {
    /* keep */
  }
  const slug = githubSlug(decoded)
  return [...new Set([decoded, decoded.toLowerCase(), slug].filter((id) => id.length > 0))]
}

/** GitHub-style heading slug: lowercase, drop punctuation, spaces become hyphens. */
export function githubSlug(text: string): string {
  return text
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s_-]/gu, '')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '')
}

export function uniqueId(text: string, used: Map<string, number>): string {
  const base = githubSlug(text) || 'section'
  let n = used.get(base) ?? 0
  let id = n ? `${base}-${n}` : base
  while (used.has(id)) id = `${base}-${++n}`
  used.set(base, n + 1)
  used.set(id, 1)
  return id
}
