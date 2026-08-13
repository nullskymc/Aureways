# Aureways

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md)

Aureways is a DeepSeek Harness (DSH) plugin that turns agents into persistent, interruptible, and resumable execution entities.

It is deliberately a single Cordis plugin—not a standalone application and not a second agent loop. DSH continues to own live sessions, model calls, inboxes, and tool execution, while Aureways owns the durable runtime state needed to resume long-running work across idle periods, client disconnects, context compaction, and process restarts.

## Why Aureways

Most harness subagents are scoped to one frontend session and disappear when that task ends. Aureways separates the logical agent from its temporary live activation:

- a persistent agent keeps a stable identity, goal, workspace, workflow state, memory, and execution history;
- a DSH activation is created or resumed only when runnable work exists;
- external events can interrupt work at a safe point and trigger a structured replan;
- an idle activation is checkpointed and released without deleting the persistent agent;
- A2A, ACP, and model tools call the same `ctx.aureways` service and never own an `AgentHandle`.

Always-On means **always resumable**, not continuously calling a model.

## V0.1 capabilities

- One public Cordis service: `ctx.aureways`.
- SQLite-backed agents, tasks, interrupts, checkpoints, leases, workflow frames, action journals, episodic memories, and context-bundle manifests.
- Event-driven Always Loop with per-agent serialization and cross-agent concurrency.
- Cold unload, restart recovery, optimistic concurrency, task idempotency, and uncertain-side-effect handling.
- Soft and urgent interrupts with safe-point checkpointing and explicit `resume | revise | pause | terminate` decisions.
- Source-audited episodic memory with SQLite FTS5 retrieval, invalidation, and stable ordering.
- Token-budgeted context reconstruction from identity, workflow, interrupts, checkpoints, workspace references, memory, and recent session summaries.
- Structural adapter for the current DSH `ctx.agents` and `ctx.sessions` APIs.
- Transport-agnostic A2A/ACP cores and stable JSON tool descriptors.

## Architecture

```text
DSH tool / A2A / ACP / external harness
                  │
            ctx.aureways
                  │
      ┌───────────┼────────────┐
      │           │            │
 Always Loop   Memory     Workflow Context
      │           │            │
 DSH adapter  SQLite + FTS5  Context Bundle
      │
 ctx.agents + ctx.sessions
```

The control loop is event-driven:

```text
wake → acquire lease → rebuild context → run bounded work
     → journal result → checkpoint → continue or become cold
```

## Requirements

- Node.js `^22.19.0` or `>=24.0.0`
- pnpm `11.7.0`
- DeepSeek Harness with Cordis `^4.0.1`

## Install into a DSH profile

From this repository:

```sh
pnpm install
pnpm run build
dsh plugin --profile web add .
dsh --profile web --dump-config
dsh --profile web
```

The bundle patch registers one plugin row named `aureways`. Runtime data is stored in `.dsh/aureways/aureways.sqlite` by default.

## Host integration

The plugin registers `ctx.aureways`, but the host composition must bind the real DSH Agent registry, Session persistence, message factory, and replan policy:

```ts
import { DshActivationAdapter } from 'dsh-aureways'

await ctx.aureways.bindRuntime({
  activation: new DshActivationAdapter({
    agents: ctx.agents,
    sessions: ctx.sessions,
    createUserMessage,
    createOptions: agent => ({
      meta: { cwd: resolveWorkspace(agent.agentId) },
    }),
  }),
  replan: {
    async requestDecision(handle, interrupt) {
      return decideReplan(handle, interrupt)
    },
  },
})
```

`createUserMessage`, `resolveWorkspace`, and `decideReplan` are host-provided integration functions. Aureways intentionally does not duplicate DSH's message or model layer.

## Public service surface

The V0.1 service exposes operations for:

- agent creation, listing, lookup, pause, and resume;
- task submission, listing, lookup, and cancellation;
- soft and urgent interrupts;
- episodic memory write, recall, and invalidation;
- auditable context reconstruction;
- runtime binding, status, and orderly shutdown.

Protocol adapters and tool handlers depend only on this service. Client disconnection does not implicitly cancel a persistent task.

## Configuration

| Option | Default | Purpose |
|---|---:|---|
| `dataDirectory` | `./.dsh/aureways` | SQLite and runtime state directory |
| `idleUnloadMs` | `300000` | Delay before an idle activation becomes cold |
| `maxLiveAgents` | `8` | Maximum concurrently active persistent agents |
| `maxEphemeralTasks` | `4` | Reserved ephemeral-task concurrency limit |
| `leaseDurationMs` | `30000` | Agent lease duration |
| `checkpointEveryTurns` | `4` | Planned periodic checkpoint cadence |
| `interruptDecisionTimeoutMs` | `60000` | Replan decision timeout |
| `recoveryPolicy` | `pause-on-uncertain` | Policy for uncertain side effects |
| `runtimeId` | `aureways-local` | Local lease owner identity |

## Development

```sh
pnpm run typecheck
pnpm run build
pnpm test
npm pack --dry-run
```

The current suite covers the DSH adapter, memory/context reconstruction, A2A/ACP mapping, interrupt safety, scheduling, recovery, Cordis service lifecycle, SQLite persistence, FTS5 retrieval, leases, and tool handlers.

## V0.1 boundaries

The following remain intentionally deferred:

- automatic host-side DSH tool registration;
- production HTTP/SSE listeners, authentication, and authorization for A2A;
- ephemeral-agent execution;
- automatic compaction-event integration;
- semantic/vector memory;
- distributed leases and multi-node runtime migration;
- a graphical management interface.

See [docs/plan.md](docs/plan.md) for the implementation plan and acceptance boundaries.

## Naming

- Product and repository: `Aureways`
- npm package: `dsh-aureways`
- Cordis plugin: `aureways`
- Context service: `ctx.aureways`
- Runtime directory: `.dsh/aureways`

## License

[MIT](LICENSE)
