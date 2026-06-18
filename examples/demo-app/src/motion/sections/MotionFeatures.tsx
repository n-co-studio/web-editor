/**
 * Motion features — showcases the three generated animated diagrams: the MCP
 * flow (full-width), token snapping, and the edit-mode grid. Reveal on scroll.
 */

import type { ReactNode } from 'react';
import McpFlow from '../graphics/McpFlow';
import TokenSnap from '../graphics/TokenSnap';
import EditModes from '../graphics/EditModes';

function Panel({ children, ratio = '16 / 6' }: { children: ReactNode; ratio?: string }) {
  return (
    <div className="m-reveal" style={{ border: '1px solid var(--m-line)', background: 'var(--m-bg-2)', aspectRatio: ratio, padding: 'var(--space-4)' }}>
      {children}
    </div>
  );
}

function Eyebrow({ children }: { children: string }) {
  return (
    <span style={{ fontFamily: 'var(--m-mono)', fontSize: 12, letterSpacing: '0.16em', textTransform: 'uppercase', color: 'var(--m-accent)' }}>
      {children}
    </span>
  );
}

function Heading({ children }: { children: string }) {
  return (
    <h2 style={{ fontFamily: 'var(--m-serif)', fontWeight: 200, fontSize: '2rem', letterSpacing: '-0.01em', color: 'var(--m-fg)', margin: 'var(--space-3) 0 var(--space-4)' }}>
      {children}
    </h2>
  );
}

function Body({ children }: { children: ReactNode }) {
  return <p style={{ fontSize: '1rem', color: 'var(--m-fg-dim)', lineHeight: 1.65, maxWidth: '44ch' }}>{children}</p>;
}

export default function MotionFeatures() {
  return (
    <section style={{ padding: 'var(--space-16) 0', borderBottom: '1px solid var(--m-line)', display: 'flex', flexDirection: 'column', gap: 'var(--space-20)' }}>
      {/* MCP flow — full width */}
      <div>
        <div className="m-reveal" style={{ maxWidth: '60ch', marginBottom: 'var(--space-8)' }}>
          <Eyebrow>From page to code</Eyebrow>
          <Heading>A diff travels the wire</Heading>
          <Body>
            The extension talks to a local MCP server over a WebSocket; the server speaks the open MCP
            protocol to your coding agent. Your edits leave the browser as one structured diff — nothing
            else does.
          </Body>
        </div>
        <Panel ratio="19 / 6"><McpFlow /></Panel>
      </div>

      {/* Token snap — 2-col */}
      <div className="nco-motion-row" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1fr) minmax(0,1.1fr)', gap: 'var(--space-12)', alignItems: 'center' }}>
        <div className="m-reveal">
          <Eyebrow>On-system by default</Eyebrow>
          <Heading>Snaps to your tokens</Heading>
          <Body>
            The server auto-discovers your design tokens — Tailwind config, a design-system file, CSS
            custom properties — and every adjustment snaps to the nearest one. Edits stay on the system.
          </Body>
        </div>
        <Panel ratio="2 / 1"><TokenSnap /></Panel>
      </div>

      {/* Edit modes — 2-col reversed */}
      <div className="nco-motion-row" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1.1fr) minmax(0,1fr)', gap: 'var(--space-12)', alignItems: 'center' }}>
        <Panel ratio="1 / 1"><EditModes /></Panel>
        <div className="m-reveal">
          <Eyebrow>One surface, nine tools</Eyebrow>
          <Heading>Every mode, on the page</Heading>
          <Body>
            Select, spacing, size, typography, colors, position, reorder, text, media. Each mode surfaces
            drag handles and quick-edit controls for that one dimension — no DevTools spelunking.
          </Body>
        </div>
      </div>
    </section>
  );
}
