# Aureways

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md)

Aureways 是一个 DeepSeek Harness（DSH）插件，用于把 Agent 变成可持久化、可中断、可恢复的持续执行实体。

它有意保持为单一 Cordis 插件，而不是独立应用，也不会创建第二套 Agent Loop。DSH 继续负责实时 Session、模型调用、Inbox 和工具执行；Aureways 负责长期任务在空闲、客户端断开、上下文压缩和进程重启后继续执行所需的持久 Runtime 状态。

## 为什么需要 Aureways

常见 Harness Subagent 依附于一次前端会话，任务结束后便被销毁。Aureways 将长期存在的逻辑 Agent 与短生命周期的实时 Activation 分离：

- Persistent Agent 保留稳定身份、Goal、Workspace、工作流状态、记忆和执行历史；
- 只有存在可执行工作时，才创建或恢复 DSH Activation；
- 外部事件可以在安全点中断当前工作，并触发结构化 Replan；
- Agent 空闲时会先建立 Checkpoint，再释放 Activation，但不会删除 Persistent Agent；
- A2A、ACP 和模型工具统一调用 `ctx.aureways`，且不会持有 `AgentHandle`。

Always-On 表示**始终可以恢复**，而不是持续调用模型。

## V0.1 能力

- 单一公共 Cordis Service：`ctx.aureways`。
- 使用 SQLite 持久化 Agent、Task、Interrupt、Checkpoint、Lease、WorkflowFrame、ActionJournal、EpisodicMemory 和 ContextBundle Manifest。
- 事件驱动 Always Loop：同一 Agent 严格串行，不同 Agent 可并行。
- 支持 cold unload、重启恢复、乐观并发、Task 幂等和不确定副作用处理。
- 支持 Soft/Urgent Interrupt、安全点 Checkpoint，以及显式的 `resume | revise | pause | terminate` 决策。
- 带来源审计的 Episodic Memory，支持 SQLite FTS5 检索、失效和稳定排序。
- 根据 Identity、Workflow、Interrupt、Checkpoint、Workspace 引用、长期记忆和最近 Session 摘要，按 Token Budget 动态重建上下文。
- 对接当前 DSH `ctx.agents` 与 `ctx.sessions` API 的结构化适配器。
- 与传输层解耦的 A2A/ACP 核心，以及稳定 JSON 工具描述和处理器。

## 架构

```text
DSH Tool / A2A / ACP / 外部 Harness
                  │
            ctx.aureways
                  │
      ┌───────────┼────────────┐
      │           │            │
 Always Loop   长期记忆     Workflow Context
      │           │            │
 DSH Adapter  SQLite + FTS5  Context Bundle
      │
 ctx.agents + ctx.sessions
```

控制循环由事件驱动：

```text
唤醒 → 获取 Lease → 重建上下文 → 执行有限工作
     → 记录结果 → Checkpoint → 继续运行或进入 cold
```

## 环境要求

- Node.js `^22.19.0` 或 `>=24.0.0`
- pnpm `11.7.0`
- DeepSeek Harness，Cordis `^4.0.1`

## 安装到 DSH Profile

在本项目目录执行：

```sh
pnpm install
pnpm run build
dsh plugin --profile web add .
dsh --profile web --dump-config
dsh --profile web
```

Bundle Patch 只注册一个名为 `aureways` 的插件项。默认 Runtime 数据库位于 `.dsh/aureways/aureways.sqlite`。

## 宿主集成

插件会注册 `ctx.aureways`，但宿主组合仍需绑定真实的 DSH Agent Registry、Session Persistence、消息工厂和 Replan 策略：

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

其中 `createUserMessage`、`resolveWorkspace` 和 `decideReplan` 由宿主提供。Aureways 不会重复实现 DSH 的消息或模型层。

## 公共 Service 能力

V0.1 Service 提供：

- Agent 创建、列举、查询、暂停和恢复；
- Task 提交、列举、查询和取消；
- Soft/Urgent Interrupt；
- Episodic Memory 写入、召回和失效；
- 可审计的动态上下文重建；
- Runtime 绑定、状态查询和有序关闭。

协议适配器和工具处理器只依赖该 Service。客户端断开不会隐式取消 Persistent Task。

## 配置

| 配置项 | 默认值 | 用途 |
|---|---:|---|
| `dataDirectory` | `./.dsh/aureways` | SQLite 和 Runtime 状态目录 |
| `idleUnloadMs` | `300000` | 空闲 Activation 进入 cold 前的等待时间 |
| `maxLiveAgents` | `8` | Persistent Agent 最大实时并发数 |
| `maxEphemeralTasks` | `4` | 为临时任务预留的并发上限 |
| `leaseDurationMs` | `30000` | Agent Lease 有效期 |
| `checkpointEveryTurns` | `4` | 计划中的周期 Checkpoint 间隔 |
| `interruptDecisionTimeoutMs` | `60000` | Replan 决策超时 |
| `recoveryPolicy` | `pause-on-uncertain` | 不确定副作用的恢复策略 |
| `runtimeId` | `aureways-local` | 本地 Lease Owner 标识 |

## 开发与验证

```sh
pnpm run typecheck
pnpm run build
pnpm test
npm pack --dry-run
```

当前测试覆盖 DSH Adapter、记忆与上下文重建、A2A/ACP 映射、中断安全点、调度、恢复、Cordis Service 生命周期、SQLite 持久化、FTS5 检索、Lease 和工具处理器。

## V0.1 边界

以下能力有意延后：

- 宿主侧 DSH 工具自动注册；
- 生产级 A2A HTTP/SSE 监听、认证和授权；
- Ephemeral Agent 执行；
- DSH Compaction 事件自动接入；
- 语义/向量记忆；
- 分布式 Lease 和多节点 Runtime 迁移；
- 图形化管理界面。

详细实施计划和验收边界见 [docs/plan.md](docs/plan.md)。

## 命名

- 产品及仓库：`Aureways`
- npm 包：`dsh-aureways`
- Cordis 插件：`aureways`
- Context Service：`ctx.aureways`
- Runtime 目录：`.dsh/aureways`

## 许可证

[MIT](LICENSE)
