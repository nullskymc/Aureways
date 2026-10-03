import { rpc } from '../rpc'
import { openFile } from './state'

export async function pickMarkdown() {
  const paths = await rpc<string[]>('pick.markdown').catch(() => [])
  for (const p of paths) openFile(p)
}
