import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { nativeMenu, post, type MenuItem } from '../bridge'
import { t } from '../i18n'
import { rpc } from '../rpc'
import { route } from '../store'
import type { AppState, QuotaSnapshot, Settings as S } from '../types'
import { HarnessIcon, Icon, Spinner } from '../components/Icon'
import { QuotaCard } from './Quota'

const SECTIONS = [
  { id: 'general', icon: 'gear' },
  { id: 'agents', icon: 'puzzle' },
  { id: 'usage', icon: 'chart' },
  { id: 'workspaces', icon: 'folder' },
  { id: 'permissions', icon: 'shield' },
  { id: 'mcp', icon: 'plug' },
] as const

const set = (key: string, value: unknown) => rpc('settings.set', { key, value })

export function Settings({ state, section }: { state: AppState; section?: string }) {
  const current = section ?? 'general'
  const s = state.settings
  useEffect(() => {
    void rpc('settings.refresh').catch(() => {})
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && (route.value = { name: 'main' })
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])
  const lights = state.chrome.trafficLights
  const headPad = state.chrome.fullscreen ? 12 : Math.max(76, lights.x + lights.w + 14)
  return (
    <>
      <aside class="sidebar settings-nav">
        <div class="sidebar-head" style={{ paddingLeft: headPad }} />
        <div class="sidebar-actions">
          <button class="nav-row" onClick={() => (route.value = { name: 'main' })}>
            <Icon name="arrowLeft" size={15} />
            <span>{t('backToApp')}</span>
            <kbd>esc</kbd>
          </button>
        </div>
        <div class="sidebar-list">
          {SECTIONS.map((sec) => (
            <button key={sec.id} class={'nav-row' + (current === sec.id ? ' selected' : '')} onClick={() => (route.value = { name: 'settings', section: sec.id })}>
              <Icon name={sec.icon} size={15} />
              <span>{t('settings_' + sec.id)}</span>
            </button>
          ))}
        </div>
        <div class="sidebar-foot settings-version">Aureways {s.version}</div>
      </aside>
      <main class="main settings-main">
        <header class="main-head" style={{ paddingLeft: 24 }}>
          <div class="head-titles"><span class="head-title">{t('settings_' + current)}</span></div>
        </header>
        <div class="settings-scroll">
          <div class="settings-page">
            {current === 'general' && <General s={s} />}
            {current === 'agents' && <Agents s={s} quota={state.quota} />}
            {current === 'usage' && <Usage s={s} quota={state.quota} />}
            {current === 'workspaces' && <Workspaces s={s} />}
            {current === 'permissions' && <Permissions s={s} />}
            {current === 'mcp' && <Mcp s={s} />}
          </div>
        </div>
      </main>
    </>
  )
}

// ---- Building blocks -------------------------------------------------------

function Group({ title, footer, children }: { title?: string; footer?: string; children: preact.ComponentChildren }) {
  return (
    <section class="form-group">
      {title && <h3 class="form-title">{title}</h3>}
      <div class="form-card">{children}</div>
      {footer && <p class="form-footer">{footer}</p>}
    </section>
  )
}

function Row({ label, detail, children, onClick }: { label: preact.ComponentChildren; detail?: preact.ComponentChildren; children?: preact.ComponentChildren; onClick?: () => void }) {
  return (
    <div class={'form-row' + (onClick ? ' clickable' : '')} onClick={onClick}>
      <div class="form-label">
        <div>{label}</div>
        {detail && <div class="form-detail">{detail}</div>}
      </div>
      <div class="form-control">{children}</div>
    </div>
  )
}

export function Switch({ on, onChange, disabled }: { on: boolean; onChange(v: boolean): void; disabled?: boolean }) {
  return (
    <button
      role="switch"
      aria-checked={on}
      disabled={disabled}
      class={'switch' + (on ? ' on' : '')}
      onClick={(e) => {
        e.stopPropagation()
        onChange(!on)
      }}
    >
      <span class="knob" />
    </button>
  )
}

