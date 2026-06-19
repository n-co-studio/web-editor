/**
 * Motion benefits — four product benefits as bordered panels with an accent
 * index rule, revealing on scroll. Same content as the classic page, restyled.
 */

type Benefit = { n: string; title: string; body: string };

const BENEFITS: Benefit[] = [
  { n: '01', title: 'Maps to your source', body: 'Edits on the rendered page map straight back to the source file and line — not throwaway tweaks.' },
  { n: '02', title: 'Any agent, over MCP', body: 'AI-agnostic: built on the open MCP protocol, so it pairs with any MCP-compatible coding agent.' },
  { n: '03', title: 'A full design toolkit', body: 'Spacing, size, type, color, layout, reorder, media — a complete visual editing suite, on the page.' },
  { n: '04', title: 'Knows your design system', body: 'Automatically pulls your project’s tokens and design system into the editing controls.' },
];

export default function MotionBenefits() {
  return (
    <section style={{ padding: 'var(--space-16) 0', borderBottom: '1px solid var(--m-line)' }}>
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))',
          gap: 'var(--space-6)',
        }}
      >
        {BENEFITS.map((b) => (
          <article key={b.n} className="m-reveal" style={{ borderTop: '2px solid var(--m-accent)', paddingTop: 'var(--space-4)' }}>
            <span style={{ fontFamily: 'var(--m-mono)', fontSize: 12, color: 'var(--m-accent)' }}>{b.n}</span>
            <h3 style={{ fontFamily: 'var(--m-sans)', fontWeight: 400, fontSize: '1.25rem', color: 'var(--m-fg)', margin: 'var(--space-3) 0 var(--space-2)' }}>
              {b.title}
            </h3>
            <p style={{ fontSize: '0.9375rem', color: 'var(--m-fg-dim)', lineHeight: 1.6 }}>{b.body}</p>
          </article>
        ))}
      </div>
    </section>
  );
}
