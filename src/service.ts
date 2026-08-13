import { Service, type Context } from '@deepseek-ai/cordis'
import {
  createAgentId,
  createContextBundleId,
  createEpisodicMemoryId,
  createInterruptId,
  createRuntimeTaskId,
  type AgentId,
  type AgentInterrupt,
  type EpisodicMemory,
  type EpisodicMemoryId,
  type JsonValue,
  type PersistentAgent,
  type RuntimeTask as PersistedTask,
  type RuntimeTaskId,
} from './domain/index.js'
import {
  buildContextBundle,
  type ContextBundle,
  type SourceReference,
  type WorkspaceReference,
  type WorkflowContext,
} from './context/index.js'
import {
  ActivationSupervisor,
  AgentTaskScheduler,
  AlwaysLoop,
  CheckpointCoordinator,
  InterruptController,
  RecoveryCoordinator,
  type ActionOutcomeVerifier,
  type ActivationAdapter,
  type ReplanAdapter,
  type RuntimeTask,
  type TaskExecutor,
} from './runtime/index.js'
import { StoreLeaseAdapter, StoreRuntimeAdapter } from './adapters/index.js'
import { SqliteAurewaysStore, type AurewaysStore } from './store/index.js'
import type { Config } from './index.js'

export interface CreatePersistentAgentInput {
  readonly name: string
  readonly workspace: string
  readonly goal: string
  readonly identity?: Readonly<Record<string, unknown>>
  readonly sessionId?: string
}

export interface SubmitTaskInput {
  readonly agentId: AgentId
  readonly instruction: string
  readonly input?: JsonValue
  readonly priority?: number
  readonly idempotencyKey?: string
}

export interface RequestInterruptInput {
  readonly agentId: AgentId
  readonly priority: AgentInterrupt['priority']
  readonly instruction: string
  readonly source: string
  readonly taskId?: RuntimeTaskId
}

export interface RememberInput {
  readonly agentId: AgentId
  readonly kind: EpisodicMemory['kind']
  readonly content: string
  readonly sourceTaskId?: RuntimeTaskId
  readonly sourceEventIds?: readonly EpisodicMemory['sourceEventIds'][number][]
  readonly confidence?: number
  readonly tags?: readonly string[]
  readonly validUntil?: number
}

export interface RebuildContextInput {
  readonly agentId: AgentId
  readonly workflow: WorkflowContext
  readonly workspace: WorkspaceReference
  readonly query?: string
  readonly recentSessionSummary?: string
  readonly tokenBudget?: number
}

/** DSH 具体 Agent/Session 能力由入口适配器注入，核心 Runtime 不依赖具体实现。 */
export interface RuntimeBindings {
  readonly activation: ActivationAdapter
  readonly replan: ReplanAdapter
  readonly taskExecutor?: TaskExecutor
  readonly outcomeVerifier?: ActionOutcomeVerifier
}

export interface AurewaysStatus {
  readonly state: 'ready' | 'running' | 'stopping' | 'stopped'
  readonly dataDirectory: string
  readonly persistentAgents: number
  readonly runtimeBound: boolean
}

interface RuntimeAssembly {
  readonly supervisor: ActivationSupervisor
  readonly scheduler: AgentTaskScheduler
  readonly interrupts: InterruptController
  readonly recovery: RecoveryCoordinator
  readonly loop: AlwaysLoop
}

/** Aureways 对 DSH、模型工具和协议适配器提供的唯一公共服务。 */
export class AurewaysService extends Service {
  private readonly config: Readonly<Config>
  private readonly store: AurewaysStore
  private runtime: RuntimeAssembly | undefined
  private lifecycleState: AurewaysStatus['state'] = 'ready'

  constructor(ctx: Context, config: Config) {
    super(ctx, 'aureways')
    this.config = Object.freeze({ ...config })
    const separator = config.dataDirectory.endsWith('/') ? '' : '/'
    this.store = new SqliteAurewaysStore(`${config.dataDirectory}${separator}aureways.sqlite`)
    this.store.initialize()

    ctx.effect(() => async () => {
      await this.shutdown()
      this.store.close()
    }, 'aureways.lifecycle')
  }

  status(): AurewaysStatus {
    return {
      state: this.lifecycleState,
      dataDirectory: this.config.dataDirectory,
      persistentAgents: this.store.listAgents().length,
      runtimeBound: this.runtime !== undefined,
    }
  }

