/**
 * Masthead strip at the top of the guide — the first thing a store installer
 * sees. Figma node 79:549: an intro line, the product name, and a "Created by"
 * credit whose wordmark links back to nco.studio.
 *
 * The strip carries the nco.studio landing page's own background: the same lava
 * field, the same forest-green palette on black, and the same blob dispersal
 * when the logo link is hovered or focused. `data-lava-scope` bounds that
 * dispersal to this strip's field, so the page's own (brighter) lava behind the
 * guide is untouched.
 *
 * One deliberate divergence from the landing page: a 35% black scrim sits
 * between the field and the text here. The landing page has none, but its copy
 * is short and centred, while this strip holds a paragraph of small grey type
 * over drifting blobs — without the scrim the intro line falls to 2.3:1 against
 * the palette's lightest green. The scrim keeps the Figma text colours and
 * clears WCAG AA (4.6:1 grey, 7.5:1 white).
 */

import LavaBackground, { LAVA_CONFIG } from './LavaBackground';
import type { LavaConfig } from './LavaBackground';
import Logo from './Logo';

/**
 * Mirrors LAVA_CONFIG in ~/Developer/nco-studio-site/assets/lava.js so the
 * strip and the landing page read as one surface. Module-level const: its
 * identity feeds a useMemo inside LavaBackground.
 */
const SITE_LAVA: LavaConfig = {
  ...LAVA_CONFIG,
  background: '#000000',
  colors: ['#0B3D22', '#14532D', '#1B5E20', '#2D6A4F', '#40916C', '#245C3A'],
  // 'darken' keeps the darker of two overlapping greens, so the field deepens
  // where blobs meet rather than lightening toward the middle.
  blend: 'darken',
  blur: 5,
  size: 32,
  drift: 13,
  blobOpacity: 0.95,
  scatterInsetMin: 0,
  scatterInsetMax: 40,
  scatterScale: 0.85,
  scatterEase: 0.011,
};

export default function TopBanner() {
  return (
    <header
      data-lava-scope
      style={{
        position: 'relative',
        isolation: 'isolate',
        background: SITE_LAVA.background,
        overflow: 'hidden',
      }}
    >
      {/* Decorative field — absolutely filling the strip, never interactive. */}
      <div
        aria-hidden="true"
        style={{ position: 'absolute', inset: 0, zIndex: 0, pointerEvents: 'none' }}
      >
        <LavaBackground config={SITE_LAVA} />
      </div>

      {/* Scrim: the field's lightest green (#40916C) drifts under the text, where
          #cacaca would sit at 2.3:1. A 35% black wash holds the palette's look
          while taking the intro line to 4.6:1 and the white copy to 7.5:1. */}
      <div
        aria-hidden="true"
        style={{
          position: 'absolute',
          inset: 0,
          zIndex: 0,
          pointerEvents: 'none',
          background: 'rgba(0, 0, 0, 0.35)',
        }}
      />

      <div
        style={{
          position: 'relative',
          zIndex: 1,
          maxWidth: 'var(--container-max)',
          margin: '0 auto',
          padding: 'var(--space-12) var(--space-6)',
          display: 'flex',
          flexDirection: 'column',
          gap: 'var(--space-3)',
          alignItems: 'flex-start',
          color: '#fff',
        }}
      >
        <p
          style={{
            margin: 0,
            fontFamily: 'var(--font-sans)',
            fontWeight: 'var(--fw-book)',
            fontSize: 'var(--text-body-sm)',
            lineHeight: 1.1,
            color: '#cacaca',
          }}
        >
          Welcome to the setup guide for:
        </p>

        {/* A real heading, so heading navigation reaches the product name. The
            page's <h1> stays with Hero's statement below; this sits above it as
            an h2 rather than competing for the single top-level heading. */}
        <h2
          style={{
            margin: 0,
            fontFamily: 'var(--font-sans)',
            fontWeight: 'var(--fw-thin)',
            // 60px at full width, stepping down on narrow screens.
            fontSize: 'clamp(2rem, 6vw, 3.75rem)',
            lineHeight: 1.1,
            letterSpacing: '-0.02em',
            color: '#fff',
          }}
        >
          Visual Web Editor for AI Agents
        </h2>

        <p
          style={{
            margin: 0,
            display: 'flex',
            alignItems: 'center',
            gap: 'var(--space-3)',
            fontFamily: 'var(--font-sans)',
            fontWeight: 'var(--fw-book)',
            fontSize: 'clamp(1rem, 2.4vw, 1.5rem)',
            lineHeight: 1.1,
            color: '#fff',
          }}
        >
          Created by
          <a
            href="https://nco.studio"
            data-lava-scatter
            aria-label="n'co studio"
            style={{ display: 'inline-flex', color: 'inherit', textDecoration: 'none' }}
          >
            <Logo height={21} />
          </a>
        </p>
      </div>
    </header>
  );
}
