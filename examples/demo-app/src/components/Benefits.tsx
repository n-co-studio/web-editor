/**
 * Benefits — a quick, scannable visual overview of why to use the editor. Four
 * monochrome outline-icon tiles in a responsive grid. Flat, sharp, no shadows.
 */

type Benefit = { title: string; body: string; icon: JSX.Element };

const BENEFITS: Benefit[] = [
  {
    title: 'Maps to your source',
    body: 'Edits on the rendered page map straight back to the source file and line — not throwaway tweaks.',
    icon: (
      <>
        <rect x="3" y="4" width="9" height="7" fill="none" stroke="currentColor" strokeWidth="1.6" />
        <path d="M12 14h4a2 2 0 002-2" fill="none" stroke="currentColor" strokeWidth="1.6" />
        <path d="M16 9l3 3-3 3M21 9l-3 3 3 3" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" transform="translate(0 4)" />
      </>
    ),
  },
  {
    title: 'Any agent, over MCP',
    body: 'AI-agnostic: send structured diffs to any LLM connected over MCP — Claude or otherwise.',
    icon: (
      <>
        <circle cx="12" cy="12" r="3" fill="none" stroke="currentColor" strokeWidth="1.6" />
        <circle cx="5" cy="5" r="2" fill="none" stroke="currentColor" strokeWidth="1.6" />
        <circle cx="19" cy="5" r="2" fill="none" stroke="currentColor" strokeWidth="1.6" />
        <circle cx="12" cy="21" r="2" fill="none" stroke="currentColor" strokeWidth="1.6" />
        <path d="M9.7 9.9L6.3 6.5M14.3 9.9l3.4-3.4M12 15v4" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
      </>
    ),
  },
  {
    title: 'A full design toolkit',
    body: 'Spacing, size, type, color, layout, reorder, media — a complete visual editing suite, on the page.',
    icon: (
      <>
        <path d="M4 7h16M4 12h16M4 17h16" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
        <circle cx="15" cy="7" r="2.2" fill="var(--color-bg)" stroke="currentColor" strokeWidth="1.6" />
        <circle cx="9" cy="12" r="2.2" fill="var(--color-bg)" stroke="currentColor" strokeWidth="1.6" />
        <circle cx="17" cy="17" r="2.2" fill="var(--color-bg)" stroke="currentColor" strokeWidth="1.6" />
      </>
    ),
  },
  {
    title: 'Knows your design system',
    body: 'Automatically pulls your project’s tokens and design system into the editing controls.',
    icon: (
      <>
        <rect x="4" y="4" width="6" height="6" fill="none" stroke="currentColor" strokeWidth="1.6" />
        <rect x="14" y="4" width="6" height="6" fill="currentColor" />
        <rect x="4" y="14" width="6" height="6" fill="currentColor" />
        <rect x="14" y="14" width="6" height="6" fill="none" stroke="currentColor" strokeWidth="1.6" />
      </>
    ),
  },
];

export default function Benefits() {
  return (
    <section style={{ marginBottom: 'var(--space-20)' }}>
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))',
          gap: 'var(--space-5)',
        }}
      >
        {BENEFITS.map((b) => (
          <article
            key={b.title}
            className="nco-card"
            style={{
              padding: 'var(--space-6)',
              display: 'flex',
              flexDirection: 'column',
              gap: 'var(--space-4)',
              background: 'var(--color-bg)',
            }}
          >
            <span style={{ color: 'var(--color-ink)' }}>
              <svg width="26" height="26" viewBox="0 0 24 24" aria-hidden="true" style={{ display: 'block' }}>
                {b.icon}
              </svg>
            </span>
            <h3 style={{ fontFamily: 'var(--font-sans)', fontWeight: 'var(--fw-regular)', fontSize: 'var(--text-h3)', color: 'var(--color-ink)' }}>
              {b.title}
            </h3>
            <p style={{ fontSize: 'var(--text-body-sm)', color: 'var(--color-secondary)' }}>{b.body}</p>
          </article>
        ))}
      </div>
    </section>
  );
}
