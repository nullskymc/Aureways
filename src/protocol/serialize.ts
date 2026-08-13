import type { AgentInterrupt, JsonValue, PersistentAgent, RuntimeTask } from '../domain/index.js'

/** 只暴露稳定、可 JSON 序列化的领域字段，不把内部 Handle 或错误对象跨协议传递。 */
export function serializeAgent(agent: PersistentAgent): JsonValue {
  return {
    id: agent.id,
    name: agent.name,
    workspace: agent.workspace,
    state: agent.state,
    goal: agent.goal,
    goalRevision: agent.goalRevision,
    revision: agent.revision,
    createdAt: agent.createdAt,
    updatedAt: agent.updatedAt,
    ...(agent.currentTaskId === undefined ? {} : { currentTaskId: agent.currentTaskId }),
    ...(agent.lastCheckpointId === undefined ? {} : { lastCheckpointId: agent.lastCheckpointId }),
  }
}

/** 保持任务传输格式稳定；未定义字段不写入结果。 */
export function serializeTask(task: RuntimeTask): JsonValue {
  return {
    id: task.id,
    agentId: task.agentId,
    state: task.state,
    instruction: task.instruction,
    revision: task.revision,
    createdAt: task.createdAt,
    updatedAt: task.updatedAt,
    ...(task.input === undefined ? {} : { input: task.input }),
    ...(task.priority === undefined ? {} : { priority: task.priority }),
    ...(task.parentTaskId === undefined ? {} : { parentTaskId: task.parentTaskId }),
    ...(task.idempotencyKey === undefined ? {} : { idempotencyKey: task.idempotencyKey }),
    ...(task.workflowId === undefined ? {} : { workflowId: task.workflowId }),
    ...(task.result === undefined ? {} : { result: task.result as JsonValue }),
    ...(task.failure === undefined ? {} : { failure: { code: task.failure.code, message: task.failure.message } }),
  }
}

/** Interrupt 的状态独立于连接生命周期，调用者断开也不改变已持久化记录。 */
export function serializeInterrupt(interrupt: AgentInterrupt): JsonValue {
  return {
    id: interrupt.id,
    agentId: interrupt.agentId,
    taskId: interrupt.taskId ?? null,
    state: interrupt.state,
    priority: interrupt.priority,
    instruction: interrupt.instruction,
    source: interrupt.source,
    revision: interrupt.revision,
    createdAt: interrupt.createdAt,
    updatedAt: interrupt.updatedAt,
    acknowledgedAt: interrupt.acknowledgedAt ?? null,
    appliedAt: interrupt.appliedAt ?? null,
  }
}
