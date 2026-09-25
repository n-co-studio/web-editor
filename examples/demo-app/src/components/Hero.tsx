/**
 * Hero — thin-weight serif display headline + sans subhead on the white
 * paper ground. Text only: no header above it, no image panel beside it.
 */

export default function Hero() {
  // Deliberately not .nco-section: that class draws a full-bleed rule at the
  // section's bottom edge, and the guide reads better with whitespace alone
  // between the headline and the tabs. Its padding-bottom is kept inline.
  return (
    <section
      style={{
        paddingTop: 'var(--space-8)',
        paddingBottom: 'var(--space-16)',
      }}
    >
      <div>
          <h1
            style={{
              fontFamily: 'var(--font-serif)',
              fontWeight: 'var(--fw-thin)',
              fontSize: 'var(--text-display)',
              lineHeight: 'var(--leading-tight)',
              letterSpacing: 'var(--tracking-tight)',
              color: 'var(--color-ink)',
              // Wide enough to hold the headline on one line at full size;
              // a max (not a fixed width) so it still reflows on narrow screens.
              maxWidth: '733px',
              marginTop: 'var(--space-5)',
            }}
          >
            Setup your new AI design tool
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
