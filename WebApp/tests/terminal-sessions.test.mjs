import assert from 'node:assert/strict'
import { test } from 'node:test'
import { RetainedTerminals } from '../src/inspector/terminalSessions.ts'

function deferred() {
  let resolve, reject
  const promise = new Promise((a, b) => { resolve = a; reject = b })
  return { promise, resolve, reject }
}
function terminal() {
  return { history: ['old output'], scrollTop: 42, disposals: 0, dispose() { this.disposals++ } }
}

test('repeated mounts share one live terminal and close disposes it exactly once', async () => {
  const store = new RetainedTerminals()
  const value = terminal()
  let creates = 0
  const create = async () => { creates++; return value }
  const first = store.get('t', create)
  assert.equal(store.get('t', create), first)
  assert.equal(await first, value)
  const moved = await store.get('t', create)
  assert.equal(moved, value)
  assert.equal(moved.scrollTop, 42)
  assert.deepEqual(moved.history, ['old output'])
  assert.equal(creates, 1)
  assert.equal(value.disposals, 0)
  store.close('t')
  store.close('t')
  assert.equal(value.disposals, 1)
})

test('closing during lazy initialization disposes the late result', async () => {
  const store = new RetainedTerminals()
  const pending = deferred()
  const result = store.get('t', () => pending.promise)
  store.close('t')
  const value = terminal()
  pending.resolve(value)
  assert.equal(await result, undefined)
  assert.equal(value.disposals, 1)
})

test('a closed pending entry cannot replace a newly opened entry', async () => {
  const store = new RetainedTerminals()
  const pending = deferred()
  const oldResult = store.get('t', () => pending.promise)
  store.close('t')
  const current = terminal()
  assert.equal(await store.get('t', async () => current), current)
  const old = terminal()
  pending.resolve(old)
  assert.equal(await oldResult, undefined)
  assert.equal(old.disposals, 1)
  assert.equal(await store.get('t', async () => { throw new Error('must reuse') }), current)
  store.close('t')
})

test('failed lazy initialization can be retried', async () => {
  const store = new RetainedTerminals()
  await assert.rejects(store.get('t', async () => { throw new Error('load failed') }), /load failed/)
  const value = terminal()
  assert.equal(await store.get('t', async () => value), value)
  store.close('t')
})
