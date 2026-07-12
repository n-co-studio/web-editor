/**
 * /motion — the dark "kinetic blueprint" variant of the guide. Its own scoped
 * theme (.nco-motion), CSS-only animation, generated animated SVG graphics.
 * Coexists with the classic page; headers cross-link.
 */

import './motion.css';
import Logo from '../components/Logo';
import MotionHero from './sections/MotionHero';
import MotionBenefits from './sections/MotionBenefits';
import MotionFeatures from './sections/MotionFeatures';
import MotionWalkthrough from './sections/MotionWalkthrough';
import MotionSetup from './sections/MotionSetup';

const NAV: ReadonlyArray<[string, string]> = [
  ['Using the editor', '#walkthrough'],
  ['Setup', '#setup'],
];

export default function MotionApp() {
  return (
    <div className="nco-motion" id="top">
      <header
        style={{
          position: 'sticky',
          top: 0,
          zIndex: 30,
          borderBottom: '1px solid var(--m-line)',
          padding: 'var(--space-4) var(--space-6)',
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--space-6)',
          background: 'color-mix(in srgb, var(--m-bg) 86%, transparent)',
          backdropFilter: 'blur(8px)',
        }}
      >
        <a href="#top" aria-label="n'co studio" style={{ color: 'var(--m-fg)', display: 'flex' }}>
          <Logo height={20} />
        </a>
        <nav style={{ marginLeft: 'auto', display: 'flex', gap: 'var(--space-6)', alignItems: 'center' }}>
          {NAV.map(([label, href]) => (
            <a key={label} href={href} style={{ fontFamily: 'var(--m-sans)', fontWeight: 300, fontSize: '0.9375rem', color: 'var(--m-fg-dim)', textDecoration: 'none' }}>
              {label}
            </a>
          ))}
          <a href="/" className="m-link" style={{ fontFamily: 'var(--m-mono)', fontSize: 12 }}>classic ↗</a>
        </nav>
      </header>

      <main style={{ maxWidth: 1080, margin: '0 auto', padding: '0 var(--space-6)', width: '100%' }}>
        <MotionHero />
        <MotionBenefits />
        <MotionFeatures />
        <MotionWalkthrough />
        <MotionSetup />
      </main>

      <footer style={{ borderTop: '1px solid var(--m-line)', padding: 'var(--space-12) var(--space-6)' }}>
        <div style={{ maxWidth: 1080, margin: '0 auto', display: 'flex', flexWrap: 'wrap', gap: 'var(--space-6)', justifyContent: 'space-between', alignItems: 'center' }}>
          <span style={{ color: 'var(--m-fg)', display: 'flex' }}><Logo height={24} /></span>
          <code style={{ fontFamily: 'var(--m-mono)', fontSize: 12, color: 'var(--m-fg-dim)' }}>npx @nco-studio/web-editor-mcp</code>
          <span style={{ fontFamily: 'var(--m-mono)', fontSize: 12, color: 'var(--m-fg-dim)' }}>© 2026 n'co studio · /motion</span>
        </div>
      </footer>
    </div>
  );
}
