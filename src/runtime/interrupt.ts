import type {
  InterruptDecision,
  ReplanAdapter,
  RuntimeAgent,
  RuntimeInterrupt,
  RuntimeStore,
} from './contracts.js'
import { CheckpointCoordinator } from './checkpoint.js'
import { ActivationSupervisor } from './supervisor.js'

/**
 * 中断控制器只编排安全点，不自行解释用户 payload。
 * 决策由 Agent 通过 ReplanAdapter 给出，并以显式状态写回 Store。
 */
export class InterruptController {
  readonly #store: RuntimeStore
  readonly #supervisor: ActivationSupervisor
  readonly #checkpoints: CheckpointCoordinator
  readonly #replan: ReplanAdapter

  constructor(
    store: RuntimeStore,
    supervisor: ActivationSupervisor,
    checkpoints: CheckpointCoordinator,
    replan: ReplanAdapter,
  ) {
    this.#store = store
    this.#supervisor = supervisor
    this.#checkpoints = checkpoints
    this.#replan = replan
  }

  /**
   * 在收到请求时立即执行 urgent cancel；soft interrupt 仅排队，
   * 由 AlwaysLoop 在任务边界调用 `settleAtSafePoint`。
   */
  async request(agent: RuntimeAgent, interrupt: RuntimeInterrupt): Promise<void> {
    if (interrupt.mode !== 'urgent') return
    const handle = this.#supervisor.getLive(agent.agentId)
    if (handle === undefined) return
    await handle.cancel(
      { kind: 'hook', reason: `aureways-interrupt:${interrupt.interruptId}` },
      { keepInbox: true },
    )
  }

  /** 在已记录工具结果、turn 停止或 cancel 收敛后处理优先级最高的中断。 */
  async settleAtSafePoint(agent: RuntimeAgent): Promise<InterruptDecision | undefined> {
    const pending = await this.#store.listRequestedInterrupts(agent.agentId)
    const interrupt = pending[0]
    if (interrupt === undefined) return undefined
    const liveAgent = await this.#store.getAgent(agent.agentId)
    if (liveAgent === undefined || liveAgent.state === 'stopped') return undefined
    const interrupting = liveAgent.state === 'interrupting'
      ? liveAgent
      : await this.#store.transitionAgent(liveAgent.agentId, liveAgent.revision, 'interrupting')
    const handle = await this.#supervisor.wake(interrupting)

    try {
      if (interrupt.mode === 'urgent') await handle.whenIdle()
      await this.#checkpoints.checkpoint(interrupting, handle, 'interrupt')
      const acknowledged = await this.#store.transitionInterrupt(
        interrupt.interruptId,
        interrupt.revision,
        'acknowledged',
      )
      const replanning = await this.#store.transitionInterrupt(
        acknowledged.interruptId,
        acknowledged.revision,
        'replanning',
      )
      const decision = await this.#replan.requestDecision(handle, replanning)
      await this.#applyDecision(interrupting, replanning, decision)
      return decision
    } catch (error) {
      const latest = (await this.#store.listRequestedInterrupts(agent.agentId))
        .find((item) => item.interruptId === interrupt.interruptId)
      if (latest !== undefined) await this.#store.transitionInterrupt(latest.interruptId, latest.revision, 'failed')
      throw error
    }
  }

  async #applyDecision(agent: RuntimeAgent, interrupt: RuntimeInterrupt, decision: InterruptDecision): Promise<void> {
    const current = await this.#store.getAgent(agent.agentId)
    if (current === undefined) throw new Error(`找不到 Agent ${agent.agentId}`)
    const target = decision === 'pause'
      ? 'paused'
      : decision === 'terminate'
        ? 'stopped'
        : 'idle'
    await this.#store.transitionAgent(current.agentId, current.revision, target)
    await this.#store.transitionInterrupt(interrupt.interruptId, interrupt.revision, 'resolved')
  }
}
