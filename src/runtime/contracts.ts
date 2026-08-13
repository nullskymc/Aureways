/**
 * Runtime 的端口定义。
 *
 * 本文件刻意不引用 Cordis 或 DSH 的具体类型：运行时只依赖这些最小能力，
 * 由插件入口通过 adapter 连接到实际 Harness，便于测试和后续协议迁移。
 */

export type AgentRuntimeState =
  | 'cold'
  | 'starting'
  | 'idle'
  | 'running'
  | 'interrupting'
  | 'recovering'
  | 'paused'
  | 'stopped'
  | 'error'

export type RuntimeTaskState =
  | 'submitted'
  | 'queued'
  | 'working'
  | 'input-required'
  | 'completed'
  | 'failed'
  | 'canceled'
  | 'outcome-unknown'

export type InterruptMode = 'soft' | 'urgent'
export type InterruptState = 'requested' | 'acknowledged' | 'replanning' | 'resolved' | 'failed'
export type InterruptDecision = 'resume' | 'revise' | 'pause' | 'terminate'
export type CheckpointReason = 'turn-end' | 'interrupt' | 'idle-unload' | 'shutdown' | 'periodic'
export type ActionState = 'planned' | 'dispatched' | 'acknowledged' | 'succeeded' | 'failed' | 'outcome-unknown'

/** 可跨 adapter、Store 和协议边界安全传输的 JSON 值。 */
export type JsonValue = null | boolean | number | string | readonly JsonValue[] | { readonly [key: string]: JsonValue }

export interface RuntimeAgent {
  readonly agentId: string
  readonly sessionId: string
  readonly state: AgentRuntimeState
  readonly revision: number
  readonly updatedAt: number
}

export interface RuntimeTask {
  readonly taskId: string
  readonly agentId: string | undefined
  readonly state: RuntimeTaskState
  readonly input: JsonValue
  readonly priority: number
  readonly revision: number
  readonly createdAt: number
  readonly updatedAt: number
}

export interface RuntimeInterrupt {
  readonly interruptId: string
  readonly agentId: string
  readonly mode: InterruptMode
  readonly state: InterruptState
  readonly priority: number
  readonly payload: JsonValue
  readonly revision: number
  readonly requestedAt: number
}

export interface ActionJournalEntry {
  readonly actionId: string
  readonly agentId: string
  readonly taskId: string | undefined
  readonly state: ActionState
  readonly idempotencyKey: string | undefined
  readonly revision: number
  readonly updatedAt: number
}

export interface RuntimeCheckpoint {
  readonly checkpointId: string
  readonly agentId: string
  readonly sessionId: string
  readonly throughSequence: number
  readonly reason: CheckpointReason
  readonly taskId: string | undefined
  readonly createdAt: number
}

/** 运行时所需的持久化事务边界。实现必须对 revision 作 CAS 检查。 */
export interface RuntimeStore {
  getAgent(agentId: string): Promise<RuntimeAgent | undefined>
  listRunnableTasks(agentId: string): Promise<readonly RuntimeTask[]>
  listRequestedInterrupts(agentId: string): Promise<readonly RuntimeInterrupt[]>
  listAgentsInStates(states: readonly AgentRuntimeState[]): Promise<readonly RuntimeAgent[]>
  listUncertainActions(agentId: string): Promise<readonly ActionJournalEntry[]>
  getLatestCheckpoint(agentId: string): Promise<RuntimeCheckpoint | undefined>
  transitionAgent(agentId: string, expectedRevision: number, state: AgentRuntimeState): Promise<RuntimeAgent>
  transitionTask(taskId: string, expectedRevision: number, state: RuntimeTaskState): Promise<RuntimeTask>
  transitionInterrupt(interruptId: string, expectedRevision: number, state: InterruptState): Promise<RuntimeInterrupt>
  transitionAction(actionId: string, expectedRevision: number, state: ActionState): Promise<ActionJournalEntry>
  createCheckpoint(input: Omit<RuntimeCheckpoint, 'checkpointId' | 'createdAt'>): Promise<RuntimeCheckpoint>
}

/** Lease 端口独立于核心状态存储，允许分布式实现替换 SQLite 锁。 */
export interface AgentLeasePort {
  acquire(agentId: string, ownerId: string, expiresAt: number): Promise<boolean>
  renew(agentId: string, ownerId: string, expiresAt: number): Promise<boolean>
  release(agentId: string, ownerId: string): Promise<void>
}

/** DSH AgentHandle 的窄包装；真实 adapter 不应把 Cordis 类型泄漏到 Runtime。 */
export interface ActivationHandle {
  readonly agentId: string
  readonly sessionId: string
  followup(input: JsonValue): Promise<void>
  steer(input: JsonValue): Promise<void>
  cancel(cause: { readonly kind: 'hook'; readonly reason: string }, options: { readonly keepInbox: true }): Promise<void>
  whenIdle(): Promise<void>
  flush(): Promise<number>
  dispose(): Promise<void>
}

export interface ActivationAdapter {
  create(agent: RuntimeAgent): Promise<ActivationHandle>
  resume(agent: RuntimeAgent, checkpoint: RuntimeCheckpoint | undefined): Promise<ActivationHandle>
}

/** 将中断后的模型决策转换为明确、可审计的 Runtime 指令。 */
export interface ReplanAdapter {
  requestDecision(handle: ActivationHandle, interrupt: RuntimeInterrupt): Promise<InterruptDecision>
}

/** 对副作用状态作外部核验，防止 crash 后盲目重放。 */
export interface ActionOutcomeVerifier {
  verify(entry: ActionJournalEntry): Promise<'succeeded' | 'failed' | 'unknown'>
}

export interface RuntimeClock {
  now(): number
}

export const systemClock: RuntimeClock = { now: () => Date.now() }
