import type {
  ActivationHandle,
  RuntimeAgent,
  RuntimeStore,
  RuntimeTask,
  RuntimeTaskState,
} from './contracts.js'
import { CheckpointCoordinator } from './checkpoint.js'
import { InterruptController } from './interrupt.js'
import { AgentTaskScheduler } from './scheduler.js'
import { ActivationSupervisor } from './supervisor.js'

/** Task 处理结果不承载隐藏上下文；附加信息应由 Store/Context 模块独立持久化。 */
export interface TaskExecutor {
  execute(task: RuntimeTask, handle: ActivationHandle): Promise<Exclude<RuntimeTaskState, 'submitted' | 'queued' | 'working'>>
}

/**
 * 事件驱动 Always Loop。
 * 每次 wake 仅 drain 已持久化的 runnable work；无 work 时进入 idle，而不是轮询模型。
 */
export class AlwaysLoop {
  readonly #store: RuntimeStore
  readonly #supervisor: ActivationSupervisor
  readonly #scheduler: AgentTaskScheduler
  readonly #interrupts: InterruptController
  readonly #checkpoints: CheckpointCoordinator
  readonly #executor: TaskExecutor

  constructor(
    store: RuntimeStore,
    supervisor: ActivationSupervisor,
    scheduler: AgentTaskScheduler,
    interrupts: InterruptController,
    checkpoints: CheckpointCoordinator,
    executor: TaskExecutor,
  ) {
    this.#store = store
    this.#supervisor = supervisor
    this.#scheduler = scheduler
    this.#interrupts = interrupts
    this.#checkpoints = checkpoints
    this.#executor = executor
  }

  /** 由提交任务、中断、定时器或外部事件触发，不创建常驻 busy loop。 */
  wake(agent: RuntimeAgent): Promise<void> {
    return this.#scheduler.schedule(agent.agentId, async () => this.#drain(agent.agentId))
  }

  async #drain(agentId: string): Promise<void> {
    let agent = await this.#store.getAgent(agentId)
    if (agent === undefined || agent.state === 'stopped' || agent.state === 'error') return
    const handle = await this.#supervisor.wake(agent)

    // 每轮先在安全点结算 interrupt，避免新任务压过更高优先级的控制事件。
    const decision = await this.#interrupts.settleAtSafePoint(agent)
    if (decision === 'pause' || decision === 'terminate') return

    while (true) {
      agent = await this.#store.getAgent(agentId)
      if (agent === undefined || agent.state === 'paused' || agent.state === 'stopped' || agent.state === 'error') return
      const task = (await this.#store.listRunnableTasks(agentId))[0]
      if (task === undefined) {
        if (agent.state !== 'idle') {
          agent = await this.#store.transitionAgent(agent.agentId, agent.revision, 'idle')
        }
        this.#supervisor.scheduleSleep(agent)
        return
      }
      await this.#runTask(agent, task, handle)
      const afterTask = await this.#store.getAgent(agentId)
      if (afterTask === undefined) return
      const afterDecision = await this.#interrupts.settleAtSafePoint(afterTask)
      if (afterDecision === 'pause' || afterDecision === 'terminate') return
    }
  }

  async #runTask(agent: RuntimeAgent, task: RuntimeTask, handle: ActivationHandle): Promise<void> {
    const runningAgent = agent.state === 'running'
      ? agent
      : await this.#store.transitionAgent(agent.agentId, agent.revision, 'running')
    const workingTask = await this.#store.transitionTask(task.taskId, task.revision, 'working')
    try {
      const state = await this.#executor.execute(workingTask, handle)
      const currentTask = await this.#store.getAgent(runningAgent.agentId)
      await this.#store.transitionTask(workingTask.taskId, workingTask.revision, state)
      if (currentTask !== undefined) await this.#checkpoints.checkpoint(currentTask, handle, 'turn-end', workingTask.taskId)
    } catch (error) {
      await this.#store.transitionTask(workingTask.taskId, workingTask.revision, 'failed')
      throw error
    }
  }
}
