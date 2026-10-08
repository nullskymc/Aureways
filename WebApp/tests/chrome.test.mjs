import assert from 'node:assert/strict'
import { test } from 'node:test'
import { parseHTML } from 'linkedom'
const { window, document } = parseHTML('<html><body><div class="app"><header class="main-head"><div data-no-drag><button>Tab</button></div><button class="add">+</button></header><div class="col-resizer"></div><button class="body-control">Body</button></div></body></html>')
Object.assign(globalThis, { window, document, Element: window.Element })
const posts = []
window.webkit = { messageHandlers: { aureways: { postMessage: m => posts.push(m) } } }
let frames = new Map(), seq = 0
Object.assign(globalThis, {
  requestAnimationFrame: fn => { frames.set(++seq, fn); return seq },
  cancelAnimationFrame: id => frames.delete(id),
  MutationObserver: window.MutationObserver,
  ResizeObserver: class { observe() {} unobserve() {} disconnect() {} },
})
const { headerHeight, titlebarRegions, observeTitlebar } = await import('../src/chrome.ts')
const box = (x, y, width, height) => ({ x, y, left: x, top: y, width, height, right: x + width, bottom: y + height })
const root = document.querySelector('.app')
root.getBoundingClientRect = () => box(0, 0, 1000, 700)
root.querySelector('header').getBoundingClientRect = () => box(300, 0, 700, 52)
root.querySelector('[data-no-drag]').getBoundingClientRect = () => box(306, 10, 450, 30)
// A scrolled-out tab must not make the native traffic-light/drag area clickable.
root.querySelector('[data-no-drag] button').getBoundingClientRect = () => box(-100, 10, 180, 30)
root.querySelector('.add').getBoundingClientRect = () => box(760, 15, 22, 22)
root.querySelector('.col-resizer').getBoundingClientRect = () => box(296, 0, 4, 700)
root.querySelector('.body-control').getBoundingClientRect = () => box(0, 1, 100, 24)
const flush = () => { const current = [...frames.values()]; frames.clear(); current.forEach(fn => fn()) }

test('native titlebar height is authoritative, including fullscreen and hidden lights', () => {
  for (const fullscreen of [true, false]) assert.equal(headerHeight({ chrome: { titlebarHeight: 52, fullscreen, trafficLights: { y: 8, h: 14 } } }), 52)
  assert.equal(headerHeight({ chrome: { titlebarHeight: 44, fullscreen: true } }), 44)
  assert.equal(headerHeight(null), 46)
})
test('only visible header controls and column dividers exclude native dragging', () => {
  assert.deepEqual(titlebarRegions(root, 52), [
    { x: 304, y: 8, w: 454, h: 34 }, { x: 758, y: 13, w: 26, h: 26 }, { x: 296, y: 0, w: 4, h: 52 },
  ])
})
test('native hit regions refresh on child tab changes and stop after cleanup', async () => {
  const stop = observeTitlebar(root, 52)
  flush()
  const first = posts.length
  const button = document.createElement('button')
  button.getBoundingClientRect = () => box(810, 15, 22, 22)
  root.querySelector('header').append(button)
  await new Promise(resolve => setTimeout(resolve, 0))
  flush()
  assert.equal(posts.length, first + 1)
  assert.ok(posts.at(-1).rects.some(r => r.x === 808))
  stop()
  button.remove()
  await new Promise(resolve => setTimeout(resolve, 0))
  flush()
  assert.equal(posts.length, first + 1)
})