  /** 将 DSH AgentHandle 能力装配进 Runtime，并执行一次崩溃恢复扫描。 */
  async bindRuntime(bindings: RuntimeBindings): Promise<void> {
    if (this.runtime !== undefined) throw new Error('Aureways Runtime 已经装配')
    const runtimeStore = new StoreRuntimeAdapter(this.store)
    const checkpoints = new CheckpointCoordinator(runtimeStore)
    const scheduler = new AgentTaskScheduler({ maxConcurrentAgents: this.config.maxLiveAgents })
    const supervisor = new ActivationSupervisor(runtimeStore, bindings.activation, checkpoints, {
      ownerId: this.config.runtimeId,
      idleUnloadMs: this.config.idleUnloadMs,
      leaseDurationMs: this.config.leaseDurationMs,
    }, new StoreLeaseAdapter(this.store))
    const interrupts = new InterruptController(runtimeStore, supervisor, checkpoints, bindings.replan)
    const recovery = new RecoveryCoordinator(runtimeStore, bindings.outcomeVerifier ?? unknownOutcomeVerifier)
    const executor = bindings.taskExecutor ?? defaultTaskExecutor
    const loop = new AlwaysLoop(runtimeStore, supervisor, scheduler, interrupts, checkpoints, executor)
    this.runtime = { supervisor, scheduler, interrupts, recovery, loop }
    await recovery.recover()
    this.lifecycleState = 'running'
  }

  createAgent(input: CreatePersistentAgentInput): PersistentAgent {
    if (!input.workspace.startsWith('/')) throw new Error('Persistent Agent workspace 必须是绝对路径')
    const now = Date.now()
    return this.store.createAgent({
      id: createAgentId(),
      revision: 0,
      createdAt: now,
      updatedAt: now,
      name: input.name,
      workspace: input.workspace,
      state: 'cold',
      goal: input.goal,
      goalRevision: 1,
      identity: Object.freeze({ ...(input.identity ?? {}) }),
      ...(input.sessionId === undefined ? {} : { sessionId: input.sessionId }),
    })
  }

  getAgent(agentId: AgentId): PersistentAgent | undefined {
    return this.store.getAgent(agentId)
  }

  listAgents(): readonly PersistentAgent[] {
    return this.store.listAgents()
  }

  /** Task 先持久化，再唤醒 Always Loop；调用方断开不会取消 Task。 */
  async submitTask(input: SubmitTaskInput): Promise<PersistedTask> {
    required(this.store.getAgent(input.agentId), 'Agent', input.agentId)
    const now = Date.now()
    const task = this.store.createTask({
      id: createRuntimeTaskId(),
      agentId: input.agentId,
      revision: 0,
      createdAt: now,
      updatedAt: now,
      state: 'queued',
      instruction: input.instruction,
      ...(input.input === undefined ? {} : { input: input.input }),
      ...(input.priority === undefined ? {} : { priority: input.priority }),
      ...(input.idempotencyKey === undefined ? {} : { idempotencyKey: input.idempotencyKey }),
    })
    await this.wake(input.agentId)
    return task
  }

  getTask(taskId: RuntimeTaskId): PersistedTask | undefined {
    return this.store.getTask(taskId)
  }

  listTasks(agentId: AgentId): readonly PersistedTask[] {
    required(this.store.getAgent(agentId), 'Agent', agentId)
    return this.store.listTasks(agentId)
  }

  /** 取消只改变尚未进入终态的持久 Task；不删除 Agent 或 Session。 */
  async cancelTask(taskId: RuntimeTaskId, reason?: string): Promise<PersistedTask> {
    const task = required(this.store.getTask(taskId), 'Task', taskId)
    if (task.state === 'cancelled') return task
    if (task.state === 'completed') throw new Error(`Task ${taskId} 已完成，不能取消`)
    const next = this.store.updateTask({
      ...task,
      state: 'cancelled',
      ...(reason === undefined ? {} : { failure: { code: 'cancelled', message: reason } }),
    }, task.revision)
    return next
  }

