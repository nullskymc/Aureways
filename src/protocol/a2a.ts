import type { JsonValue } from '../domain/index.js'
import { agentId, type AurewaysProtocolService, type JsonObject, type ProtocolResult, taskId } from './contracts.js'
import { serializeAgent, serializeInterrupt, serializeTask } from './serialize.js'

export type A2AMethod = 'task.submit' | 'task.get' | 'task.list' | 'task.cancel' | 'agent.status' | 'agent.interrupt'

export interface A2ARequest {
  readonly id?: string
  readonly method: A2AMethod
  readonly params: JsonObject
}

/**
 * 传输无关的 A2A 核心：HTTP、stdio、WebSocket 只需把请求解码为该对象。
 * 不将客户端连接当作 Agent 或 Task 的所有者。
 */
export class A2AAdapter {
  constructor(private readonly service: AurewaysProtocolService) {}

  async dispatch(request: A2ARequest): Promise<ProtocolResult> {
    try {
      switch (request.method) {
        case 'task.submit': return success(await this.submit(request.params))
        case 'task.get': return success(this.get(request.params))
        case 'task.list': return success(this.list(request.params))
        case 'task.cancel': return success(await this.cancel(request.params))
        case 'agent.status': return success(this.status(request.params))
        case 'agent.interrupt': return success(await this.interrupt(request.params))
      }
    } catch (error) {
      return failure(error)
    }
  }

  private async submit(params: JsonObject): Promise<JsonValue> {
    const targetAgentId = requiredString(params, 'agentId')
    const instruction = requiredString(params, 'instruction')
    const priority = optionalNumber(params, 'priority')
    const idempotencyKey = optionalString(params, 'idempotencyKey')
    const task = await this.service.submitTask({
      agentId: agentId(targetAgentId), instruction,
      ...(params.input === undefined ? {} : { input: params.input }),
      ...(priority === undefined ? {} : { priority }),
      ...(idempotencyKey === undefined ? {} : { idempotencyKey }),
    })
    return serializeTask(task)
  }

  private get(params: JsonObject): JsonValue {
    const task = this.service.getTask(taskId(requiredString(params, 'taskId')))
    if (task === undefined) throw notFound('Task')
    return serializeTask(task)
  }

  private list(params: JsonObject): JsonValue {
    const targetAgentId = requiredString(params, 'agentId')
    return this.service.listTasks(agentId(targetAgentId)).map(serializeTask)
  }

  private async cancel(params: JsonObject): Promise<JsonValue> {
    const task = await this.service.cancelTask(taskId(requiredString(params, 'taskId')), optionalString(params, 'reason'))
    return serializeTask(task)
  }

  private status(params: JsonObject): JsonValue {
    const targetAgentId = optionalString(params, 'agentId')
    if (targetAgentId === undefined) {
      const status = this.service.status()
      return { state: status.state, dataDirectory: status.dataDirectory, persistentAgents: status.persistentAgents, runtimeBound: status.runtimeBound }
    }
    const agent = this.service.getAgent(agentId(targetAgentId))
    if (agent === undefined) throw notFound('Agent')
    return serializeAgent(agent)
  }

  private async interrupt(params: JsonObject): Promise<JsonValue> {
    const targetAgentId = requiredString(params, 'agentId')
    const priority = requiredString(params, 'priority')
    if (priority !== 'soft' && priority !== 'urgent') throw invalid('priority 必须为 soft 或 urgent')
    const targetTaskId = optionalString(params, 'taskId')
    const interrupt = await this.service.interrupt({
      agentId: agentId(targetAgentId), priority, instruction: requiredString(params, 'instruction'),
      source: optionalString(params, 'source') ?? 'a2a',
      ...(targetTaskId === undefined ? {} : { taskId: taskId(targetTaskId) }),
    })
    return serializeInterrupt(interrupt)
  }
}

function success(data: JsonValue): ProtocolResult { return { ok: true, data } }
function invalid(message: string): Error { const error = new Error(message); error.name = 'InvalidRequest'; return error }
function notFound(kind: string): Error { const error = new Error(`${kind} 不存在`); error.name = 'NotFound'; return error }
function failure(error: unknown): ProtocolResult {
  const message = error instanceof Error ? error.message : '未知错误'
  const code = error instanceof Error && error.name === 'InvalidRequest' ? 'invalid-request'
    : error instanceof Error && error.name === 'NotFound' ? 'not-found' : 'internal'
  return { ok: false, error: { code, message } }
}
function requiredString(params: JsonObject, key: string): string {
  const value = params[key]
  if (typeof value !== 'string' || value.length === 0) throw invalid(`${key} 必须是非空字符串`)
  return value
}
function optionalString(params: JsonObject, key: string): string | undefined {
  const value = params[key]
  if (value === undefined) return undefined
  if (typeof value !== 'string') throw invalid(`${key} 必须是字符串`)
  return value
}
function optionalNumber(params: JsonObject, key: string): number | undefined {
  const value = params[key]
  if (value === undefined) return undefined
  if (typeof value !== 'number' || !Number.isFinite(value)) throw invalid(`${key} 必须是有限数字`)
  return value
}
