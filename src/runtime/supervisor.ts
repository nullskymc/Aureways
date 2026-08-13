import type {
  ActivationAdapter,
  ActivationHandle,
  AgentLeasePort,
  RuntimeAgent,
  RuntimeClock,
  RuntimeStore,
} from './contracts.js'
import { systemClock } from './contracts.js'
import { CheckpointCoordinator } from './checkpoint.js'

export interface SupervisorOptions {
  readonly ownerId: string
  readonly idleUnloadMs: number
  readonly leaseDurationMs: number
  readonly clock?: RuntimeClock
}

/**
 * Persistent Agent 与短生命周期 Activation 的唯一映射。
 * 所有 handle 都由 Supervisor 所有，协议层不能直接保存它。
 */
export class ActivationSupervisor {
  readonly #store: RuntimeStore
  readonly #adapter: ActivationAdapter
  readonly #checkpoints: CheckpointCoordinator
  readonly #lease: AgentLeasePort | undefined
  readonly #options: Required<SupervisorOptions>
  readonly #activations = new Map<string, ActivationHandle>()
  readonly #wakePromises = new Map<string, Promise<ActivationHandle>>()
  readonly #idleTimers = new Map<string, ReturnType<typeof setTimeout>>()

  constructor(
    store: RuntimeStore,
    adapter: ActivationAdapter,
    checkpoints: CheckpointCoordinator,
    options: SupervisorOptions,
    lease?: AgentLeasePort,
  ) {
    if (options.idleUnloadMs < 0 || options.leaseDurationMs <= 0) throw new RangeError('Supervisor 时间配置无效')
    this.#store = store
    this.#adapter = adapter
    this.#checkpoints = checkpoints
    this.#lease = lease
    this.#options = { ...options, clock: options.clock ?? systemClock }
  }

  getLive(agentId: string): ActivationHandle | undefined {
    return this.#activations.get(agentId)
  }

  /** 唤醒或恢复 Agent；同一 Agent 的并发唤醒会合并为一次 Activation。 */
  wake(agent: RuntimeAgent): Promise<ActivationHandle> {
    const live = this.#activations.get(agent.agentId)
    if (live !== undefined) {
      this.#cancelIdleTimer(agent.agentId)
      return Promise.resolve(live)
    }
    const pending = this.#wakePromises.get(agent.agentId)
    if (pending !== undefined) return pending

    const promise = this.#wake(agent).finally(() => this.#wakePromises.delete(agent.agentId))
    this.#wakePromises.set(agent.agentId, promise)
    return promise
  }

  /** 为安全点调用方安排延时 cold unload。 */
  scheduleSleep(agent: RuntimeAgent): void {
    this.#cancelIdleTimer(agent.agentId)
    if (agent.state !== 'idle' || this.#options.idleUnloadMs === 0) return
    const timer = setTimeout(() => {
      void this.sleep(agent.agentId)
    }, this.#options.idleUnloadMs)
    this.#idleTimers.set(agent.agentId, timer)
  }

  /** 只允许 idle Agent 冷却；有工作或中断时由调用方再次 wake。 */
  async sleep(agentId: string): Promise<void> {
    this.#cancelIdleTimer(agentId)
    const handle = this.#activations.get(agentId)
    if (handle === undefined) return
    const agent = await this.#store.getAgent(agentId)
    if (agent === undefined || agent.state !== 'idle') return

    try {
      await this.#checkpoints.checkpoint(agent, handle, 'idle-unload')
      const cold = await this.#store.transitionAgent(agentId, agent.revision, 'cold')
      await handle.dispose()
      this.#activations.delete(agentId)
      await this.#releaseLease(cold.agentId)
    } catch (error) {
      // 卸载不完整时保持 handle 可达，避免下一次 wake 创建第二个 Activation。
      const current = await this.#store.getAgent(agentId)
      if (current !== undefined && current.state !== 'error') {
        await this.#store.transitionAgent(agentId, current.revision, 'error')
      }
      throw error
    }
  }

  /** 插件卸载的有序收敛入口。 */
  async shutdown(): Promise<void> {
    for (const timer of this.#idleTimers.values()) clearTimeout(timer)
    this.#idleTimers.clear()
    await Promise.all([...this.#activations.keys()].map(async (agentId) => {
      const handle = this.#activations.get(agentId)
      const agent = await this.#store.getAgent(agentId)
      if (handle === undefined || agent === undefined) return
      try {
        await handle.whenIdle()
        await this.#checkpoints.checkpoint(agent, handle, 'shutdown')
        // 插件卸载只是释放当前 Activation；Persistent Agent 身份必须可在下次启动恢复。
        const cold = await this.#store.transitionAgent(agentId, agent.revision, 'cold')
        await handle.dispose()
        await this.#releaseLease(cold.agentId)
      } finally {
        this.#activations.delete(agentId)
      }
    }))
  }

  async #wake(agent: RuntimeAgent): Promise<ActivationHandle> {
    this.#cancelIdleTimer(agent.agentId)
    await this.#acquireLease(agent.agentId)
    let starting = agent
    if (agent.state === 'cold' || agent.state === 'paused' || agent.state === 'recovering') {
      starting = await this.#store.transitionAgent(agent.agentId, agent.revision, 'starting')
    }

    try {
      const checkpoint = await this.#store.getLatestCheckpoint(agent.agentId)
      const handle = checkpoint === undefined
        ? await this.#adapter.create(starting)
        : await this.#adapter.resume(starting, checkpoint)
      this.#activations.set(agent.agentId, handle)
      await this.#store.transitionAgent(starting.agentId, starting.revision, 'idle')
      return handle
    } catch (error) {
      const current = await this.#store.getAgent(agent.agentId)
      if (current !== undefined && current.state !== 'error') {
        await this.#store.transitionAgent(current.agentId, current.revision, 'error')
      }
      await this.#releaseLease(agent.agentId)
      throw error
    }
  }

  async #acquireLease(agentId: string): Promise<void> {
    if (this.#lease === undefined) return
    const accepted = await this.#lease.acquire(agentId, this.#options.ownerId, this.#options.clock.now() + this.#options.leaseDurationMs)
    if (!accepted) throw new Error(`Agent ${agentId} 已被其他 Runtime 持有`)
  }

  async #releaseLease(agentId: string): Promise<void> {
    if (this.#lease !== undefined) await this.#lease.release(agentId, this.#options.ownerId)
  }

  #cancelIdleTimer(agentId: string): void {
    const timer = this.#idleTimers.get(agentId)
    if (timer !== undefined) clearTimeout(timer)
    this.#idleTimers.delete(agentId)
  }
}
