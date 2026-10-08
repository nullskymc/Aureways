// Bundle TypeScript with the same resolver as Vite, then run Node's test runner.
// All output lives in a temporary directory; no generated tests enter src/.
import { build } from 'esbuild'
import { mkdtemp, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const root = fileURLToPath(new URL('../', import.meta.url))
async function discover(dir) {
  const files = []
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) files.push(...await discover(path))
    else if (/\.test\.(ts|tsx|mjs)$/.test(entry.name)) files.push(path)
  }
  return files.sort()
}
const entries = [...await discover(join(root, 'src')), ...await discover(join(root, 'tests'))]
if (!entries.length) throw new Error('No frontend tests found')
const temp = await mkdtemp(join(tmpdir(), 'aureways-tests-'))
try {
  const outputs = []
  for (const [index, entry] of entries.entries()) {
    const outfile = join(temp, `${index}.test.mjs`)
    await build({
      absWorkingDir: root,
      entryPoints: [entry], outfile, bundle: true, platform: 'node', format: 'esm', target: 'node22',
      loader: { '.css': 'empty', '.svg': 'text' },
      banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" },
      // Component tests exercise real Preact/DOM lifecycles without a canvas or PTY.
      plugins: /(?:terminal|workbench|changes)-view\.test\.mjs$/.test(entry) ? [{
        name: 'test-xterm',
        setup(build) {
          build.onResolve({ filter: /^@xterm\/(xterm|addon-fit)$/ }, () => ({
            path: resolve(root, 'tests/fixtures/xterm.mjs'),
          }))
        },
      }] : [],
    })
    outputs.push(outfile)
  }
  const result = spawnSync(process.execPath, ['--test', ...outputs], { stdio: 'inherit' })
  if (result.error) throw result.error
  process.exitCode = result.status ?? 1
} finally {
  await rm(temp, { recursive: true, force: true })
}
