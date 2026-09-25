/**
 * StepsRow — the three beats of using the editor as bare text columns
 * on white — no card chrome: design on the page, send mapped edits over MCP, the
 * agent writes the code. Sans two-digit indices against serif titles — the
 * page's heading idiom, so the row reads as headings rather than as labels.
 * Sharp, flat.
 */

type Block = { title: string; body: string };

const BLOCKS: Block[] = [
  {
    title: 'Explore and design',
    body: 'Work directly on the rendered page — drag to reorder, adjust spacing, type, and color, with edits snapping to your design-system tokens. Explore freely; only the end state matters.',
  },
  {
    title: 'Send source code mapped edits over MCP',
    body: 'Build-time tags map every element to its component in code. Edits collect in a review queue with before-and-after values — prune the batch, then send it over the MCP bridge.',
  },
  {
    title: 'Agent implements changes in the code',
    body: 'The agent watching your local dev environment receives the collapsed change requests and writes the real code — clean, responsive, and exactly where the tags point.',
  },
];

export default function StepsRow() {
  return (
    <section style={{ marginBottom: 'var(--space-20)' }}>
      <div className="nco-steps-grid">
        {BLOCKS.map((b, i) => (
          <article key={b.title}>
            <span
              style={{
                fontFamily: 'var(--font-sans)',
                fontWeight: 'var(--fw-light)',
                fontSize: 'var(--text-h3)',
                color: 'var(--color-secondary)',
                lineHeight: 1,
              }}
            >
              {String(i + 1).padStart(2, '0')}
            </span>
            <h3
              style={{
                fontFamily: 'var(--font-serif)',
                fontWeight: 'var(--fw-light)',
                fontSize: 'var(--text-h2)',
                lineHeight: 'var(--leading-tight)',
                letterSpacing: 'var(--tracking-tight)',
                color: 'var(--color-ink)',
                marginTop: 'var(--space-3)',
              }}
            >
              {b.title}
            </h3>
            <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)', marginTop: 'var(--space-3)' }}>
              {b.body}
            </p>
          </article>
        ))}
      </div>
    </section>
  );
}
