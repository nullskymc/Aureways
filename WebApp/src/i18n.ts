import { app } from './store'

const zh: Record<string, string> = {
  newChat: '新对话',
  search: '搜索会话',
  settings: '设置',
  addWorkspace: '添加工作区',
  other: '其他',
  toggleSidebar: '切换侧边栏',
  placeholder: '要求 Agent 做点什么，@ 引用文件，/ 使用命令',
  placeholderFollow: '继续追问…',
  send: '发送',
  stop: '停止',
  attach: '添加附件',
  connecting: '正在连接 {0}…',
  retry: '重试',
  open: '打开',
  working: '正在工作',
  workedFor: '已工作 {0}',
  steps: '{0} 步',
  usedTools: '已调用工具',
  toolCount: '{0} 个工具',
  toolCount1: '1 个工具',
  thinking: '思考中',
  thoughtFor: '已思考 {0}',
  thought: '思考',
  plan: '计划',
  jumpBottom: '回到底部',
  permission: '需要你的批准',
  reject: '拒绝',
  planReady: '计划已就绪',
  approve: '批准并执行',
  requestChanges: '修改计划',
  quit: '放弃',
  question: 'Agent 想问你',
  submit: '提交',
  skip: '跳过',
  landingTitle: '在 {0} 里构建什么？',
  landingHint: '选择一个 Agent，然后开始描述任务',
  harnessUnavailable: '未安装',
  find: '在对话中查找',
  noResults: '无结果',
  copy: '复制',
  copied: '已复制',
  command: '命令',
  output: '输出',
  exit: '退出码 {0}',
  failed: '连接失败',
  dismiss: '知道了',
  addWs: '添加工作区…',
  changeWorkspace: '切换工作区',
  pastedText: '粘贴的文本 · {0} 字符',
  noSessions: '还没有会话',
  context: '上下文 {0}%',
  newChatIn: '在 {0} 中新建对话',
}
const en: Record<string, string> = {
  newChat: 'New chat',
  search: 'Search chats',
  settings: 'Settings',
  addWorkspace: 'Add workspace',
  other: 'Other',
  toggleSidebar: 'Toggle sidebar',
  placeholder: 'Ask the agent to do anything — @ for files, / for commands',
  placeholderFollow: 'Ask a follow-up…',
  send: 'Send',
  stop: 'Stop',
  attach: 'Attach files',
  connecting: 'Connecting to {0}…',
  retry: 'Retry',
  open: 'Open',
  working: 'Working',
  workedFor: 'Worked for {0}',
  steps: '{0} steps',
  usedTools: 'Used tools',
  toolCount: '{0} tools',
  toolCount1: '1 tool',
  thinking: 'Thinking',
  thoughtFor: 'Thought for {0}',
  thought: 'Thought',
  plan: 'Plan',
  jumpBottom: 'Jump to bottom',
  permission: 'Needs your approval',
  reject: 'Reject',
  planReady: 'Plan ready',
  approve: 'Approve & run',
  requestChanges: 'Request changes',
  quit: 'Quit',
  question: 'The agent has a question',
  submit: 'Submit',
  skip: 'Skip',
  landingTitle: 'What should we build in {0}?',
  landingHint: 'Pick an agent, then describe the task',
  harnessUnavailable: 'not installed',
  find: 'Find in chat',
  noResults: 'No results',
  copy: 'Copy',
  copied: 'Copied',
  command: 'Command',
  output: 'Output',
  exit: 'exit {0}',
  failed: 'Connection failed',
  dismiss: 'Dismiss',
  addWs: 'Add workspace…',
  changeWorkspace: 'Change workspace',
  pastedText: 'Pasted text · {0} chars',
  noSessions: 'No chats yet',
  context: 'Context {0}%',
  newChatIn: 'New chat in {0}',
}

export function t(key: string, ...args: (string | number)[]): string {
  const table = app.value?.locale === 'zh' ? zh : en
  let s = table[key] ?? en[key] ?? key
  args.forEach((a, i) => (s = s.replace(`{${i}}`, String(a))))
  return s
}

export function duration(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000))
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m ${s % 60}s`
  return `${Math.floor(m / 60)}h ${m % 60}m`
}

export function relativeTime(ts: number): string {
  const d = Date.now() - ts
  const m = Math.floor(d / 60000)
  if (m < 1) return app.value?.locale === 'zh' ? '刚刚' : 'now'
  if (m < 60) return `${m}m`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}h`
  const days = Math.floor(h / 24)
  if (days < 7) return `${days}d`
  return `${Math.floor(days / 7)}w`
}
