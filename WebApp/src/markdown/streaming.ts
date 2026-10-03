// Streaming helpers: make a partial Markdown snapshot render like its
// eventual final form instead of flashing raw syntax.

/** Close an unterminated fence, then unbalanced `code` / **bold** on the last line. */
export function patchStreamingTail(src: string): string {
  let fence: string | null = null
  for (const line of src.split('\n')) {
    const m = /^ {0,3}(`{3,}|~{3,})/.exec(line)
    if (!m) continue
    const marker = m[1]
    if (fence === null) fence = marker
    else if (marker[0] === fence[0] && marker.length >= fence.length && line.trim() === marker) fence = null
  }
  if (fence !== null) return src + (src.endsWith('\n') ? '' : '\n') + fence

  const line = src.slice(src.lastIndexOf('\n') + 1)
  let patch = ''
  const ticks = (line.match(/`/g) ?? []).length
  if (ticks % 2 === 1) patch += '`'
  const outsideCode = (line + patch).replace(/`[^`]*`/g, '')
  if (((outsideCode.match(/\*\*/g) ?? []).length) % 2 === 1) patch += '**'
  // A dangling "[label](" would render as text; hide the half-typed link target.
  if (/\[[^\]]*\]\([^)]*$/.test(line)) return src.replace(/\]\([^)]*$/, ']') + patch
  return src + patch
}

/** Cheap 32-bit FNV-1a, used for highlight cache keys. */
export function hash(s: string): string {
  let h = 0x811c9dc5
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = Math.imul(h, 0x01000193)
  }
  return (h >>> 0).toString(36) + ':' + s.length
}
