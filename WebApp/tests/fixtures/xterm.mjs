// Keep state on the instance so a dispose/recreate regression is observable.
export const instances = []
export class Terminal {
  constructor(options) {
    this.options = options
    this.output = ''
    this.scrollTop = 0
    this.cols = 80
    this.rows = 24
    this.disposals = 0
    this.focusCalls = 0
    instances.push(this)
  }
  loadAddon(addon) { this.addon = addon }
  open(element) { this.element = element }
  onData(listener) { this.input = listener }
  onResize(listener) { this.resize = listener }
  write(data) { this.output += typeof data === 'string' ? data : new TextDecoder().decode(data) }
  focus() { this.focusCalls++ }
  dispose() { this.disposals++ }
}
export class FitAddon { fit() {} }
