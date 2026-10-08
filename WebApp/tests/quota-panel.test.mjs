import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseHTML } from 'linkedom'
import { h, render } from 'preact'
import { act } from 'preact/test-utils'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const { window, document } = parseHTML('<html><body><div id="app"></div></body></html>')
// Linkedom lacks onwheel, so Preact would listen for 'Wheel'.
window.HTMLElement.prototype.onwheel = null
Object.assign(globalThis, { window, document, HTMLElement: window.HTMLElement, Element: window.Element, location: { hash: '#menubar' } })
globalThis.requestAnimationFrame = callback => setTimeout(callback, 0)
globalThis.cancelAnimationFrame = clearTimeout
globalThis.ResizeObserver = class { observe() {} disconnect() {} }
globalThis.MutationObserver = window.MutationObserver ?? class { observe() {} disconnect() {} }
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

const tabs = () => [...root.querySelectorAll('.mb-bar [role="tab"]')]
const selectedTab = () => root.querySelector('.mb-bar [aria-selected="true"]')
const detail = () => root.querySelector('#mb-detail')
const lastPost = type => posted.filter(m => m.type === type).at(-1)
const key = async k => act(async () => { document.dispatchEvent(Object.assign(new window.Event('keydown', { bubbles: true, cancelable: true }), { key: k })) })

test('icon bar: one tab per provider, labelled, the first signed-in provider selected; its detail shows every limit', async () => {
  await mount({
    claude: { ...provider('claude', []), status: 'notSignedIn', statusDetail: 'notConfigured' },
    codex: provider('codex', [win('p', '5h', 62), win('s', 'Weekly', 21, { kind: 'weekly' }), { id: 'c', label: 'Credits', kind: 'credits', balance: 12.5, unit: 'credits', level: 'unknown', source: 'officialAPI', estimated: false }], { plan: 'Plus', sourceKind: 'officialAPI', account: 'me@x.com' }),
    cursor: { ...provider('cursor', []), status: 'unsupported' },
    hidden: provider('hidden', [win('p', '5h', 1)]),
  }, [agent('claude'), agent('codex'), agent('cursor'), agent('hidden', { available: false })])
  assert.deepEqual(tabs().map(t => t.getAttribute('aria-label')), ['claude · 未登录', 'codex', 'cursor · 暂不支持查询额度'], 'not-installed hidden; status in the label')
  assert.deepEqual(tabs().map(t => t.title), tabs().map(t => t.getAttribute('aria-label')), 'tooltip = label')
  assert.deepEqual(tabs().map(t => t.classList.contains('dim')), [true, false, true], 'signed out / unsupported icons are dimmed')
  assert.equal(root.querySelector('.mb-sev, .avail-dot, .attention-dot.mb'), null, 'no ambiguous dots')
  assert.equal(selectedTab().getAttribute('aria-label'), 'codex', 'defaults to the first signed-in provider')
  const d = detail()
  assert.equal(d.getAttribute('aria-labelledby'), 'mb-tab-codex')
  assert.equal(text(d.querySelector('.mb-q-name')), 'codex')
  assert.equal(text(d.querySelector('.badge')), 'Plus')
  const lines = [...d.querySelectorAll('.mb-w')]
  assert.deepEqual(lines.map(l => text(l.querySelector('.mb-w-line span'))), ['5 小时', '每周', '余额'], 'every window')
  assert.deepEqual(lines.map(l => text(l.querySelector('.mb-w-pct'))), ['38%', '79%', '12.50 credits'], 'remaining, not used')
  assert.equal(lines[0].querySelector('.mb-q-fill').getAttribute('class'), 'mb-q-fill moderate')
  assert.equal(lines[1].querySelector('.mb-q-fill').getAttribute('class'), 'mb-q-fill ample')
  assert.match(lines[0].querySelector('.mb-q-fill').getAttribute('style'), /width: ?38%/)
  assert.match(text(lines[0]), /2 小时 15 分 后重置/)
  assert.match(text(d.querySelector('.mb-q-meta')), /me@x\.com · 账号接口 · 更新于 3 分钟前/)
  // Compact header: app name, when it was updated, refresh. No summary line.
  assert.equal(root.querySelector('.mb-summary'), null)
  assert.equal(text(root.querySelector('.mb-head .mb-title')), 'Aureways')
  assert.match(text(root.querySelector('.mb-updated')), /更新于 3 分钟前/)
  assert.equal(root.querySelectorAll('.mb-row').length, 3, 'recent chats reduced to 3')
  assert.deepEqual([...root.querySelectorAll('.mb-foot .mb-link')].map(text), ['新对话', '打开 Aureways', '设置', '退出'])
  await act(async () => { root.querySelector('.mb-head .icon-btn').click() })
  assert.deepEqual(posted.at(-1), { type: 'refreshQuota' })
  assert.ok(posted.some(m => m.type === 'menuBarOpened'), 'opening the panel asks for a stale-only refresh')
})

