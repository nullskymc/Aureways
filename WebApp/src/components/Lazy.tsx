import type { ComponentType } from 'preact'
import { useEffect, useState } from 'preact/hooks'

/** Code-split component: loads its chunk on first render. */
export function lazy<P extends object>(load: () => Promise<ComponentType<P>>): ComponentType<P> {
  let cached: ComponentType<P> | null = null
  let pending: Promise<ComponentType<P>> | null = null
  return function Lazy(props: P) {
    const [C, setC] = useState<ComponentType<P> | null>(() => cached)
    useEffect(() => {
      if (C) return
      pending ??= load().then((c) => (cached = c))
      let live = true
      pending.then((c) => live && setC(() => c))
      return () => {
        live = false
      }
    }, [])
    return C ? <C {...props} /> : null
  }
}
