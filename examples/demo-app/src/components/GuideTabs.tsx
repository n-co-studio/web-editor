/**
 * GuideTabs — the guide section with two tabs: "Set it up" (install +
 * connect) and "How to use" (the editing loop). Flat underline tabs in the
 * lava theme; sharp, no shadows.
 */

import { useState } from 'react';
import SetupGuide from './SetupGuide';
import HowToUse from './HowToUse';

const TABS = [
  { id: 'setup', label: 'Set it up' },
  { id: 'use', label: 'How to use' },
] as const;

type TabId = (typeof TABS)[number]['id'];

export default function GuideTabs() {
  const [tab, setTab] = useState<TabId>('setup');

  return (
    <section id="setup" style={{ paddingBottom: 'var(--space-16)', marginBottom: 'var(--space-20)', scrollMarginTop: 'var(--space-12)' }}>
      <div role="tablist" aria-label="Guide" style={{ display: 'flex', gap: 'var(--space-8)', marginBottom: 'var(--space-10)' }}>
        {TABS.map((t) => {
          const active = t.id === tab;
          return (
            <button
              key={t.id}
              role="tab"
              aria-selected={active}
              aria-controls={`guide-panel-${t.id}`}
              id={`guide-tab-${t.id}`}
              onClick={() => setTab(t.id)}
              style={{
                appearance: 'none',
                background: 'none',
                border: 'none',
                borderBottom: active ? '2px solid var(--color-ink)' : '2px solid transparent',
                padding: '0 0 var(--space-2)',
                cursor: 'pointer',
                fontFamily: 'var(--font-serif)',
                fontWeight: 'var(--fw-light)',
                fontSize: 'var(--text-h2)',
                letterSpacing: 'var(--tracking-tight)',
                color: 'var(--color-ink)',
                opacity: active ? 1 : 0.55,
                transition: 'opacity 0.2s ease',
              }}
            >
              {t.label}
            </button>
          );
        })}
      </div>

      <div role="tabpanel" id={`guide-panel-${tab}`} aria-labelledby={`guide-tab-${tab}`}>
        {tab === 'setup' ? <SetupGuide /> : <HowToUse />}
      </div>
    </section>
  );
}