function Select({ value, options, onChange }: { value: string; options: { id: string; title: string }[]; onChange(v: string): void }) {
  const cur = options.find((o) => o.id === value)
  return (
    <button
      class="select"
      onClick={async (e) => {
        const items: MenuItem[] = options.map((o) => ({ id: o.id, title: o.title, checked: o.id === value }))
        const id = await nativeMenu(items, e.currentTarget as Element)
        if (id && id !== value) onChange(id)
      }}
    >
      <span>{cur?.title ?? value}</span>
      <Icon name="chevronUpDown" size={11} />
    </button>
  )
}

// ---- Pages -----------------------------------------------------------------

function General({ s }: { s: S }) {
  return (
    <>
      <Group title={t('appearance')}>
        <Row label={t('theme')}>
          <div class="seg">
            {(['system', 'light', 'dark'] as const).map((v) => (
              <button key={v} class={s.appearance === v ? 'on' : ''} onClick={() => set('appearance', v)}>
                {t('theme_' + v)}
              </button>
            ))}
          </div>
        </Row>
        <Row label={t('menuBarIcon')}>
          <Switch on={s.showMenuBar} onChange={(v) => set('showMenuBar', v)} />
        </Row>
      </Group>
      <Group title={t('language')} footer={t('languageFooter')}>
        <Row label={t('uiLanguage')}>
          <Select
            value={s.language}
            options={[
              { id: s.systemLanguage, title: t('followSystem') },
              { id: 'zh-Hans', title: '简体中文' },
              { id: 'en', title: 'English' },
            ]}
            onChange={(v) => set('language', v)}
          />
        </Row>
      </Group>
      <Group title="Markdown" footer={t('markdownFooter')}>
        <Row label={s.markdownDefault ? t('markdownIsDefault') : t('markdownMakeDefault')}>
          <button class="btn small" disabled={s.markdownDefault} onClick={() => rpc('settings.markdownDefault')}>
            {s.markdownDefault ? <Icon name="check" size={12} /> : t('setDefault')}
          </button>
        </Row>
      </Group>
      <Group title={t('newChatDefaults')} footer={t('newChatDefaultsFooter')}>
        <Row label="Agent">
          <Select
            value={s.defaultAgentId}
            options={s.agents.filter((a) => a.enabled).map((a) => ({ id: a.id, title: a.title }))}
            onChange={(v) => set('defaultAgent', v)}
          />
        </Row>
      </Group>
      <Group title={t('about')} footer={t('aboutFooter')}>
        <div class="about">
          <div class="about-mark"><HarnessIcon id="aureways" size={30} /></div>
          <div>
            <div class="about-name">Aureways</div>
            <div class="form-detail">{t('version', s.version)}</div>
            <div class="form-detail">{t('tagline')}</div>
          </div>
        </div>
      </Group>
    </>
  )
}

