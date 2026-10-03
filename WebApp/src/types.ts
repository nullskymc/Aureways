// Shapes sent by WebShellBridge.swift (docs/web-shell.md).

export interface Rect { x: number; y: number; w: number; h: number }

export interface Session {
  id: string
  title: string
  agentId: string
  agentTitle: string
  cwd: string
  ws: string
  phase: 'idle' | 'connecting' | 'ready' | 'failed'
  streaming: boolean
  attention: boolean
  createdAt: number
  error?: string
  /** Pending request for a session that isn't selected. */
  permission?: Permission
  pendingKind?: 'plan' | 'question'
}

export interface Agent { id: string; title: string; subtitle: string; available: boolean }
export interface Workspace { path: string; name: string }

export interface Choice { id: string; name: string; group: string | null; description: string | null }
export interface Picker { configId: string | null; current: string | null; options: Choice[] }

export interface PendingAttachment { id: string; name: string; kind: 'image' | 'file' | 'pastedText'; src?: string; path?: string; chars?: number }

export interface ComposerState {
  sessionId?: string
  attachments: PendingAttachment[]
  commands?: { name: string; description: string }[]
  model?: Picker
  effort?: Picker
  mode?: Picker
}

export interface PermissionOption { id: string; name: string; kind: string; allow: boolean }
export interface Permission { title: string; options: PermissionOption[]; tool?: ToolFields }

export interface Question {
  questions: { id: string; text: string; multi: boolean; options: { label: string; description: string | null }[] }[]
}

export interface AppState {
  locale: 'zh' | 'en'
  appearance: string
  selectedSessionId: string | null
  selectedAgentId: string
  workspacePath: string
  workspaceName: string
  branch: string | null
  homePath: string
  error: string | null
  chrome: { trafficLights: Rect; fullscreen: boolean; titlebarHeight: number; glass?: boolean }
  workspaces: Workspace[]
  agents: Agent[]
  sessions: Session[]
  composer: ComposerState
  permission?: Permission
  planApproval?: { content: string; filePath: string | null }
  question?: Question
  usage?: { used: number; size: number }
  uiPrefs?: Record<string, unknown>
  inspectorRoot: string
  settings: Settings
  quota: Record<string, QuotaSnapshot>
}

export interface SettingsAgent {
  id: string; title: string; subtitle: string; builtIn: boolean; launchLine: string; notes: string
  enabled: boolean; available: boolean; quotaRefreshing: boolean
}

export interface Settings {
  appearance: string
  language: string
  systemLanguage: string
  showMenuBar: boolean
  markdownDefault: boolean
  autoApprove: boolean
  defaultAgentId: string
  version: string
  agents: SettingsAgent[]
  workspaces: Workspace[]
  defaultWorkspace: string
  mcpServers: { id: string; name: string; transport: string; summary: string; enabled: boolean }[]
  reportedMcp: { name: string; summary: string }[]
  mcpCaps?: { http: boolean; sse: boolean }
}

export interface QuotaWindow {
  id: string; title: string; usedPercent: number; resetsAt?: number; resetDescription?: string; windowMinutes?: number
}

export interface QuotaSnapshot {
  harnessId: string
  providerTitle: string
  planType?: string
  accountEmail?: string
  primaryWindow?: QuotaWindow
  secondaryWindow?: QuotaWindow
  extraWindows?: QuotaWindow[]
  usageBreakdown?: { id: string; title: string; usedPercent: number }[]
  creditsRemaining?: number
  creditsUnit?: string
  resetCreditsAvailable?: number
  updatedAt: number
  error?: string
  severity: 'healthy' | 'warning' | 'critical' | 'unknown'
  summary: string
}

export interface Run { s: number; e: number | null }

export interface Attachment { id: string; kind: string; name: string; path?: string; chars?: number; src?: string }

export interface DiffFile {
  path: string
  added: number
  removed: number
  truncated: boolean
  isNew: boolean
  hunks: { header: string; oldStart: number; newStart: number; lines: string[] }[]
}

export interface ToolFields {
  callId: string
  title: string
  fullTitle: string
  toolKind: string
  status: string
  layout: 'command' | 'edit' | 'file' | 'search' | 'fetch' | 'other'
  progress: boolean
  path?: string
  command?: string
  cwd?: string
  output?: string
  exitCode?: number
  pattern?: string
  url?: string
  input?: string
  diffs?: DiffFile[]
}

export type Item =
  | { kind: 'user'; id: string; text: string; attachments: Attachment[] }
  | { kind: 'agent'; id: string; text: string }
  | { kind: 'thought'; id: string; text: string; run?: Run }
  | ({ kind: 'tool'; id: string; run?: Run } & ToolFields)
  | { kind: 'plan'; id: string; entries: { content: string; status: string }[]; run?: Run }
  | { kind: 'status'; id: string; text: string }

export type PatchOp =
  | { op: 'upsert'; index: number; item: Item }
  | { op: 'append'; id: string; delta: string }
  | { op: 'remove'; id: string }

export type Incoming =
  | { type: 'state'; state: AppState }
  | { type: 'transcript'; sessionId: string; items: Item[] }
  | { type: 'patch'; sessionId: string; ops: PatchOp[] }
  | { type: 'command'; name: string; paths?: string[] }
  | { type: 'menuResult'; token: number; id: string | null }
  | { type: 'rpcResult'; id: number; result?: unknown; error?: string }
  | { type: 'termData'; id: string; data: string }
  | { type: 'termExit'; id: string; code: number | null }
  | { type: 'fileChanged'; path: string }
