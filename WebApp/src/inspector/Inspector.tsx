import { useSignal } from '@preact/signals'
import { nativeMenu } from '../bridge'
import { t } from '../i18n'
import { prefs } from '../prefs'
import { app } from '../store'
import { Icon } from '../components/Icon'
import { ChangesView } from './Changes'
import { FileTree } from './FileTree'
import { FileView } from './FileView'
import { DiffPane } from './DiffPane'
import { closeTab, currentPane, openTerminal, selectTab, buffers, type Tab } from './state'
import { TerminalView } from './Terminal'

export function Inspector() {
  const pane = currentPane()
  const active = pane.tabs.find((t) => t.id === pane.active) ?? pane.tabs[0]
  const terms = pane.tabs.filter((t): t is Extract<Tab, { kind: 'term' }> => t.kind === 'term')
  return (
    <aside class="inspector" style={{ width: prefs.inspectorWidth.value }}>
      <InspectorResizer />
      <div class="insp-tabs" data-no-drag>
        <div class="insp-tab-strip">
          {pane.tabs.map((tab) => (
            <TabButton key={tab.id} tab={tab} active={tab.id === active.id} />
          ))}
        </div>
        <button
          class="icon-btn small"
          title={t('newTerminal')}
          onClick={async (e) => {
            const id = await nativeMenu(
              [
                { id: 'term', title: t('newTerminal'), icon: 'terminal' },
                { id: 'md', title: t('openMarkdown'), icon: 'doc.text' },
              ],
              e.currentTarget as Element,
            )
            if (id === 'term') void openTerminal()
            if (id === 'md') void import('./open').then((m) => m.pickMarkdown())
          }}
        >
          <Icon name="plus" size={13} />
        </button>
        <button class="icon-btn small" title={t('closeInspector')} onClick={() => (prefs.inspectorOpen.value = false)}>
          <Icon name="panelRight" size={14} />
        </button>
      </div>
      <div class="insp-body">
        {active.kind === 'files' && <FileTree root={app.value?.inspectorRoot ?? ''} />}
        {active.kind === 'changes' && <ChangesView />}
        {active.kind === 'file' && <FileView key={active.path} path={active.path} />}
        {active.kind === 'diff' && <DiffPane key={active.file.path} file={active.file} />}
        {/* Terminals stay mounted so xterm keeps its buffer; only the active one shows. */}
        {terms.map((tab) => (
          <TerminalView key={tab.termId} id={tab.termId} visible={tab.id === active.id} exited={!!tab.exited} />
        ))}
      </div>
    </aside>
  )
}

function TabButton({ tab, active }: { tab: Tab; active: boolean }) {
  let icon = 'file'
  let label = ''
  let dirty = false
  switch (tab.kind) {
    case 'files':
      icon = 'folder'
      label = t('files')
      break
    case 'changes':
      icon = 'gitDiff'
      label = t('changes')
      break
    case 'file':
      label = tab.path.split('/').pop() ?? tab.path
      dirty = !!buffers.get(tab.path)?.dirty.value
      break
    case 'diff':
      icon = 'gitDiff'
      label = (tab.file.path.split('/').pop() ?? tab.file.path) + ' · Diff'
      break
    case 'term':
      icon = 'terminal'
      label = tab.exited ? `${tab.title} ✕` : tab.title
      break
  }
  const closable = tab.kind === 'file' || tab.kind === 'diff' || tab.kind === 'term'
  return (
    <div
      class={'insp-tab' + (active ? ' active' : '')}
      data-no-drag
      title={tab.kind === 'file' ? tab.path : label}
      onMouseDown={(e) => {
        if (e.button === 1 && closable) {
          e.preventDefault()
          void closeTab(tab.id)
        }
      }}
    >
      <button class="insp-tab-main" onClick={() => selectTab(tab.id)}>
        <Icon name={icon} size={12} />
        <span class="insp-tab-label">{label}</span>
        {dirty && <span class="dirty-dot" />}
      </button>
      {closable && (
        <button class="insp-tab-x" onClick={() => void closeTab(tab.id)}>
          <Icon name="x" size={10} />
        </button>
      )}
    </div>
  )
}

function InspectorResizer() {
  const dragging = useSignal(false)
  return (
    <div
      class={'insp-resizer' + (dragging.value ? ' active' : '')}
      onMouseDown={(e) => {
        e.preventDefault()
        const startX = e.clientX
        const start = prefs.inspectorWidth.value
        dragging.value = true
        const move = (ev: MouseEvent) => {
          const max = Math.max(320, window.innerWidth - 520)
          prefs.inspectorWidth.value = Math.round(Math.max(300, Math.min(max, start - (ev.clientX - startX))))
        }
        const up = () => {
          dragging.value = false
          window.removeEventListener('mousemove', move)
          window.removeEventListener('mouseup', up)
          document.body.classList.remove('resizing')
        }
        document.body.classList.add('resizing')
        window.addEventListener('mousemove', move)
        window.addEventListener('mouseup', up)
      }}
    />
  )
}
