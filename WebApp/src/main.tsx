import './styles.css'
import './markdown/markdown.css'
import { render } from 'preact'
import { inApp, post } from './bridge'
import { App } from './components/App'
import './store'

// Links inside rendered content open natively; code-block copy uses the native pasteboard.
document.addEventListener('click', (e) => {
  const target = e.target as HTMLElement
  const copy = target.closest<HTMLButtonElement>('.code-copy')
  if (copy) {
    e.preventDefault()
    post('copy', { text: copy.closest('.code-block')?.querySelector('code')?.textContent ?? '' })
    copy.textContent = '✓'
    copy.classList.add('done')
    setTimeout(() => {
      copy.textContent = 'Copy'
      copy.classList.remove('done')
    }, 1400)
    return
  }
  const a = target.closest<HTMLAnchorElement>('a[href]')
  if (a) {
    e.preventDefault()
    post('openLink', { href: a.getAttribute('href') ?? '' })
  }
})

// No browser context menu except on editable / selected text.
document.addEventListener('contextmenu', (e) => {
  const el = e.target as HTMLElement
  if (el.closest('textarea, input') || String(window.getSelection() ?? '').length) return
  e.preventDefault()
})

const isMenuBar = location.hash.startsWith('#menubar')
const isComposer = location.hash === '#composer'
if (isMenuBar) document.documentElement.classList.add('in-menubar')
if (isComposer) document.documentElement.classList.add('in-composer', 'glass')
const Root = isMenuBar
  ? (await import('./components/MenuBar')).MenuBar
  : isComposer
    ? (await import('./components/ComposerOverlay')).ComposerOverlay
    : App
render(<Root />, document.getElementById('app')!)
post('ready')
if (!inApp) import('./demo').then((m) => m.loadDemo())
