/**
 * A button that copies a prompt to the clipboard.
 *
 * Shared because both guide tabs hand the reader a prompt to paste: the setup
 * tab's MCP config prompt and the how-to tab's watch loop. A prompt the reader
 * has to select by hand is a prompt they will mistype or truncate.
 */

import { useEffect, useRef, useState } from 'react';

function CopyPromptButton({ text }: { text: string }) {
  const [state, setState] = useState<'idle' | 'copied' | 'failed'>('idle');
  // GuideTabs unmounts this whole step when you switch tabs, so a pending
  // reset must be cancellable — otherwise it fires against a dead component.
  const resetTimer = useRef<number | undefined>(undefined);

  useEffect(() => () => window.clearTimeout(resetTimer.current), []);

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setState('copied');
    } catch {
      // Clipboard access can be refused (permission, insecure context).
      // Say so rather than showing a success that did not happen.
      setState('failed');
    }
    window.clearTimeout(resetTimer.current);
    resetTimer.current = window.setTimeout(() => setState('idle'), 2000);
  }

  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-3)' }}>
      <button
        type="button"
        onClick={copy}
        style={{
          fontFamily: 'var(--font-sans)',
          fontSize: 'var(--text-body-sm)',
          fontWeight: 'var(--fw-regular)',
          color: 'var(--color-on-ink)',
          background: 'var(--color-ink)',
          border: '1px solid var(--color-ink)',
          padding: 'var(--space-2) var(--space-4)',
          cursor: 'pointer',
        }}
      >
        Copy prompt
      </button>
      {/* Announced, not merely shown — the button's own label does not change. */}
      <span
        role="status"
        aria-live="polite"
        style={{ fontSize: 'var(--text-caption)', color: 'var(--color-secondary)' }}
      >
        {state === 'copied'
          ? 'Copied'
          : state === 'failed'
            ? // Names the prompt rather than pointing at it, so reordering the
              // step cannot make this message wrong. It once said "above".
              'Copy failed — select the prompt text and copy it manually'
            : ''}
      </span>
    </div>
  );
}

export default CopyPromptButton;
