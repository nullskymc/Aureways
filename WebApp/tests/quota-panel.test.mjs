import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseHTML } from 'linkedom'
import { h, render } from 'preact'
import { act } from 'preact/test-utils'

const { window, document } = parseHTML('<html><body><div id="app"></div></body></html>')
Object.assign(globalThis, { window, document, HTMLElement: window.HTMLElement, Element: window.Element, location: { hash: '#menubar' } })
globalThis.requestAnimationFrame = callback => setTimeout(callback, 0)
globalThis.cancelAnimationFrame = clearTimeout
globalThis.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} })
Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true })

const posted = []
window.webkit = { messageHandlers: { aureways: { postMessage(m) { posted.push(m) } } } }

const quota = await import('../src/quota.ts')
const { MenuBar } = await import('../src/components/MenuBar.tsx')
const { app } = await import('../src/store.ts')
const root = document.getElementById('app')
const now = Date.now()
const H = 3600e3

function win(id, label, used, extra = {}) {
  const remainingPercent = Math.max(0, 100 - used)
  return { id, label, kind: 'session', usedPercent: used, remainingPercent, level: quota.levelFor(remainingPercent), resetsAt: now + 2 * H + 15 * 60e3, source: 'officialAPI', estimated: false, ...extra }
}
function provider(harnessId, windows, extra = {}) {
  const rated = windows.filter(w => w.remainingPercent != null)
  const tight = rated.reduce((m, w) => (!m || w.remainingPercent < m.remainingPercent ? w : m), undefined)
  return { harnessId, providerTitle: harnessId, windows, status: 'ok', lastUpdated: now - 3 * 60e3, tightestId: tight?.id, remainingPercent: tight?.remainingPercent, level: tight?.level ?? 'unknown', estimated: tight?.estimated ?? false, refreshing: false, ...extra }
}
const agent = (id, extra = {}) => ({ id, title: id, subtitle: '', builtIn: true, launchLine: '', notes: '', enabled: true, available: true, ...extra })

async function mount(quotaMap, agents, locale = 'zh') {
  app.value = { locale, sessions: [1, 2, 3, 4, 5].map(i => ({ id: 's' + i, title: 'Chat ' + i, agentId: 'codex', createdAt: now - i * 60e3 })), settings: { agents }, quota: quotaMap }
  render(null, root)
  await act(async () => { render(h(MenuBar, {}), root) })
}
const rows = () => [...root.querySelectorAll('.mb-q')]
const text = el => el?.textContent ?? ''

test('levels, labels and summaries follow the approved bands and always speak in REMAINING', () => {
  app.value = { locale: 'zh' }
  assert.equal(quota.levelFor(51), 'ample')
  assert.equal(quota.levelFor(50), 'moderate')
  assert.equal(quota.levelFor(20), 'moderate')
  assert.equal(quota.levelFor(19.9), 'low')
  assert.equal(quota.levelFor(null), 'unknown')
  assert.equal(quota.percentText(38.4, false), '38%')
  assert.equal(quota.percentText(38.4, true), '约 38%')
  assert.equal(quota.windowLabel('Gemini 5h'), 'Gemini 5 小时')
  assert.equal(quota.windowLabel('Weekly Opus'), '每周 Opus')
  assert.equal(quota.countdown(now + 2 * H + 15 * 60e3, now), '2 小时 15 分')
  assert.equal(quota.countdown(now + 3 * 24 * H + 4 * H, now), '3 天 4 小时')
  assert.equal(quota.summarize, undefined, 'no cross-provider summary line')
  app.value = { locale: 'en' }
  assert.equal(quota.percentText(38, true), '~38%')
})

test('one row per provider with the tightest limit, its remaining %, bar colour and reset countdown', async () => {
  await mount({
    codex: provider('codex', [win('p', '5h', 62), win('s', 'Weekly', 21, { kind: 'weekly' })], { plan: 'Plus' }),
    claude: provider('claude', [win('p', '5h', 88, { estimated: true, source: 'localEstimate' })]),
  }, [agent('codex'), agent('claude')])
  assert.equal(rows().length, 2)
  const [codex, claude] = rows()
  assert.equal(text(codex.querySelector('.mb-q-name')), 'codex')
  assert.equal(text(codex.querySelector('.badge')), 'Plus')
  assert.equal(text(codex.querySelector('.mb-q-pct')), '38%', 'remaining of the tightest window, not used')
  assert.equal(codex.querySelector('.mb-q-fill').getAttribute('class'), 'mb-q-fill moderate')
  assert.match(codex.querySelector('.mb-q-fill').getAttribute('style'), /width: ?38%/)
  assert.equal(text(codex.querySelector('.mb-q-sub span')), '5 小时')
  assert.match(text(codex.querySelector('.mb-q-sub')), /2 小时 15 分 后重置/)
  assert.equal(codex.querySelectorAll('.mb-w').length, 0, 'collapsed: only the tightest window')
  assert.equal(text(claude.querySelector('.mb-q-pct')), '约 12%')
  assert.equal(claude.querySelector('.mb-q-fill').getAttribute('class'), 'mb-q-fill low')
  // Compact header: app name, when it was updated, refresh. No summary line.
  assert.equal(root.querySelector('.mb-summary'), null)
  assert.equal(text(root.querySelector('.mb-head .mb-title')), 'Aureways')
  assert.match(text(root.querySelector('.mb-updated')), /更新于 3 分钟前/)
  assert.doesNotMatch(text(root.querySelector('.mb-head')), /快用完|未登录|全部正常/)
  assert.equal(root.querySelectorAll('.mb-row').length, 3, 'recent chats reduced to 3')
  assert.deepEqual([...root.querySelectorAll('.mb-foot .mb-link')].map(text), ['新对话', '打开 Aureways', '设置', '退出'])
})

