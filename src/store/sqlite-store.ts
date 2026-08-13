import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import {
  EntityNotFoundError,
  LeaseConflictError,
  RevisionConflictError,
  assertActionTransition,
  assertAgentTransition,
  assertInterruptTransition,
  assertTaskTransition,
  type ActionJournalEntry,
  type AgentId,
  type AgentInterrupt,
  type Checkpoint,
  type ContextBundle,
  type EpisodicMemory,
  type LeaseHolderId,
  type PersistentAgent,
  type RuntimeTask,
  type WorkflowFrame,
} from '../domain/index.js'
import type { AgentLease, AurewaysStore, MemorySearch } from './types.js'

type EntityKind = 'agent' | 'task' | 'interrupt' | 'checkpoint' | 'workflow' | 'action' | 'memory' | 'context-bundle'
type StoredEntity = PersistentAgent | RuntimeTask | AgentInterrupt | Checkpoint | WorkflowFrame | ActionJournalEntry | EpisodicMemory | ContextBundle
type EntityRow = { readonly payload: string }

/** SQLite State Store：JSON 保留模型演进空间，索引列承载调度和检索热路径。 */
export class SqliteAurewaysStore implements AurewaysStore {
  readonly #database: DatabaseSync
  #initialized = false

  constructor(databasePath: string) {
    mkdirSync(dirname(databasePath), { recursive: true })
    this.#database = new DatabaseSync(databasePath)
  }

