import type {
  ActionId,
  AgentId,
  CheckpointId,
  ContextBundleId,
  EpisodicMemoryId,
  EventId,
  InterruptId,
  RuntimeTaskId,
  WorkflowId,
} from './id.js'

/** 所有落盘对象的乐观并发版本和时间戳。 */
export interface PersistedEntity<Id extends string> {
  readonly id: Id
  readonly revision: number
  readonly createdAt: number
  readonly updatedAt: number
}

/**
 * `active` / `failed` 等旧状态仍保留，便于已落盘的 V0.1 早期数据平滑升级；
 * Runtime 使用 cold 至 error 这一组显式 Activation 生命周期状态。
 */
export type AgentState =
  | 'active' | 'idle' | 'paused' | 'terminating' | 'terminated' | 'failed'
  | 'cold' | 'starting' | 'running' | 'interrupting' | 'recovering' | 'stopped' | 'error'
export type RuntimeTaskState = 'queued' | 'running' | 'waiting' | 'completed' | 'failed' | 'cancelled'
export type InterruptState = 'pending' | 'acknowledged' | 'applied' | 'dismissed'
export type InterruptPriority = 'soft' | 'urgent'
export type ActionState = 'planned' | 'dispatched' | 'acknowledged' | 'succeeded' | 'failed' | 'outcome-unknown' | 'cancelled'

export interface PersistentAgent extends PersistedEntity<AgentId> {
  readonly name: string
  readonly workspace: string
  readonly state: AgentState
  readonly goal: string
  readonly goalRevision: number
  readonly identity: Readonly<Record<string, unknown>>
  /** DSH Session 的稳定标识；旧记录可为空，并由恢复流程补写。 */
  readonly sessionId?: string
  readonly currentTaskId?: RuntimeTaskId
  readonly lastCheckpointId?: CheckpointId
}

export interface RuntimeTask extends PersistedEntity<RuntimeTaskId> {
  readonly agentId: AgentId
  readonly state: RuntimeTaskState
  readonly instruction: string
  /** 协议适配层提交的完整 JSON 输入，instruction 保留为兼容的人类可读摘要。 */
  readonly input?: JsonValue
  /** 数字越大越优先；缺省时调度器按 0 处理。 */
  readonly priority?: number
  readonly parentTaskId?: RuntimeTaskId
  readonly idempotencyKey?: string
  readonly workflowId?: WorkflowId
  readonly result?: Readonly<Record<string, unknown>>
  readonly failure?: Readonly<{ code: string; message: string }>
}

export interface AgentInterrupt extends PersistedEntity<InterruptId> {
  readonly agentId: AgentId
  readonly state: InterruptState
  readonly priority: InterruptPriority
  readonly instruction: string
  readonly source: string
  readonly taskId?: RuntimeTaskId
  readonly acknowledgedAt?: number
  readonly appliedAt?: number
}

export interface Checkpoint extends PersistedEntity<CheckpointId> {
  readonly agentId: AgentId
  readonly taskId?: RuntimeTaskId
  readonly workflowId?: WorkflowId
  readonly goalRevision: number
  readonly workflowFrameRevision: number
  /** Session flush 后的已持久化序列号，恢复时禁止回退到其前的消息。 */
  readonly sessionSequence?: number
  readonly sessionId?: string
  readonly lastCommittedEventId?: EventId
  readonly workspaceRevision?: string
  readonly pendingActionIds: readonly ActionId[]
  readonly reason: CheckpointReason
  readonly summary: string
}

/** 不保存隐藏推理，只保存可审计、可恢复的工作流控制状态。 */
export interface WorkflowFrame extends PersistedEntity<WorkflowId> {
  readonly agentId: AgentId
  readonly taskId?: RuntimeTaskId
  readonly goalRevision: number
  readonly phase: string
  readonly currentStepId?: string
  readonly completedStepIds: readonly string[]
  readonly blockedStepIds: readonly string[]
  readonly pendingConditions: readonly PendingCondition[]
  readonly nextActions: readonly PlannedAction[]
  readonly invariants: readonly string[]
  readonly openQuestions: readonly string[]
  readonly lastObservationEventId?: EventId
  readonly lastCheckpointId?: CheckpointId
}

export interface PendingCondition { readonly id: string; readonly description: string; readonly kind: 'external-event' | 'timer' | 'approval' | 'dependency' }
export interface PlannedAction { readonly id: ActionId; readonly description: string; readonly requiresConfirmation: boolean }

export interface ActionJournalEntry extends PersistedEntity<ActionId> {
  readonly agentId: AgentId
  readonly taskId?: RuntimeTaskId
  readonly workflowId?: WorkflowId
  readonly state: ActionState
  readonly description: string
  readonly idempotencyKey?: string
  readonly externalReference?: string
  readonly outcome?: Readonly<Record<string, unknown>>
}

export interface EpisodicMemory extends PersistedEntity<EpisodicMemoryId> {
  readonly agentId: AgentId
  readonly kind: 'decision' | 'observation' | 'failure' | 'preference' | 'lesson'
  readonly content: string
  readonly sourceTaskId?: RuntimeTaskId
  readonly sourceEventIds: readonly EventId[]
  readonly confidence: number
  readonly validFrom: number
  readonly validUntil?: number
  readonly tags: readonly string[]
}

/** 一次模型调用实际使用了哪些持久事实，确保决定可以追溯。 */
export interface ContextBundle extends PersistedEntity<ContextBundleId> {
  readonly agentId: AgentId
  readonly taskId?: RuntimeTaskId
  /** 首次执行前可能还没有 Checkpoint，但 Bundle 清单仍必须可审计。 */
  readonly checkpointId?: CheckpointId
  readonly memoryIds: readonly EpisodicMemoryId[]
  readonly eventRange?: readonly [EventId, EventId]
  readonly tokenBudget: number
  readonly contentHash: string
  /** 实际入模分区与来源的可审计清单，不包含隐藏推理。 */
  readonly manifest?: Readonly<Record<string, unknown>>
}

/** 可安全落盘、跨协议传输的任务输入；不承载函数、Error 或 Handle。 */
export type JsonValue = null | boolean | number | string | readonly JsonValue[] | { readonly [key: string]: JsonValue }

/** 同时覆盖领域检查点与 Runtime 生命周期的恢复锚点原因。 */
export type CheckpointReason =
  | 'step-completed' | 'before-side-effect' | 'interrupt' | 'idle-unload' | 'manual'
  | 'turn-end' | 'shutdown' | 'periodic' | 'recovery' | 'before-replan' | 'after-replan'
