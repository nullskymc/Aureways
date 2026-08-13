import { retrieveEpisodicMemories, type MemoryQuery } from './memory.js'
import type {
  AgentIdentity,
  CheckpointContext,
  ContextBundle,
  ContextSection,
  EpisodicMemory,
  InterruptContext,
  SourceReference,
  WorkspaceReference,
  WorkflowContext,
} from './types.js'

export interface ContextBuildInput {
  readonly bundleId: string
  readonly createdAt: string
  readonly identity: AgentIdentity
  readonly workflow: WorkflowContext
  readonly workspace: WorkspaceReference
  readonly memories: readonly EpisodicMemory[]
  readonly memoryQuery: Omit<MemoryQuery, 'agentId'>
  readonly checkpoint?: CheckpointContext
  readonly interrupts?: readonly InterruptContext[]
  readonly recentSessionSummary?: string
  readonly tokenBudget?: number
  readonly estimateTokens?: (text: string) => number
}

const DEFAULT_TOKEN_BUDGET = 8_000

/**
 * 以固定优先级重建一次可审计上下文。输入相同时输出顺序稳定。
 * 此处只处理状态、摘要和来源，绝不接收或保存隐藏推理。
 */
export function buildContextBundle(input: ContextBuildInput): ContextBundle {
  const estimateTokens = input.estimateTokens ?? estimateTokensByCharacters
  const budget = input.tokenBudget ?? DEFAULT_TOKEN_BUDGET
  const memoryHits = retrieveEpisodicMemories(input.memories, {
    ...input.memoryQuery,
    agentId: input.identity.agentId,
  })
  const candidates = makeSections(input, memoryHits.map((hit) => hit.memory), estimateTokens)
  const selected = selectWithinBudget(candidates, budget)
  const sourceRefs = uniqueSourceRefs(selected.flatMap((section) => section.sourceRefs))
  const prompt = selected.map((section) => `## ${section.kind}\n${section.text}`).join('\n\n')

  return {
    manifest: {
      bundleId: input.bundleId,
      agentId: input.identity.agentId,
      workflowId: input.workflow.workflowId,
      workflowRevision: input.workflow.revision,
      ...(input.checkpoint === undefined ? {} : { checkpointId: input.checkpoint.checkpointId }),
      workspaceRevision: input.workspace.revision,
      createdAt: input.createdAt,
      tokenBudget: budget,
      tokenUsed: selected.reduce((total, section) => total + section.tokenCount, 0),
      sections: selected,
      selectedMemoryIds: selected
        .flatMap((section) => section.memoryIds ?? [])
        .sort((left, right) => left.localeCompare(right)),
      sourceRefs,
    },
    prompt,
  }
}

function makeSections(
  input: ContextBuildInput,
  memories: readonly EpisodicMemory[],
  estimateTokens: (text: string) => number,
): readonly ContextSection[] {
  const sections: ContextSection[] = [
    section('identity', 100, identityText(input.identity), policyRefs(input.identity), estimateTokens),
    section('workflow', 90, workflowText(input.workflow), [], estimateTokens),
    section('workspace', 70, workspaceText(input.workspace), artifactSources(input.workspace), estimateTokens),
  ]
  if (input.interrupts !== undefined) {
    for (const interrupt of [...input.interrupts].sort(compareInterrupt)) {
      sections.push(section('interrupt', interrupt.priority === 'urgent' ? 95 : 85, interrupt.summary, interrupt.sourceRefs, estimateTokens))
    }
  }
  if (input.checkpoint !== undefined) {
    sections.push(section('checkpoint', 80, checkpointText(input.checkpoint), [{ sourceType: 'checkpoint', sourceId: input.checkpoint.checkpointId }], estimateTokens))
  }
  for (const memory of memories) {
    sections.push({
      ...section('memory', 60, memory.summary, memory.sourceRefs, estimateTokens),
      memoryIds: [memory.memoryId],
    })
  }
  if (input.recentSessionSummary !== undefined && input.recentSessionSummary.trim() !== '') {
    sections.push(section('recent-session', 40, input.recentSessionSummary, [], estimateTokens))
  }
  return sections.sort((left, right) => right.priority - left.priority || left.kind.localeCompare(right.kind) || left.text.localeCompare(right.text))
}

