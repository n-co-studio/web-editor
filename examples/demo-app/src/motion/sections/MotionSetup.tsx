/**
 * Motion setup — install / run MCP / dev plugin / activate, as a dark numbered
 * stepper with code panels. Reveal on scroll. Same content as the classic page.
 */

import type { ReactNode } from 'react';

function Code({ children }: { children: string }) {
  return (
    <pre
      style={{
        margin: 'var(--space-3) 0 0',
        background: 'var(--m-bg-2)',
        color: 'var(--m-fg)',
        borderLeft: '2px solid var(--m-accent)',
        fontFamily: 'var(--m-mono)',
        fontSize: '0.875rem',
        lineHeight: 1.6,
        padding: 'var(--space-3) var(--space-4)',
        overflowX: 'auto',
      }}
    >
      <code>{children}</code>
    </pre>
  );
}

type Step = { title: string; body: ReactNode };

const STEPS: Step[] = [
  { title: 'Install the extension', body: (
    <>
      <p style={{ fontSize: '0.9375rem', color: 'var(--m-fg-dim)' }}>From the Chrome Web Store, or load it unpacked for development:</p>
      <Code>{`chrome://extensions → Developer mode → Load unpacked
→ select packages/chrome-extension/dist`}</Code>
    </>
  ) },
  { title: 'Connect your agent', body: (
    <>
      <p style={{ fontSize: '0.9375rem', color: 'var(--m-fg-dim)' }}>
        It’s a standard MCP server — the same config works with any MCP-compatible agent. Add it wherever your
        agent reads MCP servers (your agent launches it, and it also serves the extension over WebSocket):
      </p>
      <Code>{`{
  "mcpServers": {
    "nco-web-editor": {
      "command": "npx",
      "args": ["--yes", "@nco-studio/web-editor-mcp@^1"]
    }
  }
}`}</Code>
      <ul style={{ listStyle: 'none', margin: 'var(--space-4) 0 0', display: 'flex', flexDirection: 'column', gap: 'var(--space-2)' }}>
        {([
          ['Claude Code', '.claude/settings.json'],
          ['Cursor', '.cursor/mcp.json'],
          ['Windsurf', '~/.codeium/windsurf/mcp_config.json'],
          ['Any MCP client', 'its own mcpServers config'],
        ] as ReadonlyArray<readonly [string, string]>).map(([name, path]) => (
          <li key={name} style={{ display: 'flex', flexWrap: 'wrap', gap: 'var(--space-3)', fontSize: '0.9375rem' }}>
            <span style={{ minWidth: 116, color: 'var(--m-fg)' }}>{name}</span>
            <code style={{ fontFamily: 'var(--m-mono)', color: 'var(--m-fg-dim)' }}>{path}</code>
          </li>
        ))}
      </ul>
    </>
  ) },
  { title: 'Add the dev plugin (optional)', body: (
    <>
      <p style={{ fontSize: '0.9375rem', color: 'var(--m-fg-dim)' }}>Enables source-file mapping so edits point at the exact line:</p>
      <Code>{`import { ncoWebEditor } from '@nco-studio/web-editor-plugin';
// vite.config.ts → plugins: [react(), ncoWebEditor()]`}</Code>
    </>
  ) },
  { title: 'Open localhost & activate', body: (
    <p style={{ fontSize: '0.9375rem', color: 'var(--m-fg-dim)' }}>
      Visit your dev server, click the toolbar icon, and the built-in walkthrough kicks in. A banner
      appears only if the extension and server versions disagree.
    </p>
  ) },
  { title: 'Run the loop', body: (
    <>
      <p style={{ fontSize: '0.9375rem', color: 'var(--m-fg-dim)' }}>
        Edit visually, <strong style={{ color: 'var(--m-fg)', fontWeight: 400 }}>Add to Queue</strong>, review,
        and hit <strong style={{ color: 'var(--m-fg)', fontWeight: 400 }}>Send</strong>. A connected agent applies
        the diff from there; if it doesn’t act on its own, tell it:
      </p>
      <Code>{`Apply my pending NCO Studio edits.`}</Code>
      <p style={{ fontSize: '0.9375rem', color: 'var(--m-fg-dim)' }}>
        It calls <code style={{ fontFamily: 'var(--m-mono)', color: 'var(--m-fg)' }}>get_pending_visual_changes</code>,
        applies each change to your source, and acknowledges it. Everything stays local.
      </p>
    </>
  ) },
];

export default function MotionSetup() {
  return (
    <section id="setup" style={{ padding: 'var(--space-16) 0', scrollMarginTop: 'var(--space-12)' }}>
      <div className="m-reveal" style={{ marginBottom: 'var(--space-12)', maxWidth: '60ch' }}>
        <span style={{ fontFamily: 'var(--m-mono)', fontSize: 12, letterSpacing: '0.16em', textTransform: 'uppercase', color: 'var(--m-accent)' }}>
          Set it up
        </span>
        <h2 style={{ fontFamily: 'var(--m-serif)', fontWeight: 200, fontSize: '2.4rem', letterSpacing: '-0.01em', color: 'var(--m-fg)', marginTop: 'var(--space-3)' }}>
          Install, connect, run the loop
        </h2>
        <p style={{ fontSize: '1rem', color: 'var(--m-fg-dim)', marginTop: 'var(--space-3)' }}>Everything runs locally — no data leaves your machine.</p>
      </div>

      <ol style={{ listStyle: 'none', display: 'flex', flexDirection: 'column', gap: 'var(--space-10)' }}>
        {STEPS.map((s, i) => (
          <li key={s.title} className="m-reveal" style={{ display: 'grid', gridTemplateColumns: '40px 1fr', gap: 'var(--space-5)', alignItems: 'start' }}>
            <span style={{ fontFamily: 'var(--m-mono)', fontSize: '1rem', color: 'var(--m-accent)', borderTop: '2px solid var(--m-accent)', paddingTop: 'var(--space-2)' }}>
              {String(i + 1).padStart(2, '0')}
            </span>
            <div style={{ maxWidth: '60ch' }}>
              <h3 style={{ fontFamily: 'var(--m-sans)', fontWeight: 400, fontSize: '1.25rem', color: 'var(--m-fg)' }}>{s.title}</h3>
              {s.body}
            </div>
          </li>
        ))}
      </ol>
    </section>
  );
}
