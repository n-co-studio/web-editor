/**
 * Motion walkthrough — the editor's six built-in tour steps, as a dark numbered
 * sequence revealing on scroll. Same content as the classic page.
 */

type Step = { title: string; body: string };

const STEPS: Step[] = [
  { title: 'The editor toolbar', body: 'Your command center. Drag the grip to move it, collapse it with the arrow, or pick a tool to enter an edit mode.' },
  { title: 'Toggle the toolbar', body: 'While the editor is active it intercepts hovers and clicks. Collapse the toolbar to use the page normally, then expand it to resume editing.' },
  { title: 'Inspect & edit', body: 'Open the DevTools panel for a DOM inspector with matched CSS rules, editable properties, and a console — for when you need to go deep.' },
  { title: 'Edit modes', body: 'Switch between Select, Spacing, Size, Typography, Colors, Position, Reorder, Text and Media — each surfaces handles and controls for that dimension.' },
  { title: 'Review & submit', body: 'Batch your edits in the review panel, then submit a single structured diff to your AI coding agent through the local MCP server.' },
  { title: 'Have a go', body: 'That’s the gist. With the editor active, tweak anything — refresh to reset, and press ESC to exit.' },
];

export default function MotionWalkthrough() {
  return (
    <section id="walkthrough" style={{ padding: 'var(--space-16) 0', borderBottom: '1px solid var(--m-line)', scrollMarginTop: 'var(--space-12)' }}>
      <div className="m-reveal" style={{ marginBottom: 'var(--space-12)', maxWidth: '60ch' }}>
        <span style={{ fontFamily: 'var(--m-mono)', fontSize: 12, letterSpacing: '0.16em', textTransform: 'uppercase', color: 'var(--m-accent)' }}>
          Using the editor
        </span>
        <h2 style={{ fontFamily: 'var(--m-serif)', fontWeight: 200, fontSize: '2.4rem', letterSpacing: '-0.01em', color: 'var(--m-fg)', marginTop: 'var(--space-3)' }}>
          Six beats, start to finish
        </h2>
      </div>

      <ol style={{ listStyle: 'none', display: 'flex', flexDirection: 'column' }}>
        {STEPS.map((s, i) => (
          <li
            key={s.title}
            className="m-reveal"
            style={{
              display: 'grid',
              gridTemplateColumns: '72px 1fr',
              gap: 'var(--space-6)',
              padding: 'var(--space-8) 0',
              borderTop: '1px solid var(--m-line)',
              alignItems: 'baseline',
            }}
          >
            <span style={{ fontFamily: 'var(--m-serif)', fontWeight: 100, fontSize: '2.4rem', color: 'var(--m-accent)', lineHeight: 1 }}>
              {String(i + 1).padStart(2, '0')}
            </span>
            <div style={{ maxWidth: '60ch' }}>
              <h3 style={{ fontFamily: 'var(--m-sans)', fontWeight: 400, fontSize: '1.375rem', color: 'var(--m-fg)' }}>{s.title}</h3>
              <p style={{ fontSize: '1rem', color: 'var(--m-fg-dim)', marginTop: 'var(--space-3)', lineHeight: 1.65 }}>{s.body}</p>
            </div>
          </li>
        ))}
      </ol>
    </section>
  );
}
