/** Agent 内串行、跨 Agent 并行的调度器。 */

export interface SchedulerOptions {
  readonly maxConcurrentAgents: number
}

export type ScheduledWork<T> = () => Promise<T>

interface QueueItem<T> {
  readonly work: ScheduledWork<T>
  readonly resolve: (value: T | PromiseLike<T>) => void
  readonly reject: (reason: unknown) => void
}

/**
 * 以 AgentId 为键的公平串行队列。
 * 同一 Agent 始终仅运行一个 work；不同 Agent 最多按全局上限并行。
 */
export class AgentTaskScheduler {
  readonly #queues = new Map<string, QueueItem<unknown>[]>()
  readonly #runningAgents = new Set<string>()
  readonly #readyAgents: string[] = []
  readonly #readySet = new Set<string>()
  readonly #maxConcurrentAgents: number
  #activeCount = 0
  #closed = false

  constructor(options: SchedulerOptions) {
    if (!Number.isSafeInteger(options.maxConcurrentAgents) || options.maxConcurrentAgents < 1) {
      throw new RangeError('maxConcurrentAgents 必须是大于零的安全整数')
    }
    this.#maxConcurrentAgents = options.maxConcurrentAgents
  }

  /** 将任务追加到指定 Agent 的尾部，并在可用 slot 中启动。 */
  schedule<T>(agentId: string, work: ScheduledWork<T>): Promise<T> {
    if (this.#closed) return Promise.reject(new Error('调度器已经关闭'))

    return new Promise<T>((resolve, reject) => {
      const queue = this.#queues.get(agentId) ?? []
      queue.push({ work, resolve, reject } as QueueItem<unknown>)
      this.#queues.set(agentId, queue)
      this.#markReady(agentId)
      this.#drain()
    })
  }

  /** 等待目前已提交的工作收敛，不阻止随后继续调度。 */
  async whenIdle(): Promise<void> {
    while (this.#activeCount > 0 || this.#queues.size > 0) {
      await new Promise<void>((resolve) => setTimeout(resolve, 0))
    }
  }

  /** 拒绝尚未开始的 work；运行中的 work 仍由其自身安全点结束。 */
  close(reason = new Error('调度器已经关闭')): void {
    this.#closed = true
    for (const queue of this.#queues.values()) {
      for (const item of queue) item.reject(reason)
    }
    this.#queues.clear()
    this.#readyAgents.length = 0
    this.#readySet.clear()
  }

  #markReady(agentId: string): void {
    if (this.#runningAgents.has(agentId) || this.#readySet.has(agentId)) return
    this.#readyAgents.push(agentId)
    this.#readySet.add(agentId)
  }

  #drain(): void {
    while (!this.#closed && this.#activeCount < this.#maxConcurrentAgents && this.#readyAgents.length > 0) {
      const agentId = this.#readyAgents.shift()
      if (agentId === undefined) return
      this.#readySet.delete(agentId)
      if (this.#runningAgents.has(agentId) || (this.#queues.get(agentId)?.length ?? 0) === 0) continue
      this.#runNext(agentId)
    }
  }

  #runNext(agentId: string): void {
    const queue = this.#queues.get(agentId)
    const item = queue?.shift()
    if (item === undefined) return

    this.#runningAgents.add(agentId)
    this.#activeCount += 1
    void Promise.resolve()
      .then(item.work)
      .then(item.resolve, item.reject)
      .finally(() => {
        this.#runningAgents.delete(agentId)
        this.#activeCount -= 1
        if ((this.#queues.get(agentId)?.length ?? 0) > 0) this.#markReady(agentId)
        else this.#queues.delete(agentId)
        this.#drain()
      })
  }
}
