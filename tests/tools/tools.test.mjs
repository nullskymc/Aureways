import assert from 'node:assert/strict'
import test from 'node:test'

import { createAurewaysTools } from '../../lib/tools/index.js'

test('工具提供稳定 JSON descriptor，且将输入转交公共 Service 契约', async () => {
  const calls = []
  const tools = createAurewaysTools({
    status() { return { state: 'running', dataDirectory: '/tmp', persistentAgents: 0, runtimeBound: true } },
    createAgent() { throw new Error('not used') }, getAgent() { return undefined }, listAgents() { return [] },
    async submitTask(input) { calls.push(input); return { id: 'tsk_1', agentId: input.agentId, state: 'queued', instruction: input.instruction, revision: 0, createdAt: 1, updatedAt: 1 } },
    getTask() { return undefined }, listTasks() { return [] },
    async cancelTask() { throw new Error('not used') }, async interrupt() { throw new Error('not used') },
  })
  const submit = tools.find((tool) => tool.name === 'aureways_task_submit')
  assert.ok(submit)
  assert.deepEqual(await submit.execute({ agentId: 'agt_1', instruction: '执行' }), {
    ok: true,
    data: { id: 'tsk_1', agentId: 'agt_1', state: 'queued', instruction: '执行', revision: 0, createdAt: 1, updatedAt: 1 },
  })
  assert.deepEqual(calls, [{ agentId: 'agt_1', instruction: '执行' }])
  assert.deepEqual(await submit.execute(['bad']), {
    ok: false, error: { code: 'invalid-request', message: '工具输入必须是 JSON 对象' },
  })
})
