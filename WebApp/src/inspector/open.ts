import { rpc } from '../rpc'
import { openDocuments } from '../reader/state'

export async function pickMarkdown() {
  const paths = await rpc<string[]>('pick.markdown').catch(() => [])
  if (paths.length) openDocuments(paths, '', true)
}
