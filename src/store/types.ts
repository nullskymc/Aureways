import type {
  ActionJournalEntry,
  AgentId,
  AgentInterrupt,
  Checkpoint,
  ContextBundle,
  ContextBundleId,
  EpisodicMemory,
  EpisodicMemoryId,
  LeaseHolderId,
  PersistentAgent,
  RuntimeTask,
  RuntimeTaskId,
  WorkflowFrame,
  WorkflowId,
} from '../domain/index.js'

export interface AgentLease {
  readonly agentId: AgentId
  readonly holderId: LeaseHolderId
  readonly expiresAt: number
}

export interface MemorySearch {
  readonly agentId: AgentId
  readonly query?: string
  readonly kinds?: readonly EpisodicMemory['kind'][]
  readonly limit?: number
  readonly now?: number
}

/** Runtime 唯一依赖的持久化契约，方便未来替换 SQLite 或接入远端 State Store。 */
export interface AurewaysStore {
  initialize(): void
  close(): void

  createAgent(agent: PersistentAgent): PersistentAgent
  getAgent(id: AgentId): PersistentAgent | undefined
  listAgents(states?: readonly PersistentAgent['state'][]): readonly PersistentAgent[]
  updateAgent(agent: PersistentAgent, expectedRevision: number): PersistentAgent

  createTask(task: RuntimeTask): RuntimeTask
  getTask(id: RuntimeTaskId): RuntimeTask | undefined
  listTasks(agentId: AgentId): readonly RuntimeTask[]
  updateTask(task: RuntimeTask, expectedRevision: number): RuntimeTask

  createInterrupt(interrupt: AgentInterrupt): AgentInterrupt
  getInterrupt(id: AgentInterrupt['id']): AgentInterrupt | undefined
  listPendingInterrupts(agentId: AgentId): readonly AgentInterrupt[]
  updateInterrupt(interrupt: AgentInterrupt, expectedRevision: number): AgentInterrupt

  createCheckpoint(checkpoint: Checkpoint): Checkpoint
  getCheckpoint(id: Checkpoint['id']): Checkpoint | undefined
  latestCheckpoint(agentId: AgentId): Checkpoint | undefined

  createWorkflow(frame: WorkflowFrame): WorkflowFrame
  getWorkflow(id: WorkflowId): WorkflowFrame | undefined
  updateWorkflow(frame: WorkflowFrame, expectedRevision: number): WorkflowFrame

  createAction(action: ActionJournalEntry): ActionJournalEntry
  getAction(id: ActionJournalEntry['id']): ActionJournalEntry | undefined
  listActions(agentId: AgentId, states?: readonly ActionJournalEntry['state'][]): readonly ActionJournalEntry[]
  updateAction(action: ActionJournalEntry, expectedRevision: number): ActionJournalEntry

  createMemory(memory: EpisodicMemory): EpisodicMemory
  getMemory(id: EpisodicMemoryId): EpisodicMemory | undefined
  updateMemory(memory: EpisodicMemory, expectedRevision: number): EpisodicMemory
  searchMemories(search: MemorySearch): readonly EpisodicMemory[]

  createContextBundle(bundle: ContextBundle): ContextBundle
  getContextBundle(id: ContextBundleId): ContextBundle | undefined

  acquireLease(agentId: AgentId, holderId: LeaseHolderId, ttlMs: number, now?: number): AgentLease
  renewLease(lease: AgentLease, ttlMs: number, now?: number): AgentLease
  releaseLease(lease: AgentLease): void
}
