/** 品牌化 ID，避免把不同领域实体的字符串 ID 混用。 */
export type Brand<Value, Name extends string> = Value & { readonly __brand: Name }

export type AgentId = Brand<string, 'AgentId'>
export type RuntimeTaskId = Brand<string, 'RuntimeTaskId'>
export type InterruptId = Brand<string, 'InterruptId'>
export type CheckpointId = Brand<string, 'CheckpointId'>
export type WorkflowId = Brand<string, 'WorkflowId'>
export type ActionId = Brand<string, 'ActionId'>
export type EpisodicMemoryId = Brand<string, 'EpisodicMemoryId'>
export type ContextBundleId = Brand<string, 'ContextBundleId'>
export type EventId = Brand<string, 'EventId'>
export type LeaseHolderId = Brand<string, 'LeaseHolderId'>

/** 为持久实体产生可读、可排序且带领域前缀的 ID。 */
export function createId<Id extends Brand<string, string>>(prefix: string): Id {
  return `${prefix}_${crypto.randomUUID()}` as Id
}

export const createAgentId = (): AgentId => createId<AgentId>('agt')
export const createRuntimeTaskId = (): RuntimeTaskId => createId<RuntimeTaskId>('tsk')
export const createInterruptId = (): InterruptId => createId<InterruptId>('int')
export const createCheckpointId = (): CheckpointId => createId<CheckpointId>('ckp')
export const createWorkflowId = (): WorkflowId => createId<WorkflowId>('wfl')
export const createActionId = (): ActionId => createId<ActionId>('act')
export const createEpisodicMemoryId = (): EpisodicMemoryId => createId<EpisodicMemoryId>('mem')
export const createContextBundleId = (): ContextBundleId => createId<ContextBundleId>('ctx')
export const createEventId = (): EventId => createId<EventId>('evt')
