import assert from 'node:assert/strict'
import test from 'node:test'

import { CheckpointCoordinator } from '../../lib/runtime/checkpoint.js'
import { InterruptController } from '../../lib/runtime/interrupt.js'
import { RecoveryCoordinator } from '../../lib/runtime/recovery.js'
import { ActivationSupervisor } from '../../lib/runtime/supervisor.js'

const json = Object.freeze({ message: 'event' })

/** 为 Runtime 端口提供最小、可观察的内存实现。 */
class FakeStore {
  agents = new Map()
  interrupts = new Map()
  actions = new Map()
  checkpoints = []
  transitions = []

  async getAgent(id) { return this.agents.get(id) }
  async listRunnableTasks() { return [] }
  async listRequestedInterrupts(agentId) {
    return [...this.interrupts.values()]
      .filter((item) => item.agentId === agentId && item.state === 'requested')
      .sort((a, b) => b.priority - a.priority)
  }
  async listAgentsInStates(states) { return [...this.agents.values()].filter((agent) => states.includes(agent.state)) }
  async listUncertainActions(agentId) {
    return [...this.actions.values()].filter((action) => action.agentId === agentId && ['dispatched', 'acknowledged', 'outcome-unknown'].includes(action.state))
  }
  async getLatestCheckpoint(agentId) { return [...this.checkpoints].reverse().find((item) => item.agentId === agentId) }
  async transitionAgent(id, expectedRevision, state) {
    const old = this.agents.get(id)
    assert.equal(old.revision, expectedRevision)
    const next = { ...old, state, revision: old.revision + 1, updatedAt: old.updatedAt + 1 }
    this.agents.set(id, next)
    this.transitions.push(['agent', id, state])
    return next
  }
  async transitionTask() { throw new Error('该测试不调度 Task') }
  async transitionInterrupt(id, expectedRevision, state) {
    const old = this.interrupts.get(id)
    assert.equal(old.revision, expectedRevision)
    const next = { ...old, state, revision: old.revision + 1 }
    this.interrupts.set(id, next)
    this.transitions.push(['interrupt', id, state])
    return next
  }
  async transitionAction(id, expectedRevision, state) {
    const old = this.actions.get(id)
    assert.equal(old.revision, expectedRevision)
    const next = { ...old, state, revision: old.revision + 1, updatedAt: old.updatedAt + 1 }
    this.actions.set(id, next)
    this.transitions.push(['action', id, state])
    return next
  }
  async createCheckpoint(input) {
    const checkpoint = { ...input, checkpointId: `checkpoint-${this.checkpoints.length + 1}`, createdAt: 10 }
    this.checkpoints.push(checkpoint)
    return checkpoint
  }
}

class FakeHandle {
  constructor(agentId, events) { this.agentId = agentId; this.sessionId = `session-${agentId}`; this.events = events }
  async followup() { this.events.push('followup') }
  async steer() { this.events.push('steer') }
  async cancel(cause) { this.events.push(`cancel:${cause.reason}`) }
  async whenIdle() { this.events.push('whenIdle') }
  async flush() { this.events.push('flush'); return 42 }
  async dispose() { this.events.push('dispose') }
}

function agent(id, state = 'idle', revision = 1) {
  return { agentId: id, sessionId: `session-${id}`, state, revision, updatedAt: 1 }
}

function interrupt(id, agentId, mode) {
  return { interruptId: id, agentId, mode, state: 'requested', priority: 1, payload: json, revision: 1, requestedAt: 1 }
}

function setupSupervisor(store, events, options = {}) {
  const coordinator = new CheckpointCoordinator(store)
  const adapter = {
    async create(value) { events.push(`create:${value.agentId}`); return new FakeHandle(value.agentId, events) },
    async resume(value) { events.push(`resume:${value.agentId}`); return new FakeHandle(value.agentId, events) },
  }
  return {
    coordinator,
    supervisor: new ActivationSupervisor(store, adapter, coordinator, {
      ownerId: 'test-owner', idleUnloadMs: 100, leaseDurationMs: 1000, ...options,
    }),
  }
}

test('soft interrupt 只在安全点 replan，不发送 cancel', async () => {
  const store = new FakeStore()
  const events = []
  const current = agent('a', 'idle')
  store.agents.set(current.agentId, current)
  const pending = interrupt('soft-1', current.agentId, 'soft')
  store.interrupts.set(pending.interruptId, pending)
  const { coordinator, supervisor } = setupSupervisor(store, events)
  const controller = new InterruptController(store, supervisor, coordinator, {
    async requestDecision() { events.push('replan'); return 'resume' },
  })

  await controller.request(current, pending)
  assert.deepEqual(events, [])
  assert.equal(await controller.settleAtSafePoint(current), 'resume')
  assert.deepEqual(events, ['create:a', 'flush', 'replan'])
  assert.equal(store.interrupts.get('soft-1').state, 'resolved')
  assert.equal(store.agents.get('a').state, 'idle')
})

test('urgent interrupt 立即请求 cancel，并在 idle 与 flush 后 replan', async () => {
  const store = new FakeStore()
  const events = []
  const current = agent('a', 'running')
  store.agents.set(current.agentId, current)
  const pending = interrupt('urgent-1', current.agentId, 'urgent')
  store.interrupts.set(pending.interruptId, pending)
  const { coordinator, supervisor } = setupSupervisor(store, events)
  const live = await supervisor.wake(current)
  events.length = 0
  const controller = new InterruptController(store, supervisor, coordinator, {
    async requestDecision() { events.push('replan'); return 'pause' },
  })

  await controller.request(current, pending)
  assert.deepEqual(events, ['cancel:aureways-interrupt:urgent-1'])
  assert.equal(await controller.settleAtSafePoint(current), 'pause')
  assert.deepEqual(events, ['cancel:aureways-interrupt:urgent-1', 'whenIdle', 'flush', 'replan'])
  assert.equal(store.agents.get('a').state, 'paused')
  assert.equal(live.agentId, 'a')
})

test('idle Agent sleep 前 flush checkpoint，随后 dispose 并进入 cold', async () => {
  const store = new FakeStore()
  const events = []
  const current = agent('a', 'idle')
  store.agents.set(current.agentId, current)
  const { supervisor } = setupSupervisor(store, events)
  await supervisor.wake(current)
  events.length = 0

  await supervisor.sleep('a')
  assert.deepEqual(events, ['flush', 'dispose'])
  assert.equal(store.checkpoints[0].reason, 'idle-unload')
  assert.equal(store.agents.get('a').state, 'cold')
  assert.equal(supervisor.getLive('a'), undefined)
})

test('recovery 对未知副作用标记 outcome-unknown 并暂停 Agent', async () => {
  const store = new FakeStore()
  store.agents.set('a', agent('a', 'running'))
  store.actions.set('action-1', {
    actionId: 'action-1', agentId: 'a', taskId: undefined, state: 'dispatched',
    idempotencyKey: undefined, revision: 1, updatedAt: 1,
  })
  const recovery = new RecoveryCoordinator(store, { async verify() { return 'unknown' } })

  const report = await recovery.recover()
  assert.deepEqual(report, { recoveredAgentIds: [], pausedAgentIds: ['a'] })
  assert.equal(store.actions.get('action-1').state, 'outcome-unknown')
  assert.equal(store.agents.get('a').state, 'paused')
})
