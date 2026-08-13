import type { JsonObject, ProtocolResult } from './contracts.js'
import { A2AAdapter } from './a2a.js'

/** ACP 仅复用任务语义；会话连接断开不会取消已提交的 Runtime Task。 */
export type ACPMethod = 'session/prompt' | 'session/cancel'

export interface ACPRequest {
  readonly method: ACPMethod
  readonly params: JsonObject
}

/**
 * ACP 到 Aureways 的薄映射。`sessionId` 可由传输层保留用于关联，
 * 但不会成为 Agent、Task 或执行 Handle 的生命周期所有者。
 */
export class ACPAdapter {
  constructor(private readonly a2a: A2AAdapter) {}

  async dispatch(request: ACPRequest): Promise<ProtocolResult> {
    switch (request.method) {
      case 'session/prompt':
        return this.a2a.dispatch({ method: 'task.submit', params: promptParams(request.params) })
      case 'session/cancel':
        return this.a2a.dispatch({ method: 'task.cancel', params: cancelParams(request.params) })
    }
  }
}

/** 将 ACP prompt 的文本和结构化输入收敛成稳定的 Runtime Task 输入。 */
function promptParams(params: JsonObject): JsonObject {
  const prompt = params.prompt
  return {
    agentId: params.agentId ?? null,
    instruction: typeof prompt === 'string' ? prompt : (params.instruction ?? null),
    ...(params.input === undefined ? {} : { input: params.input }),
    ...(params.priority === undefined ? {} : { priority: params.priority }),
    ...(params.idempotencyKey === undefined ? {} : { idempotencyKey: params.idempotencyKey }),
  }
}

/** ACP cancel 必须明确指向持久 Task，避免以连接关闭隐式取消工作。 */
function cancelParams(params: JsonObject): JsonObject {
  return {
    taskId: params.taskId ?? null,
    ...(params.reason === undefined ? {} : { reason: params.reason }),
  }
}
