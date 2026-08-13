import type { ActionOutcomeVerifier, RuntimeAgent, RuntimeStore } from './contracts.js'

export interface RecoveryReport {
  readonly recoveredAgentIds: readonly string[]
  readonly pausedAgentIds: readonly string[]
}

/**
 * 崩溃恢复不自动重放含副作用的 action。先核验外部结果，未知结果保留给 Replan。
 */
export class RecoveryCoordinator {
  readonly #store: RuntimeStore
  readonly #verifier: ActionOutcomeVerifier

  constructor(store: RuntimeStore, verifier: ActionOutcomeVerifier) {
    this.#store = store
    this.#verifier = verifier
  }

  async recover(): Promise<RecoveryReport> {
    const stale = await this.#store.listAgentsInStates(['running', 'interrupting', 'recovering'])
    const recoveredAgentIds: string[] = []
    const pausedAgentIds: string[] = []

    for (const agent of stale) {
      const uncertain = await this.#reconcileActions(agent)
      const current = await this.#store.getAgent(agent.agentId)
      if (current === undefined) continue
      const state = uncertain ? 'paused' : 'recovering'
      await this.#store.transitionAgent(current.agentId, current.revision, state)
      if (uncertain) pausedAgentIds.push(agent.agentId)
      else recoveredAgentIds.push(agent.agentId)
    }
    return { recoveredAgentIds, pausedAgentIds }
  }

  async #reconcileActions(agent: RuntimeAgent): Promise<boolean> {
    let hasUnknownOutcome = false
    for (const action of await this.#store.listUncertainActions(agent.agentId)) {
      const outcome = await this.#verifier.verify(action)
      if (outcome === 'unknown') {
        hasUnknownOutcome = true
        if (action.state !== 'outcome-unknown') {
          await this.#store.transitionAction(action.actionId, action.revision, 'outcome-unknown')
        }
      } else {
        await this.#store.transitionAction(action.actionId, action.revision, outcome)
      }
    }
    return hasUnknownOutcome
  }
}
