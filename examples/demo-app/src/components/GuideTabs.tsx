/**
 * GuideTabs — the guide section with three tabs: "Set it up" (install +
 * connect), "How to use" (the editing loop), and "Troubleshooting" (MCP
 * connection problems and resets). Flat underline tabs in ink on white;
 * sharp, no shadows.
 */

import { useEffect, useState } from 'react';
import SetupGuide from './SetupGuide';
import HowToUse from './HowToUse';
import Troubleshooting from './Troubleshooting';

const TABS = [
  { id: 'setup', label: 'Set it up' },
  { id: 'use', label: 'How to use' },
  { id: 'trouble', label: 'Troubleshooting' },
] as const;

type TabId = (typeof TABS)[number]['id'];

/**
 * URL fragments that select a tab.
 *
 * Spelled out rather than derived from the ids so the links can read properly:
 * the Chrome Web Store listing's Support URL points at `#troubleshooting`, and
 * a support link that lands on "Set it up" is a support link that failed.
 * The internal id stays short; the fragment is the public name.
 */
const HASH_TO_TAB: Record<string, TabId> = {
  '#setup': 'setup',
  '#how-to-use': 'use',
  '#use': 'use',
  '#troubleshooting': 'trouble',
  '#trouble': 'trouble',
};

export default function GuideTabs() {
  // Initialised from the fragment so a deep link renders the right tab on the
  // first paint rather than flashing "Set it up" and then switching.
  const [tab, setTab] = useState<TabId>(
    () => (typeof window === 'undefined' ? 'setup' : HASH_TO_TAB[window.location.hash] ?? 'setup'),
  );

  // Hover and pressed are React state rather than CSS :hover/:active because
  // this file styles inline, as the rest of the guide does.
  const [hover, setHover] = useState<TabId | null>(null);
  const [pressed, setPressed] = useState<TabId | null>(null);

  // Follow later fragment changes too — the back button, and a second click on
  // the same support link while the page is already open.
  useEffect(() => {
    const onHashChange = (): void => {
      const next = HASH_TO_TAB[window.location.hash];
      if (next) setTab(next);
    };
    window.addEventListener('hashchange', onHashChange);
    return () => window.removeEventListener('hashchange', onHashChange);
  }, []);

  return (
    <section id="setup" style={{ paddingBottom: 'var(--space-16)', marginBottom: 'var(--space-20)', scrollMarginTop: 'var(--space-12)' }}>
      {/* Figma 52:3891 — the tabs sit flush as a joined strip, each carrying a
          4px underline. No gap between them, so the underlines read as one
          rule; the per-state colours are set below. */}
      <div role="tablist" aria-label="Guide" style={{ display: 'flex', flexWrap: 'wrap', marginBottom: '60px' }}>
        {TABS.map((t) => {
          const active = t.id === tab;
          const hot = t.id === hover;
          const down = t.id === pressed;

          // The four states of the Tab component set (Figma 52:3865). Each one
          // moves fill, underline and label together:
          //   Default  white   / black     / #2f2f2f
          //   Hover    #f3f3f3 / #787878   / #2f2f2f
          //   Tapped   #f3f3f3 / #afafaf   / #afafaf
          //   Active   #2f2f2f / #d2f2cb   / white
          // Active has no hover or tapped variant, so the selected tab holds
          // its appearance under the pointer — matching the design rather than
          // inventing a lift for it.
          const fill = active
            ? 'var(--color-display-ink)'
            : hot || down
              ? '#f3f3f3'
              : '#fff';
          const rule = active
            ? 'var(--color-accent-mint)'
            : down
              ? '#afafaf'
              : hot
                ? '#787878'
                : 'var(--color-ink)';
          // Tapped sets the label to #afafaf, which is 1.98:1 on its own fill —
          // below AA. Kept because it is the design's momentary press feedback,
          // not a state any label is read in: it exists only while the pointer
          // is held down, and the accessible name never changes.
          const label = active ? '#fff' : down ? '#afafaf' : 'var(--color-display-ink)';

          return (
            <button
              key={t.id}
              role="tab"
              aria-selected={active}
              aria-controls={`guide-panel-${t.id}`}
              id={`guide-tab-${t.id}`}
              onClick={() => setTab(t.id)}
              onMouseEnter={() => setHover(t.id)}
              onMouseLeave={() => { setHover(null); setPressed(null); }}
              onPointerDown={() => setPressed(t.id)}
              onPointerUp={() => setPressed(null)}
              // Pointer events alone leave the keyboard with no pressed state,
              // and touch fires no mouseenter — so focus drives hover too, and
              // pointer events cover tap.
              onFocus={() => setHover(t.id)}
              onBlur={() => { setHover(null); setPressed(null); }}
              style={{
                appearance: 'none',
                border: 'none',
                borderBottom: `4px solid ${rule}`,
                background: fill,
                color: label,
                padding: 'var(--space-2) var(--space-6) var(--space-3)',
                cursor: 'pointer',
                fontFamily: 'var(--font-display)',
                fontWeight: 'var(--fw-bold)',
                fontSize: '1.375rem',
                lineHeight: 0.9,
                letterSpacing: '-0.05em',
                whiteSpace: 'nowrap',
                // No opacity shift: the inactive state is carried by the fill
                // and text colour inverting, so fading them too would push the
                // inactive labels below AA on white.
                transition: 'background 0.2s ease, color 0.2s ease',
              }}
            >
              {t.label}
            </button>
          );
        })}
      </div>

      <div role="tabpanel" id={`guide-panel-${tab}`} aria-labelledby={`guide-tab-${tab}`}>
        {tab === 'setup' && <SetupGuide />}
        {tab === 'use' && <HowToUse />}
        {tab === 'trouble' && <Troubleshooting />}
      </div>
    </section>
  );
}
