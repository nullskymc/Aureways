import { useEffect, useRef } from 'preact/hooks'
import { post } from '../bridge'
import { t } from '../i18n'
import { subscribeTerminal } from './state'

type XTerm = import('@xterm/xterm').Terminal
type Fit = import('@xterm/addon-fit').FitAddon

// xterm.js is a lazy chunk: nothing loads until the first terminal opens.
let xtermLib: Promise<[typeof import('@xterm/xterm'), typeof import('@xterm/addon-fit')]> | null = null
const loadXterm = () => {
  if (!xtermLib) {
    xtermLib = Promise.all([import('@xterm/xterm'), import('@xterm/addon-fit'), import('@xterm/xterm/css/xterm.css')]).then(
      ([a, b]) => [a, b] as [typeof import('@xterm/xterm'), typeof import('@xterm/addon-fit')],
    )
  }
  return xtermLib
}

/** Follow the page color-scheme, not the system, when appearance is pinned. */
function pageIsDark(): boolean {
  const scheme = document.documentElement.style.colorScheme
  if (scheme === 'dark') return true
  if (scheme === 'light') return false
  return matchMedia('(prefers-color-scheme: dark)').matches
}

/**
 * Used color of a custom property. `getPropertyValue` returns the raw
 * `light-dark()` token, which xterm rejects and replaces with white text.
 * The viewport is transparent, so that white sits on the light terminal fill.
 */
function usedCssColor(name: string, fallback: string): string {
  const probe = document.createElement('span')
  probe.style.color = `var(${name})`
  document.documentElement.appendChild(probe)
  const color = getComputedStyle(probe).color
  probe.remove()
  return color && color !== 'rgba(0, 0, 0, 0)' ? color : fallback
}

function themeFromCSS(): Record<string, string> {
  const dark = pageIsDark()
  const background = usedCssColor('--term-bg', dark ? '#1b1b1d' : '#fbfbfa')
  const foreground = usedCssColor('--term-fg', dark ? '#e4e4e6' : '#1f1f22')
  return {
    background,
    foreground,
    cursor: foreground,
    cursorAccent: background,
    selectionBackground: dark ? '#3a4a6a' : '#cfe0ff',
    ...(dark
      ? { black: '#1b1b1d', red: '#ff7b72', green: '#7ee787', yellow: '#e3b341', blue: '#79c0ff', magenta: '#d2a8ff', cyan: '#56d4dd', white: '#c9d1d9', brightBlack: '#6e7681' }
      : {
          black: '#24292f', red: '#cf222e', green: '#116329', yellow: '#9a6700', blue: '#0969da', magenta: '#8250df', cyan: '#1b7c83', white: '#6e7781',
          brightBlack: '#57606a', brightRed: '#a40e26', brightGreen: '#1a7f37', brightYellow: '#7d4e00', brightBlue: '#0550ae', brightMagenta: '#6639ba', brightCyan: '#0e6670', brightWhite: '#24292f',
        }),
  }
}

const decoder = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))

export function TerminalView({ id, visible, exited }: { id: string; visible: boolean; exited: boolean }) {
  const host = useRef<HTMLDivElement>(null)
  const term = useRef<{ x: XTerm; fit: Fit } | null>(null)

  useEffect(() => {
    let disposed = false
    let unsub = () => {}
    let ro: ResizeObserver | null = null
    let mq: MediaQueryList | null = null
    let schemeObserver: MutationObserver | null = null
    const onScheme = () => term.current && (term.current.x.options.theme = themeFromCSS())
    void loadXterm().then(([{ Terminal }, { FitAddon }]) => {
      if (disposed || !host.current) return
      const x = new Terminal({
        fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
        fontSize: 12,
        lineHeight: 1.15,
        cursorBlink: true,
        allowProposedApi: false,
        macOptionIsMeta: true,
        scrollback: 5000,
        theme: themeFromCSS(),
      })
      const fit = new FitAddon()
      x.loadAddon(fit)
      x.open(host.current)
      term.current = { x, fit }
      x.onData((data) => post('term.input', { id, data }))
      x.onResize(({ cols, rows }) => post('term.resize', { id, cols, rows }))
      unsub = subscribeTerminal(id, {
        data: (b64) => x.write(decoder(b64)),
        exit: (code) => x.write(`\r\n\x1b[2m[${t('processExited', code ?? '?')}]\x1b[0m\r\n`),
      })
      const refit = () => {
        if (!host.current || host.current.offsetWidth === 0) return
        try {
          fit.fit()
        } catch {}
      }
      ro = new ResizeObserver(() => requestAnimationFrame(refit))
      ro.observe(host.current)
      refit()
      post('term.resize', { id, cols: x.cols, rows: x.rows })
      mq = matchMedia('(prefers-color-scheme: dark)')
      mq.addEventListener('change', onScheme)
      schemeObserver = new MutationObserver(onScheme)
      schemeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ['style'] })
      x.focus()
    })
    return () => {
      disposed = true
      unsub()
      ro?.disconnect()
      mq?.removeEventListener('change', onScheme)
      schemeObserver?.disconnect()
      term.current?.x.dispose()
    }
  }, [id])

  useEffect(() => {
    if (visible && term.current) {
      requestAnimationFrame(() => {
        try {
          term.current?.fit.fit()
        } catch {}
        term.current?.x.focus()
      })
    }
  }, [visible])

  return <div class={'terminal' + (exited ? ' exited' : '')} style={{ display: visible ? 'block' : 'none' }} ref={host} />
}
