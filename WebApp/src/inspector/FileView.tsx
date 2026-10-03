import { useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks'
import { post } from '../bridge'
import { t } from '../i18n'
import { MarkdownView } from '../markdown/render'
import { canonicalLang, highlight } from '../markdown/highlight'
import { Icon, Spinner } from '../components/Icon'
import { mentionFile } from '../components/Composer'
import { displayPath } from '../components/Blocks'
import { app } from '../store'
import { ensureBuffer, loadBuffer, saveBuffer, type Buffer } from './state'

const HIGHLIGHT_LIMIT = 300_000

export function FileView({ path }: { path: string }) {
  const b = ensureBuffer(path)
  const data = b.data.value
  const editing = b.draft.value !== null
  const isMarkdown = /\.(md|markdown|mdown|mkd|mkdn|mdwn)$/i.test(path)

  const startEdit = () => {
    if (data?.text === undefined) return
    b.draft.value = data.text
  }
  const save = async () => {
    if (await saveBuffer(b)) b.draft.value = null
  }

  return (
    <div class="fileview">
      <div class="file-head">
        <span class="file-path" title={path}>{displayPath(path)}</span>
        <div class="flex1" />
        {isMarkdown && !editing && (
          <button class={'icon-btn tiny' + (b.preview.value ? ' on' : '')} title={b.preview.value ? t('showSource') : t('showPreview')} onClick={() => (b.preview.value = !b.preview.value)}>
            <Icon name={b.preview.value ? 'code' : 'eye'} size={12} />
          </button>
        )}
        {data?.text !== undefined &&
          (editing ? (
            <>
              <button class="btn small subtle" onClick={() => { b.draft.value = null; b.dirty.value = false }}>{t('cancel')}</button>
              <button class="btn small primary" disabled={!b.dirty.value} onClick={save} title="⌘S">{t('save')}</button>
            </>
          ) : (
            <button class="icon-btn tiny" title={t('edit')} onClick={startEdit}>
              <Icon name="pencil" size={12} />
            </button>
          ))}
        <button class="icon-btn tiny" title={t('mention')} onClick={() => mentionFile(path, app.peek()?.inspectorRoot ?? '')}>
          <Icon name="at" size={12} />
        </button>
        <button class="icon-btn tiny" title={t('revealInFinder')} onClick={() => post('openPath', { path })}>
          <Icon name="external" size={12} />
        </button>
      </div>
      {b.external.value && (
        <div class="banner warn slim">
          <Icon name="alert" size={13} />
          <span class="flex1">{t('changedOnDisk')}</span>
          <button class="btn small" onClick={() => { b.dirty.value = false; b.draft.value = null; void loadBuffer(b) }}>{t('reload')}</button>
          <button class="btn small subtle" onClick={() => void saveBuffer(b, true)}>{t('keepMine')}</button>
        </div>
      )}
      <div class="file-body">
        {b.loading.value && !data ? (
          <div class="file-empty"><Spinner size={14} /></div>
        ) : b.error.value && !data ? (
          <div class="file-empty">{b.error.value}</div>
        ) : !data ? null : data.image ? (
          <div class="file-image"><img src={data.image} alt="" /></div>
        ) : data.tooLarge ? (
          <div class="file-empty">{t('fileTooLarge')}</div>
        ) : data.binary ? (
          <div class="file-empty">{t('binaryFile')}</div>
        ) : editing ? (
          <Editor b={b} onSave={save} />
        ) : isMarkdown && b.preview.value ? (
          <MarkdownPreview text={data.text ?? ''} />
        ) : (
          <CodeView text={data.text ?? ''} path={path} />
        )}
      </div>
    </div>
  )
}

function Editor({ b, onSave }: { b: Buffer; onSave(): void }) {
  const ref = useRef<HTMLTextAreaElement>(null)
  useEffect(() => ref.current?.focus(), [])
  return (
    <textarea
      ref={ref}
      class="editor"
      spellcheck={false}
      value={b.draft.value ?? ''}
      onInput={(e) => {
        b.draft.value = (e.target as HTMLTextAreaElement).value
        b.dirty.value = b.draft.value !== b.data.peek()?.text
      }}
      onKeyDown={(e) => {
        if ((e.metaKey || e.ctrlKey) && e.key === 's') {
          e.preventDefault()
          onSave()
        } else if (e.key === 'Tab' && !e.shiftKey) {
          e.preventDefault()
          document.execCommand('insertText', false, '  ')
        }
      }}
    />
  )
}

function MarkdownPreview({ text }: { text: string }) {
  const ref = useRef<HTMLDivElement>(null)
  const view = useRef<MarkdownView | null>(null)
  useLayoutEffect(() => {
    view.current = new MarkdownView(ref.current!)
    return () => view.current?.dispose()
  }, [])
  useLayoutEffect(() => view.current?.set(text, false, true), [text])
  return <div class="md-preview" ref={ref} />
}

function CodeView({ text, path }: { text: string; path: string }) {
  const ext = path.split('.').pop()?.toLowerCase() ?? ''
  const name = path.split('/').pop()?.toLowerCase() ?? ''
  const lang = canonicalLang(name === 'dockerfile' ? 'bash' : name === 'makefile' ? 'bash' : ext)
  const [html, setHtml] = useState<string | null>(null)
  useEffect(() => {
    setHtml(null)
    if (!lang || text.length > HIGHLIGHT_LIMIT) return
    let live = true
    highlight(text.replace(/\n$/, ''), lang).then((h) => live && setHtml(h))
    return () => {
      live = false
    }
  }, [text, lang])
  const lines = text.replace(/\n$/, '').split('\n').length
  return (
    <div class="codeview">
      <pre class="gutter" aria-hidden="true">
        {Array.from({ length: lines }, (_, i) => i + 1).join('\n')}
      </pre>
      {html ? <pre class="code"><code dangerouslySetInnerHTML={{ __html: html }} /></pre> : <pre class="code"><code>{text}</code></pre>}
    </div>
  )
}
