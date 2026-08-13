import assert from 'node:assert/strict'
import test from 'node:test'

import { AgentTaskScheduler } from '../../lib/runtime/scheduler.js'

test('同一 Agent 串行，不同 Agent 可并行', async () => {
  const scheduler = new AgentTaskScheduler({ maxConcurrentAgents: 2 })
  const events = []
  let releaseFirst
  const firstBarrier = new Promise((resolve) => { releaseFirst = resolve })

  const first = scheduler.schedule('agent-a', async () => {
    events.push('a1:start')
    await firstBarrier
    events.push('a1:end')
  })
  const second = scheduler.schedule('agent-a', async () => events.push('a2'))
  const parallel = scheduler.schedule('agent-b', async () => events.push('b1'))

  await parallel
  assert.deepEqual(events, ['a1:start', 'b1'])
  releaseFirst()
  await Promise.all([first, second])
  assert.deepEqual(events, ['a1:start', 'b1', 'a1:end', 'a2'])
})

test('关闭后拒绝未执行任务', async () => {
  const scheduler = new AgentTaskScheduler({ maxConcurrentAgents: 1 })
  let release
  const barrier = new Promise((resolve) => { release = resolve })
  const running = scheduler.schedule('agent-a', () => barrier)
  const pending = scheduler.schedule('agent-a', async () => undefined)
  scheduler.close()
  await assert.rejects(pending, /关闭/)
  release()
  await running
})
