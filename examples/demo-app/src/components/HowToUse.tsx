/**
 * How to use — the editing loop as a numbered stepper, matching SetupGuide's
 * badge + hairline-connector pattern. Text only; rendered as a tab inside
 * GuideTabs.
 */

import type { ReactNode } from 'react';

function Code({ children }: { children: string }) {
  return (
    <pre
      style={{
        margin: 0,
        background: 'var(--color-bg)',
        color: 'var(--color-ink)',
        border: '1px solid var(--color-border)',
        fontFamily: 'var(--font-mono)',
        fontSize: 'var(--text-body-sm)',
        lineHeight: 1.6,
        padding: 'var(--space-3) var(--space-4)',
        overflowX: 'auto',
      }}
    >
      <code>{children}</code>
    </pre>
  );
}

type Step = { title: string; body: ReactNode };

const STEPS: Step[] = [
  {
    title: 'Put your agent on watch',
    body: (
      <>
        <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
          Start an agent session in the project first — it launches the bridge, so nothing can reach
          your code until one is running. Then hand it the loop:
        </p>
        <Code>{`Watch editor-queue-status.yaml for pending_count above
zero. When a batch lands, read it with
get_pending_visual_changes, apply each diff to the source file
it names, then acknowledge_visual_change on each one — and
re-check the queue before you go idle.`}</Code>
        <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
          Agents that read the server's own instructions already work this way; the prompt makes it
          explicit for those that don't.
        </p>
      </>
    ),
  },
  {
    title: 'Activate the editor',
    body: (
      <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
        On your localhost page, click the pinned icon and click <strong>Extension</strong> in the popup to
        toggle it <strong>On</strong>. The editor toolbar appears — drag the grip to move it, collapse it to
        browse the page normally, press <kbd style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--text-caption)', border: '1px solid var(--color-border)', padding: '0 4px' }}>ESC</kbd> to exit.
      </p>
    ),
  },
  {
    title: 'Select and edit elements',
    body: (
      <>
        <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>
          Point and click anything on the page. Build-time tags map every element to its component in
          code, so what you select is exactly what the agent will edit. From there:
        </p>
        <ul
          style={{
            listStyle: 'disc',
            paddingLeft: 'var(--space-5)',
            margin: 'var(--space-3) 0 0',
            display: 'flex',
            flexDirection: 'column',
            gap: 'var(--space-3)',
            fontSize: 'var(--text-body-sm)',
            color: 'var(--color-secondary)',
          }}
        >
          <li>
            <strong style={{ color: 'var(--color-ink)', fontWeight: 'var(--fw-regular)' }}>
              Edit with your design system.
            </strong>{' '}
            Adjust spacing, size, type, colour and layout. The editor reads the design tokens from
            your code and snaps edits to them, so changes stay on-system.
          </li>
          <li>
            <strong style={{ color: 'var(--color-ink)', fontWeight: 'var(--fw-regular)' }}>
              Rearrange by dragging.
            </strong>{' '}
            Reorder elements directly. The editor understands CSS grid and flexbox auto-layout, so
            the page stays responsive and the generated code stays clean.
          </li>
          <li>
            <strong style={{ color: 'var(--color-ink)', fontWeight: 'var(--fw-regular)' }}>
              Change text, images and structure.
            </strong>{' '}
            Edit copy in place, swap images, insert or remove elements — not just styling.
          </li>
        </ul>
      </>
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
          style={{ position: 'absolute', left: 15, top: 16, bottom: 16, width: 1, background: 'var(--color-divider)', zIndex: 'var(--z-base)' }}
        />
        <ol style={{ listStyle: 'none', display: 'flex', flexDirection: 'column', gap: 'var(--space-8)' }}>
          {STEPS.map((s, i) => (
            <li key={s.title} style={{ position: 'relative', display: 'grid', gridTemplateColumns: '32px 1fr', gap: 'var(--space-5)', alignItems: 'start' }}>
              <span
                style={{
                  position: 'relative',
                  zIndex: 'var(--z-raised)',
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
