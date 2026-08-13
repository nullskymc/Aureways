import assert from 'node:assert/strict'
import test from 'node:test'
import { DshActivationAdapter } from '../../lib/adapters/dsh.js'

function runtimeAgent(overrides = {}) {
  return {
    agentId: 'agent-1', sessionId: 'session-1', state: 'cold', revision: 1, updatedAt: 1,
    ...overrides,
  }
}

function createFixture({ sessionId = 'session-1', seq = 5 } = {}) {
  const calls = []
  const dshAgent = {
    id: sessionId,
    session: { seq },
    followup(message) { calls.push(['followup', message]) },
    steer(message) { calls.push(['steer', message]) },
    cancel(cause, options) { calls.push(['cancel', cause, options]) },
    async whenIdle() { calls.push(['whenIdle']) },
  }
  const owned = { agent: dshAgent, async dispose() { calls.push(['dispose']) } }
  const adapter = new DshActivationAdapter({
    agents: {
      async create(options) { calls.push(['create', options]); return owned },
      async resume(options) { calls.push(['resume', options]); return owned },
    },
    sessions: { async flush(session) { calls.push(['flush', session]); return true } },
    createUserMessage(input) { calls.push(['message', input]); return { generated: input } },
  })
  return { adapter, calls, dshAgent }
}

test('creates a DSH agent with the runtime session identity and wraps lifecycle operations', async () => {
  const { adapter, calls, dshAgent } = createFixture()
  const handle = await adapter.create(runtimeAgent())

  await handle.followup({ task: 'continue' })
  await handle.steer({ interrupt: 'new input' })
  await handle.cancel({ kind: 'hook', reason: 'urgent interrupt' }, { keepInbox: true })
  await handle.whenIdle()
  assert.equal(await handle.flush(), 4)
  await handle.dispose()

  assert.deepEqual(calls.map(([kind]) => kind), ['create', 'message', 'followup', 'message', 'steer', 'cancel', 'whenIdle', 'flush', 'dispose'])
  assert.deepEqual(calls[0][1], { sessionId: 'session-1' })
  assert.deepEqual(calls[1][1], {
    content: [{ type: 'text', text: '{"task":"continue"}' }],
    source: { kind: 'plugin', plugin: 'aureways', form: 'notice', summary: 'Aureways runtime task' },
  })
  assert.deepEqual(calls[5].slice(1), [{ kind: 'hook', reason: 'urgent interrupt' }, { keepInbox: true }])
  assert.equal(calls[7][1], dshAgent.session)
})

test('resumes the persisted DSH session and permits injected agent options', async () => {
  const { calls } = createFixture()
  const configured = new DshActivationAdapter({
    agents: {
      async create() { throw new Error('unexpected create') },
      async resume(options) { calls.push(['resume', options]); return { agent: { id: 'session-1', session: { seq: 1 }, followup() {}, steer() {}, cancel() {}, async whenIdle() {} }, async dispose() {} } },
    },
    sessions: { async flush() { return true } },
    createUserMessage(input) { return input },
    resumeOptions: () => ({ agentOptions: { model: 'deepseek-chat' } }),
  })

  await configured.resume(runtimeAgent(), undefined)
  assert.deepEqual(calls, [['resume', { resumeSessionId: 'session-1', agentOptions: { model: 'deepseek-chat' } }]])
})

test('rejects a checkpoint or returned DSH handle that belongs to another session', async () => {
  const { adapter } = createFixture()
  await assert.rejects(
    adapter.resume(runtimeAgent(), { checkpointId: 'checkpoint-1', agentId: 'agent-1', sessionId: 'other-session', throughSequence: 1, reason: 'periodic', createdAt: 1 }),
    /不匹配/,
  )

  const mismatch = createFixture({ sessionId: 'other-session' })
  await assert.rejects(mismatch.adapter.create(runtimeAgent()), /不一致/)
})