function Agents({ s, quota }: { s: S; quota: Record<string, QuotaSnapshot> }) {
  const adding = useSignal(false)
  const title = useSignal('')
  const command = useSignal('')
  const builtIn = s.agents.filter((a) => a.builtIn)
  const custom = s.agents.filter((a) => !a.builtIn)
  const row = (a: S['agents'][number]) => (
    <div
      key={a.id}
      class={'agent-row' + (a.enabled ? '' : ' disabled')}
      onClick={() => a.enabled && set('defaultAgent', a.id)}
      onContextMenu={async (e) => {
        e.preventDefault()
        const items: MenuItem[] = [
          { id: 'default', title: t('setDefault'), disabled: !a.enabled },
          { id: 'copy', title: t('copyLaunch') },
        ]
        if (!a.builtIn) items.push({ type: 'separator' }, { id: 'remove', title: t('remove') })
        const id = await nativeMenu(items, { x: e.clientX, y: e.clientY })
        if (id === 'default') set('defaultAgent', a.id)
        if (id === 'copy') rpc('agent.copyLaunch', { id: a.id })
        if (id === 'remove') rpc('agent.remove', { id: a.id })
      }}
    >
      <span class="agent-mark">
        <HarnessIcon id={a.id} size={16} />
        <span class={'avail-dot' + (a.available ? ' ok' : '')} title={a.available ? t('cliFound') : t('cliMissing')} />
      </span>
      <div class="agent-text">
        <div class="agent-title">
          {a.title}
          <span class="badge">{a.builtIn ? t('builtIn') : t('custom')}</span>
          {s.defaultAgentId === a.id && <span class="badge accent">{t('default')}</span>}
        </div>
        <div class="agent-launch mono" title={a.notes}>{a.launchLine}</div>
      </div>
      {quota[a.id] && <span class={'quota-badge ' + quota[a.id].severity} title={quota[a.id].summary}>{quota[a.id].summary}</span>}
      <Switch on={a.enabled} onChange={(v) => rpc('agent.enable', { id: a.id, enabled: v })} />
    </div>
  )
  return (
    <>
      <Group title={t('builtIn')} footer={t('agentsFooter')}>
        {builtIn.map(row)}
      </Group>
      {custom.length > 0 && <Group title={t('custom')}>{custom.map(row)}</Group>}
      <Group>
        {adding.value ? (
          <div class="form-edit">
            <label class="field"><span>{t('name')}</span><input value={title.value} onInput={(e) => (title.value = (e.target as HTMLInputElement).value)} placeholder="My Agent" /></label>
            <label class="field"><span>{t('launchCommand')}</span><input class="mono" value={command.value} onInput={(e) => (command.value = (e.target as HTMLInputElement).value)} placeholder="my-agent --acp" /></label>
            <div class="form-actions">
              <button class="btn small subtle" onClick={async () => { const p = await rpc<string | null>('pick.executable'); if (p) command.value = p }}>{t('browse')}</button>
              <div class="flex1" />
              <button class="btn small subtle" onClick={() => (adding.value = false)}>{t('cancel')}</button>
              <button
                class="btn small primary"
                disabled={!command.value.trim()}
                onClick={async () => {
                  await rpc('agent.add', { title: title.value, command: command.value })
                  title.value = ''
                  command.value = ''
                  adding.value = false
                }}
              >
                {t('add')}
              </button>
            </div>
          </div>
        ) : (
          <Row label={<span class="link-like"><Icon name="plus" size={13} /> {t('addCustomAgent')}</span>} onClick={() => (adding.value = true)} />
        )}
      </Group>
    </>
  )
}

function Usage({ s, quota }: { s: S; quota: Record<string, QuotaSnapshot> }) {
  const agents = s.agents.filter((a) => a.enabled)
  return (
    <>
      <div class="usage-head">
        <p class="form-footer">{t('usageIntro')}</p>
        <button class="btn small" onClick={() => rpc('quota.refresh')}><Icon name="refresh" size={12} /> {t('refreshAll')}</button>
      </div>
      <div class="quota-grid">
        {agents.map((a) => (
          <QuotaCard key={a.id} agent={a} snapshot={quota[a.id]} />
        ))}
      </div>
    </>
  )
}

function Workspaces({ s }: { s: S }) {
  return (
    <Group title={t('addedWorkspaces')} footer={t('workspacesFooter')}>
      {s.workspaces.map((w) => (
        <Row key={w.path} label={w.name} detail={<span class="mono">{w.path}</span>} onClick={() => rpc('workspace.select', { path: w.path })}>
          {w.path === s.defaultWorkspace && <span class="badge accent">{t('default')}</span>}
          <button class="icon-btn small" title="Finder" onClick={(e) => { e.stopPropagation(); post('revealWorkspace', { path: w.path }) }}><Icon name="external" size={12} /></button>
          <button class="btn small subtle danger" onClick={(e) => { e.stopPropagation(); rpc('workspace.remove', { path: w.path }) }}>{t('remove')}</button>
        </Row>
      ))}
      <Row label={<span class="link-like"><Icon name="plus" size={13} /> {t('addWs')}</span>} onClick={() => post('addWorkspace')} />
    </Group>
  )
}

