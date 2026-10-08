import assert from 'node:assert/strict'
import { test } from 'node:test'
import { uniqueId } from '../src/reader/paths.ts'

for (const headings of [
  ['Hello', 'Hello', 'Hello-1'],
  ['Hello-1', 'Hello', 'Hello', 'Hello'],
  ['Hello', 'Hello', 'Hello-1', 'Hello-1', 'Hello'],
  ['!!!', 'section', '!!!', 'section-1'],
  ['安装说明', '安装说明', '安装说明-1'],
]) {
  test(`heading IDs stay unique: ${headings.join(', ')}`, () => {
    const used = new Map()
    const ids = headings.map(heading => uniqueId(heading, used))
    assert.equal(new Set(ids).size, headings.length)
  })
}

test('ordinary duplicate headings keep their familiar suffixes', () => {
  const used = new Map()
  assert.deepEqual(['Hello', 'Hello', 'Hello'].map(h => uniqueId(h, used)), ['hello', 'hello-1', 'hello-2'])
  assert.equal(uniqueId('Hello', new Map()), 'hello')
})
