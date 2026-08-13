import assert from 'node:assert/strict'
import { existsSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import {
  createActionId,
  createAgentId,
  createRuntimeTaskId,
} from '../../lib/domain/index.js'
import { LeaseConflictError, RevisionConflictError } from '../../lib/domain/errors.js'
import { SqliteAurewaysStore } from '../../lib/store/index.js'

/** 每个测试使用独立文件，验证迁移和锁不会跨测试泄漏。 */
function createStore() {
  const path = join(tmpdir(), `aureways-store-${crypto.randomUUID()}.sqlite`)
  const store = new SqliteAurewaysStore(path)
  store.initialize()
  return {
    store,
    cleanup() {
      store.close()
      if (existsSync(path)) rmSync(path)
      if (existsSync(`${path}-wal`)) rmSync(`${path}-wal`)
      if (existsSync(`${path}-shm`)) rmSync(`${path}-shm`)
    },
  }
}

function agent(state = 'cold') {
  const now = Date.now()
  return {
    id: createAgentId(), revision: 0, createdAt: now, updatedAt: now,
    name: 'store-test', workspace: '/tmp/aureways', state, goal: 'verify persistence', goalRevision: 1,
    sessionId: 'session-store-test', identity: {},
  }
}

test('按状态列出 Agent，并以 CAS 保护生命周期写入', () => {
  const fixture = createStore()
  try {
    const created = fixture.store.createAgent(agent())
    assert.deepEqual(fixture.store.listAgents(['cold']).map((item) => item.id), [created.id])
    const starting = fixture.store.updateAgent({ ...created, state: 'starting' }, created.revision)
    assert.equal(starting.revision, 1)
    assert.throws(() => fixture.store.updateAgent({ ...starting, state: 'idle' }, 0), RevisionConflictError)
    assert.throws(() => fixture.store.updateAgent({ ...starting, state: 'interrupting' }, starting.revision), /Invalid agent state transition/)
  } finally { fixture.cleanup() }
})

test('任务输入、优先级和幂等键在重试时返回原任务', () => {
  const fixture = createStore()
  try {
    const owner = fixture.store.createAgent(agent())
    const now = Date.now()
    const first = fixture.store.createTask({
      id: createRuntimeTaskId(), revision: 0, createdAt: now, updatedAt: now, agentId: owner.id,
      state: 'queued', instruction: 'inspect', input: { path: 'src', recursive: true }, priority: 9, idempotencyKey: 'request-42',
    })
    const second = fixture.store.createTask({ ...first, id: createRuntimeTaskId() })
    assert.equal(second.id, first.id)
    assert.deepEqual(first.input, { path: 'src', recursive: true })
    assert.equal(first.priority, 9)
  } finally { fixture.cleanup() }
})

test('动作查询和租约竞争均以 Agent 为边界', () => {
  const fixture = createStore()
  try {
    const owner = fixture.store.createAgent(agent())
    const now = Date.now()
    const action = fixture.store.createAction({
      id: createActionId(), revision: 0, createdAt: now, updatedAt: now, agentId: owner.id,
      state: 'outcome-unknown', description: 'verify remote side effect', idempotencyKey: 'effect-1',
    })
    assert.deepEqual(fixture.store.listActions(owner.id, ['outcome-unknown']).map((item) => item.id), [action.id])
    const firstLease = fixture.store.acquireLease(owner.id, 'holder-one', 1_000, now)
    assert.throws(() => fixture.store.acquireLease(owner.id, 'holder-two', 1_000, now + 1), LeaseConflictError)
    fixture.store.releaseLease(firstLease)
    assert.equal(fixture.store.acquireLease(owner.id, 'holder-two', 1_000, now + 2).holderId, 'holder-two')
  } finally { fixture.cleanup() }
})
