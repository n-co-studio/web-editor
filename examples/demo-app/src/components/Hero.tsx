/**
 * Hero — Mark Preston editorial: thin-weight serif display headline + sans
 * subhead on the left, a parallax image panel on the right. The panel clips a
 * taller inner layer that drifts on scroll via a pure-CSS scroll-driven
 * animation (see .nco-parallax in tokens.css) — placeholder line-art for now,
 * swap the layer's contents for a real <img> later.
 */

/** Monochrome line-art placeholder: an "element selection" motif (on-theme). */
function HeroPlaceholder() {
  return (
    <svg
      viewBox="0 0 480 600"
      preserveAspectRatio="xMidYMid slice"
      width="100%"
      height="100%"
      role="img"
      aria-label="Placeholder: visual editing illustration"
      style={{ display: 'block', color: 'var(--color-secondary)' }}
    >
      {/* stacked "cards" being edited (the page itself now carries the dot grid) */}
      <rect x="70" y="96" width="340" height="120" fill="none" stroke="currentColor" strokeWidth="1.5" opacity="0.5" />
      <rect x="70" y="240" width="160" height="220" fill="none" stroke="currentColor" strokeWidth="1.5" opacity="0.5" />

      {/* selected card (ink) with corner handles */}
      <rect x="250" y="240" width="160" height="220" fill="none" stroke="var(--color-ink)" strokeWidth="2" />
      {[
        [250, 240], [410, 240], [250, 460], [410, 460],
        [330, 240], [250, 350], [410, 350], [330, 460],
      ].map(([cx, cy]) => (
        <rect key={`${cx}-${cy}`} x={cx - 4} y={cy - 4} width="8" height="8" fill="var(--color-bg)" stroke="var(--color-ink)" strokeWidth="1.5" />
      ))}

      {/* cursor */}
      <path d="M392 372 l34 13 -14 4 -4 14 -16 -31 z" fill="var(--color-ink)" stroke="var(--color-bg)" strokeWidth="1.5" />
    </svg>
  );
}

export default function Hero() {
  return (
    <section
      className="nco-section"
      style={{
        paddingTop: 'var(--space-8)',
        marginBottom: 'var(--space-16)',
      }}
    >
      <div className="nco-hero">
        {/* Text column */}
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
            n'co studio Web Editor — guide
          </span>

          <h1
            style={{
              fontFamily: 'var(--font-serif)',
              fontWeight: 'var(--fw-thin)',
              fontSize: 'var(--text-display)',
              lineHeight: 'var(--leading-tight)',
              letterSpacing: 'var(--tracking-tight)',
              color: 'var(--color-ink)',
              maxWidth: '14ch',
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
              maxWidth: '46ch',
              marginTop: 'var(--space-6)',
            }}
          >
            A visual editing overlay for your local dev pages. Point at any element, adjust it on the
            page, and send the changes to your AI coding agent as a structured diff. This guide walks
            through the editor, then covers setup.
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
        </div>

        {/* Parallax image panel */}
        <div
          className="nco-parallax"
          style={{ border: '1px solid var(--color-divider)', height: 420, background: 'var(--color-bg)' }}
        >
          <div className="nco-parallax-layer">
            <HeroPlaceholder />
          </div>
        </div>
      </div>
    </section>
  );
}
