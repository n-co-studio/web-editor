/**
 * Setup guide — a numbered vertical stepper. A hairline connector runs behind
 * ink step badges; code blocks are flat ink panels. Sharp corners, no shadows.
 */

import type { ReactNode } from 'react';

function Code({ children }: { children: string }) {
  return (
    <pre
      style={{
        margin: 0,
        background: 'var(--color-bg)',
        color: 'var(--color-ink)',
        border: '1px solid var(--color-border)',
        fontFamily: 'var(--font-mono)',
        fontSize: 'var(--text-body-sm)',
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
  {
    title: 'Install and pin the extension',
    body: (
      <>
        <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
          Install from the Chrome Web Store, then <strong>pin it to your toolbar</strong> — click the
          puzzle-piece icon in Chrome’s toolbar and hit the pin beside the editor. The icon is how you
          switch the editor on and off, so you want it visible. It is built for your own dev server —
          pages served from <code style={{ fontFamily: 'var(--font-mono)' }}>localhost</code> or{' '}
          <code style={{ fontFamily: 'var(--font-mono)' }}>127.0.0.1</code> — where the source mapping and
          design tokens it relies on come from.
        </p>
        <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
          Developing on the extension itself? Load it unpacked instead:
        </p>
        <Code>{`chrome://extensions → Developer mode → Load unpacked
→ select packages/chrome-extension/dist`}</Code>
      </>
    ),
  },
  {
    title: 'Connect your agent',
    body: (
      <>
        <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
          It’s a standard MCP server — the same config works with any MCP-compatible agent. Add it wherever your
          agent reads MCP servers (your agent launches it, and it also serves the extension over WebSocket):
        </p>
        <Code>{`{
  "mcpServers": {
    "nco-web-editor": {
      "command": "npx",
      "args": ["--yes", "@nco-studio/web-editor-mcp@^0"]
    }
  }
}`}</Code>
        <ul style={{ listStyle: 'none', margin: 'var(--space-4) 0 0', display: 'flex', flexDirection: 'column', gap: 'var(--space-2)' }}>
          {([
            ['Claude Code', '.mcp.json'],
            ['Cursor', '.cursor/mcp.json'],
            ['Windsurf', '~/.codeium/windsurf/mcp_config.json'],
            ['Any MCP client', 'its own mcpServers config'],
          ] as ReadonlyArray<readonly [string, string]>).map(([name, path]) => (
            <li key={name} style={{ display: 'flex', flexWrap: 'wrap', gap: 'var(--space-3)', fontSize: 'var(--text-body-sm)' }}>
              <span style={{ minWidth: 116, color: 'var(--color-ink)', fontWeight: 'var(--fw-regular)' }}>{name}</span>
              <code style={{ fontFamily: 'var(--font-mono)', color: 'var(--color-secondary)' }}>{path}</code>
            </li>
          ))}
        </ul>
      </>
    ),
  },
  {
    title: 'Add the dev plugin (optional)',
    body: (
      <>
        <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
          Enables source-file mapping so edits point at the exact line:
        </p>
        <Code>{`import { ncoWebEditor } from '@nco-studio/web-editor-plugin';
// vite.config.ts → plugins: [react(), ncoWebEditor()]`}</Code>
      </>
    ),
  },
  {
    title: 'Switch it on',
    body: (
      <>
        <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
          Open your dev server in Chrome, click the pinned icon, and click <strong>Extension</strong> in the
          popup to toggle it <strong>On</strong>. The overlay appears and elements highlight as you hover.
        </p>
        <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
          Chrome asks to allow access to devices on your local network the first time it connects —{' '}
          <strong>allow it</strong>. That is the editor reaching your MCP server over{' '}
          <code style={{ fontFamily: 'var(--font-mono)' }}>ws://localhost</code>; nothing leaves your machine.
          A banner appears only if the extension and server versions disagree.
        </p>
      </>
    ),
  },
  {
    title: 'Run the loop',
    body: (
      <>
        <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
          Edit visually — each change queues automatically. Click <strong>Review changes</strong> in the toolbar (or <strong>Open Change Queue</strong> in the popup) to see pending edits, then hit <strong>Apply Changes</strong>. A connected agent
          applies the diff from there. Without an integrated setup, give it an explicit instruction that names the
          server and tools — it reads their descriptions and applies each diff to the right file:
        </p>
        <Code>{`Check my nco-web-editor MCP server for pending visual edits
from the browser. Apply each diff to the source file it points
to, then mark it done — using the get_pending_visual_changes
and acknowledge_visual_change tools.`}</Code>
        <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
          <code style={{ fontFamily: 'var(--font-mono)' }}>nco-web-editor</code> is the <code style={{ fontFamily: 'var(--font-mono)' }}>mcpServers</code> key
          from step 2 — swap in whatever you named it. Everything stays local.
        </p>
      </>
    ),
  },
];

export default function SetupGuide() {
  return (
    <div>
      <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)', maxWidth: 'var(--measure)', marginBottom: 'var(--space-10)' }}>
        Install it, point your agent at it, and activate. Everything runs locally — no data leaves your machine.
      </p>

      <div style={{ position: 'relative' }}>
        {/* connector line behind the badges — sibling of the list, not inside it */}
        <span
          aria-hidden="true"
          style={{ position: 'absolute', left: 15, top: 16, bottom: 16, width: 1, background: 'var(--color-divider)', zIndex: 'var(--z-base)' }}
        />
        <ol style={{ listStyle: 'none', display: 'flex', flexDirection: 'column', gap: 'var(--space-8)' }}>
        {STEPS.map((s, i) => (
          <li key={s.title} style={{ position: 'relative', display: 'grid', gridTemplateColumns: '32px 1fr', gap: 'var(--space-5)', alignItems: 'start' }}>
            <span
              style={{
                position: 'relative',
                zIndex: 'var(--z-raised)',
                width: 32,
                height: 32,
                borderRadius: 'var(--radius-full)',
                background: 'var(--color-ink)',
                color: 'var(--color-on-ink)',
                display: 'inline-flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: 'var(--text-body-sm)',
                fontWeight: 'var(--fw-regular)',
              }}
            >
              {i + 1}
            </span>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-3)', paddingTop: '3px', minWidth: 0, maxWidth: 'var(--measure)' }}>
              <h3 style={{ fontFamily: 'var(--font-sans)', fontWeight: 'var(--fw-regular)', fontSize: 'var(--text-h3)', color: 'var(--color-ink)' }}>{s.title}</h3>
              {s.body}
            </div>
          </li>
        ))}
        </ol>
      </div>
    </div>
  );
}
