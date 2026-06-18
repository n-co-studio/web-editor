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
        background: 'var(--color-ink)',
        color: 'var(--color-on-ink)',
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
    title: 'Install the extension',
    body: (
      <>
        <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
          From the Chrome Web Store, or load it unpacked for development:
        </p>
        <Code>{`chrome://extensions → Developer mode → Load unpacked
→ select packages/chrome-extension/dist`}</Code>
      </>
    ),
  },
  {
    title: 'Run the MCP server',
    body: (
      <>
        <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
          It scans your project for design tokens and bridges the editor to your AI coding agent (any MCP client, e.g. Claude Code):
        </p>
        <Code>{`npx @nco-studio/web-editor-mcp@latest`}</Code>
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
    title: 'Open localhost & activate',
    body: (
      <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
        Visit your dev server, click the toolbar icon, and the built-in walkthrough above kicks in.
        A banner appears only if the extension and server versions disagree.
      </p>
    ),
  },
];

export default function SetupGuide() {
  return (
    <section id="setup" style={{ marginBottom: 'var(--space-20)', scrollMarginTop: 'var(--space-12)' }}>
      <h2 style={{ fontFamily: 'var(--font-serif)', fontWeight: 'var(--fw-light)', fontSize: 'var(--text-h2)', letterSpacing: 'var(--tracking-tight)' }}>
        Set it up
      </h2>
      <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)', maxWidth: 'var(--measure)', marginTop: 'var(--space-3)', marginBottom: 'var(--space-10)' }}>
        Three commands and a click. Everything runs locally — no data leaves your machine.
      </p>

      <div style={{ position: 'relative' }}>
        {/* connector line behind the badges — sibling of the list, not inside it */}
        <span
          aria-hidden="true"
          style={{ position: 'absolute', left: 15, top: 16, bottom: 16, width: 1, background: 'var(--color-divider)', zIndex: 1 }}
        />
        <ol style={{ listStyle: 'none', display: 'flex', flexDirection: 'column', gap: 'var(--space-8)' }}>
        {STEPS.map((s, i) => (
          <li key={s.title} style={{ position: 'relative', display: 'grid', gridTemplateColumns: '32px 1fr', gap: 'var(--space-5)', alignItems: 'start' }}>
            <span
              style={{
                position: 'relative',
                zIndex: 10,
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
    </section>
  );
}
