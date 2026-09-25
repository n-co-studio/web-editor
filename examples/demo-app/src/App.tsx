import Hero from './components/Hero';
import GuideTabs from './components/GuideTabs';
import TopBanner from './components/TopBanner';

export default function App() {
  return (
    <div className="nco-paper" style={{ minHeight: '100vh', display: 'flex', flexDirection: 'column' }}>
      {/* The lava field is confined to the masthead strip (see TopBanner); the
          guide itself is ink on white paper, which is where the token set in
          tokens.css sits by default. */}
      <TopBanner />

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
        <GuideTabs />
      </main>

    </div>
  );
}
