import { InvalidStateTransitionError } from './errors.js'
import type { ActionState, AgentState, InterruptState, RuntimeTaskState } from './models.js'

const transitions = {
  agent: {
    active: ['idle', 'running', 'paused', 'terminating', 'failed', 'error'],
    cold: ['starting', 'recovering', 'paused', 'stopped', 'error'],
    starting: ['idle', 'running', 'cold', 'error', 'paused'],
    idle: ['active', 'running', 'interrupting', 'paused', 'terminating', 'failed', 'cold', 'stopped', 'error'],
    running: ['idle', 'cold', 'interrupting', 'paused', 'terminating', 'failed', 'error'],
    interrupting: ['idle', 'cold', 'paused', 'stopped', 'error'],
    recovering: ['starting', 'idle', 'cold', 'paused', 'error'],
    paused: ['active', 'starting', 'recovering', 'terminating', 'failed', 'stopped', 'error'],
    terminating: ['terminated', 'stopped', 'failed', 'error'],
    stopped: [],
    terminated: [],
    failed: ['active', 'starting', 'recovering', 'terminating', 'error'],
    error: ['recovering', 'paused', 'terminating', 'stopped'],
  },
  task: { queued: ['running', 'cancelled'], running: ['waiting', 'completed', 'failed', 'cancelled'], waiting: ['running', 'cancelled', 'failed'], completed: [], failed: ['queued', 'cancelled'], cancelled: [] },
  interrupt: { pending: ['acknowledged', 'dismissed'], acknowledged: ['applied', 'dismissed'], applied: [], dismissed: [] },
  action: { planned: ['dispatched', 'cancelled'], dispatched: ['acknowledged', 'succeeded', 'failed', 'outcome-unknown'], acknowledged: ['succeeded', 'failed', 'outcome-unknown'], succeeded: [], failed: [], 'outcome-unknown': ['succeeded', 'failed'], cancelled: [] },
} as const

/** 验证状态切换，避免恢复路径把终态对象重新投入执行。 */
export function assertStateTransition<K extends keyof typeof transitions>(kind: K, from: (typeof transitions)[K] extends Record<string, unknown> ? keyof (typeof transitions)[K] : never, to: string): void {
  if (!(transitions[kind][from] as readonly string[]).includes(to)) throw new InvalidStateTransitionError(kind, String(from), to)
}

export const assertAgentTransition = (from: AgentState, to: AgentState): void => assertStateTransition('agent', from, to)
export const assertTaskTransition = (from: RuntimeTaskState, to: RuntimeTaskState): void => assertStateTransition('task', from, to)
export const assertInterruptTransition = (from: InterruptState, to: InterruptState): void => assertStateTransition('interrupt', from, to)
export const assertActionTransition = (from: ActionState, to: ActionState): void => assertStateTransition('action', from, to)
