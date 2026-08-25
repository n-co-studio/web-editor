/**
 * How to use — the editing loop as a numbered stepper, matching SetupGuide's
 * badge + hairline-connector pattern. Text only; rendered as a tab inside
 * GuideTabs.
 */

import type { ReactNode } from 'react';

type Step = { title: string; body: ReactNode };

const STEPS: Step[] = [
  {
    title: 'Activate the editor',
    body: (
      <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
        On your localhost page, click the toolbar icon. The editor toolbar appears — drag the grip to
        move it, collapse it to browse the page normally, press <kbd style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--text-caption)', border: '1px solid var(--color-border)', padding: '0 4px' }}>ESC</kbd> to exit.
      </p>
    ),
  },
  {
    title: 'Select an element',
    body: (
      <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
        Point and click anything on the page. Build-time tags map every element to its component in
        code, so what you select is exactly what the agent will edit.
      </p>
    ),
  },
  {
    title: 'Edit with your design system',
    body: (
      <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
        Adjust spacing, size, type, color, and layout. The editor pulls the design-system tokens from
        your code and restricts edits to token values, so every change stays on-system.
      </p>
    ),
  },
  {
    title: 'Rearrange by dragging',
    body: (
      <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
        Drag to reorder elements. The editor works with CSS grid and flexbox auto-layout, so the page
        stays responsive and the generated code stays clean.
      </p>
    ),
  },
  {
    title: 'Queue and review',
    body: (
      <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
        Add each edit to the queue. Changes collect with before-and-after values — review, prune, and
        shape the batch before anything leaves the browser.
      </p>
    ),
  },
  {
    title: 'Send to your agent',
    body: (
      <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
        Submit the batch. Exploratory edits collapse to their latest state, and the agent watching
        your local dev environment writes the real code changes.
      </p>
    ),
  },
];

export default function HowToUse() {
  return (
    <div>
      <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)', maxWidth: 'var(--measure)', marginBottom: 'var(--space-10)' }}>
        The editing loop, end to end — from activating the editor to the agent writing code.
      </p>

      <div style={{ position: 'relative' }}>
        <span
          aria-hidden="true"
          style={{ position: 'absolute', left: 15, top: 16, bottom: 16, width: 1, background: 'var(--color-divider)', zIndex: 1 }}
        />
        <ol style={{ listStyle: 'none', display: 'flex', flexDirection: 'column', gap: 'var(--space-8)' }}>
          {STEPS.map((s, i) => (
            <li key={s.title} style={{ position: 'relative', display: 'grid', gridTemplateColumns: '32px 1fr', gap: 'var(--space-5)', alignItems: 'start' }}>
              <span
                style={{
                  position: 'relative',
                  zIndex: 10,
                  width: 32,
                  height: 32,
                  borderRadius: 'var(--radius-full)',
                  background: 'var(--color-ink)',
                  color: 'var(--color-on-ink)',
                  display: 'inline-flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  fontSize: 'var(--text-body-sm)',
                  fontWeight: 'var(--fw-regular)',
                }}
              >
                {i + 1}
              </span>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-3)', paddingTop: '3px', minWidth: 0, maxWidth: 'var(--measure)' }}>
                <h3 style={{ fontFamily: 'var(--font-sans)', fontWeight: 'var(--fw-regular)', fontSize: 'var(--text-h3)', color: 'var(--color-ink)' }}>{s.title}</h3>
                {s.body}
              </div>
            </li>
          ))}
        </ol>
      </div>
    </div>
  );
}
