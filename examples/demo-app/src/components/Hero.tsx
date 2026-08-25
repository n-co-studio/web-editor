/**
 * Hero — thin-weight serif display headline + sans subhead over the lava
 * field. Text only: no header above it, no image panel beside it.
 */

export default function Hero() {
  return (
    <section
      className="nco-section"
      style={{
        paddingTop: 'var(--space-8)',
        marginBottom: 'var(--space-16)',
      }}
    >
      <div>
          <span
            style={{
              fontSize: 'var(--text-caption)',
              fontFamily: 'var(--font-mono)',
              textTransform: 'uppercase',
              letterSpacing: 'var(--tracking-wide)',
              color: 'var(--color-secondary)',
            }}
          >
            n'co studio Web Editor — on the Chrome Extension Store
          </span>

          <h1
            style={{
              fontFamily: 'var(--font-serif)',
              fontWeight: 'var(--fw-thin)',
              fontSize: 'var(--text-display)',
              lineHeight: 'var(--leading-tight)',
              letterSpacing: 'var(--tracking-tight)',
              color: '#ffffff',
              maxWidth: '14ch',
              marginTop: 'var(--space-5)',
            }}
          >
            Design on the page. Hand off to your agent.
          </h1>

          <p
            style={{
              fontFamily: 'var(--font-sans)',
              fontWeight: 'var(--fw-book)',
              fontSize: 'var(--text-body)',
              color: 'var(--color-secondary)',
              maxWidth: '46ch',
              marginTop: 'var(--space-6)',
            }}
          >
            The Web Editor lets AI-native designers make precise frontend changes without touching
            code — a drag-and-drop design interface on your local dev pages that hands reviewed
            edits to the agent watching your dev environment. Built as a process tool for a
            portfolio; now a feature-rich, production-ready product.
          </p>

          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 'var(--space-6)', alignItems: 'center', marginTop: 'var(--space-8)' }}>
            <a
              href="#setup"
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
              Set it up
            </a>
          </div>
      </div>
    </section>
  );
}
