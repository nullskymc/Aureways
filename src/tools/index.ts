import type { JsonValue } from '../domain/index.js'
import { A2AAdapter, type AurewaysProtocolService, type JsonObject, type ProtocolResult } from '../protocol/index.js'

/** 不绑定某个 Harness 的工具描述；Harness 可将其投影为各自的 Tool Schema。 */
export interface AurewaysToolDescriptor {
  readonly name: string
  readonly description: string
  readonly inputSchema: JsonValue
  readonly execute: (input: JsonValue) => Promise<ProtocolResult>
}

/**
 * 生成稳定 JSON 输入/输出工具。每次执行仅调用 Service 公共契约，
 * 不缓存 Activation、AgentHandle 或客户端连接对象。
 */
export function createAurewaysTools(service: AurewaysProtocolService): readonly AurewaysToolDescriptor[] {
  const a2a = new A2AAdapter(service)
  return descriptors.map((descriptor) => ({
    ...descriptor,
    async execute(input: JsonValue): Promise<ProtocolResult> {
      if (!isObject(input)) return invalidInput('工具输入必须是 JSON 对象')
      return a2a.dispatch({ method: descriptor.method, params: input })
    },
  }))
}

interface DescriptorTemplate {
  readonly name: string
  readonly description: string
  readonly method: Parameters<A2AAdapter['dispatch']>[0]['method']
  readonly inputSchema: JsonValue
}

const descriptors: readonly DescriptorTemplate[] = [
  { name: 'aureways_task_submit', description: '向持久 Agent 提交可恢复任务。', method: 'task.submit', inputSchema: schema(['agentId', 'instruction']) },
  { name: 'aureways_task_get', description: '查询持久任务状态与结果。', method: 'task.get', inputSchema: schema(['taskId']) },
  { name: 'aureways_task_list', description: '列出 Agent 的持久任务。', method: 'task.list', inputSchema: schema(['agentId']) },
  { name: 'aureways_task_cancel', description: '显式取消一个持久任务。', method: 'task.cancel', inputSchema: schema(['taskId']) },
  { name: 'aureways_agent_status', description: '查询 Runtime 或指定 Agent 状态。', method: 'agent.status', inputSchema: schema([]) },
  { name: 'aureways_agent_interrupt', description: '向 Agent 投递 soft 或 urgent Interrupt。', method: 'agent.interrupt', inputSchema: schema(['agentId', 'priority', 'instruction']) },
]

/** 轻量 JSON Schema 元数据，实际校验由各 handler 保持一致。 */
function schema(required: readonly string[]): JsonValue {
  return { type: 'object', required, additionalProperties: true }
}
function isObject(value: JsonValue): value is JsonObject { return value !== null && !Array.isArray(value) && typeof value === 'object' }
function invalidInput(message: string): ProtocolResult { return { ok: false, error: { code: 'invalid-request', message } } }
