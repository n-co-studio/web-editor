import Logo from './components/Logo';
import Hero from './components/Hero';
import Benefits from './components/Benefits';
import Walkthrough from './components/Walkthrough';
import SetupGuide from './components/SetupGuide';
import SiteFooter from './components/SiteFooter';

const NAV: ReadonlyArray<[string, string]> = [
  ['Using the editor', '#walkthrough'],
  ['Setup', '#setup'],
];

export default function App() {
  return (
    <div style={{ minHeight: '100vh', background: 'var(--color-bg)', display: 'flex', flexDirection: 'column' }}>
      <header
        style={{
          position: 'sticky',
          top: 0,
          zIndex: 30,
          borderBottom: '1px solid var(--color-divider)',
          padding: 'var(--space-4) var(--space-6)',
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--space-6)',
          background: 'color-mix(in srgb, var(--color-bg) 90%, transparent)',
          backdropFilter: 'blur(8px)',
        }}
      >
        <a href="#top" aria-label="NCO Studio" style={{ color: 'var(--color-ink)', display: 'flex' }}>
          <Logo height={20} />
        </a>

        <nav style={{ marginLeft: 'auto', display: 'flex', gap: 'var(--space-6)' }}>
          {NAV.map(([label, href]) => (
            <a
              key={label}
              href={href}
              style={{ fontFamily: 'var(--font-sans)', fontWeight: 'var(--fw-book)', fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)', textDecoration: 'none' }}
            >
              {label}
            </a>
          ))}
          <a
            href="/motion"
            style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--text-caption)', color: 'var(--color-ink)', textDecoration: 'none', borderBottom: '1px solid var(--color-ink)', paddingBottom: 1 }}
          >
            motion ↗
          </a>
        </nav>
      </header>

      <main
        id="top"
        style={{
          flex: 1,
          padding: 'var(--space-12) var(--space-6) var(--space-16)',
          maxWidth: 'var(--container-max)',
          margin: '0 auto',
          width: '100%',
        }}
      >
        <Hero />
        <Benefits />
        <Walkthrough />
        <SetupGuide />
      </main>

      <SiteFooter />
    </div>
  );
}
