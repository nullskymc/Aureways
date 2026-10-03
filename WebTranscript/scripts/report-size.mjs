// Prints raw + gzip size of the built bundle, split into the eager path
// (what loads for a plain-text answer) and lazy chunks (Shiki theme/grammars).
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'
import { gzipSync } from 'node:zlib'

const root = new URL('../../Aureways/WebTranscriptBundle/', import.meta.url).pathname
const files = []
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) walk(p)
    else files.push(p)
  }
}
walk(root)
const eager = new Set(['index.html', 'assets/main.js', 'assets/style.css'])
let tot = { raw: 0, gz: 0 }, eag = { raw: 0, gz: 0 }
const kb = (n) => (n / 1024).toFixed(1) + ' KB'
for (const f of files.sort()) {
  const buf = readFileSync(f)
  const raw = buf.length, gz = gzipSync(buf, { level: 9 }).length
  const rel = relative(root, f)
  tot.raw += raw; tot.gz += gz
  if (eager.has(rel)) { eag.raw += raw; eag.gz += gz }
}
console.log(`WebTranscriptBundle: ${files.length} files`)
console.log(`  eager (html+main.js+css): ${kb(eag.raw)} raw / ${kb(eag.gz)} gz`)
console.log(`  total on disk:            ${kb(tot.raw)} raw / ${kb(tot.gz)} gz`)
