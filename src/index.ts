/** Aureways 的 DSH Cordis 插件入口。 */
import { type Context } from '@deepseek-ai/cordis'
import Schema from '@deepseek-ai/schemastery'
import { AurewaysService } from './service.js'

declare module '@deepseek-ai/cordis' {
  interface Context {
    /** Aureways 持久 Agent Runtime 的唯一公共入口。 */
    aureways: AurewaysService
  }
}

export const name = 'aureways'

export interface Config {
  readonly dataDirectory: string
  readonly idleUnloadMs: number
  readonly maxLiveAgents: number
  readonly maxEphemeralTasks: number
  readonly leaseDurationMs: number
  readonly checkpointEveryTurns: number
  readonly interruptDecisionTimeoutMs: number
  readonly recoveryPolicy: 'pause-on-uncertain' | 'replan-on-uncertain'
  readonly runtimeId: string
}

export const Config: Schema<Config> = Schema.object({
  dataDirectory: Schema.string().default('./.dsh/aureways'),
  idleUnloadMs: Schema.number().min(0).default(300_000),
  maxLiveAgents: Schema.number().min(1).default(8),
  maxEphemeralTasks: Schema.number().min(1).default(4),
  leaseDurationMs: Schema.number().min(1_000).default(30_000),
  checkpointEveryTurns: Schema.number().min(1).default(4),
  interruptDecisionTimeoutMs: Schema.number().min(1_000).default(60_000),
  recoveryPolicy: Schema.union(['pause-on-uncertain', 'replan-on-uncertain']).default('pause-on-uncertain'),
  runtimeId: Schema.string().default('aureways-local'),
})

/** 挂载单个 `ctx.aureways` Service；不创建独立 App 或第二套 Agent Loop。 */
export function apply(ctx: Context, config: Config): void {
  ctx.plugin(AurewaysService, config)
}

export * from './adapters/index.js'
export * from './domain/index.js'
export * from './service.js'
export * from './store/index.js'
export * from './protocol/index.js'
export * from './tools/index.js'
export * as aurewaysContext from './context/index.js'
export * as aurewaysRuntime from './runtime/index.js'
