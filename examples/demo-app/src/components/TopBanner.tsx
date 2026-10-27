/**
 * Masthead strip at the top of the guide — the first thing a store installer
 * sees. Figma node 79:549: an intro line, the product name, and a "Created by"
 * credit whose wordmark links back to nco.studio.
 *
 * The strip carries the nco.studio landing page's own background: the same lava
 * field, the same forest-green palette on black, and the same blob dispersal
 * when the logo link is hovered or focused. `data-lava-scope` bounds that
 * dispersal to this strip's field — the guide below is ink on white paper, and
 * this strip is the page's only dark surface.
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
import StoreInstallButton from './StoreInstallButton';

/**
 * Mirrors LAVA_CONFIG in ~/Developer/nco-studio-site/assets/lava.js so the
 * strip and the landing page read as one surface. Module-level const: its
 * identity feeds a useMemo inside LavaBackground.
 */
const SITE_LAVA: LavaConfig = {
  ...LAVA_CONFIG,
  // Logo spectrum: the mark's off-black ground with blobs stepped along the
  // mark's own mint hue (#D2F2CB — 109deg, 60% sat), rather than the unrelated
  // forest-green set this used before.
  //
  // The stops are not picked by eye. Each one solves for the luminance that
  // reproduces the previous palette's blob-against-field contrast, so the field
  // reads with the same depth it always did:
  //
  //     before  #000000 ground, blobs 1.70:1 – 5.48:1
  //     after   #0F0F0F ground, blobs 1.69:1 – 5.02:1
  //
  // The top of the ramp is capped rather than matched exactly, and that cap is
  // load-bearing. #0F0F0F is lighter than #000000, so holding the old 5.48:1
  // would need a more luminous blob, which pushed the #cacaca intro line under
  // the scrim down to 4.33:1 — below AA, and precisely what the scrim below
  // exists to prevent. Capping the lightest blob keeps white at 7.50:1 and grey
  // at 4.57:1, against 7.53 and 4.60 before.
  background: '#0F0F0F',
  colors: ['#1A4311', '#215716', '#256118', '#2B6F1C', '#399525', '#256118'],
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

      {/* Scrim: the field's lightest green (#399525) drifts under the text, where
          #cacaca would sit far below AA. A 35% black wash holds the palette's
          look while taking the intro line to 4.57:1 and the white copy to
          7.50:1. The blob ramp above is capped to keep those two figures; raise
          the lightest stop and the intro line is the first thing to fail. */}
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
        {/* Title row — eyebrow + product name on the left, the Chrome Web Store
            badge bottom-aligned on the right (Figma 52:3907, align items-end).
            Wraps on narrow screens rather than squeezing the 60px type. */}
        <div
          style={{
            display: 'flex',
            width: '100%',
            alignItems: 'flex-end',
            justifyContent: 'space-between',
            gap: 'var(--space-6)',
            flexWrap: 'wrap',
          }}
        >
          <div
            style={{
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'flex-start',
              gap: 'var(--space-4)',
            }}
          >
            {/* A white chip, not plain text on the field: the design sets this
                line in the display face on white (Figma 52:3910/52:3911). It
                also sidesteps the contrast problem the scrim exists for. */}
            <p
              style={{
                margin: 0,
                background: '#fff',
                color: 'var(--color-display-ink)',
                padding: '2px var(--space-2)',
                fontFamily: 'var(--font-display)',
                fontWeight: 'var(--fw-bold)',
                fontSize: '1rem',
                lineHeight: 1.1,
                textTransform: 'uppercase',
              }}
            >
              Welcome to the setup guide for:
            </p>

            {/* A real heading, so heading navigation reaches the product name.
                The page's <h1> stays with Hero's statement below; this sits
                above it as an h2 rather than competing for the single
                top-level heading. */}
            <h2
              style={{
                margin: 0,
                fontFamily: 'var(--font-display)',
                fontWeight: 'var(--fw-bold)',
                // 60px at full width, stepping down on narrow screens.
                fontSize: 'clamp(2rem, 6vw, 3.75rem)',
                lineHeight: 1.1,
                letterSpacing: '-0.05em',
                textTransform: 'uppercase',
                color: '#fff',
              }}
            >
              AI Agent Visual Editor
            </h2>
          </div>

          <StoreInstallButton />
        </div>

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
