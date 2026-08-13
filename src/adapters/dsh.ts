import type {
  ActivationAdapter,
  ActivationHandle,
  JsonValue,
  RuntimeAgent,
  RuntimeCheckpoint,
} from '../runtime/contracts.js'

/** DSH 当前 `UserMessage` 所需的最小文本块形状。 */
export interface DshTextBlock {
  readonly type: 'text'
  readonly text: string
}

/** DSH `createUserMessage()` 的结构输入；由宿主传入真实工厂实现。 */
export interface DshUserMessageInput {
  readonly content: readonly DshTextBlock[]
  readonly source: {
    readonly kind: 'plugin'
    readonly plugin: string
    readonly form: 'notice'
    readonly summary: string
  }
}

/** 不直接导入 DSH，以便插件不会重复捆绑 Harness 运行时。 */
export interface DshSessionLike {
  /** DSH Session 的下一条 event 序号；最后一条已存在 event 为 `seq - 1`。 */
  readonly seq: number
}

/** DSH Agent 的公开运行面。`followup`、`steer` 与 `cancel` 都是同步操作。 */
export interface DshAgentLike {
  readonly id: string
  readonly session: DshSessionLike
  followup(message: unknown): void
  steer(message: unknown): void
  cancel(cause: { readonly kind: 'hook'; readonly reason: string }, options: { readonly keepInbox: true }): void
  whenIdle(): Promise<void>
}

/** DSH AgentRegistry 创建或恢复后返回的所有权句柄。 */
export interface DshAgentHandleLike {
  readonly agent: DshAgentLike
  dispose(): Promise<void>
}

export interface DshCreateAgentOptions {
  readonly sessionId: string
  readonly meta?: Readonly<Record<string, unknown>>
  readonly agentOptions?: Readonly<Record<string, unknown>>
}

export interface DshResumeAgentOptions {
  readonly resumeSessionId: string
  readonly agentOptions?: Readonly<Record<string, unknown>>
}

/** DSH `ctx.agents` 的最小结构接口。 */
export interface DshAgentRegistryLike {
  create(options: DshCreateAgentOptions): Promise<DshAgentHandleLike>
  resume(options: DshResumeAgentOptions): Promise<DshAgentHandleLike>
}

/** DSH `ctx.sessions` 的持久化屏障；返回值仅表示是否有监听器参与。 */
export interface DshSessionStoreLike {
  flush(session: DshSessionLike): Promise<boolean>
}

export interface DshActivationAdapterOptions {
  readonly agents: DshAgentRegistryLike
  readonly sessions: DshSessionStoreLike
  /** 必须注入 DSH 的 `createUserMessage()`，由 Harness 生成合法、冻结且带 id 的消息。 */
  readonly createUserMessage: (input: DshUserMessageInput) => unknown
  /** 可选地提供 DSH `AgentOptions`、session metadata 等创建期配置。 */
  readonly createOptions?: (agent: RuntimeAgent) => Omit<DshCreateAgentOptions, 'sessionId'>
  /** 可选地提供恢复期的 DSH `AgentOptions`。 */
  readonly resumeOptions?: (agent: RuntimeAgent, checkpoint: RuntimeCheckpoint | undefined) => Omit<DshResumeAgentOptions, 'resumeSessionId'>
}

/**
 * 将 Aureways 的 ActivationAdapter 映射到 DSH 当前公开 Agent/Session API。
 *
 * 该类不创建第二套 Agent Loop：DSH 保持对会话、inbox 与取消语义的唯一所有权；
 * Aureways 只持有 DSH 返回的 lifecycle handle，并负责其持久生命周期编排。
 */
export class DshActivationAdapter implements ActivationAdapter {
  readonly #options: DshActivationAdapterOptions

  constructor(options: DshActivationAdapterOptions) {
    this.#options = options
  }

  async create(agent: RuntimeAgent): Promise<ActivationHandle> {
    const extra = this.#options.createOptions?.(agent)
    const handle = await this.#options.agents.create({
      ...(extra ?? {}),
      // 固定由 Aureways 分配的稳定 Session 身份，不能被注入配置覆盖。
      sessionId: agent.sessionId,
    })
    return this.#wrap(agent, handle)
  }

  async resume(agent: RuntimeAgent, checkpoint: RuntimeCheckpoint | undefined): Promise<ActivationHandle> {
    if (checkpoint !== undefined && checkpoint.sessionId !== agent.sessionId) {
      throw new Error(`Checkpoint session ${checkpoint.sessionId} 与 Agent session ${agent.sessionId} 不匹配`)
    }
    const extra = this.#options.resumeOptions?.(agent, checkpoint)
    const handle = await this.#options.agents.resume({
      ...(extra ?? {}),
      // 恢复必须回到同一持久 Session，不能借由可选配置跳转到其他记录。
      resumeSessionId: agent.sessionId,
    })
    return this.#wrap(agent, handle)
  }

  /** 将 DSH 的同步 inbox 操作封装为 Runtime 的异步端口。 */
  #wrap(runtimeAgent: RuntimeAgent, handle: DshAgentHandleLike): ActivationHandle {
    if (handle.agent.id !== runtimeAgent.sessionId) {
      throw new Error(`DSH Agent id ${handle.agent.id} 与请求 session ${runtimeAgent.sessionId} 不一致`)
    }
    const dshAgent = handle.agent
    return {
      agentId: runtimeAgent.agentId,
      sessionId: runtimeAgent.sessionId,
      followup: async (input) => { dshAgent.followup(this.#message('followup', input)) },
      steer: async (input) => { dshAgent.steer(this.#message('steer', input)) },
      cancel: async (cause, options) => { dshAgent.cancel(cause, options) },
      whenIdle: async () => { await dshAgent.whenIdle() },
      flush: async () => {
        // DSH flush 只返回 listener 是否参与，不暴露 durable event seq。
        // 先取当前尾部作为保守水位，避免把 flush 期间新增的事件错误记入 checkpoint。
        const throughSequence = Math.max(0, dshAgent.session.seq - 1)
        await this.#options.sessions.flush(dshAgent.session)
        return throughSequence
      },
      dispose: async () => { await handle.dispose() },
    }
  }

  /** 构造交给 DSH 正式消息工厂的插件来源消息，保留输入 JSON 的精确边界。 */
  #message(kind: 'followup' | 'steer', input: JsonValue): unknown {
    return this.#options.createUserMessage({
      content: [{ type: 'text', text: JSON.stringify(input) }],
      source: {
        kind: 'plugin',
        plugin: 'aureways',
        form: 'notice',
        summary: kind === 'followup' ? 'Aureways runtime task' : 'Aureways interrupt instruction',
      },
    })
  }
}
