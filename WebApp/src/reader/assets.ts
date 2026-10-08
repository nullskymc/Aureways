// Rewrite relative images onto data URLs. The page origin is the app bundle,
// so a src of `./pic.png` cannot load by itself.
import { rpc, type FileRead } from '../rpc'
import { canonicalPath, localFile } from './paths'

const cache = new Map<string, string>()

export function forgetImage(path: string) {
  const key = canonicalPath(path)
  for (const cached of cache.keys()) {
    if (canonicalPath(cached) === key) cache.delete(cached)
  }
}

export async function hydrateImages(root: HTMLElement, baseFile: string, token: { cancelled: boolean }) {
  const imgs = [...root.querySelectorAll('img')]
  await Promise.all(
    imgs.map(async (img) => {
      const src = img.getAttribute('src') ?? ''
      if (!src || /^(data:|https?:|blob:)/i.test(src)) return
      const path = localFile(baseFile, src)
      if (!path) return
      const hit = cache.get(path)
      if (hit) {
        if (!token.cancelled && img.isConnected) img.src = hit
        return
      }
      try {
        const data = await rpc<FileRead>('fs.read', { path })
        if (token.cancelled || !img.isConnected) return
        let url = data.image
        if (!url && data.text && /\.svg$/i.test(path)) {
          url = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(data.text)
        }
        if (!url) return
        cache.set(path, url)
        img.src = url
      } catch {
        img.classList.add('broken')
      }
    }),
  )
}
