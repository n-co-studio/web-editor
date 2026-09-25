/**
 * FAQ — grounded in how the editor actually works: build-time element tags,
 * token-restricted editing, the review queue, and the change-compression
 * layer. Hairline cards on white; sharp, flat, no shadows.
 */

type Qa = { q: string; a: string };

const QA: Qa[] = [
  {
    q: 'Who is it for?',
    a: 'AI-native designers making precise frontend changes without touching code. You edit on the rendered page through a drag-and-drop design interface; the edits hand off to the dev agent watching your local environment.',
  },
  {
    q: 'How do edits land accurately in code?',
    a: 'A dev plugin inserts tags at build time on every frontend element and maps each one to its corresponding component in code. The MCP bridge carries your edit to exactly that source location, so changes land where they should and code integrity is maintained.',
  },
  {
    q: 'Does rearranging the page produce messy code?',
    a: 'No — the editor is built around auto-layout in CSS grid and flexbox with drag-to-reorder. Elements are easy to rearrange on the page, and the generated code stays clean and responsive.',
  },
  {
    q: 'Does it respect our design system?',
    a: 'The editor pulls design-system tokens from your code and surfaces them in the appropriate places across the interface. Edits are restricted to token values only, so every change stays consistent with the system.',
  },
  {
    q: 'Can I review changes before the agent sees them?',
    a: 'Yes. Edits collect in a review queue with before-and-after values — a surface to review, prune, and submit change request batches to agents watching in the local dev environment.',
  },
  {
    q: 'What if I explore — edit the same thing ten times?',
    a: 'A compression layer based on IDs and timestamps collapses changes to their latest state before handoff. Designers explore freely; agents implement the intended end result, not the journey.',
  },
  {
    q: 'Is it production-ready?',
    a: 'It began as a process tool for a portfolio and grew into a feature-rich, production-ready product — now published on the Chrome Extension Store. Everything runs locally; no data leaves your machine.',
  },
];

export default function Faq() {
  return (
    <section id="faq" style={{ marginBottom: 'var(--space-20)', scrollMarginTop: 'var(--space-12)' }}>
      <h2 style={{ fontFamily: 'var(--font-serif)', fontWeight: 'var(--fw-light)', fontSize: 'var(--text-h2)', letterSpacing: 'var(--tracking-tight)' }}>
        FAQ
      </h2>

      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))',
          gap: 'var(--space-5)',
          marginTop: 'var(--space-10)',
        }}
      >
        {QA.map(({ q, a }) => (
          <article key={q} className="nco-card" style={{ padding: 'var(--space-6)' }}>
            <h3 style={{ fontFamily: 'var(--font-sans)', fontWeight: 'var(--fw-regular)', fontSize: 'var(--text-h3)', color: 'var(--color-ink)' }}>
              {q}
            </h3>
            <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)', marginTop: 'var(--space-3)' }}>
              {a}
            </p>
          </article>
        ))}
      </div>
    </section>
  );
}
