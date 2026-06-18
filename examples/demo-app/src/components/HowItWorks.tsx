/**
 * The loop — point → adjust → send, in three columns divided by hairlines.
 * Flat, sharp, serif numerals. Accurate to how the tool actually works.
 */

type Step = { n: string; title: string; body: string };

const STEPS: Step[] = [
  {
    n: '01',
    title: 'Point',
    body: 'Activate the overlay and select any element. It reads the box model, matched CSS rules, and (with the dev plugin) the source file.',
  },
  {
    n: '02',
    title: 'Adjust',
    body: 'Switch edit modes and tweak spacing, size, type, colors, or position right on the page. Values snap to the design tokens in your project.',
  },
  {
    n: '03',
    title: 'Send',
    body: 'Batch edits in the review panel and submit a structured diff to Claude Code through the local MCP server. It writes the real code.',
  },
];

export default function HowItWorks() {
  return (
    <section id="loop" style={{ marginBottom: 'var(--space-20)', scrollMarginTop: 'var(--space-12)' }}>
      <h2 style={{ fontFamily: 'var(--font-serif)', fontWeight: 'var(--fw-light)', fontSize: 'var(--text-h2)', letterSpacing: 'var(--tracking-tight)', marginBottom: 'var(--space-8)' }}>
        The loop
      </h2>

      <ol
        style={{
          listStyle: 'none',
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))',
          borderTop: '1px solid var(--color-divider)',
        }}
      >
        {STEPS.map((s, i) => (
          <li
            key={s.n}
            style={{
              padding: 'var(--space-6) var(--space-6) var(--space-6) 0',
              borderLeft: i === 0 ? 'none' : '1px solid var(--color-divider)',
              paddingLeft: i === 0 ? 0 : 'var(--space-6)',
              display: 'flex',
              flexDirection: 'column',
              gap: 'var(--space-3)',
            }}
          >
            <span style={{ fontFamily: 'var(--font-serif)', fontWeight: 'var(--fw-thin)', fontSize: 'var(--text-h2)', color: 'var(--color-secondary)', lineHeight: 1 }}>
              {s.n}
            </span>
            <h3 style={{ fontFamily: 'var(--font-sans)', fontWeight: 'var(--fw-regular)', fontSize: 'var(--text-h3)', color: 'var(--color-ink)' }}>
              {s.title}
            </h3>
            <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>{s.body}</p>
          </li>
        ))}
      </ol>
    </section>
  );
}
