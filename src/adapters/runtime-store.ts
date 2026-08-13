import {
  createCheckpointId,
  type ActionJournalEntry as DomainAction,
  type AgentId,
  type AgentInterrupt as DomainInterrupt,
  type AgentState as DomainAgentState,
  type Checkpoint as DomainCheckpoint,
  type CheckpointReason as DomainCheckpointReason,
  type InterruptId,
  type LeaseHolderId,
  type PersistentAgent,
  type RuntimeTask as DomainTask,
  type RuntimeTaskId,
} from '../domain/index.js'
import type {
  ActionJournalEntry,
  ActionState,
  AgentLeasePort,
  AgentRuntimeState,
  CheckpointReason,
  InterruptState,
  JsonValue,
  RuntimeAgent,
  RuntimeCheckpoint,
  RuntimeInterrupt,
  RuntimeStore,
  RuntimeTask,
  RuntimeTaskState,
} from '../runtime/index.js'
import type { AgentLease, AurewaysStore } from '../store/index.js'

/** 将同步领域 Store 适配成 Runtime 使用的异步端口。 */
export class StoreRuntimeAdapter implements RuntimeStore {
  readonly #store: AurewaysStore

  constructor(store: AurewaysStore) {
    this.#store = store
  }

  async getAgent(agentId: string): Promise<RuntimeAgent | undefined> {
    return toRuntimeAgent(this.#store.getAgent(agentId as AgentId))
  }

  async listRunnableTasks(agentId: string): Promise<readonly RuntimeTask[]> {
    return this.#store.listTasks(agentId as AgentId)
      .filter((task) => task.state === 'queued' || task.state === 'waiting')
      .sort((left, right) => (right.priority ?? 0) - (left.priority ?? 0) || left.createdAt - right.createdAt)
      .map(toRuntimeTask)
  }

  async listRequestedInterrupts(agentId: string): Promise<readonly RuntimeInterrupt[]> {
    return [...this.#store.listPendingInterrupts(agentId as AgentId)]
      .sort((left, right) => interruptWeight(right) - interruptWeight(left) || left.createdAt - right.createdAt)
      .map(toRuntimeInterrupt)
  }

  async listAgentsInStates(states: readonly AgentRuntimeState[]): Promise<readonly RuntimeAgent[]> {
    return this.#store.listAgents(states as readonly DomainAgentState[]).map(toRuntimeAgentRequired)
  }

  async listUncertainActions(agentId: string): Promise<readonly ActionJournalEntry[]> {
    return this.#store.listActions(agentId as AgentId, ['dispatched', 'acknowledged', 'outcome-unknown']).map(toRuntimeAction)
  }

  async getLatestCheckpoint(agentId: string): Promise<RuntimeCheckpoint | undefined> {
    return toRuntimeCheckpoint(this.#store.latestCheckpoint(agentId as AgentId))
  }

  async transitionAgent(agentId: string, expectedRevision: number, state: AgentRuntimeState): Promise<RuntimeAgent> {
    const current = required(this.#store.getAgent(agentId as AgentId), 'Agent', agentId)
    return toRuntimeAgentRequired(this.#store.updateAgent({ ...current, state }, expectedRevision))
  }

  async transitionTask(taskId: string, expectedRevision: number, state: RuntimeTaskState): Promise<RuntimeTask> {
    const current = required(this.#store.getTask(taskId as RuntimeTaskId), 'Task', taskId)
    const updated = this.#store.updateTask({ ...current, state: toDomainTaskState(state) }, expectedRevision)
    return toRuntimeTask(updated)
  }

  async transitionInterrupt(interruptId: string, expectedRevision: number, state: InterruptState): Promise<RuntimeInterrupt> {
    const current = required(this.#store.getInterrupt(interruptId as InterruptId), 'Interrupt', interruptId)
    const now = Date.now()
    const updated = this.#store.updateInterrupt({
      ...current,
      state: toDomainInterruptState(state),
      ...(state === 'acknowledged' ? { acknowledgedAt: now } : {}),
      ...(state === 'resolved' ? { appliedAt: now } : {}),
    }, expectedRevision)
    return { ...toRuntimeInterrupt(updated), state }
  }

  async transitionAction(actionId: string, expectedRevision: number, state: ActionState): Promise<ActionJournalEntry> {
    const current = required(this.#store.getAction(actionId as DomainAction['id']), 'Action', actionId)
    return toRuntimeAction(this.#store.updateAction({ ...current, state }, expectedRevision))
  }

  async createCheckpoint(input: Omit<RuntimeCheckpoint, 'checkpointId' | 'createdAt'>): Promise<RuntimeCheckpoint> {
    const agent = required(this.#store.getAgent(input.agentId as AgentId), 'Agent', input.agentId)
    const now = Date.now()
    return toRuntimeCheckpointRequired(this.#store.createCheckpoint({
      id: createCheckpointId(),
      agentId: agent.id,
      revision: 0,
      createdAt: now,
      updatedAt: now,
      goalRevision: agent.goalRevision,
      workflowFrameRevision: 0,
      sessionId: input.sessionId,
      sessionSequence: input.throughSequence,
      reason: toDomainCheckpointReason(input.reason),
      pendingActionIds: [],
      summary: `Runtime checkpoint: ${input.reason}`,
      ...(input.taskId === undefined ? {} : { taskId: input.taskId as RuntimeTaskId }),
    }))
  }
}

/** 将领域 Lease 语义适配为 Runtime 的布尔竞争接口。 */
export class StoreLeaseAdapter implements AgentLeasePort {
  readonly #store: AurewaysStore
  readonly #leases = new Map<string, AgentLease>()

  constructor(store: AurewaysStore) {
    this.#store = store
  }

  async acquire(agentId: string, ownerId: string, expiresAt: number): Promise<boolean> {
    try {
      const now = Date.now()
      const lease = this.#store.acquireLease(agentId as AgentId, ownerId as LeaseHolderId, expiresAt - now, now)
      this.#leases.set(leaseKey(agentId, ownerId), lease)
      return true
    } catch {
      return false
    }
  }

  async renew(agentId: string, ownerId: string, expiresAt: number): Promise<boolean> {
    const key = leaseKey(agentId, ownerId)
    const lease = this.#leases.get(key)
    if (lease === undefined) return false
    try {
      const now = Date.now()
      this.#leases.set(key, this.#store.renewLease(lease, expiresAt - now, now))
      return true
    } catch {
      return false
    }
  }

  async release(agentId: string, ownerId: string): Promise<void> {
    const key = leaseKey(agentId, ownerId)
    const lease = this.#leases.get(key)
    if (lease === undefined) return
    this.#store.releaseLease(lease)
    this.#leases.delete(key)
  }
}

function toRuntimeAgent(agent: PersistentAgent | undefined): RuntimeAgent | undefined {
  return agent === undefined ? undefined : toRuntimeAgentRequired(agent)
}

function toRuntimeAgentRequired(agent: PersistentAgent): RuntimeAgent {
  return {
    agentId: agent.id,
    sessionId: agent.sessionId ?? agent.id,
    state: normalizeAgentState(agent.state),
    revision: agent.revision,
    updatedAt: agent.updatedAt,
  }
}

function normalizeAgentState(state: DomainAgentState): AgentRuntimeState {
  if (state === 'active') return 'running'
  if (state === 'failed') return 'error'
  if (state === 'terminating') return 'running'
  if (state === 'terminated') return 'stopped'
  return state
}

function toRuntimeTask(task: DomainTask): RuntimeTask {
  return {
    taskId: task.id,
    agentId: task.agentId,
    state: toRuntimeTaskState(task.state),
    input: (task.input ?? task.instruction) as JsonValue,
    priority: task.priority ?? 0,
    revision: task.revision,
    createdAt: task.createdAt,
    updatedAt: task.updatedAt,
  }
}

function toRuntimeTaskState(state: DomainTask['state']): RuntimeTaskState {
  if (state === 'queued') return 'queued'
  if (state === 'running') return 'working'
  if (state === 'waiting') return 'input-required'
  if (state === 'cancelled') return 'canceled'
  return state
}

function toDomainTaskState(state: RuntimeTaskState): DomainTask['state'] {
  if (state === 'submitted' || state === 'queued') return 'queued'
  if (state === 'working') return 'running'
  if (state === 'input-required' || state === 'outcome-unknown') return 'waiting'
  if (state === 'canceled') return 'cancelled'
  return state
}

function toRuntimeInterrupt(interrupt: DomainInterrupt): RuntimeInterrupt {
  return {
    interruptId: interrupt.id,
    agentId: interrupt.agentId,
    mode: interrupt.priority,
    state: interrupt.state === 'pending' ? 'requested' : interrupt.state === 'applied' ? 'resolved' : interrupt.state === 'dismissed' ? 'failed' : 'acknowledged',
    priority: interruptWeight(interrupt),
    payload: interrupt.instruction,
    revision: interrupt.revision,
    requestedAt: interrupt.createdAt,
  }
}

function toDomainInterruptState(state: InterruptState): DomainInterrupt['state'] {
  if (state === 'requested') return 'pending'
  if (state === 'acknowledged' || state === 'replanning') return 'acknowledged'
  if (state === 'resolved') return 'applied'
  return 'dismissed'
}

function interruptWeight(interrupt: DomainInterrupt): number {
  return interrupt.priority === 'urgent' ? 100 : 10
}

function toRuntimeAction(action: DomainAction): ActionJournalEntry {
  return {
    actionId: action.id,
    agentId: action.agentId,
    taskId: action.taskId,
    state: action.state === 'cancelled' ? 'failed' : action.state,
    idempotencyKey: action.idempotencyKey,
    revision: action.revision,
    updatedAt: action.updatedAt,
  }
}

function toRuntimeCheckpoint(checkpoint: DomainCheckpoint | undefined): RuntimeCheckpoint | undefined {
  return checkpoint === undefined ? undefined : toRuntimeCheckpointRequired(checkpoint)
}

function toRuntimeCheckpointRequired(checkpoint: DomainCheckpoint): RuntimeCheckpoint {
  return {
    checkpointId: checkpoint.id,
    agentId: checkpoint.agentId,
    sessionId: checkpoint.sessionId ?? checkpoint.agentId,
    throughSequence: checkpoint.sessionSequence ?? 0,
    reason: toRuntimeCheckpointReason(checkpoint.reason),
    taskId: checkpoint.taskId,
    createdAt: checkpoint.createdAt,
  }
}

function toRuntimeCheckpointReason(reason: DomainCheckpointReason): CheckpointReason {
  if (reason === 'turn-end' || reason === 'interrupt' || reason === 'idle-unload' || reason === 'shutdown' || reason === 'periodic') return reason
  return 'periodic'
}

function toDomainCheckpointReason(reason: CheckpointReason): DomainCheckpointReason {
  return reason
}

function required<T>(value: T | undefined, kind: string, id: string): T {
  if (value === undefined) throw new Error(`${kind} ${id} 不存在`)
  return value
}

function leaseKey(agentId: string, ownerId: string): string {
  return `${agentId}:${ownerId}`
}
