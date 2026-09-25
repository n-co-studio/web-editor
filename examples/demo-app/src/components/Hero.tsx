/**
 * Hero — a thin-weight serif display headline on the white paper ground,
 * and nothing else: no eyebrow above it, no standfirst below it, no image
 * panel beside it. The masthead strip names the product; this states the
 * page's purpose and hands straight over to the tabs.
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
              // Deliberately narrow, so the headline breaks over several lines
              // rather than running the width of the column. A max (not a fixed
              // width) so it still reflows on narrow screens.
              maxWidth: '472px',
              marginTop: 'var(--space-5)',
            }}
          >
            Get to know your new AI design tool.
          </h1>

      </div>
    </section>
  );
}
