import { Component, h, type FunctionComponent } from 'preact'

/** Tiny `memo` without preact/compat. */
export function memo<P extends object>(fn: FunctionComponent<P>, equal: (a: P, b: P) => boolean): FunctionComponent<P> {
  class Memo extends Component<P> {
    shouldComponentUpdate(next: P) {
      return !equal(this.props as P, next)
    }
    render(props: P) {
      return h(fn, props)
    }
  }
  return Memo as unknown as FunctionComponent<P>
}

export function shallowEqual<P extends object>(a: P, b: P) {
  for (const k in a) if ((a as Record<string, unknown>)[k] !== (b as Record<string, unknown>)[k]) return false
  for (const k in b) if (!(k in a)) return false
  return true
}
