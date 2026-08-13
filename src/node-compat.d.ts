/**
 * 当前 DSH 脚手架不携带 @types/node；此处只声明本插件实际使用的 Node 22+ API。
 * 运行时仍直接使用 Node 内置模块，不引入额外运行时依赖。
 */
declare module 'node:fs' {
  export function mkdirSync(path: string, options?: { recursive?: boolean }): string | undefined
}

declare module 'node:path' {
  export function dirname(path: string): string
}

declare module 'node:sqlite' {
  interface StatementSync {
    get(...parameters: unknown[]): unknown
    all(...parameters: unknown[]): unknown
    run(...parameters: unknown[]): { readonly changes: number }
  }
  export class DatabaseSync {
    constructor(path: string)
    exec(sql: string): void
    prepare(sql: string): StatementSync
    close(): void
  }
}
