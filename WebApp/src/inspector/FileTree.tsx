import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { nativeMenu, post } from '../bridge'
import { t } from '../i18n'
import { prefs } from '../prefs'
import { rpc, type DirEntry, type SearchHit } from '../rpc'
import { Icon, Spinner } from '../components/Icon'
import { mentionFile } from '../components/Composer'
import { filesVersion, openFile } from './state'

const expanded = new Set<string>()
const cache = new Map<string, DirEntry[]>()

export function FileTree({ root }: { root: string }) {
  const version = useSignal(0)
  const query = useSignal('')
  const hits = useSignal<SearchHit[] | null>(null)
  const hidden = prefs.showHidden.value

  const load = async (path: string, force = false) => {
    if (cache.has(path) && !force) return
    try {
      cache.set(path, await rpc<DirEntry[]>('fs.list', { path, hidden }))
    } catch {
      cache.set(path, [])
    }
    version.value++
  }

  // Reload expanded folders when the agent writes files or the root changes.
  useEffect(() => {
    void load(root, true)
    for (const p of expanded) if (p.startsWith(root)) void load(p, true)
  }, [root, filesVersion.value, hidden])

  useEffect(() => {
    const q = query.value.trim()
    if (!q) {
      hits.value = null
      return
    }
    let live = true
    const timer = setTimeout(async () => {
      const res = await rpc<SearchHit[]>('fs.search', { root, query: q, limit: 80 }).catch(() => [])
      if (live) hits.value = res
    }, 80)
    return () => {
      live = false
      clearTimeout(timer)
    }
  }, [query.value, root])

  void version.value
  const rows: { e: DirEntry; depth: number }[] = []
  const walk = (path: string, depth: number) => {
    for (const e of cache.get(path) ?? []) {
      rows.push({ e, depth })
      if (e.dir && expanded.has(e.path)) walk(e.path, depth + 1)
    }
  }
  walk(root, 0)

  const toggle = (e: DirEntry) => {
    if (expanded.has(e.path)) expanded.delete(e.path)
    else {
      expanded.add(e.path)
      void load(e.path)
    }
    version.value++
  }

  const menu = async (ev: MouseEvent, path: string, dir: boolean) => {
    ev.preventDefault()
    const id = await nativeMenu(
      [
        ...(dir ? [] : [{ id: 'open', title: t('open'), icon: 'doc' }, { id: 'mention', title: t('mention'), icon: 'at' }]),
        { id: 'reveal', title: t('revealInFinder'), icon: 'folder' },
        { id: 'copy', title: t('copyPath'), icon: 'doc.on.doc' },
      ],
      { x: ev.clientX, y: ev.clientY },
    )
    if (id === 'open') openFile(path)
    if (id === 'mention') mentionFile(path, root)
    if (id === 'reveal') post('openPath', { path })
    if (id === 'copy') post('copy', { text: path })
  }

  const name = root.split('/').filter(Boolean).pop() ?? root
  return (
    <div class="tree">
      <div class="tree-head">
        <Icon name="folderOpen" size={13} />
        <span class="tree-root" title={root}>{name}</span>
        <div class="flex1" />
        <button class={'icon-btn tiny' + (hidden ? ' on' : '')} title={t('showHidden')} onClick={() => (prefs.showHidden.value = !hidden)}>
          <Icon name="eye" size={12} />
        </button>
        <button class="icon-btn tiny" title={t('refresh')} onClick={() => { cache.clear(); void load(root, true); for (const p of expanded) void load(p, true) }}>
          <Icon name="refresh" size={12} />
        </button>
        <button class="icon-btn tiny" title={t('collapseAll')} onClick={() => { expanded.clear(); version.value++ }}>
          <Icon name="chevronUpDown" size={12} />
        </button>
      </div>
      <label class="tree-filter">
        <Icon name="search" size={12} />
        <input placeholder={t('filterFiles')} value={query.value} onInput={(e) => (query.value = (e.target as HTMLInputElement).value)} onKeyDown={(e) => e.key === 'Escape' && (query.value = '')} />
      </label>
      <div class="tree-list">
        {hits.value
          ? hits.value.map((h) => (
              <button key={h.path} class="tree-row" style={{ paddingLeft: 10 }} onClick={() => openFile(h.path)} onContextMenu={(e) => menu(e, h.path, false)} title={h.rel}>
                <Icon name="file" size={13} class="tree-icon" />
                <span class="tree-name">{h.rel.split('/').pop()}</span>
                <span class="tree-hint">{h.rel.split('/').slice(0, -1).join('/')}</span>
              </button>
            ))
          : rows.map(({ e, depth }) => (
              <button
                key={e.path}
                class="tree-row"
                style={{ paddingLeft: 8 + depth * 14 }}
                onClick={() => (e.dir ? toggle(e) : openFile(e.path))}
                onContextMenu={(ev) => menu(ev, e.path, e.dir)}
                title={e.path}
              >
                {e.dir ? <Icon name={expanded.has(e.path) ? 'chevronDown' : 'chevronRight'} size={11} class="tree-chev" /> : <span class="tree-chev-pad" />}
                <Icon name={e.dir ? 'folder' : 'file'} size={13} class={'tree-icon' + (e.dir ? ' dir' : '')} />
                <span class="tree-name">{e.name}</span>
              </button>
            ))}
        {!hits.value && !cache.has(root) && (
          <div class="tree-empty">
            <Spinner size={12} />
          </div>
        )}
        {hits.value && !hits.value.length && <div class="tree-empty">{t('noMatches')}</div>}
      </div>
    </div>
  )
}