/** 预算不足时宁可省略低优先级背景，也不截断结构化执行状态。 */
function selectWithinBudget(sections: readonly ContextSection[], budget: number): readonly ContextSection[] {
  const selected: ContextSection[] = []
  let used = 0
  for (const item of sections) {
    // 身份、工作流和紧急中断属于控制面事实，预算不足也不能静默丢弃。
    const required = item.kind === 'identity' || item.kind === 'workflow'
      || (item.kind === 'interrupt' && item.priority >= 95)
    if (required || item.tokenCount <= budget - used) {
      selected.push(item)
      used += item.tokenCount
    }
  }
  return selected
}

function section(kind: ContextSection['kind'], priority: number, text: string, sourceRefs: readonly SourceReference[], estimateTokens: (text: string) => number): ContextSection {
  return { kind, priority, text, tokenCount: estimateTokens(text), sourceRefs: uniqueSourceRefs(sourceRefs) }
}

function identityText(identity: AgentIdentity): string {
  return `Agent: ${identity.displayName}\nPurpose: ${identity.purpose}\nWorkspace: ${identity.workspaceId}\nPolicies: ${identity.policyRefs.join(', ')}\nCapabilities: ${identity.capabilityRefs.join(', ')}`
}

function policyRefs(identity: AgentIdentity): readonly SourceReference[] {
  return identity.policyRefs.map((sourceId) => ({ sourceType: 'workspace', sourceId }))
}

function workflowText(workflow: WorkflowContext): string {
  return `Goal: ${workflow.goalId} (revision ${workflow.goalRevision})\nPhase: ${workflow.phase}\nCurrent step: ${workflow.currentStepId ?? 'none'}\nCompleted: ${workflow.completedStepIds.join(', ')}\nBlocked: ${workflow.blockedStepIds.join(', ')}\nNext actions: ${workflow.nextActions.map((action) => action.summary).join(' | ')}\nConstraints: ${workflow.invariants.join(' | ')}\nOpen questions: ${workflow.openQuestions.join(' | ')}`
}

function checkpointText(checkpoint: CheckpointContext): string {
  return `Checkpoint: ${checkpoint.checkpointId}\nReason: ${checkpoint.reason}\nLast committed event: ${checkpoint.lastCommittedEventId}\nWorkflow revision: ${checkpoint.workflowRevision}`
}

function workspaceText(workspace: WorkspaceReference): string {
  return workspace.artifacts
    .slice()
    .sort((left, right) => left.path.localeCompare(right.path) || left.artifactId.localeCompare(right.artifactId))
    .map((artifact) => `${artifact.path}@${artifact.revision}: ${artifact.summary}`)
    .join('\n')
}

function artifactSources(workspace: WorkspaceReference): readonly SourceReference[] {
  return workspace.artifacts.flatMap((artifact) => artifact.sourceRefs)
}

function compareInterrupt(left: InterruptContext, right: InterruptContext): number {
  return (left.priority === 'urgent' ? 0 : 1) - (right.priority === 'urgent' ? 0 : 1)
    || left.interruptId.localeCompare(right.interruptId)
}

function estimateTokensByCharacters(text: string): number {
  return Math.max(1, Math.ceil(text.length / 4))
}

function uniqueSourceRefs(refs: readonly SourceReference[]): readonly SourceReference[] {
  const map = new Map<string, SourceReference>()
  for (const ref of refs) map.set(`${ref.sourceType}:${ref.sourceId}:${ref.observedAt ?? ''}`, ref)
  return [...map.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([, ref]) => ref)
}
