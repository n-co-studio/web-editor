/**
 * Hero — Mark Preston editorial: a thin-weight serif display headline (minion-3-
 * display), sans subhead (hero-new), generous whitespace, a hairline rule. Flat:
 * no shadows, sharp corners.
 */

export default function Hero() {
  return (
    <section
      style={{
        paddingTop: 'var(--space-8)',
        paddingBottom: 'var(--space-16)',
        borderBottom: '1px solid var(--color-divider)',
        marginBottom: 'var(--space-16)',
      }}
    >
      <span
        style={{
          fontSize: 'var(--text-caption)',
          fontFamily: 'var(--font-mono)',
          textTransform: 'uppercase',
          letterSpacing: 'var(--tracking-wide)',
          color: 'var(--color-secondary)',
        }}
      >
        NCO Studio Web Editor — guide
      </span>

      <h1
        style={{
          fontFamily: 'var(--font-serif)',
          fontWeight: 'var(--fw-thin)',
          fontSize: 'var(--text-display)',
          lineHeight: 'var(--leading-tight)',
          letterSpacing: 'var(--tracking-tight)',
          color: 'var(--color-ink)',
          maxWidth: '16ch',
          marginTop: 'var(--space-5)',
        }}
      >
        Edit the page. Ship the code.
      </h1>

      <p
        style={{
          fontFamily: 'var(--font-sans)',
          fontWeight: 'var(--fw-book)',
          fontSize: 'var(--text-body)',
          color: 'var(--color-secondary)',
          maxWidth: 'var(--measure)',
          marginTop: 'var(--space-6)',
        }}
      >
        A visual editing overlay for your local dev pages. Activate it, point at any element,
        and adjust its spacing, size, type, or color directly on the page — then send the
        changes to Claude Code as a structured diff. This guide walks through the editor exactly
        as its built-in tour does, then covers setup.
      </p>

      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 'var(--space-6)', alignItems: 'center', marginTop: 'var(--space-8)' }}>
        <a
          href="#walkthrough"
          style={{
            fontFamily: 'var(--font-sans)',
            fontSize: 'var(--text-body-sm)',
            fontWeight: 'var(--fw-book)',
            color: 'var(--color-on-ink)',
            background: 'var(--color-ink)',
            padding: 'var(--space-3) var(--space-6)',
            textDecoration: 'none',
          }}
        >
          Walk through the editor
        </a>
        <a href="#setup" className="nco-link" style={{ fontSize: 'var(--text-body-sm)' }}>
          Jump to setup
        </a>
      </div>
    </section>
  );
}