  initialize(): void {
    if (this.#initialized) return
    this.#database.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;')
    this.#database.exec(`
      CREATE TABLE IF NOT EXISTS aureways_schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS aureways_entities (
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, agent_id TEXT, state TEXT, revision INTEGER NOT NULL,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, payload TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS aureways_entities_agent_kind_idx ON aureways_entities(agent_id, kind, updated_at DESC);
      CREATE INDEX IF NOT EXISTS aureways_entities_kind_state_idx ON aureways_entities(kind, state, updated_at DESC);
      CREATE TABLE IF NOT EXISTS aureways_idempotency (
        scope TEXT NOT NULL, key TEXT NOT NULL, entity_id TEXT NOT NULL, created_at INTEGER NOT NULL,
        PRIMARY KEY (scope, key)
      );
      CREATE TABLE IF NOT EXISTS aureways_leases (
        agent_id TEXT PRIMARY KEY, holder_id TEXT NOT NULL, expires_at INTEGER NOT NULL
      );
      CREATE VIRTUAL TABLE IF NOT EXISTS aureways_memory_fts USING fts5(
        id UNINDEXED, agent_id UNINDEXED, content, tags
      );
      INSERT OR IGNORE INTO aureways_schema_migrations(version, applied_at) VALUES (1, unixepoch() * 1000);
      INSERT INTO aureways_memory_fts(id, agent_id, content, tags)
      SELECT e.id, e.agent_id, json_extract(e.payload, '$.content'), json_extract(e.payload, '$.tags')
      FROM aureways_entities e
      WHERE e.kind = 'memory'
        AND NOT EXISTS (SELECT 1 FROM aureways_memory_fts f WHERE f.id = e.id);
    `)
    this.#initialized = true
  }

  close(): void { this.#database.close() }

  createAgent(agent: PersistentAgent): PersistentAgent { return this.#create('agent', agent) }
  getAgent(id: AgentId): PersistentAgent | undefined { return this.#get('agent', id) as PersistentAgent | undefined }
  listAgents(states?: readonly PersistentAgent['state'][]): readonly PersistentAgent[] {
    return this.#listByKindAndStates('agent', states) as readonly PersistentAgent[]
  }
  updateAgent(agent: PersistentAgent, expectedRevision: number): PersistentAgent { return this.#updateWithStateCheck('agent', agent, expectedRevision) }

  createTask(task: RuntimeTask): RuntimeTask {
    if (!task.idempotencyKey) return this.#create('task', task)
    const scope = `task:${task.agentId}`
    return this.#transaction(() => {
      const prior = this.#database.prepare('SELECT entity_id FROM aureways_idempotency WHERE scope = ? AND key = ?').get(scope, task.idempotencyKey) as { entity_id: string } | undefined
      if (prior) return this.#required('task', prior.entity_id) as RuntimeTask
      const created = this.#create('task', task)
      this.#database.prepare('INSERT INTO aureways_idempotency(scope, key, entity_id, created_at) VALUES (?, ?, ?, ?)').run(scope, task.idempotencyKey, task.id, task.createdAt)
      return created
    })
  }
  getTask(id: RuntimeTask['id']): RuntimeTask | undefined { return this.#get('task', id) as RuntimeTask | undefined }
  listTasks(agentId: AgentId): readonly RuntimeTask[] { return this.#list('task', agentId) as readonly RuntimeTask[] }
  updateTask(task: RuntimeTask, expectedRevision: number): RuntimeTask { return this.#updateWithStateCheck('task', task, expectedRevision) }

  createInterrupt(interrupt: AgentInterrupt): AgentInterrupt { return this.#create('interrupt', interrupt) }
  getInterrupt(id: AgentInterrupt['id']): AgentInterrupt | undefined { return this.#get('interrupt', id) as AgentInterrupt | undefined }
  listPendingInterrupts(agentId: AgentId): readonly AgentInterrupt[] { return this.#list('interrupt', agentId, 'pending') as readonly AgentInterrupt[] }
  updateInterrupt(interrupt: AgentInterrupt, expectedRevision: number): AgentInterrupt { return this.#updateWithStateCheck('interrupt', interrupt, expectedRevision) }

  createCheckpoint(checkpoint: Checkpoint): Checkpoint { return this.#create('checkpoint', checkpoint) }
  getCheckpoint(id: Checkpoint['id']): Checkpoint | undefined { return this.#get('checkpoint', id) as Checkpoint | undefined }
  latestCheckpoint(agentId: AgentId): Checkpoint | undefined {
    const row = this.#database.prepare("SELECT payload FROM aureways_entities WHERE kind = 'checkpoint' AND agent_id = ? ORDER BY created_at DESC LIMIT 1").get(agentId) as EntityRow | undefined
    return row ? this.#parse(row) as Checkpoint : undefined
  }

  createWorkflow(frame: WorkflowFrame): WorkflowFrame { return this.#create('workflow', frame) }
  getWorkflow(id: WorkflowFrame['id']): WorkflowFrame | undefined { return this.#get('workflow', id) as WorkflowFrame | undefined }
  updateWorkflow(frame: WorkflowFrame, expectedRevision: number): WorkflowFrame { return this.#update('workflow', frame, expectedRevision) }

  createAction(action: ActionJournalEntry): ActionJournalEntry { return this.#create('action', action) }
  getAction(id: ActionJournalEntry['id']): ActionJournalEntry | undefined { return this.#get('action', id) as ActionJournalEntry | undefined }
  listActions(agentId: AgentId, states?: readonly ActionJournalEntry['state'][]): readonly ActionJournalEntry[] {
    return this.#listByKindAndStates('action', states, agentId) as readonly ActionJournalEntry[]
  }
  updateAction(action: ActionJournalEntry, expectedRevision: number): ActionJournalEntry { return this.#updateWithStateCheck('action', action, expectedRevision) }

  createMemory(memory: EpisodicMemory): EpisodicMemory {
    return this.#transaction(() => {
      const created = this.#create('memory', memory)
      this.#indexMemory(created)
      return created
    })
  }
  getMemory(id: EpisodicMemory['id']): EpisodicMemory | undefined { return this.#get('memory', id) as EpisodicMemory | undefined }
  updateMemory(memory: EpisodicMemory, expectedRevision: number): EpisodicMemory {
    return this.#transaction(() => {
      const updated = this.#update('memory', memory, expectedRevision)
      this.#indexMemory(updated)
      return updated
    })
  }
  searchMemories(search: MemorySearch): readonly EpisodicMemory[] {
    const limit = search.limit ?? 20
    const now = search.now ?? Date.now()
    const terms = tokenizeFtsQuery(search.query)
    const kinds = search.kinds ?? []
    const kindClause = kinds.length === 0
      ? ''
      : ` AND json_extract(e.payload, '$.kind') IN (${kinds.map(() => '?').join(', ')})`
    const validity = " AND (json_extract(e.payload, '$.validUntil') IS NULL OR json_extract(e.payload, '$.validUntil') > ?)"
    const parameters: unknown[] = [search.agentId, now, ...kinds]
    let sql: string
    if (terms === undefined) {
      sql = `SELECT e.payload FROM aureways_entities e WHERE e.kind = 'memory' AND e.agent_id = ?${validity}${kindClause} ORDER BY e.updated_at DESC, e.id ASC LIMIT ?`
    } else {
      sql = `SELECT e.payload FROM aureways_entities e JOIN aureways_memory_fts f ON f.id = e.id WHERE e.kind = 'memory' AND e.agent_id = ?${validity}${kindClause} AND aureways_memory_fts MATCH ? ORDER BY bm25(aureways_memory_fts), e.updated_at DESC, e.id ASC LIMIT ?`
      parameters.push(terms)
    }
    parameters.push(limit)
    const rows = this.#database.prepare(sql).all(...parameters) as EntityRow[]
    return rows.map((row) => this.#parse(row) as EpisodicMemory)
  }

  createContextBundle(bundle: ContextBundle): ContextBundle { return this.#create('context-bundle', bundle) }
  getContextBundle(id: ContextBundle['id']): ContextBundle | undefined { return this.#get('context-bundle', id) as ContextBundle | undefined }

  acquireLease(agentId: AgentId, holderId: LeaseHolderId, ttlMs: number, now = Date.now()): AgentLease {
    const expiresAt = now + this.#validTtl(ttlMs)
    return this.#transaction(() => {
      const current = this.#database.prepare('SELECT holder_id, expires_at FROM aureways_leases WHERE agent_id = ?').get(agentId) as { holder_id: string; expires_at: number } | undefined
      if (current && current.expires_at > now && current.holder_id !== holderId) throw new LeaseConflictError(agentId, holderId)
      this.#database.prepare('INSERT INTO aureways_leases(agent_id, holder_id, expires_at) VALUES (?, ?, ?) ON CONFLICT(agent_id) DO UPDATE SET holder_id = excluded.holder_id, expires_at = excluded.expires_at').run(agentId, holderId, expiresAt)
      return { agentId, holderId, expiresAt }
    })
  }
  renewLease(lease: AgentLease, ttlMs: number, now = Date.now()): AgentLease {
    const expiresAt = now + this.#validTtl(ttlMs)
    const result = this.#database.prepare('UPDATE aureways_leases SET expires_at = ? WHERE agent_id = ? AND holder_id = ? AND expires_at > ?').run(expiresAt, lease.agentId, lease.holderId, now)
    if (result.changes !== 1) throw new LeaseConflictError(lease.agentId, lease.holderId)
    return { ...lease, expiresAt }
  }
  releaseLease(lease: AgentLease): void { this.#database.prepare('DELETE FROM aureways_leases WHERE agent_id = ? AND holder_id = ?').run(lease.agentId, lease.holderId) }

  #create<T extends StoredEntity>(kind: EntityKind, entity: T): T {
    this.#ensureInitialized()
    const result = this.#database.prepare('INSERT OR IGNORE INTO aureways_entities(id, kind, agent_id, state, revision, created_at, updated_at, payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run(entity.id, kind, this.#agentId(entity), this.#state(entity), entity.revision, entity.createdAt, entity.updatedAt, JSON.stringify(entity))
    if (result.changes !== 1) throw new RevisionConflictError(kind, entity.id, 0)
    return entity
  }
  #update<T extends StoredEntity>(kind: EntityKind, entity: T, expectedRevision: number): T {
    this.#ensureInitialized()
    const next = { ...entity, revision: expectedRevision + 1, updatedAt: Date.now() } as T
    const result = this.#database.prepare('UPDATE aureways_entities SET agent_id = ?, state = ?, revision = ?, updated_at = ?, payload = ? WHERE id = ? AND kind = ? AND revision = ?').run(this.#agentId(next), this.#state(next), next.revision, next.updatedAt, JSON.stringify(next), next.id, kind, expectedRevision)
    if (result.changes !== 1) throw new RevisionConflictError(kind, entity.id, expectedRevision)
    return next
  }
  /** 先用权威旧版本校验状态机，再执行 CAS，防止调用方绕开领域转换规则。 */
  #updateWithStateCheck<T extends PersistentAgent | RuntimeTask | AgentInterrupt | ActionJournalEntry>(kind: 'agent' | 'task' | 'interrupt' | 'action', entity: T, expectedRevision: number): T {
    const prior = this.#required(kind, entity.id) as T
    if (prior.revision !== expectedRevision) throw new RevisionConflictError(kind, entity.id, expectedRevision)
    if (prior.state !== entity.state) {
      if (kind === 'agent') assertAgentTransition(prior.state as PersistentAgent['state'], entity.state as PersistentAgent['state'])
      if (kind === 'task') assertTaskTransition(prior.state as RuntimeTask['state'], entity.state as RuntimeTask['state'])
      if (kind === 'interrupt') assertInterruptTransition(prior.state as AgentInterrupt['state'], entity.state as AgentInterrupt['state'])
      if (kind === 'action') assertActionTransition(prior.state as ActionJournalEntry['state'], entity.state as ActionJournalEntry['state'])
    }
    return this.#update(kind, entity, expectedRevision)
  }
  #get(kind: EntityKind, id: string): StoredEntity | undefined {
    this.#ensureInitialized()
    const row = this.#database.prepare('SELECT payload FROM aureways_entities WHERE id = ? AND kind = ?').get(id, kind) as EntityRow | undefined
    return row ? this.#parse(row) : undefined
  }
  #required(kind: EntityKind, id: string): StoredEntity { return this.#get(kind, id) ?? (() => { throw new EntityNotFoundError(kind, id) })() }
  #list(kind: EntityKind, agentId: AgentId, state?: string): readonly StoredEntity[] {
    this.#ensureInitialized()
    const query = state ? 'SELECT payload FROM aureways_entities WHERE kind = ? AND agent_id = ? AND state = ? ORDER BY created_at ASC' : 'SELECT payload FROM aureways_entities WHERE kind = ? AND agent_id = ? ORDER BY created_at ASC'
    const rows = (state ? this.#database.prepare(query).all(kind, agentId, state) : this.#database.prepare(query).all(kind, agentId)) as EntityRow[]
    return rows.map((row) => this.#parse(row))
  }
  /** 将状态数组参数化，避免 adapter 为每个状态分别读取并自行合并。 */
  #listByKindAndStates(kind: 'agent' | 'action', states?: readonly string[], agentId?: AgentId): readonly StoredEntity[] {
    this.#ensureInitialized()
    const clauses = ['kind = ?']
    const parameters: unknown[] = [kind]
    if (agentId) { clauses.push('agent_id = ?'); parameters.push(agentId) }
    if (states && states.length > 0) {
      clauses.push(`state IN (${states.map(() => '?').join(', ')})`)
      parameters.push(...states)
    }
    const rows = this.#database.prepare(`SELECT payload FROM aureways_entities WHERE ${clauses.join(' AND ')} ORDER BY updated_at ASC`).all(...parameters) as EntityRow[]
    return rows.map((row) => this.#parse(row))
  }
  #parse(row: EntityRow): StoredEntity { return JSON.parse(row.payload) as StoredEntity }
  #agentId(entity: StoredEntity): string | null { return 'agentId' in entity ? entity.agentId : entity.id }
  #state(entity: StoredEntity): string | null { return 'state' in entity ? entity.state : null }
  /** FTS 是可重建投影；权威内容始终保留在 entities.payload。 */
  #indexMemory(memory: EpisodicMemory): void {
    this.#database.prepare('DELETE FROM aureways_memory_fts WHERE id = ?').run(memory.id)
    this.#database.prepare('INSERT INTO aureways_memory_fts(id, agent_id, content, tags) VALUES (?, ?, ?, ?)')
      .run(memory.id, memory.agentId, memory.content, memory.tags.join(' '))
  }
  #ensureInitialized(): void { if (!this.#initialized) this.initialize() }
  #validTtl(ttlMs: number): number { if (!Number.isFinite(ttlMs) || ttlMs <= 0) throw new RangeError('Lease ttlMs must be a positive finite number'); return ttlMs }
  #transaction<T>(operation: () => T): T {
    this.#ensureInitialized()
    this.#database.exec('BEGIN IMMEDIATE')
    try { const result = operation(); this.#database.exec('COMMIT'); return result } catch (error) { this.#database.exec('ROLLBACK'); throw error }
  }
}

/** 将外部文本转成只含 quoted terms 的 FTS5 查询，避免暴露查询语法。 */
function tokenizeFtsQuery(query: string | undefined): string | undefined {
  const terms = (query ?? '').normalize('NFKC').toLocaleLowerCase().split(/[^\p{L}\p{N}_-]+/u).filter(Boolean)
  if (terms.length === 0) return undefined
  return [...new Set(terms)].map((term) => `"${term.replaceAll('"', '""')}"`).join(' AND ')
}
