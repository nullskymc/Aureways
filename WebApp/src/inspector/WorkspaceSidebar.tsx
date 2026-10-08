import type { ComponentChildren } from 'preact'
import { prefs } from '../prefs'

/** The file navigator belongs to a workbench, never to the window title bar. */
export function WorkspaceSidebar({ children }: { children: ComponentChildren }) {
  return (
    <aside class="workspace-sidebar" style={{ width: prefs.inspectorWidth.value }}>
      <div class="insp-resizer" onMouseDown={(e) => {
        e.preventDefault()
        const startX = e.clientX
        const start = prefs.inspectorWidth.value
        const parentWidth = e.currentTarget.parentElement?.parentElement?.getBoundingClientRect().width ?? 600
        const move = (ev: MouseEvent) => (prefs.inspectorWidth.value = Math.round(Math.max(160, Math.min(400, parentWidth - 180, start + startX - ev.clientX))))
        const up = () => {
          window.removeEventListener('mousemove', move)
          window.removeEventListener('mouseup', up)
          document.body.classList.remove('resizing')
        }
        document.body.classList.add('resizing')
        window.addEventListener('mousemove', move)
        window.addEventListener('mouseup', up)
      }} />
      {children}
    </aside>
  )
}
