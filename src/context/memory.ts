import type { EpisodicMemory, MemoryKind, SourceReference } from './types.js'

export interface MemoryQuery {
  readonly agentId: string
  readonly text?: string
  readonly kinds?: readonly MemoryKind[]
  readonly limit?: number
  readonly now?: string
}

export interface MemoryHit {
  readonly memory: EpisodicMemory
  readonly score: number
}

/**
 * 用关键词提供 V0.1 的可解释检索；后续向量索引可实现同一契约。
 */
export function retrieveEpisodicMemories(
  memories: readonly EpisodicMemory[],
  query: MemoryQuery,
): readonly MemoryHit[] {
  const terms = tokenize(query.text)
  const now = query.now ?? new Date().toISOString()
  const limit = query.limit ?? 8

  return memories
    .filter((memory) => isRetrievable(memory, query, now))
    .map((memory) => ({ memory, score: scoreMemory(memory, terms) }))
    .sort((left, right) => right.score - left.score
      || right.memory.updatedAt.localeCompare(left.memory.updatedAt)
      || left.memory.memoryId.localeCompare(right.memory.memoryId))
    .slice(0, limit)
}

/** 合并语义相同的记忆，同时保留全部原始来源。 */
export function mergeEpisodicMemories(
  base: EpisodicMemory,
  incoming: EpisodicMemory,
  mergedAt: string,
): EpisodicMemory {
  if (base.agentId !== incoming.agentId) {
    throw new Error('Cannot merge memories from different agents.')
  }
  return {
    ...base,
    confidence: Math.max(base.confidence, incoming.confidence),
    keywords: uniqueSorted([...base.keywords, ...incoming.keywords]),
    sourceRefs: mergeSourceRefs(base.sourceRefs, incoming.sourceRefs),
    supersedesMemoryIds: uniqueSorted([...base.supersedesMemoryIds, incoming.memoryId]),
    updatedAt: mergedAt,
  }
}

/** 返回不可再检索的新版记录；持久层应以此替换旧版本。 */
export function invalidateEpisodicMemory(
  memory: EpisodicMemory,
  invalidatedAt: string,
  reason: SourceReference,
): EpisodicMemory {
  return {
    ...memory,
    status: 'invalidated',
    sourceRefs: mergeSourceRefs(memory.sourceRefs, [reason]),
    updatedAt: invalidatedAt,
  }
}

function isRetrievable(memory: EpisodicMemory, query: MemoryQuery, now: string): boolean {
  return memory.agentId === query.agentId
    && memory.status === 'active'
    && (memory.validUntil === undefined || memory.validUntil > now)
    && (query.kinds === undefined || query.kinds.includes(memory.kind))
}

function scoreMemory(memory: EpisodicMemory, terms: readonly string[]): number {
  if (terms.length === 0) return memory.confidence
  const searchable = `${memory.summary} ${memory.keywords.join(' ')}`.toLocaleLowerCase()
  const matches = terms.filter((term) => searchable.includes(term)).length
  return matches * 10 + memory.confidence
}

function tokenize(value: string | undefined): readonly string[] {
  return uniqueSorted((value ?? '').toLocaleLowerCase().split(/[^\\p{L}\\p{N}_-]+/u).filter(Boolean))
}

function mergeSourceRefs(left: readonly SourceReference[], right: readonly SourceReference[]): readonly SourceReference[] {
  const seen = new Map<string, SourceReference>()
  for (const ref of [...left, ...right]) seen.set(`${ref.sourceType}:${ref.sourceId}:${ref.observedAt ?? ''}`, ref)
  return [...seen.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([, ref]) => ref)
}

function uniqueSorted(values: readonly string[]): readonly string[] {
  return [...new Set(values)].sort((left, right) => left.localeCompare(right))
}
