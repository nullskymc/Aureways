/** 可持久化身份；不包含模型的私有推理或完整对话。 */
export interface AgentIdentity {
  readonly agentId: string
  readonly displayName: string
  readonly purpose: string
  readonly workspaceId: string
  readonly policyRefs: readonly string[]
  readonly capabilityRefs: readonly string[]
  readonly revision: number
}

/** 可恢复工作流的公开控制面状态。 */
export interface WorkflowContext {
  readonly workflowId: string
  readonly goalId: string
  readonly goalRevision: number
  readonly phase: string
  readonly currentStepId?: string
  readonly completedStepIds: readonly string[]
  readonly blockedStepIds: readonly string[]
  readonly nextActions: readonly PlannedAction[]
  readonly pendingConditions: readonly PendingCondition[]
  readonly invariants: readonly string[]
  readonly openQuestions: readonly string[]
  readonly revision: number
  readonly lastCheckpointId?: string
}

export interface PlannedAction {
  readonly actionId: string
  readonly summary: string
  readonly sideEffect: 'none' | 'reversible' | 'external'
}

export interface PendingCondition {
  readonly conditionId: string
  readonly description: string
  readonly kind: 'event' | 'approval' | 'time' | 'dependency'
}

export type MemoryKind = 'decision' | 'observation' | 'failure' | 'preference' | 'lesson'
export type MemoryStatus = 'active' | 'superseded' | 'invalidated'

/** 每条长期经历记忆都带来源，可审计且可失效。 */
export interface EpisodicMemory {
  readonly memoryId: string
  readonly agentId: string
  readonly kind: MemoryKind
  readonly summary: string
  readonly keywords: readonly string[]
  readonly sourceRefs: readonly SourceReference[]
  readonly confidence: number
  readonly status: MemoryStatus
  readonly createdAt: string
  readonly updatedAt: string
  readonly validUntil?: string
  readonly supersedesMemoryIds: readonly string[]
}

export interface SourceReference {
  readonly sourceType: 'task' | 'event' | 'checkpoint' | 'workspace' | 'user'
  readonly sourceId: string
  readonly observedAt?: string
}

/** 工作区内容只以版本或制品引用进入记忆，不把整份文件复制进上下文。 */
export interface WorkspaceReference {
  readonly workspaceId: string
  readonly revision: string
  readonly artifacts: readonly WorkspaceArtifact[]
}

export interface WorkspaceArtifact {
  readonly artifactId: string
  readonly path: string
  readonly revision: string
  readonly digest?: string
  readonly summary: string
  readonly sourceRefs: readonly SourceReference[]
}

export interface InterruptContext {
  readonly interruptId: string
  readonly priority: 'soft' | 'urgent'
  readonly summary: string
  readonly sourceRefs: readonly SourceReference[]
}

export interface CheckpointContext {
  readonly checkpointId: string
  readonly reason: 'step-completed' | 'before-side-effect' | 'interrupt' | 'idle-unload' | 'manual'
  readonly lastCommittedEventId: string
  readonly workflowRevision: number
  readonly createdAt: string
}

export type ContextSectionKind =
  | 'identity'
  | 'workflow'
  | 'interrupt'
  | 'checkpoint'
  | 'workspace'
  | 'memory'
  | 'recent-session'

export interface ContextSection {
  readonly kind: ContextSectionKind
  readonly priority: number
  readonly text: string
  readonly tokenCount: number
  readonly sourceRefs: readonly SourceReference[]
  /** 仅 memory 分区填写，用于清单记录实际选择的记忆。 */
  readonly memoryIds?: readonly string[]
}

/** 可重放的上下文清单，而非模型的隐藏 CoT。 */
export interface ContextBundleManifest {
  readonly bundleId: string
  readonly agentId: string
  readonly workflowId: string
  readonly workflowRevision: number
  readonly checkpointId?: string
  readonly workspaceRevision: string
  readonly createdAt: string
  readonly tokenBudget: number
  readonly tokenUsed: number
  readonly sections: readonly ContextSection[]
  readonly selectedMemoryIds: readonly string[]
  readonly sourceRefs: readonly SourceReference[]
}

export interface ContextBundle {
  readonly manifest: ContextBundleManifest
  readonly prompt: string
}
