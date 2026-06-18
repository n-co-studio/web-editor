/**
 * Footer — the one ink section. NCO Studio wordmark (inherits paper via
 * currentColor) over a flat ink field. No nav columns: every link there would
 * have been a dead "#" placeholder, so the footer is just brand + the one real
 * command. Sharp, no shadows.
 */

import Logo from './Logo';

export default function SiteFooter() {
  return (
    <footer style={{ background: 'var(--color-ink)', color: 'var(--color-on-ink)', padding: 'var(--space-16) var(--space-10)' }}>
      <div
        style={{
          display: 'flex',
          flexWrap: 'wrap',
          gap: 'var(--space-8)',
          alignItems: 'flex-start',
          justifyContent: 'space-between',
        }}
      >
        <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-4)', maxWidth: 360 }}>
          <span style={{ color: 'var(--color-on-ink)' }}>
            <Logo height={26} />
          </span>
          <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-on-ink-muted)' }}>
            A visual editing overlay for local dev pages that feeds structured diffs to your AI coding agent over MCP.
          </p>
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-2)' }}>
          <span style={{ fontSize: 'var(--text-caption)', textTransform: 'uppercase', letterSpacing: 'var(--tracking-wide)', color: 'var(--color-on-ink-muted)' }}>
            Run the server
          </span>
          <code style={{ fontSize: 'var(--text-body-sm)', fontFamily: 'var(--font-mono)', color: 'var(--color-on-ink)' }}>
            npx @nco-studio/web-editor-mcp
          </code>
        </div>
      </div>

      <div
        style={{
          marginTop: 'var(--space-16)',
          paddingTop: 'var(--space-4)',
          borderTop: '1px solid rgba(255,255,255,0.16)',
          display: 'flex',
          flexWrap: 'wrap',
          gap: 'var(--space-3)',
          justifyContent: 'space-between',
          fontSize: 'var(--text-caption)',
          color: 'var(--color-on-ink-muted)',
        }}
      >
        <span>© 2026 NCO Studio · Demo fixture</span>
        <span style={{ fontFamily: 'var(--font-mono)' }}>localhost:5173</span>
      </div>
    </footer>
  );
}