  /** 写入带来源的长期经历；长期记忆不接受隐藏 Chain-of-Thought。 */
  remember(input: RememberInput): EpisodicMemory {
    required(this.store.getAgent(input.agentId), 'Agent', input.agentId)
    if (!Number.isFinite(input.confidence ?? 1) || (input.confidence ?? 1) < 0 || (input.confidence ?? 1) > 1) {
      throw new RangeError('Memory confidence 必须位于 0 到 1')
    }
    const now = Date.now()
    return this.store.createMemory({
      id: createEpisodicMemoryId(),
      agentId: input.agentId,
      revision: 0,
      createdAt: now,
      updatedAt: now,
      kind: input.kind,
      content: input.content,
      sourceEventIds: input.sourceEventIds ?? [],
      confidence: input.confidence ?? 1,
      validFrom: now,
      tags: [...new Set(input.tags ?? [])].sort(),
      ...(input.sourceTaskId === undefined ? {} : { sourceTaskId: input.sourceTaskId }),
      ...(input.validUntil === undefined ? {} : { validUntil: input.validUntil }),
    })
  }

  recall(agentId: AgentId, query?: string, limit = 8): readonly EpisodicMemory[] {
    return this.store.searchMemories({ agentId, ...(query === undefined ? {} : { query }), limit })
  }

  /** 失效采用版本化更新而非删除，保留历史来源和审计能力。 */
  invalidateMemory(memoryId: EpisodicMemoryId): EpisodicMemory {
    const memory = required(this.store.getMemory(memoryId), 'Memory', memoryId)
    return this.store.updateMemory({ ...memory, validUntil: Date.now() }, memory.revision)
  }

  /** 从权威 Workflow、Workspace、Interrupt、Checkpoint 和长期记忆重建一次上下文。 */
  rebuildContext(input: RebuildContextInput): ContextBundle {
    const agent = required(this.store.getAgent(input.agentId), 'Agent', input.agentId)
    const checkpoint = this.store.latestCheckpoint(agent.id)
    const memories = this.store.searchMemories({ agentId: agent.id, ...(input.query === undefined ? {} : { query: input.query }), limit: 12 })
    const interrupts = this.store.listPendingInterrupts(agent.id)
    const createdAt = new Date().toISOString()
    const bundle = buildContextBundle({
      bundleId: createContextBundleId(),
      createdAt,
      identity: {
        agentId: agent.id,
        displayName: agent.name,
        purpose: agent.goal,
        workspaceId: input.workspace.workspaceId,
        policyRefs: stringList(agent.identity.policyRefs),
        capabilityRefs: stringList(agent.identity.capabilityRefs),
        revision: agent.revision,
      },
      workflow: input.workflow,
      workspace: input.workspace,
      memories: memories.map(toContextMemory),
      memoryQuery: { ...(input.query === undefined ? {} : { text: input.query }), limit: 8, now: createdAt },
      interrupts: interrupts.map((interrupt) => ({
        interruptId: interrupt.id,
        priority: interrupt.priority,
        summary: interrupt.instruction,
        sourceRefs: [{ sourceType: 'event', sourceId: interrupt.source }],
      })),
      ...(checkpoint === undefined ? {} : {
        checkpoint: {
          checkpointId: checkpoint.id,
          reason: normalizeContextCheckpointReason(checkpoint.reason),
          lastCommittedEventId: checkpoint.lastCommittedEventId ?? checkpoint.id,
          workflowRevision: checkpoint.workflowFrameRevision,
          createdAt: new Date(checkpoint.createdAt).toISOString(),
        },
      }),
      ...(input.recentSessionSummary === undefined ? {} : { recentSessionSummary: input.recentSessionSummary }),
      ...(input.tokenBudget === undefined ? {} : { tokenBudget: input.tokenBudget }),
    })

    const now = Date.now()
    this.store.createContextBundle({
      id: bundle.manifest.bundleId as ReturnType<typeof createContextBundleId>,
      agentId: agent.id,
      memoryIds: bundle.manifest.selectedMemoryIds as readonly EpisodicMemoryId[],
      tokenBudget: bundle.manifest.tokenBudget,
      contentHash: stableContentHash(bundle.prompt),
      manifest: bundle.manifest as unknown as Readonly<Record<string, unknown>>,
      revision: 0,
      createdAt: now,
      updatedAt: now,
      ...(checkpoint === undefined ? {} : { checkpointId: checkpoint.id }),
    })
    return bundle
  }

