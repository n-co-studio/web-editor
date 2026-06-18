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
  { title: 'Run the MCP server', body: (
    <>
      <p style={{ fontSize: '0.9375rem', color: 'var(--m-fg-dim)' }}>It scans your project for design tokens and bridges the editor to your AI coding agent:</p>
      <Code>{`npx @nco-studio/web-editor-mcp@latest`}</Code>
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
];

export default function MotionSetup() {
  return (
    <section id="setup" style={{ padding: 'var(--space-16) 0', scrollMarginTop: 'var(--space-12)' }}>
      <div className="m-reveal" style={{ marginBottom: 'var(--space-12)', maxWidth: '60ch' }}>
        <span style={{ fontFamily: 'var(--m-mono)', fontSize: 12, letterSpacing: '0.16em', textTransform: 'uppercase', color: 'var(--m-accent)' }}>
          Set it up
        </span>
        <h2 style={{ fontFamily: 'var(--m-serif)', fontWeight: 200, fontSize: '2.4rem', letterSpacing: '-0.01em', color: 'var(--m-fg)', marginTop: 'var(--space-3)' }}>
          Three commands and a click
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
