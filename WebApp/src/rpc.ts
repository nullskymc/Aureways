// Request/response calls to Swift (WebShellServices.swift) and the native
// event streams that ride on the same channel.
import { inApp, onMessage, post } from './bridge'

let seq = 0
const pending = new Map<number, { resolve(v: unknown): void; reject(e: Error): void }>()

onMessage((m) => {
  if (m.type !== 'rpcResult') return
  const p = pending.get(m.id)
  if (!p) return
  pending.delete(m.id)
  if (m.error !== undefined) p.reject(new Error(m.error))
  else p.resolve(m.result)
})

export function rpc<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  if (!inApp) return Promise.reject(new Error('offline'))
  const id = ++seq
  return new Promise<T>((resolve, reject) => {
    pending.set(id, { resolve: resolve as (v: unknown) => void, reject })
    post('rpc', { id, method, params })
  })
}

export interface DirEntry { name: string; path: string; dir: boolean }
export interface FileRead {
  path: string
  size: number
  mtime: number
  text?: string
  image?: string
  binary?: boolean
  tooLarge?: boolean
}
export interface GitDiff { repo: boolean; root?: string; branch?: string; diff?: string; untracked?: string[] }
export interface SearchHit { rel: string; path: string }