  /** Interrupt 先落盘；urgent 模式随后请求当前 Activation 尽快收敛。 */
  async interrupt(input: RequestInterruptInput): Promise<AgentInterrupt> {
    const agent = required(this.store.getAgent(input.agentId), 'Agent', input.agentId)
    const now = Date.now()
    const interrupt = this.store.createInterrupt({
      id: createInterruptId(),
      agentId: input.agentId,
      revision: 0,
      createdAt: now,
      updatedAt: now,
      state: 'pending',
      priority: input.priority,
      instruction: input.instruction,
      source: input.source,
      ...(input.taskId === undefined ? {} : { taskId: input.taskId }),
    })
    const runtime = this.requiredRuntime()
    const runtimeAgent = await new StoreRuntimeAdapter(this.store).getAgent(agent.id)
    const runtimeInterrupt = (await new StoreRuntimeAdapter(this.store).listRequestedInterrupts(agent.id))
      .find((item) => item.interruptId === interrupt.id)
    if (runtimeAgent !== undefined && runtimeInterrupt !== undefined) {
      await runtime.interrupts.request(runtimeAgent, runtimeInterrupt)
    }
    await this.wake(input.agentId)
    return interrupt
  }

  async pause(agentId: AgentId): Promise<PersistentAgent> {
    const agent = required(this.store.getAgent(agentId), 'Agent', agentId)
    return this.store.updateAgent({ ...agent, state: 'paused' }, agent.revision)
  }

  async resume(agentId: AgentId): Promise<PersistentAgent> {
    const agent = required(this.store.getAgent(agentId), 'Agent', agentId)
    const next = this.store.updateAgent({ ...agent, state: 'recovering' }, agent.revision)
    await this.wake(agentId)
    return next
  }

  /** 有序停止 Runtime；插件实体数据仍保留在 SQLite。 */
  async shutdown(): Promise<void> {
    if (this.lifecycleState === 'stopped' || this.lifecycleState === 'stopping') return
    this.lifecycleState = 'stopping'
    const runtime = this.runtime
    if (runtime !== undefined) {
      runtime.scheduler.close()
      await runtime.supervisor.shutdown()
      this.runtime = undefined
    }
    this.lifecycleState = 'stopped'
  }

  private async wake(agentId: AgentId): Promise<void> {
    const runtime = this.requiredRuntime()
    const agent = await new StoreRuntimeAdapter(this.store).getAgent(agentId)
    if (agent === undefined) throw new Error(`Agent ${agentId} 不存在`)
    await runtime.loop.wake(agent)
  }

  private requiredRuntime(): RuntimeAssembly {
    if (this.runtime === undefined) throw new Error('Aureways Runtime 尚未绑定 DSH ActivationAdapter')
    return this.runtime
  }
}

const unknownOutcomeVerifier: ActionOutcomeVerifier = {
  async verify() { return 'unknown' },
}

const defaultTaskExecutor: TaskExecutor = {
  async execute(task: RuntimeTask, handle) {
    await handle.followup(task.input)
    await handle.whenIdle()
    return 'completed'
  },
}

function required<T>(value: T | undefined, kind: string, id: string): T {
  if (value === undefined) throw new Error(`${kind} ${id} 不存在`)
  return value
}

function toContextMemory(memory: EpisodicMemory) {
  const sourceRefs: SourceReference[] = memory.sourceEventIds.map((sourceId) => ({ sourceType: 'event', sourceId }))
  if (memory.sourceTaskId !== undefined) sourceRefs.push({ sourceType: 'task', sourceId: memory.sourceTaskId })
  return {
    memoryId: memory.id,
    agentId: memory.agentId,
    kind: memory.kind,
    summary: memory.content,
    keywords: memory.tags,
    sourceRefs,
    confidence: memory.confidence,
    status: 'active' as const,
    createdAt: new Date(memory.createdAt).toISOString(),
    updatedAt: new Date(memory.updatedAt).toISOString(),
    ...(memory.validUntil === undefined ? {} : { validUntil: new Date(memory.validUntil).toISOString() }),
    supersedesMemoryIds: [],
  }
}

function stringList(value: unknown): readonly string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []
}

function normalizeContextCheckpointReason(reason: string): 'step-completed' | 'before-side-effect' | 'interrupt' | 'idle-unload' | 'manual' {
  if (reason === 'step-completed' || reason === 'before-side-effect' || reason === 'interrupt' || reason === 'idle-unload') return reason
  return 'manual'
}

/** FNV-1a 64-bit 足以作为内容变更指纹；它不是安全签名。 */
function stableContentHash(content: string): string {
  let hash = 0xcbf29ce484222325n
  for (const byte of new TextEncoder().encode(content)) {
    hash ^= BigInt(byte)
    hash = BigInt.asUintN(64, hash * 0x100000001b3n)
  }
  return hash.toString(16).padStart(16, '0')
}