function Permissions({ s }: { s: S }) {
  return (
    <Group title={t('toolPermissions')} footer={t('autoApproveFooter')}>
      <Row label={t('autoApprove')}>
        <Switch on={s.autoApprove} onChange={(v) => set('autoApprove', v)} />
      </Row>
    </Group>
  )
}

function Mcp({ s }: { s: S }) {
  const adding = useSignal(false)
  const name = useSignal('')
  const transport = useSignal('stdio')
  const command = useSignal('')
  const url = useSignal('')
  const valid = name.value.trim() && (transport.value === 'stdio' ? command.value.trim() : url.value.trim())
  return (
    <>
      <Group title={t('mcpServers')} footer={t('mcpFooter')}>
        {!s.mcpServers.length && <Row label={<span class="muted">{t('noMcp')}</span>} />}
        {s.mcpServers.map((m) => (
          <Row key={m.id} label={<>{m.name} <span class="badge">{m.transport.toUpperCase()}</span></>} detail={<span class="mono">{m.summary || t('noCommand')}</span>}>
            <Switch on={m.enabled} onChange={(v) => rpc('mcp.enable', { id: m.id, enabled: v })} />
            <button class="btn small subtle danger" onClick={() => rpc('mcp.remove', { id: m.id })}>{t('remove')}</button>
          </Row>
        ))}
        {adding.value ? (
          <div class="form-edit">
            <label class="field"><span>{t('name')}</span><input value={name.value} onInput={(e) => (name.value = (e.target as HTMLInputElement).value)} /></label>
            <div class="field"><span>{t('transport')}</span>
              <div class="seg">
                {['stdio', 'http', 'sse'].map((v) => <button key={v} class={transport.value === v ? 'on' : ''} onClick={() => (transport.value = v)}>{v === 'stdio' ? 'stdio' : v.toUpperCase()}</button>)}
              </div>
            </div>
            {transport.value === 'stdio' ? (
              <label class="field"><span>{t('launchCommand')}</span><input class="mono" value={command.value} placeholder="npx -y @modelcontextprotocol/server-filesystem /path" onInput={(e) => (command.value = (e.target as HTMLInputElement).value)} /></label>
            ) : (
              <label class="field"><span>URL</span><input class="mono" value={url.value} placeholder="https://…" onInput={(e) => (url.value = (e.target as HTMLInputElement).value)} /></label>
            )}
            <div class="form-actions">
              <div class="flex1" />
              <button class="btn small subtle" onClick={() => (adding.value = false)}>{t('cancel')}</button>
              <button
                class="btn small primary"
                disabled={!valid}
                onClick={async () => {
                  await rpc('mcp.add', { name: name.value, transport: transport.value, command: command.value, url: url.value })
                  name.value = command.value = url.value = ''
                  adding.value = false
                }}
              >
                {t('add')}
              </button>
            </div>
          </div>
        ) : (
          <Row label={<span class="link-like"><Icon name="plus" size={13} /> {t('addMcp')}</span>} onClick={() => (adding.value = true)} />
        )}
      </Group>
      {s.mcpCaps && (
        <Group title={t('agentCaps')}>
          <Row label="HTTP">{s.mcpCaps.http ? t('supported') : t('unsupported')}</Row>
          <Row label="SSE">{s.mcpCaps.sse ? t('supported') : t('unsupported')}</Row>
        </Group>
      )}
      {s.reportedMcp.length > 0 && (
        <Group title={t('reportedMcp')} footer={t('reportedMcpFooter')}>
          {s.reportedMcp.map((m) => <Row key={m.name} label={m.name} detail={<span class="mono">{m.summary}</span>} />)}
        </Group>
      )}
    </>
  )
}

export { Spinner }
