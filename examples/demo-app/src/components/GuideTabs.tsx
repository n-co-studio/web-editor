/**
 * GuideTabs — the guide section with three tabs: "Set it up" (install +
 * connect), "How to use" (the editing loop), and "Troubleshooting" (MCP
 * connection problems and resets). Flat underline tabs in the lava theme;
 * sharp, no shadows.
 */

import { useState } from 'react';
import SetupGuide from './SetupGuide';
import HowToUse from './HowToUse';
import Troubleshooting from './Troubleshooting';

const TABS = [
  { id: 'setup', label: 'Set it up' },
  { id: 'use', label: 'How to use' },
  { id: 'trouble', label: 'Troubleshooting' },
] as const;

type TabId = (typeof TABS)[number]['id'];

export default function GuideTabs() {
  const [tab, setTab] = useState<TabId>('setup');

  return (
    <section id="setup" style={{ paddingBottom: 'var(--space-16)', marginBottom: 'var(--space-20)', scrollMarginTop: 'var(--space-12)' }}>
      <div role="tablist" aria-label="Guide" style={{ display: 'flex', flexWrap: 'wrap', gap: 'var(--space-5) var(--space-8)', marginBottom: 'var(--space-10)' }}>
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
        {tab === 'setup' && <SetupGuide />}
        {tab === 'use' && <HowToUse />}
        {tab === 'trouble' && <Troubleshooting />}
      </div>
    </section>
  );
}
