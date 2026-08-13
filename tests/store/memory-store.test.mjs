import assert from 'node:assert/strict'
import { existsSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { createAgentId, createEpisodicMemoryId } from '../../lib/domain/index.js'
import { SqliteAurewaysStore } from '../../lib/store/index.js'

test('FTS 可召回较旧记忆，并在失效和数据库重开后保持一致', () => {
  const path = join(tmpdir(), `aureways-memory-${crypto.randomUUID()}.sqlite`)
  const agentId = createAgentId()
  let store = new SqliteAurewaysStore(path)
  store.initialize()
  const old = store.createMemory(memory(agentId, '外部副作用前必须 checkpoint', ['durability'], 1))
  for (let index = 0; index < 30; index += 1) {
    store.createMemory(memory(agentId, `无关的近期记录 ${index}`, ['recent'], 100 + index))
  }
  assert.deepEqual(store.searchMemories({ agentId, query: 'checkpoint', limit: 5 }).map((item) => item.id), [old.id])

  const invalid = store.updateMemory({ ...old, validUntil: Date.now() - 1 }, old.revision)
  assert.equal(invalid.revision, 1)
  assert.deepEqual(store.searchMemories({ agentId, query: 'checkpoint' }), [])
  store.close()

  store = new SqliteAurewaysStore(path)
  store.initialize()
  assert.equal(store.searchMemories({ agentId, query: 'recent', kinds: ['observation'], limit: 50 }).length, 30)
  store.close()
  for (const suffix of ['', '-wal', '-shm']) if (existsSync(`${path}${suffix}`)) rmSync(`${path}${suffix}`)
})

function memory(agentId, content, tags, updatedAt) {
  return {
    id: createEpisodicMemoryId(), agentId, revision: 0, createdAt: updatedAt, updatedAt,
    kind: 'observation', content, sourceEventIds: [], confidence: 0.8, validFrom: updatedAt, tags,
  }
}
