/** 所有可预期的 Aureways 领域失败都使用此基类。 */
export class AurewaysDomainError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly details: Readonly<Record<string, unknown>> = {},
  ) {
    super(message)
    this.name = 'AurewaysDomainError'
  }
}

export class InvalidStateTransitionError extends AurewaysDomainError {
  constructor(entity: string, from: string, to: string) {
    super(`Invalid ${entity} state transition: ${from} -> ${to}`, 'INVALID_STATE_TRANSITION', { entity, from, to })
    this.name = 'InvalidStateTransitionError'
  }
}

export class RevisionConflictError extends AurewaysDomainError {
  constructor(entity: string, id: string, expected: number) {
    super(`Revision conflict for ${entity} ${id}`, 'REVISION_CONFLICT', { entity, id, expected })
    this.name = 'RevisionConflictError'
  }
}

export class EntityNotFoundError extends AurewaysDomainError {
  constructor(entity: string, id: string) {
    super(`${entity} ${id} was not found`, 'ENTITY_NOT_FOUND', { entity, id })
    this.name = 'EntityNotFoundError'
  }
}

export class LeaseConflictError extends AurewaysDomainError {
  constructor(agentId: string, holderId: string) {
    super(`Agent ${agentId} is leased by another activation`, 'LEASE_CONFLICT', { agentId, holderId })
    this.name = 'LeaseConflictError'
  }
}
