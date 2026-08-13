import type {
  ActivationHandle,
  CheckpointReason,
  RuntimeAgent,
  RuntimeCheckpoint,
  RuntimeStore,
} from './contracts.js'

/**
 * 在 Session flush 成功后才写 Aureways checkpoint。
 * 该顺序避免 Store 宣称可恢复、而底层 Session 尚未落盘的伪检查点。
 */
export class CheckpointCoordinator {
  readonly #store: RuntimeStore

  constructor(store: RuntimeStore) {
    this.#store = store
  }

  async checkpoint(
    agent: RuntimeAgent,
    handle: ActivationHandle,
    reason: CheckpointReason,
    taskId?: string,
  ): Promise<RuntimeCheckpoint> {
    const throughSequence = await handle.flush()
    return this.#store.createCheckpoint({
      agentId: agent.agentId,
      sessionId: handle.sessionId,
      throughSequence,
      reason,
      taskId,
    })
  }
}
