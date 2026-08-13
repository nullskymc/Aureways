import assert from 'node:assert/strict'
import { existsSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { Context } from '@deepseek-ai/cordis'

import { AurewaysService } from '../lib/service.js'

test('Cordis Service 装配 Store 与 Always Loop，并在插件卸载时清理', async () => {
  const dataDirectory = join(tmpdir(), `aureways-service-${crypto.randomUUID()}`)
  const ctx = new Context()
  const fiber = ctx.plugin(AurewaysService, {
    dataDirectory,
    idleUnloadMs: 60_000,
    maxLiveAgents: 2,
    maxEphemeralTasks: 2,
    leaseDurationMs: 30_000,
    checkpointEveryTurns: 4,
    interruptDecisionTimeoutMs: 60_000,
    recoveryPolicy: 'pause-on-uncertain',
    runtimeId: 'service-test',
  })
  await fiber

  const events = []
  await ctx.aureways.bindRuntime({
    activation: {
      async create(agent) { events.push(`create:${agent.agentId}`); return handle(agent, events) },
      async resume(agent) { events.push(`resume:${agent.agentId}`); return handle(agent, events) },
    },
    replan: { async requestDecision() { return 'resume' } },
  })

  const agent = ctx.aureways.createAgent({
    name: 'long-running-worker',
    workspace: '/tmp/aureways-workspace',
    goal: '持续完成工作流',
  })
  const task = await ctx.aureways.submitTask({ agentId: agent.id, instruction: '执行第一步', priority: 5 })

  assert.equal(ctx.aureways.getTask(task.id)?.state, 'completed')
  assert.equal(ctx.aureways.getAgent(agent.id)?.state, 'idle')
  assert.deepEqual(events.slice(0, 3), [`create:${agent.id}`, 'followup', 'whenIdle'])
  assert.equal(ctx.aureways.status().runtimeBound, true)

  const memory = ctx.aureways.remember({
    agentId: agent.id,
    kind: 'lesson',
    content: '外部副作用前必须建立 checkpoint',
    tags: ['checkpoint', 'side-effect'],
    confidence: 0.95,
  })
  const context = ctx.aureways.rebuildContext({
    agentId: agent.id,
    query: 'checkpoint',
    workflow: {
      workflowId: 'workflow-1', goalId: 'goal-1', goalRevision: 1, phase: 'execute',
      completedStepIds: [], blockedStepIds: [], nextActions: [], pendingConditions: [],
      invariants: ['不盲目重放副作用'], openQuestions: [], revision: 1,
    },
    workspace: { workspaceId: 'workspace-1', revision: 'rev-1', artifacts: [] },
  })
  assert.deepEqual(context.manifest.selectedMemoryIds, [memory.id])
  assert.match(context.prompt, /外部副作用前必须建立 checkpoint/)
  ctx.aureways.invalidateMemory(memory.id)
  assert.deepEqual(ctx.aureways.recall(agent.id, 'checkpoint'), [])

  await fiber.dispose()
  assert.ok(events.includes('dispose'))
  const reopened = new (await import('../lib/store/index.js')).SqliteAurewaysStore(join(dataDirectory, 'aureways.sqlite'))
  reopened.initialize()
  assert.equal(reopened.getAgent(agent.id)?.state, 'cold')
  reopened.close()
  if (existsSync(dataDirectory)) rmSync(dataDirectory, { recursive: true, force: true })
})

function handle(agent, events) {
  return {
    agentId: agent.agentId,
    sessionId: agent.sessionId,
    async followup() { events.push('followup') },
    async steer() { events.push('steer') },
    async cancel() { events.push('cancel') },
    async whenIdle() { events.push('whenIdle') },
    async flush() { events.push('flush'); return 1 },
    async dispose() { events.push('dispose') },
  }
}
