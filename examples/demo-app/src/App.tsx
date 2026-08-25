import LavaBackground, { LAVA_CONFIG } from './components/LavaBackground';
import type { LavaConfig } from './components/LavaBackground';
import Hero from './components/Hero';
import GuideTabs from './components/GuideTabs';
import SiteFooter from './components/SiteFooter';

// Page lava: operator-chosen green (#277910) as a tonal ramp so merging blobs
// keep depth. Module-level const so the config identity is stable across
// renders (it feeds a useMemo in LavaBackground).
const PAGE_LAVA: LavaConfig = {
  ...LAVA_CONFIG,
  colors: ['#277910', '#3fae1c', '#1b5a0a', '#63cf35', '#144706', '#2f9114'],
};

export default function App() {
  return (
    <div className="nco-paper nco-lava" style={{ minHeight: '100vh', display: 'flex', flexDirection: 'column' }}>
      {/* Animated lava field — fixed behind everything; decorative only. */}
      <div className="nco-lava-bg" aria-hidden="true">
        <LavaBackground config={PAGE_LAVA} />
      </div>

      <main
        id="top"
        className="nco-lava-content"
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

      <div className="nco-lava-content">
        <SiteFooter />
      </div>
    </div>
  );
}
