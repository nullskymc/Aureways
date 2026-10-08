// Finder, ⌘O and in-document Markdown links open a file tab in the main strip.
import { signal } from '@preact/signals'
import { onMessage } from '../bridge'
import { openExternal, openFile } from '../inspector/state'
import { forgetImage } from './assets'
import { canonicalPath } from './paths'

/** Fragment to scroll to after the next paint of the active Markdown tab. */
export const pendingHash = signal('')

export function openDocuments(paths: string[], hash = '', external = false) {
  let opened = false
  for (const raw of paths) {
    if (!raw) continue
    const path = raw.startsWith('/') ? canonicalPath(raw) : raw
    if (external) openExternal(path)
    else openFile(path)
    opened = true
  }
  if (opened && hash) pendingHash.value = hash
}

onMessage((m) => {
  if (m.type === 'fileChanged') forgetImage(m.path)
  if (m.type === 'command' && m.name === 'openReader' && m.paths?.length) openDocuments(m.paths, '', true)
})
