/**
 * Motion hero — big Minion display headline + the animated HeroSelection scene.
 * Dark kinetic theme; the scene assembles itself on load.
 */

import HeroSelection from '../graphics/HeroSelection';

export default function MotionHero() {
  return (
    <section
      style={{
        display: 'grid',
        gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)',
        gap: 'var(--space-12)',
        alignItems: 'center',
        padding: 'var(--space-16) 0 var(--space-12)',
        borderBottom: '1px solid var(--m-line)',
      }}
      className="nco-motion-hero nco-motion-grid"
    >
      <div>
        <span style={{ fontFamily: 'var(--m-mono)', fontSize: 12, letterSpacing: '0.18em', textTransform: 'uppercase', color: 'var(--m-accent)' }}>
          n'co studio — in motion
        </span>
        <h1
          style={{
            fontFamily: 'var(--m-serif)',
            fontWeight: 100,
            fontSize: 'clamp(2.6rem, 5vw, 4.6rem)',
            lineHeight: 1.04,
            letterSpacing: '-0.01em',
            color: 'var(--m-fg)',
            margin: 'var(--space-5) 0 0',
          }}
        >
          Edit the page.
          <br />
          <span style={{ color: 'var(--m-accent)' }}>Ship</span> the code.
        </h1>
        <p style={{ fontSize: '1.0625rem', color: 'var(--m-fg-dim)', maxWidth: '46ch', marginTop: 'var(--space-6)', lineHeight: 1.6 }}>
          A visual editing overlay for your local dev pages. Point at any element, adjust it on the
          page, and send the change to your AI coding agent as a structured diff over MCP.
        </p>
        <div style={{ display: 'flex', gap: 'var(--space-6)', alignItems: 'center', marginTop: 'var(--space-8)' }}>
          <a
            href="#walkthrough"
            style={{
              fontFamily: 'var(--m-sans)', fontSize: '0.9375rem', fontWeight: 400,
              color: 'var(--m-bg)', background: 'var(--m-accent)',
              padding: 'var(--space-3) var(--space-6)', textDecoration: 'none',
            }}
          >
            Walk through the editor
          </a>
          <a href="#setup" className="m-link" style={{ fontSize: '0.9375rem' }}>Jump to setup</a>
        </div>
      </div>

      <div className="m-reveal" style={{ border: '1px solid var(--m-line)', background: 'var(--m-bg-2)', aspectRatio: '4 / 3' }}>
        <HeroSelection />
      </div>
    </section>
  );
}
