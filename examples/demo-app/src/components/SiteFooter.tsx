/**
 * Footer — the one ink section. NCO Studio wordmark (inherits paper via
 * currentColor) over a flat ink field, with a multi-column link grid. Sharp,
 * no shadows.
 */

import Logo from './Logo';

type LinkGroup = { heading: string; links: string[] };

const GROUPS: LinkGroup[] = [
  { heading: 'Product', links: ['Overview', 'Edit modes', 'Setup', 'Changelog'] },
  { heading: 'Resources', links: ['Quickstart', 'MCP server', 'Dev plugin', 'Compatibility'] },
  { heading: 'Community', links: ['GitHub', 'Issues', 'Discussions', 'Security'] },
];

export default function SiteFooter() {
  return (
    <footer style={{ background: 'var(--color-ink)', color: 'var(--color-on-ink)', padding: 'var(--space-16) var(--space-10)' }}>
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'minmax(220px, 1.4fr) repeat(3, minmax(120px, 1fr))',
          gap: 'var(--space-10)',
        }}
      >
        <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-4)' }}>
          <span style={{ color: 'var(--color-on-ink)' }}>
            <Logo height={26} />
          </span>
          <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-on-ink-muted)', maxWidth: 280 }}>
            A visual editing overlay for local dev pages that feeds structured diffs to Claude Code.
          </p>
          <code style={{ fontSize: 'var(--text-caption)', fontFamily: 'var(--font-mono)', color: 'var(--color-on-ink-muted)' }}>
            npx @nco-studio/web-editor-mcp
          </code>
        </div>

        {GROUPS.map((g) => (
          <nav key={g.heading} style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-3)' }}>
            <span style={{ fontSize: 'var(--text-caption)', textTransform: 'uppercase', letterSpacing: 'var(--tracking-wide)', color: 'var(--color-on-ink-muted)' }}>
              {g.heading}
            </span>
            {g.links.map((l) => (
              <a key={l} href="#" style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-on-ink)', textDecoration: 'none' }}>
                {l}
              </a>
            ))}
          </nav>
        ))}
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
