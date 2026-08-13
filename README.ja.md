# Aureways

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md)

Aureways は、Agent を永続化可能・割り込み可能・再開可能な実行エンティティにする DeepSeek Harness（DSH）プラグインです。

Aureways は意図的に単一の Cordis プラグインとして構成されており、独立アプリケーションでも、第二の Agent Loop でもありません。ライブ Session、モデル呼び出し、Inbox、ツール実行は引き続き DSH が所有し、Aureways はアイドル期間、クライアント切断、コンテキスト圧縮、プロセス再起動を越えて長期タスクを再開するための永続 Runtime 状態を管理します。

## Aureways が解決すること

一般的な Harness の Subagent は一つのフロントエンド Session に属し、タスク終了時に破棄されます。Aureways は、長期に存在する論理 Agent と短命なライブ Activation を分離します。

- Persistent Agent は安定した Identity、Goal、Workspace、Workflow 状態、Memory、実行履歴を保持します。
- 実行可能な作業があるときだけ DSH Activation を作成または再開します。
- 外部イベントは安全点で現在の処理に割り込み、構造化された Replan を開始できます。
- アイドル時は Checkpoint を作成してから Activation を解放し、Persistent Agent 自体は削除しません。
- A2A、ACP、モデルツールはすべて `ctx.aureways` を呼び出し、`AgentHandle` を所有しません。

Always-On とは**常に再開できること**であり、モデルを常時呼び出すことではありません。

## V0.1 の機能

- 単一の公開 Cordis Service：`ctx.aureways`。
- Agent、Task、Interrupt、Checkpoint、Lease、WorkflowFrame、ActionJournal、EpisodicMemory、ContextBundle Manifest の SQLite 永続化。
- Agent 内直列化と Agent 間並列化を行うイベント駆動 Always Loop。
- cold unload、再起動リカバリ、楽観的並行制御、Task の冪等性、不確実な副作用の処理。
- Soft/Urgent Interrupt、安全点 Checkpoint、明示的な `resume | revise | pause | terminate` 判断。
- 出典を監査できる Episodic Memory、SQLite FTS5 検索、無効化、安定ソート。
- Identity、Workflow、Interrupt、Checkpoint、Workspace 参照、長期 Memory、最近の Session 要約から、Token Budget に応じて Context を動的再構築。
- 現行 DSH `ctx.agents` / `ctx.sessions` API 用の構造的 Adapter。
- Transport 非依存の A2A/ACP Core と、安定した JSON Tool Descriptor/Handler。

## アーキテクチャ

```text
DSH Tool / A2A / ACP / 外部 Harness
                  │
            ctx.aureways
                  │
      ┌───────────┼────────────┐
      │           │            │
 Always Loop   長期 Memory   Workflow Context
      │           │            │
 DSH Adapter  SQLite + FTS5  Context Bundle
      │
 ctx.agents + ctx.sessions
```

制御ループはイベント駆動です。

```text
wake → Lease 取得 → Context 再構築 → 有限の作業を実行
     → 結果を記録 → Checkpoint → 続行または cold へ移行
```

## 必要環境

- Node.js `^22.19.0` または `>=24.0.0`
- pnpm `11.7.0`
- Cordis `^4.0.1` を含む DeepSeek Harness

## DSH Profile へのインストール

このリポジトリで次を実行します。

```sh
pnpm install
pnpm run build
dsh plugin --profile web add .
dsh --profile web --dump-config
dsh --profile web
```

Bundle Patch は `aureways` という一つのプラグイン行のみを登録します。Runtime データベースの既定パスは `.dsh/aureways/aureways.sqlite` です。

## Host 統合

プラグインは `ctx.aureways` を登録しますが、Host 側の構成で実際の DSH Agent Registry、Session Persistence、Message Factory、Replan Policy をバインドする必要があります。

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

`createUserMessage`、`resolveWorkspace`、`decideReplan` は Host が提供する統合関数です。Aureways は DSH の Message 層や Model 層を重複実装しません。

## 公開 Service API

V0.1 Service は次の操作を提供します。

- Agent の作成、一覧、取得、一時停止、再開。
- Task の投入、一覧、取得、キャンセル。
- Soft/Urgent Interrupt。
- Episodic Memory の保存、検索、無効化。
- 監査可能な Context 再構築。
- Runtime のバインド、状態取得、安全なシャットダウン。

Protocol Adapter と Tool Handler はこの Service のみに依存します。クライアント切断によって Persistent Task が暗黙的にキャンセルされることはありません。

## 設定

| 設定 | 既定値 | 用途 |
|---|---:|---|
| `dataDirectory` | `./.dsh/aureways` | SQLite と Runtime 状態の保存先 |
| `idleUnloadMs` | `300000` | アイドル Activation が cold になるまでの待機時間 |
| `maxLiveAgents` | `8` | 同時にライブにできる Persistent Agent 数 |
| `maxEphemeralTasks` | `4` | Ephemeral Task 用に予約された並列上限 |
| `leaseDurationMs` | `30000` | Agent Lease の有効期間 |
| `checkpointEveryTurns` | `4` | 予定されている定期 Checkpoint 間隔 |
| `interruptDecisionTimeoutMs` | `60000` | Replan 判断のタイムアウト |
| `recoveryPolicy` | `pause-on-uncertain` | 不確実な副作用に対する復旧方針 |
| `runtimeId` | `aureways-local` | ローカル Lease Owner の識別子 |

## 開発と検証

```sh
pnpm run typecheck
pnpm run build
pnpm test
npm pack --dry-run
```

現在のテストは DSH Adapter、Memory/Context 再構築、A2A/ACP Mapping、Interrupt の安全性、Scheduler、Recovery、Cordis Service Lifecycle、SQLite 永続化、FTS5 検索、Lease、Tool Handler を対象としています。

## V0.1 の境界

次の機能は意図的に延期されています。

- Host 側での DSH Tool 自動登録。
- 本番用 A2A HTTP/SSE Listener、認証、認可。
- Ephemeral Agent の実行。
- DSH Compaction Event の自動統合。
- Semantic/Vector Memory。
- 分散 Lease とマルチノード Runtime Migration。
- GUI 管理画面。

実装計画と受け入れ条件の詳細は [docs/plan.md](docs/plan.md) を参照してください。

## 命名

- 製品・リポジトリ：`Aureways`
- npm Package：`dsh-aureways`
- Cordis Plugin：`aureways`
- Context Service：`ctx.aureways`
- Runtime Directory：`.dsh/aureways`

## ライセンス

[MIT](LICENSE)