test('click, ←/→ and a horizontal swipe switch providers; the choice is remembered', async () => {
  posted.length = 0
  const map = {
    codex: provider('codex', [win('p', '5h', 62)]),
    claude: provider('claude', [win('p', '5h', 88, { estimated: true, source: 'localEstimate' }), win('w', 'Weekly', 40)]),
    grok: { ...provider('grok', []), status: 'error', statusDetail: 'network' },
  }
  const agents = [agent('codex'), agent('claude'), agent('grok')]
  await mount(map, agents)
  assert.equal(selectedTab().getAttribute('aria-label'), 'codex')
  await act(async () => { tabs()[1].click() })
  assert.equal(selectedTab().getAttribute('aria-label'), 'claude')
  assert.deepEqual(lastPost('menuBarProvider'), { type: 'menuBarProvider', id: 'claude' })
  assert.equal(text(detail().querySelector('.mb-w-pct')), '约 12%')
  assert.equal(detail().querySelector('.mb-q-fill').getAttribute('class'), 'mb-q-fill low')
  // Slide: the old page leaves to the left, the new one comes from the right.
  assert.ok(root.querySelector('.mb-page.leaving.to-left'))
  assert.ok(detail().classList.contains('from-right'))
  await key('ArrowRight')
  assert.equal(selectedTab().getAttribute('aria-label'), 'grok')
  assert.match(text(detail().querySelector('.mb-q-note')), /网络错误.* · 重试 · 去设置$/)
  await act(async () => { detail().querySelector('.mb-inline-link').click() })
  assert.deepEqual(posted.at(-1), { type: 'refreshQuota', id: 'grok' })
  await key('ArrowRight')
  assert.equal(selectedTab().getAttribute('aria-label'), 'grok', 'stops at the last provider')
  await key('ArrowLeft')
  assert.equal(selectedTab().getAttribute('aria-label'), 'claude')
  assert.ok(root.querySelector('.mb-page.leaving.to-right'), 'going back slides the other way')
  // Trackpad: one step per gesture, however long the swipe.
  const pager = root.querySelector('.mb-pager')
  await act(async () => {
    for (let i = 0; i < 12; i++) pager.dispatchEvent(Object.assign(new window.Event('wheel', { bubbles: true, cancelable: true }), { deltaX: -12, deltaY: 1 }))
  })
  assert.equal(selectedTab().getAttribute('aria-label'), 'codex')
  await act(async () => { pager.dispatchEvent(Object.assign(new window.Event('wheel', { bubbles: true }), { deltaX: 2, deltaY: 30 })) })
  assert.equal(selectedTab().getAttribute('aria-label'), 'codex', 'vertical scrolling does not switch')
  // Reopened (fresh page): the remembered provider comes back from native state.
  app.value = { ...app.value, menuBarProvider: 'claude' }
  render(null, root)
  await act(async () => { render(h(MenuBar, {}), root) })
  assert.equal(selectedTab().getAttribute('aria-label'), 'claude')
  assert.equal(root.querySelector('.mb-page.leaving'), null, 'no slide on open')
  // A remembered provider that is gone falls back to the first signed-in one.
  app.value = { ...app.value, menuBarProvider: 'gone' }
  render(null, root)
  await act(async () => { render(h(MenuBar, {}), root) })
  assert.equal(selectedTab().getAttribute('aria-label'), 'codex')
})

