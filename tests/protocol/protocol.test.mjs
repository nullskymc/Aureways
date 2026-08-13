import assert from 'node:assert/strict'
import test from 'node:test'

import { A2AAdapter, ACPAdapter } from '../../lib/protocol/index.js'

/** 为协议层提供纯公共方法 Fake，不模拟 Cordis、连接或 AgentHandle。 */
function service() {
  const agents = new Map([['agt_1', {
    id: 'agt_1', name: 'worker', workspace: '/tmp/workspace', state: 'idle', goal: '完成工作', goalRevision: 1,
    revision: 0, createdAt: 1, updatedAt: 1, identity: {},
  }]])
  const tasks = new Map()
  const calls = []
  return {
    calls,
    status() { return { state: 'running', dataDirectory: '/tmp/aureways', persistentAgents: agents.size, runtimeBound: true } },
    createAgent() { throw new Error('not used') },
    getAgent(id) { return agents.get(id) },
    listAgents() { return [...agents.values()] },
    async submitTask(input) {
      calls.push(['submit', input])
      const task = { id: `tsk_${tasks.size + 1}`, agentId: input.agentId, state: 'queued', instruction: input.instruction,
        input: input.input, priority: input.priority, revision: 0, createdAt: 2, updatedAt: 2 }
      tasks.set(task.id, task)
      return task
    },
    getTask(id) { return tasks.get(id) },
    listTasks(id) { return [...tasks.values()].filter((task) => task.agentId === id) },
    async cancelTask(id, reason) {
      calls.push(['cancel', id, reason])
      const old = tasks.get(id)
      if (!old) throw Object.assign(new Error('Task 不存在'), { name: 'NotFound' })
      const next = { ...old, state: 'cancelled', revision: old.revision + 1 }
      tasks.set(id, next)
      return next
    },
    async interrupt(input) {
      calls.push(['interrupt', input])
      return { id: 'int_1', agentId: input.agentId, taskId: input.taskId, state: 'pending', priority: input.priority,
        instruction: input.instruction, source: input.source, revision: 0, createdAt: 3, updatedAt: 3 }
    },
  }
}

test('A2A 映射持久 Task 的 submit/get/list/cancel，连接状态不参与所有权', async () => {
  const fake = service()
  const adapter = new A2AAdapter(fake)
  const submitted = await adapter.dispatch({ method: 'task.submit', params: { agentId: 'agt_1', instruction: '继续工作', input: { value: 1 } } })
  assert.equal(submitted.ok, true)
  assert.equal(submitted.data.id, 'tsk_1')
  const listed = await adapter.dispatch({ method: 'task.list', params: { agentId: 'agt_1' } })
  assert.equal(listed.ok, true)
  assert.equal(listed.data.length, 1)
  const cancelled = await adapter.dispatch({ method: 'task.cancel', params: { taskId: 'tsk_1', reason: '用户取消' } })
  assert.equal(cancelled.ok, true)
  assert.equal(cancelled.data.state, 'cancelled')
  assert.deepEqual(fake.calls[1], ['cancel', 'tsk_1', '用户取消'])
})

test('A2A 对不存在实体与非法输入返回稳定 JSON failure', async () => {
  const adapter = new A2AAdapter(service())
  assert.deepEqual(await adapter.dispatch({ method: 'task.get', params: { taskId: 'tsk_missing' } }), {
    ok: false, error: { code: 'not-found', message: 'Task 不存在' },
  })
  assert.deepEqual(await adapter.dispatch({ method: 'agent.interrupt', params: { agentId: 'agt_1', priority: 'now', instruction: '停止' } }), {
    ok: false, error: { code: 'invalid-request', message: 'priority 必须为 soft 或 urgent' },
  })
})

test('ACP prompt 与 cancel 映射为 Task 操作，不把 sessionId 当作运行时所有者', async () => {
  const fake = service()
  const acp = new ACPAdapter(new A2AAdapter(fake))
  const prompt = await acp.dispatch({ method: 'session/prompt', params: { sessionId: 'client-1', agentId: 'agt_1', prompt: '处理新信息' } })
  assert.equal(prompt.ok, true)
  assert.deepEqual(fake.calls[0], ['submit', { agentId: 'agt_1', instruction: '处理新信息' }])
  const cancellation = await acp.dispatch({ method: 'session/cancel', params: { sessionId: 'client-1', taskId: 'tsk_1' } })
  assert.equal(cancellation.ok, true)
  assert.deepEqual(fake.calls[1], ['cancel', 'tsk_1', undefined])
})
