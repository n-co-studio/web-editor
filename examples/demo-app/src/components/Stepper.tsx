/**
 * The numbered stepper shared by the Set it up and How to use tabs, and the
 * type treatment its steps use.
 *
 * Shared because both tabs render the same pattern and the Figma design
 * (node 52:3948/52:3950) specifies it once. Two copies drift: the previous
 * pair had already diverged into different badge sizes and connector weights.
 *
 * From the design:
 *   - badge: a 44px #2F2F2F circle, numeral at 32px in the display face, mint
 *   - connector: a 7px #2F2F2F rule, centred on the badge
 *   - title: 22px display, uppercase, -1.32px tracking, 0.9 line-height
 *   - body: 18px body face, 1.7 line-height, 0.36px tracking
 *
 * The badge and connector arrive from Figma as SVG assets, but both are plain
 * primitives — `<circle r="22" fill="#2F2F2F">` and a single stroked path — so
 * they are drawn in CSS here. Shipping two files to render a circle and a line
 * would add fetches and make the numeral harder to centre.
 */

import type { CSSProperties, ReactNode } from 'react';

const BADGE = 44;
/** Connector stroke, from the design's 7px line. */
const RULE = 7;

/** Step heading — Figma 52:3949. */
export const stepTitleStyle: CSSProperties = {
  margin: 0,
  fontFamily: 'var(--font-display)',
  fontWeight: 'var(--fw-bold)',
  fontSize: '1.375rem',
  lineHeight: 0.9,
  letterSpacing: '-0.06em',
  textTransform: 'uppercase',
  color: 'var(--color-ink)',
};

/** Step body copy — Figma 53:3977. */
export const stepBodyStyle: CSSProperties = {
  fontFamily: 'var(--font-sans)',
  fontWeight: 'var(--fw-regular)',
  fontSize: '1.125rem',
  lineHeight: 1.7,
  letterSpacing: '0.02em',
  color: 'var(--color-ink)',
};

export type StepItem = {
  title: string;
  body: ReactNode;
  /** Renders a tick on a mint badge instead of a numeral. */
  complete?: boolean;
};

export default function Stepper({ steps }: { steps: StepItem[] }) {
  return (
    <ol
      style={{
        listStyle: 'none',
        margin: 0,
        padding: 0,
        display: 'flex',
        flexDirection: 'column',
        gap: 'var(--space-8)',
      }}
    >
      {steps.map((s, i) => {
        const isLast = i === steps.length - 1;
        return (
          <li
            key={s.title}
            style={{
              position: 'relative',
              display: 'grid',
              gridTemplateColumns: `${BADGE}px 1fr`,
              gap: 'var(--space-5)',
              alignItems: 'start',
            }}
          >
            {/* Connector, drawn per step rather than as one rule behind the
                list: the last step must not trail a line below it, and a
                single absolutely-positioned span cannot know where the last
                badge is. It overshoots the list item by the <ol> gap so the
                rule stays unbroken between steps. */}
            {!isLast && (
              <span
                aria-hidden="true"
                style={{
                  position: 'absolute',
                  left: BADGE / 2 - RULE / 2,
                  top: BADGE,
                  bottom: 'calc(-1 * var(--space-8))',
                  width: RULE,
                  background: 'var(--color-display-ink)',
                  zIndex: 'var(--z-base)',
                }}
              />
            )}

            <span
              // role="img" is required for the label to be announced: an
              // aria-label on a bare span has no role to attach to, and most
              // screen readers drop it.
              role={s.complete ? 'img' : undefined}
              aria-hidden={s.complete ? undefined : true}
              aria-label={s.complete ? 'Setup complete' : undefined}
              style={{
                position: 'relative',
                zIndex: 'var(--z-raised)',
                width: BADGE,
                height: BADGE,
                borderRadius: 'var(--radius-full)',
                // The finished step is the other badges inverted: mint fill,
                // dark mark — where every numbered step is a dark fill with a
                // mint numeral. Same two colours, swapped, so it reads as the
                // end of the same set rather than a new element. Both
                // directions land at 11.03:1.
                background: s.complete
                  ? 'var(--color-accent-mint)'
                  : 'var(--color-display-ink)',
                color: s.complete
                  ? 'var(--color-display-ink)'
                  : 'var(--color-accent-mint)',
                display: 'inline-flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontFamily: 'var(--font-display)',
                fontWeight: 'var(--fw-bold)',
                fontSize: s.complete ? '1.25rem' : '2rem',
                lineHeight: 1,
              }}
            >
              {s.complete ? '✓' : i + 1}
            </span>

            <div
              style={{
                display: 'flex',
                flexDirection: 'column',
                gap: 'var(--space-5)',
                paddingTop: 'var(--space-2)',
                minWidth: 0,
                maxWidth: '785px',
              }}
            >
              <h3 style={stepTitleStyle}>{s.title}</h3>
              {s.body}
            </div>
          </li>
        );
      })}
    </ol>
  );
}