test('not signed in and unsupported read as gray text; Reduce Motion switches without a slide', async () => {
  const media = globalThis.matchMedia
  globalThis.matchMedia = q => ({ matches: q.includes('reduce'), addEventListener() {}, removeEventListener() {} })
  await mount({
    claude: { ...provider('claude', []), status: 'notSignedIn', statusDetail: 'notConfigured' },
    cursor: { ...provider('cursor', []), status: 'unsupported' },
  }, [agent('claude'), agent('cursor')])
  assert.equal(selectedTab().getAttribute('aria-label'), 'claude · 未登录', 'nothing signed in: the first one')
  assert.match(text(detail().querySelector('.mb-q-note')), /^未登录 · 去设置$/)
  await act(async () => { detail().querySelector('.mb-inline-link').click() })
  assert.deepEqual(posted.at(-1), { type: 'openSettings', section: 'usage' })
  await act(async () => { tabs()[1].click() })
  assert.equal(root.querySelector('.mb-page.leaving'), null, 'Reduce Motion: no slide')
  assert.equal(text(detail().querySelector('.mb-q-note')), '暂不支持查询额度')
  assert.equal(detail().querySelector('.mb-w'), null)
  const css = readFileSync(join(process.cwd(), 'src/styles.css'), 'utf8')
  assert.match(css, /@media \(prefers-reduced-motion: reduce\) \{\s*\.mb-page \{ animation: none !important; \}/)
  globalThis.matchMedia = media
})

test('stale readings keep their numbers and say why', async () => {
  await mount({ codex: provider('codex', [win('p', '5h', 40)], { status: 'stale', statusDetail: 'rateLimited' }) }, [agent('codex')], 'en')
  assert.equal(text(detail().querySelector('.mb-w-pct')), '60%')
  assert.match(text(detail().querySelector('.mb-q-note')), /May be out of date · Rate limited/)
})

test('panel height: the full natural content height goes to native only when it changes', async () => {
  const { naturalHeight, observeHeight } = await import('../src/components/MenuBar.tsx')
  // padding + header, bar, provider page, recent chats, footer + 4 gaps.
  assert.equal(naturalHeight({ padding: 16, gap: 8, blocks: [22, 28, 120.2, 110, 29] }), 358)
  assert.equal(naturalHeight({ padding: 16, gap: 8, blocks: [22, 0, 120, 110, 29] }), 321, 'a missing block adds no gap')
  posted.length = 0
  const panel = document.createElement('div')
  panel.innerHTML = '<div class="mb-head"></div><div class="mb-pager"><div class="mb-page"></div></div><section class="mb-section"></section><div class="mb-foot"></div>'
  const size = (el, h) => { el.getBoundingClientRect = () => ({ height: h, width: 340, top: 0, left: 0, right: 340, bottom: h }) }
  const [head, pager, page, section, foot] = ['.mb-head', '.mb-pager', '.mb-page', '.mb-section', '.mb-foot'].map(sel => panel.querySelector(sel))
  size(head, 22); size(pager, 60); size(page, 120); size(section, 110); size(foot, 29)
  const style = globalThis.getComputedStyle
  globalThis.getComputedStyle = () => ({ paddingTop: '9px', paddingBottom: '7px', rowGap: '8px' })
  const observers = []
  globalThis.ResizeObserver = class { constructor(cb) { this.cb = cb; observers.push(this) } observe() {} disconnect() {} }
  const stop = observeHeight(panel)
  await new Promise(resolve => setTimeout(resolve, 5))
  // Pager clipped to 60 by a short window: the page's own 120 counts, footer included.
  assert.deepEqual(posted.filter(m => m.type === 'menuBarHeight'), [{ type: 'menuBarHeight', height: 321 }])
  assert.equal(panel.classList.contains('capped'), false, 'fits the screen: no inner scrolling')
  // The window catches up: same natural height, nothing re-sent.
  size(pager, 120)
  observers[0].cb([])
  await new Promise(resolve => setTimeout(resolve, 5))
  assert.equal(posted.filter(m => m.type === 'menuBarHeight').length, 1)
  // A provider with fewer limits: one message, smaller.
  size(page, 54)
  observers[0].cb([])
  await new Promise(resolve => setTimeout(resolve, 5))
  assert.deepEqual(posted.filter(m => m.type === 'menuBarHeight').at(-1), { type: 'menuBarHeight', height: 255 })
  stop()
  globalThis.getComputedStyle = style
  const css = readFileSync(join(process.cwd(), 'src/styles.css'), 'utf8')
  assert.match(css.match(/\.mb-pager \{([^}]*)\}/)[1], /overflow: hidden;/, 'no inner scrollbar unless capped by the screen')
  assert.match(css, /\.menubar\.capped \.mb-pager \{ overflow-y: auto; \}/)
})

test('swipe tracker: threshold, one step per gesture, resets when the wheel goes quiet', async () => {
  const { swipeTracker } = await import('../src/components/MenuBar.tsx')
  const steps = []
  const tracker = swipeTracker(dir => steps.push(dir), 36, 20)
  tracker.wheel({ deltaX: 20, deltaY: 0 })
  assert.deepEqual(steps, [])
  tracker.wheel({ deltaX: 20, deltaY: 0 })
  tracker.wheel({ deltaX: 200, deltaY: 0 })
  assert.deepEqual(steps, [1], 'momentum does not skip providers')
  await new Promise(resolve => setTimeout(resolve, 30))
  tracker.wheel({ deltaX: -40, deltaY: 0 })
  assert.deepEqual(steps, [1, -1])
})
