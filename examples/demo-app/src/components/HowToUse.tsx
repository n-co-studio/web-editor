/**
 * How to use — the editing loop as a numbered stepper, matching SetupGuide's
 * badge + hairline-connector pattern. Text only; rendered as a tab inside
 * GuideTabs.
 */

import type { ReactNode } from 'react';
import CopyPromptButton from './CopyPromptButton';
import Stepper, { stepBodyStyle } from './Stepper';

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

/**
 * The watch loop handed to the agent in step 1.
 *
 * Written as a standing instruction rather than a task. The earlier version
 * ended "re-check the queue before you go idle", which an agent can satisfy by
 * checking once and stopping — and then the next batch sits in the queue
 * unnoticed while the designer keeps editing, which looks like the tool is
 * broken. This version says to return to watching and makes idle mean waiting
 * for the next batch, not finishing.
 *
 * It also names the stop condition. Without one, "keep going" invites an agent
 * to burn tokens spinning; being told that waiting is the correct state, and
 * that only the user ends it, is what makes idling safe.
 */
const WATCH_PROMPT = `Watch editor-queue-status.yaml and wait for pending_count
to go above zero.

When a batch lands: read it with get_pending_visual_changes,
apply each diff to the source file it names, then call
acknowledge_visual_change on each one.

Then check the queue again. If another batch has arrived,
repeat immediately. If not, go back to watching and stay
there — waiting is the correct state, not a reason to stop.

Keep this loop running until I tell you otherwise. Do not end
the task because the queue is empty.`;

const STEPS: Step[] = [
  {
    title: 'Put your agent on watch',
    body: (
      <>
        <p style={stepBodyStyle}>
          Start an agent session in the project first — it launches the bridge, so nothing can reach
          your code until one is running. Then hand it the loop:
        </p>
        <Code>{WATCH_PROMPT}</Code>
        <div style={{ marginTop: 'var(--space-4)' }}>
          <CopyPromptButton text={WATCH_PROMPT} />
        </div>
        <p style={{ ...stepBodyStyle, marginTop: 'var(--space-4)' }}>
          Agents that read the server's own instructions already work this way; the prompt makes it
          explicit for those that don't.
        </p>
      </>
    ),
  },
  {
    title: 'Activate the editor',
    body: (
      <>
        <p style={stepBodyStyle}>
          On your localhost page, click the pinned icon and click <strong>Extension</strong> in the popup to
          toggle it <strong>On</strong>. The editor toolbar appears — drag the grip to move it, collapse it to
          browse the page normally, press <kbd style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--text-caption)', border: '1px solid var(--color-border)', padding: '0 4px' }}>ESC</kbd> to exit.
        </p>
        <figure style={{ margin: 'var(--space-4) 0 0' }}>
          <img
            src={`${import.meta.env.BASE_URL}images/web-editor-example-switch-on.png`}
            alt="The extension popup before and after: Extension toggled from Off to On, and the toolbar icon turning from grey to green"
            width={958}
            height={576}
            style={{
              display: 'block',
              width: '100%',
              height: 'auto',
              borderRadius: 'var(--radius-sm, 4px)',
            }}
          />
        </figure>
      </>
    ),
  },
  {
    title: 'Select and edit elements',
    body: (
      <>
        <p style={stepBodyStyle}>
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
            fontFamily: 'var(--font-sans)',
            fontWeight: 'var(--fw-regular)',
            fontSize: '1.125rem',
            lineHeight: 1.7,
            letterSpacing: '0.02em',
            color: 'var(--color-ink)',
          }}
        >
          <li>
            <strong style={{ color: 'var(--color-ink)' }}>
              Edit with your design system.
            </strong>{' '}
            Adjust spacing, size, type, colour and layout. The editor reads the design tokens from
            your code and snaps edits to them, so changes stay on-system.
          </li>
          <li>
            <strong style={{ color: 'var(--color-ink)' }}>
              Rearrange by dragging.
            </strong>{' '}
            Reorder elements directly. The editor understands CSS grid and flexbox auto-layout, so
            the page stays responsive and the generated code stays clean.
          </li>
          <li>
            <strong style={{ color: 'var(--color-ink)' }}>
              Change text, images and structure.
            </strong>{' '}
            Edit copy in place, swap images, insert or remove elements — not just styling.
          </li>
        </ul>
      </>
    ),
  },
  {
    title: 'Review and send',
    body: (
      <p style={stepBodyStyle}>
        Every edit queues as you make it, with before-and-after values — nothing to add by hand.
        Open the queue to review and prune the batch, then send it. Exploratory edits collapse to
        their latest state, and the agent watching your dev environment writes the real code
        changes.
      </p>
    ),
  },
];

export default function HowToUse() {
  return (
    <div>
      <p style={{ ...stepBodyStyle, maxWidth: 'var(--measure)', marginBottom: 'var(--space-10)' }}>
        The editing loop, end to end — from activating the editor to the agent writing code.
      </p>

        <Stepper steps={STEPS} />
    </div>
  );
}