test('clicking a row expands every limit; not signed in / unsupported / error are gray inline text', async () => {
  posted.length = 0
  await mount({
    codex: provider('codex', [win('p', '5h', 62), win('s', 'Weekly', 21, { kind: 'weekly' }), { id: 'c', label: 'Credits', kind: 'credits', balance: 12.5, unit: 'credits', level: 'unknown', source: 'officialAPI', estimated: false }], { sourceKind: 'officialAPI', account: 'me@x.com' }),
    claude: { ...provider('claude', []), status: 'notSignedIn', statusDetail: 'notConfigured' },
    grok: { ...provider('grok', []), status: 'error', statusDetail: 'network' },
    cursor: { ...provider('cursor', []), status: 'unsupported' },
    opencode: { ...provider('opencode', []), status: 'unsupported' },
    hidden: provider('hidden', [win('p', '5h', 1)]),
  }, [agent('codex'), agent('claude'), agent('grok'), agent('cursor'), agent('opencode'), agent('hidden', { available: false })])
  assert.deepEqual(rows().map(r => text(r.querySelector('.mb-q-name'))), ['codex', 'claude', 'grok'], 'unsupported grouped, not-installed hidden')
  assert.equal(text(root.querySelector('.mb-unsupported')), '不支持查询额度：cursor · opencode')
  const claude = rows()[1]
  assert.equal(claude.querySelector('.mb-q-pct'), null)
  assert.match(text(claude.querySelector('.mb-q-note')), /^未登录 · 去设置$/)
  assert.equal(root.querySelector('.mb-sev, .avail-dot'), null, 'no ambiguous dots')
  await act(async () => { claude.querySelector('.mb-inline-link').click() })
  assert.deepEqual(posted.at(-1), { type: 'openSettings', section: 'usage' })
  const grok = rows()[2]
  assert.match(text(grok.querySelector('.mb-q-note')), /网络错误/)
  await act(async () => { grok.querySelector('.mb-inline-link').click() })
  assert.deepEqual(posted.at(-1), { type: 'refreshQuota', id: 'grok' })

  await act(async () => { rows()[0].querySelector('.mb-q-main').click() })
  const lines = [...rows()[0].querySelectorAll('.mb-w')]
  assert.equal(lines.length, 3, 'expanded: every window')
  assert.deepEqual(lines.map(l => text(l.querySelector('.mb-w-line span'))), ['5 小时', '每周', '余额'])
  assert.equal(text(lines[1].querySelector('.mb-w-pct')), '79%')
  assert.equal(text(lines[2].querySelector('.mb-w-pct')), '12.50 credits')
  assert.match(text(rows()[0].querySelector('.mb-q-meta')), /me@x\.com · 账号接口 · 更新于 3 分钟前/)
  await act(async () => { rows()[0].querySelector('.mb-q-main').click() })
  assert.equal(rows()[0].querySelectorAll('.mb-w').length, 0, 'click again collapses')
  await act(async () => { rows()[1].querySelector('.mb-q-main').click() })
  assert.equal(rows()[1].querySelectorAll('.mb-w').length, 0, 'rows without numbers do not expand')

  await act(async () => { root.querySelector('.mb-head .icon-btn').click() })
  assert.deepEqual(posted.at(-1), { type: 'refreshQuota' })
  assert.ok(posted.some(m => m.type === 'menuBarOpened'), 'opening the panel asks for a stale-only refresh')
})

test('stale readings keep their numbers and say why', async () => {
  await mount({ codex: provider('codex', [win('p', '5h', 40)], { status: 'stale', statusDetail: 'rateLimited' }) }, [agent('codex')], 'en')
  assert.equal(text(rows()[0].querySelector('.mb-q-pct')), '60%')
  assert.match(text(rows()[0].querySelector('.mb-q-note')), /May be out of date · Rate limited/)
  assert.equal(root.querySelector('.mb-summary'), null)
})
