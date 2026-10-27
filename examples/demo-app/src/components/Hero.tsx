/**
 * Hero — the guide's section head, as the Figma design sets it (node 53:3976):
 * the display heading on the left with the mark beside it on the right.
 *
 * The standfirst used to sit here as a second column. The design moved it below
 * the tab strip, so it now lives at the top of SetupGuide — it is setup-tab
 * copy ("Install it, point your agent at it, and activate"), not a page-level
 * statement, and putting it in GuideTabs would show it over How to use and
 * Troubleshooting too.
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
      <div
        style={{
          display: 'flex',
          alignItems: 'flex-start',
          gap: 'var(--space-5)',
          flexWrap: 'wrap',
        }}
      >
        <h1
          style={{
            margin: 0,
            maxWidth: '446px',
            fontFamily: 'var(--font-display)',
            fontWeight: 'var(--fw-bold)',
            fontSize: 'clamp(2rem, 4.2vw, 2.625rem)',
            lineHeight: 0.9,
            letterSpacing: '-0.05em',
            textTransform: 'uppercase',
            color: 'var(--color-display-ink)',
          }}
        >
          Get to know your new AI design tool
        </h1>

        {/* Natural dimensions are 99.708 x 95.9967; width alone is set so the
            ratio holds. The design slots it at 87.53px wide. */}
        <img
          src={`${import.meta.env.BASE_URL}images/design-tool-icon.svg`}
          alt=""
          aria-hidden="true"
          style={{ width: 88, height: 'auto', display: 'block', flexShrink: 0 }}
        />
      </div>
    </section>
  );
}
