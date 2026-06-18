/**
 * Walkthrough — the guide's core, built from the editor's own built-in tour
 * (markpreston EditorWalkthrough, 6 steps). Alternating image-left / text-right
 * rows. Screenshots don't exist yet, so each row renders a labeled placeholder
 * frame — drop a real file at the noted path and swap the placeholder for <img>.
 */

import type { ReactNode } from 'react';

const EDIT_MODES = [
  'Select', 'Spacing', 'Size', 'Typography',
  'Colors', 'Position', 'Reorder', 'Text', 'Media',
] as const;

function EditModesGrid() {
  return (
    <ul
      style={{
        listStyle: 'none',
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fill, minmax(110px, 1fr))',
        gap: 0,
        border: '1px solid var(--color-border)',
        borderBottom: 'none',
        borderRight: 'none',
        marginTop: 'var(--space-4)',
      }}
    >
      {EDIT_MODES.map((m) => (
        <li
          key={m}
          style={{
            padding: 'var(--space-3) var(--space-4)',
            borderRight: '1px solid var(--color-border)',
            borderBottom: '1px solid var(--color-border)',
            fontSize: 'var(--text-body-sm)',
            color: 'var(--color-ink)',
          }}
        >
          {m}
        </li>
      ))}
    </ul>
  );
}

/** Placeholder screenshot frame. Swap for <img src={shot} alt={...} /> when the asset exists. */
function StepFigure({ index, shot }: { index: number; shot: string }) {
  return (
    <figure
      className="nco-step-figure"
      style={{
        aspectRatio: '16 / 10',
        border: '1px solid var(--color-divider)',
        background: 'repeating-linear-gradient(135deg, var(--color-bg), var(--color-bg) 11px, #fafafa 11px, #fafafa 22px)',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 'var(--space-2)',
        minWidth: 0,
      }}
    >
      <span
        aria-hidden="true"
        style={{
          fontFamily: 'var(--font-serif)',
          fontWeight: 'var(--fw-thin)',
          fontSize: 'var(--text-h2)',
          color: 'var(--color-divider)',
          lineHeight: 1,
        }}
      >
        {String(index + 1).padStart(2, '0')}
      </span>
      <figcaption
        style={{
          fontFamily: 'var(--font-mono)',
          fontSize: 'var(--text-caption)',
          color: 'var(--color-secondary)',
          background: 'var(--color-bg)',
          padding: '2px var(--space-2)',
          border: '1px solid var(--color-border)',
        }}
      >
        screenshot · {shot}
      </figcaption>
    </figure>
  );
}

type Step = { title: string; shot: string; body: ReactNode };

const STEPS: Step[] = [
  {
    title: 'The editor toolbar',
    shot: 'toolbar.png',
    body: (
      <>Your command center. Drag the grip to move it, collapse it with the arrow, or pick a tool to
      enter an edit mode.</>
    ),
  },
  {
    title: 'Toggle the toolbar',
    shot: 'toolbar-collapsed.png',
    body: (
      <>While the editor is active it intercepts hovers and clicks. Collapse the toolbar to scroll and
      click the page normally, then expand it again to resume editing.</>
    ),
  },
  {
    title: 'Inspect & edit',
    shot: 'devtools-panel.png',
    body: (
      <>Open the DevTools panel for a DOM inspector with matched CSS rules, editable properties, and a
      console — for when you need to go deep.</>
    ),
  },
  {
    title: 'Edit modes',
    shot: 'edit-modes.png',
    body: (
      <>
        Switch between modes — each surfaces drag handles and quick-edit controls for that one
        dimension:
        <EditModesGrid />
      </>
    ),
  },
  {
    title: 'Review & submit',
    shot: 'review-panel.png',
    body: (
      <>Batch your edits in the review panel, then submit them as a single structured diff to Claude
      Code through the local MCP server, which writes the real code changes.</>
    ),
  },
  {
    title: 'Have a go',
    shot: 'selection.png',
    body: (
      <>That’s the gist. With the editor active, click around and tweak anything — refresh the page to
      reset, and press <kbd style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--text-caption)', border: '1px solid var(--color-border)', padding: '0 4px' }}>ESC</kbd> to exit.</>
    ),
  },
];

export default function Walkthrough() {
  return (
    <section id="walkthrough" style={{ marginBottom: 'var(--space-20)', scrollMarginTop: 'var(--space-12)' }}>
      <h2 style={{ fontFamily: 'var(--font-serif)', fontWeight: 'var(--fw-light)', fontSize: 'var(--text-h2)', letterSpacing: 'var(--tracking-tight)' }}>
        Using the editor
      </h2>
      <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)', maxWidth: 'var(--measure)', marginTop: 'var(--space-3)', marginBottom: 'var(--space-16)' }}>
        The same six beats as the editor’s built-in walkthrough — what each part of the interface does.
      </p>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-20)' }}>
        {STEPS.map((s, i) => (
          <div key={s.title} className={`nco-step-row${i % 2 === 1 ? ' nco-step-row--reverse' : ''}`}>
            <StepFigure index={i} shot={s.shot} />
            <div className="nco-step-text" style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-3)', minWidth: 0 }}>
              <span style={{ fontFamily: 'var(--font-serif)', fontWeight: 'var(--fw-thin)', fontSize: 'var(--text-h3)', color: 'var(--color-secondary)', lineHeight: 1 }}>
                {String(i + 1).padStart(2, '0')}
              </span>
              <h3 style={{ fontFamily: 'var(--font-sans)', fontWeight: 'var(--fw-regular)', fontSize: 'var(--text-h3)', color: 'var(--color-ink)' }}>
                {s.title}
              </h3>
              <div style={{ fontSize: 'var(--text-body)', color: 'var(--color-secondary)' }}>{s.body}</div>
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}
