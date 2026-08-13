import type {
  AgentId,
  AgentInterrupt,
  JsonValue,
  PersistentAgent,
  RuntimeTask,
  RuntimeTaskId,
} from '../domain/index.js'
import type {
  AurewaysStatus,
  CreatePersistentAgentInput,
  RequestInterruptInput,
  SubmitTaskInput,
} from '../service.js'

/**
 * 协议层仅依赖这个公共契约，不接触 DSH Handle、Session 或 Cordis Context。
 * `listTasks` 与 `cancelTask` 是 V0.1 对外协议所需、但当前 Service 尚未提供的方法。
 */
export interface AurewaysProtocolService {
  status(): AurewaysStatus
  createAgent(input: CreatePersistentAgentInput): PersistentAgent
  getAgent(agentId: AgentId): PersistentAgent | undefined
  listAgents(): readonly PersistentAgent[]
  submitTask(input: SubmitTaskInput): Promise<RuntimeTask>
  getTask(taskId: RuntimeTaskId): RuntimeTask | undefined
  listTasks(agentId: AgentId): readonly RuntimeTask[]
  cancelTask(taskId: RuntimeTaskId, reason?: string): Promise<RuntimeTask>
  interrupt(input: RequestInterruptInput): Promise<AgentInterrupt>
}

/** A2A/ACP 调用边界只允许 JSON 数据，避免把函数和运行时对象泄漏出去。 */
export type JsonObject = { readonly [key: string]: JsonValue }

export interface ProtocolFailure {
  readonly code: 'invalid-request' | 'not-found' | 'conflict' | 'unsupported' | 'internal'
  readonly message: string
}

export type ProtocolResult =
  | { readonly ok: true; readonly data: JsonValue }
  | { readonly ok: false; readonly error: ProtocolFailure }

/** 将协议字符串显式转换为领域 ID；格式与存在性仍由 Service 作为权威判断。 */
export function agentId(value: string): AgentId {
  return value as AgentId
}

/** 将协议字符串显式转换为领域 ID；格式与存在性仍由 Service 作为权威判断。 */
export function taskId(value: string): RuntimeTaskId {
  return value as RuntimeTaskId
}
