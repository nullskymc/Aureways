// JS -> Swift. `aureways` is registered by WKUserContentController on the
// native side. Outside the app (vite dev) messages go to the console.
export type OutMessage =
  | { type: 'ready' }
  | { type: 'height'; height: number }
  | { type: 'link'; href: string }
  | { type: 'copy'; text: string }

declare global {
  interface Window {
    webkit?: { messageHandlers?: { aureways?: { postMessage(m: unknown): void } } }
  }
}

export function post(message: OutMessage) {
  const handler = window.webkit?.messageHandlers?.aureways
  if (handler) handler.postMessage(message)
  else console.debug('[aureways]', message)
}
