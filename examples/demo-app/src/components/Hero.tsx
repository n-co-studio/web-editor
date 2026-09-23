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
            Visual Web Editor for AI Agents — by n'co studio
          </span>

          <h1
            style={{
              fontFamily: 'var(--font-serif)',
              fontWeight: 'var(--fw-thin)',
              fontSize: 'var(--text-display)',
              lineHeight: 'var(--leading-tight)',
              letterSpacing: 'var(--tracking-tight)',
              color: 'var(--color-ink)',
              maxWidth: '24ch',
              marginTop: 'var(--space-5)',
            }}
          >
            Design directly on the page,<br />AI builds in the background.
          </h1>

          <p
            style={{
              fontFamily: 'var(--font-sans)',
              fontWeight: 'var(--fw-book)',
              fontSize: 'var(--text-body)',
              color: 'var(--color-secondary)',
              maxWidth: '70ch',
              marginTop: 'var(--space-6)',
              marginBottom: 'var(--space-16)',
            }}
          >
            The Web Editor lets AI-native designers make precise frontend changes without touching
            code — a drag-and-drop design interface on your local dev pages that hands reviewed
            edits to the agent watching your dev environment. Built as a process tool for a
            portfolio; now a feature-rich, production-ready product.
          </p>

      </div>
    </section>
  );
}
