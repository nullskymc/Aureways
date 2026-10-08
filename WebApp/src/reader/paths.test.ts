import { canonicalPath, classifyLink, githubSlug, localFile, uniqueId } from './paths'

function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg)
}

assert(githubSlug('Hello, World!') === 'hello-world', 'slug')
assert(githubSlug('安装说明') === '安装说明', 'cjk')
assert(githubSlug('Foo / Bar') === 'foo-bar', 'slash')

assert(localFile('/repo/README.md', './docs/a.md') === '/repo/docs/a.md', 'rel')
assert(localFile('/repo/docs/a.md', '../README.md') === '/repo/README.md', 'parent')
assert(localFile('/repo/README.md', 'https://example.com') === null, 'http')
assert(localFile('/repo/README.md', '/abs/pic.png') === '/abs/pic.png', 'abs')
assert(localFile('/repo/README.md', 'javascript:alert(1)') === null, 'js file')

const md = classifyLink('/repo/README.md', './docs/a.md#Install')
assert(md?.type === 'markdown' && md.path === '/repo/docs/a.md' && md.hash === 'Install', 'md link')

const anchor = classifyLink('/repo/README.md', '#hello-world')
assert(anchor?.type === 'anchor' && anchor.id === 'hello-world', 'anchor')

assert(classifyLink('/repo/README.md', 'https://example.com') === null, 'external')
assert(classifyLink('/repo/README.md', 'mailto:a@b.c') === null, 'mailto')

const img = classifyLink('/repo/README.md', './pic.png')
assert(img?.type === 'file' && img.path === '/repo/pic.png', 'file')

const js = classifyLink('/repo/README.md', 'javascript:alert(1)')
assert(js?.type === 'ignore', 'js')

assert(canonicalPath('/private/tmp/a.md') === '/tmp/a.md', 'private')
assert(canonicalPath('/repo/docs/../README.md') === '/repo/README.md', 'dotdot')

const used = new Map<string, number>()
assert(uniqueId('Hello', used) === 'hello', 'id1')
assert(uniqueId('Hello', used) === 'hello-1', 'id2')
assert(uniqueId('!!!', used) === 'section', 'empty')

console.log('paths ok')
