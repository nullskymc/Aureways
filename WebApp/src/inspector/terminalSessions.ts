import type { Terminal } from '@xterm/xterm'
import type { FitAddon } from '@xterm/addon-fit'

interface Disposable { dispose(): void }
interface Entry<T> { pending: Promise<T | undefined>; value?: T }

/** A tab owns its terminal, not the column/view currently displaying it. */
export class RetainedTerminals<T extends Disposable> {
  private entries = new Map<string, Entry<T>>()

  get(id: string, create: () => Promise<T>): Promise<T | undefined> {
    const existing = this.entries.get(id)
    if (existing) return existing.pending
    const entry: Entry<T> = { pending: Promise.resolve(undefined) }
    entry.pending = Promise.resolve().then(create).then((value) => {
      // A tab can close while the lazy xterm chunk is still loading.
      if (this.entries.get(id) !== entry) {
        value.dispose()
        return undefined
      }
      entry.value = value
      return value
    }).catch((error) => {
      if (this.entries.get(id) === entry) this.entries.delete(id)
      throw error
    })
    this.entries.set(id, entry)
    return entry.pending
  }

  close(id: string) {
    const entry = this.entries.get(id)
    this.entries.delete(id)
    entry?.value?.dispose()
  }
}

export interface TerminalSession extends Disposable {
  element: HTMLDivElement
  x: Terminal
  fit: FitAddon
}

export const terminalSessions = new RetainedTerminals<TerminalSession>()
