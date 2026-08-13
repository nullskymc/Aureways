import assert from 'node:assert/strict'
import test from 'node:test'
import { buildContextBundle, invalidateEpisodicMemory, retrieveEpisodicMemories } from '../../lib/context/index.js'

const identity = {
  agentId: 'agent-1', displayName: 'Aureways', purpose: 'Complete durable work',
  workspaceId: 'workspace-1', policyRefs: ['policy-1'], capabilityRefs: ['fs'], revision: 1,
}
const workflow = {
  workflowId: 'workflow-1', goalId: 'goal-1', goalRevision: 1, phase: 'implement',
  completedStepIds: [], blockedStepIds: [], nextActions: [], pendingConditions: [],
  invariants: ['never hide side effects'], openQuestions: [], revision: 2,
}
const workspace = { workspaceId: 'workspace-1', revision: 'abc123', artifacts: [] }
const memory = {
  memoryId: 'memory-1', agentId: 'agent-1', kind: 'lesson', summary: 'Prefer checkpoints before external tools.',
  keywords: ['checkpoint'], sourceRefs: [{ sourceType: 'event', sourceId: 'event-1' }], confidence: 0.9,
  status: 'active', createdAt: '2026-08-13T00:00:00.000Z', updatedAt: '2026-08-13T00:00:00.000Z', supersedesMemoryIds: [],
}

test('retrieval excludes invalid and expired memories', () => {
  const invalid = invalidateEpisodicMemory(memory, '2026-08-13T00:01:00.000Z', { sourceType: 'user', sourceId: 'user-1' })
  assert.deepEqual(retrieveEpisodicMemories([memory, invalid], { agentId: 'agent-1', text: 'checkpoint', now: '2026-08-13T00:02:00.000Z' }).map((hit) => hit.memory.memoryId), ['memory-1'])
})

test('builder preserves high-priority workflow and records selected memories', () => {
  const result = buildContextBundle({
    bundleId: 'bundle-1', createdAt: '2026-08-13T00:00:00.000Z', identity, workflow, workspace,
    memories: [memory], memoryQuery: { text: 'checkpoint' }, tokenBudget: 500, estimateTokens: () => 10,
  })
  assert.equal(result.manifest.sections[0].kind, 'identity')
  assert.ok(result.manifest.sections.some((section) => section.kind === 'workflow'))
  assert.deepEqual(result.manifest.selectedMemoryIds, ['memory-1'])
})

test('tiny budget never drops identity, workflow, or urgent interrupt', () => {
  const result = buildContextBundle({
    bundleId: 'bundle-tiny', createdAt: '2026-08-13T00:00:00.000Z', identity, workflow, workspace,
    memories: [memory], memoryQuery: { text: 'checkpoint' }, tokenBudget: 1, estimateTokens: () => 10,
    interrupts: [{ interruptId: 'interrupt-1', priority: 'urgent', summary: '立即停止外部写入', sourceRefs: [] }],
  })
  assert.deepEqual(result.manifest.sections.map((section) => section.kind), ['identity', 'interrupt', 'workflow'])
  assert.equal(result.manifest.tokenUsed, 30)
})
