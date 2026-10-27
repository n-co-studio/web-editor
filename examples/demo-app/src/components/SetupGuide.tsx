/**
 * Setup guide — a numbered vertical stepper. A hairline connector runs behind
 * ink step badges; code blocks are flat ink panels. Sharp corners, no shadows.
 */

import { useEffect, useRef, useState, type ReactNode } from 'react';
import CopyPromptButton from './CopyPromptButton';
import Stepper, { stepBodyStyle } from './Stepper';
import { CHROME_STORE_URL } from '../storeUrl';


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

// ---------------------------------------------------------------------------
// Step 2 — agent connection
// ---------------------------------------------------------------------------

type Provider = {
  /** Shown on the selector. */
  name: string;
  /** Where this agent reads MCP servers from. */
  configPath: string;
  /** How the prompt should describe that location to the agent. */
  promptLocation: string;
};

/**
 * The MCP config is byte-identical for every agent — only the file it belongs
 * in differs. That difference is the whole point of the selector: an agent told
 * to write the wrong file leaves you with a config nothing reads.
 */
const PROVIDERS: Provider[] = [
  {
    name: 'Claude Code',
    configPath: '.mcp.json',
    promptLocation: '.mcp.json at the root of this project (create it if it does not exist)',
  },
  {
    name: 'Cursor',
    configPath: '.cursor/mcp.json',
    promptLocation: '.cursor/mcp.json in this project (create the folder and file if needed)',
  },
  {
    name: 'Windsurf',
    configPath: '~/.codeium/windsurf/mcp_config.json',
    // Unlike the others this file is outside the project and applies to every
    // Windsurf workspace. Say so in the prompt: agents are often sandboxed to
    // the project directory and will need to ask before writing to $HOME.
    promptLocation:
      '~/.codeium/windsurf/mcp_config.json (create it if it does not exist). ' +
      'Note that this file lives outside this project and applies to all your ' +
      'Windsurf workspaces, so ask me first if you need permission to write there',
  },
  {
    name: 'Any MCP client',
    configPath: 'its own mcpServers config',
    promptLocation:
      'wherever this client reads its mcpServers config from — check its docs if you are unsure',
  },
];

function mcpPrompt(p: Provider): string {
  return `Set up the nco-web-editor MCP server for me.

Add this entry to ${p.promptLocation}, merging it into any
mcpServers block that is already there rather than replacing it:

  "nco-web-editor": {
    "command": "npx",
    "args": ["--yes", "@nco-studio/web-editor-mcp@^0"]
  }

Then tell me what you changed, and whether I need to restart you
for it to take effect.`;
}

/**
 * Step 2's body. Stateful, unlike the other steps: the agent you pick drives
 * both the config path named in the prose and the prompt below it, so you read
 * one correct instruction rather than picking your line out of a table of four.
 * The underline-tab idiom matches GuideTabs, the guide's own tab strip.
 */
function ConnectYourAgent() {
  const [provider, setProvider] = useState<Provider>(PROVIDERS[0]);
  const optionRefs = useRef<Array<HTMLButtonElement | null>>([]);

  /**
   * A radiogroup owes its users arrow keys: assistive tech announces "1 of 4"
   * and expects Left/Right/Up/Down to move the selection, wrapping at the ends.
   * Paired with the roving tabindex below, so Tab enters and leaves the group
   * once rather than stopping on all four options.
   */
  function onKeyDown(e: React.KeyboardEvent, index: number) {
    const delta =
      e.key === 'ArrowRight' || e.key === 'ArrowDown'
        ? 1
        : e.key === 'ArrowLeft' || e.key === 'ArrowUp'
          ? -1
          : 0;
    if (delta === 0) return;
    e.preventDefault();
    const next = (index + delta + PROVIDERS.length) % PROVIDERS.length;
    setProvider(PROVIDERS[next]);
    optionRefs.current[next]?.focus();
  }

  return (
    <>
      <p style={stepBodyStyle}>
        It’s a standard MCP server — the same config works with any MCP-compatible agent. Your agent
        launches it, and it also serves the extension over WebSocket.
      </p>

      {/* One block: picker, prompt, copy button.
          These are three parts of a single action, and they were reading as
          three unrelated things stacked up — a row of text links, a button,
          then a code sample. Sharing one surface makes the sequence legible,
          and the copy button sits under the text it copies rather than above
          it, where it referred to something the reader had not seen yet. */}
      <div
        style={{
          marginTop: 'var(--space-4)',
          border: '1px solid var(--color-border)',
          borderRadius: 'var(--radius-sm, 4px)',
          overflow: 'hidden',
        }}
      >
        {/* Instruction, as the block's own first section rather than a
            separate panel above it. As a bordered box of its own it read as
            disconnected from the thing it describes — the picker, prompt and
            copy button directly below. Sharing their surface and their divider
            makes it the head of one unit.

            It was once nested lower, beside the code, where it read as a
            caption on the sample. Sitting above the picker it heads the whole
            sequence instead.

            Colour is confined to the chip: a mint-on-ink label, set the way
            the step numerals are, so it belongs to the stepper it sits inside.
            The label is 13px against 18px body — an earlier pass set both at
            18px, where two faces at one size clashed rather than ranked. */}
        <div
          style={{
            padding: 'var(--space-4)',
            background: 'var(--color-surface)',
            borderBottom: '1px solid var(--color-border)',
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'flex-start',
            gap: 'var(--space-3)',
          }}
        >
          <span
            style={{
              background: 'var(--color-display-ink)',
              color: 'var(--color-accent-mint)',
              padding: '3px var(--space-3)',
              fontFamily: 'var(--font-display)',
              fontWeight: 'var(--fw-bold)',
              fontSize: '0.8125rem',
              lineHeight: 1.2,
              // Positive tracking, against the tight negative tracking the
              // display face carries at heading sizes: at 13px the letterforms
              // need opening up, and it separates a label from a heading.
              letterSpacing: '0.08em',
              textTransform: 'uppercase',
              whiteSpace: 'nowrap',
            }}
          >
            Easiest way
          </span>
          <p
            style={{
              margin: 0,
              fontFamily: 'var(--font-sans)',
              fontWeight: 'var(--fw-regular)',
              fontSize: '1.125rem',
              lineHeight: 1.5,
              letterSpacing: '0.02em',
              color: 'var(--color-ink)',
              maxWidth: '58ch',
            }}
          >
            Let {provider.name} set itself up. Pick your agent, then copy the prompt and
            paste it to your agent in the repo.
          </p>
        </div>
        <div
          style={{
            padding: 'var(--space-4)',
            background: 'var(--color-surface)',
            borderBottom: '1px solid var(--color-border)',
          }}
        >
        <div
          id="agent-picker-label"
          style={{
            fontFamily: 'var(--font-mono)',
            fontSize: 'var(--text-caption)',
            letterSpacing: '0.04em',
            textTransform: 'uppercase',
            color: 'var(--color-secondary)',
            marginBottom: 'var(--space-3)',
          }}
        >
          Choose your agent
        </div>
      <div
        role="radiogroup"
        aria-labelledby="agent-picker-label"
        style={{ display: 'flex', flexWrap: 'wrap', gap: 'var(--space-2)' }}
      >
        {PROVIDERS.map((p, i) => {
          const selected = p.name === provider.name;
          return (
            <button
              key={p.name}
              type="button"
              role="radio"
              aria-checked={selected}
              // Roving tabindex: only the checked option is a Tab stop.
              tabIndex={selected ? 0 : -1}
              ref={(el) => {
                optionRefs.current[i] = el;
              }}
              onClick={() => setProvider(p)}
              onKeyDown={(e) => onKeyDown(e, i)}
              style={{
                fontFamily: 'var(--font-sans)',
                fontSize: 'var(--text-body-sm)',
                fontWeight: 'var(--fw-book)',
                color: selected ? 'var(--color-on-ink)' : 'var(--color-ink)',
                background: selected ? 'var(--color-ink)' : 'var(--color-bg)',
                border: `1px solid ${selected ? 'var(--color-ink)' : 'var(--color-border)'}`,
                borderRadius: 'var(--radius-full, 999px)',
                padding: 'var(--space-2) var(--space-4)',
                cursor: 'pointer',
                transition: 'background 0.12s, color 0.12s, border-color 0.12s',
              }}
            >
              {p.name}
            </button>
          );
        })}
        </div>
        </div>

        <div style={{ padding: 'var(--space-4)' }}>
          <Code>{mcpPrompt(provider)}</Code>
          <div style={{ marginTop: 'var(--space-4)' }}>
            <CopyPromptButton text={mcpPrompt(provider)} />
          </div>
        </div>
      </div>

      <p
        style={{
          fontFamily: 'var(--font-sans)',
          fontWeight: 'var(--fw-regular)',
          fontSize: '1.125rem',
          lineHeight: 1.7,
          letterSpacing: '0.02em',
          color: 'var(--color-ink)',
          marginTop: 'var(--space-3)',
        }}
      >
        Or add it yourself, to{' '}
        <code style={{ fontFamily: 'var(--font-mono)', color: 'var(--color-ink)' }}>
          {provider.configPath}
        </code>
        :
      </p>
      <Code>{`{
  "mcpServers": {
    "nco-web-editor": {
      "command": "npx",
      "args": ["--yes", "@nco-studio/web-editor-mcp@^0"]
    }
  }
}`}</Code>
      <p style={stepBodyStyle}>
        Either way there is nothing to install first:{' '}
        <code style={{ fontFamily: 'var(--font-mono)' }}>npx</code> fetches the server the first time
        your agent starts it, then reuses the cached copy.
      </p>
    </>
  );
}

// ---------------------------------------------------------------------------

type Step = { title: string; body: ReactNode };

const STEPS: Step[] = [
  {
    title: 'Install and pin the extension',
    body: (
      <>
        <p style={stepBodyStyle}>
          <a className="nco-link" href={CHROME_STORE_URL} target="_blank" rel="noopener noreferrer">
            Install from the Chrome Web Store
          </a>
          , then <strong>pin it to your toolbar</strong> — click the puzzle-piece icon in Chrome’s
          toolbar and hit the pin beside the editor. The icon is how you switch the editor on and
          off, so you want it visible. It is built for your own dev server — pages served from{' '}
          <code style={{ fontFamily: 'var(--font-mono)' }}>localhost</code> or{' '}
          <code style={{ fontFamily: 'var(--font-mono)' }}>127.0.0.1</code> — where the source mapping and
          design tokens it relies on come from.
        </p>
        {/* The src is built from BASE_URL, not written as a literal "/images/…".
            The site build runs with base "/web-editor/" (see build:site), and Vite
            does not rewrite absolute paths inside JSX — a literal would resolve to
            nco.studio/images/… and 404 in production while working locally. */}
        <figure style={{ margin: 'var(--space-2) 0 0' }}>
          <img
            src={`${import.meta.env.BASE_URL}images/web-editor-example-extension-pin.png`}
            alt="Chrome’s puzzle-piece menu open, with AI Agent Visual Editor listed and the pin icon highlighted"
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
    title: 'Connect your agent',
    body: <ConnectYourAgent />,
  },
  {
    title: 'Connect your code base',
    body: (
      <>
        <p style={stepBodyStyle}>
          <strong style={{ color: 'var(--color-ink)' }}>
            Add the editor's dev plugin, this is what connects your edits to your code.
          </strong>{' '}
          It tags elements at build time with their file and line, so a change arrives naming the
          exact component. Without it your agent gets a CSS selector and has to guess — and on
          repeated components it will sometimes guess wrong.
        </p>
        <p style={stepBodyStyle}>
          Dev dependency only; it does nothing in a production build.
        </p>
        <Code>{`npm install --save-dev @nco-studio/web-editor-plugin`}</Code>
        <p style={stepBodyStyle}>
          Then register it in your Vite config:
        </p>
        <Code>{`import { ncoWebEditor } from '@nco-studio/web-editor-plugin';
// vite.config.ts → plugins: [react(), ncoWebEditor()]`}</Code>
      </>
    ),
  },
  {
    title: 'Switch it on',
    body: (
      <>
        <p style={stepBodyStyle}>
          Open your dev server in Chrome, click the pinned icon, and click <strong>Extension</strong> in the
          popup to toggle it <strong>On</strong>. The overlay appears and elements highlight as you hover.
        </p>
        <p style={stepBodyStyle}>
          Chrome asks to allow access to devices on your local network the first time it connects —{' '}
          <strong>allow it</strong>. That is the editor reaching your MCP server over{' '}
          <code style={{ fontFamily: 'var(--font-mono)' }}>ws://localhost</code> — a connection that goes no further than your own machine.
          A banner appears only if the extension and server versions disagree.
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
    title: 'Run the loop',
    body: (
      <>
        <p style={stepBodyStyle}>
          Edit visually — each change queues automatically. Click <strong>Review changes</strong> in the toolbar (or <strong>Open Change Queue</strong> in the popup) to see pending edits, then hit <strong>Apply Changes</strong>. A connected agent
          applies the diff from there. Without an integrated setup, give it an explicit instruction that names the
          server and tools — it reads their descriptions and applies each diff to the right file:
        </p>
        <Code>{`Check my nco-web-editor MCP server for pending visual edits
from the browser. Apply each diff to the source file it points
to, then mark it done — using the get_pending_visual_changes
and acknowledge_visual_change tools.`}</Code>
        <p style={stepBodyStyle}>
          <code style={{ fontFamily: 'var(--font-mono)' }}>nco-web-editor</code> is the <code style={{ fontFamily: 'var(--font-mono)' }}>mcpServers</code> key
          from step 2 — swap in whatever you named it. The server runs on your machine; your agent is the one that sees your edits, and most agents send what they read to a model provider.
        </p>
      </>
    ),
  },
];

export default function SetupGuide() {
  return (
    <div>
      {/* Standfirst. The design (Figma 52:3900) sets this at 22px in the body
          face on full black over a 770px measure, directly under the tab strip
          — not the muted 15px secondary note it was before. It is setup-tab
          copy, which is why it lives here rather than in GuideTabs where it
          would also appear over How to use and Troubleshooting. */}
      <p
        style={{
          fontFamily: 'var(--font-sans)',
          fontWeight: 'var(--fw-regular)',
          fontSize: '1.375rem',
          lineHeight: 1.3,
          color: 'var(--color-ink)',
          maxWidth: '770px',
          marginTop: 0,
          marginBottom: '60px',
        }}
      >
        Install it, point your agent at it, and activate. It all runs on your machine — the editor talks only to your own MCP server, which hands your edits to your agent.
      </p>

        <Stepper
          steps={STEPS.map((st, i) => ({
            // The last step is the finish line, marked with a tick on a mint
            // rather than another number. A numbered list gives no signal that
            // it has ended — a reader who completes the final step cannot tell
            // whether setup is done or whether there is more below the fold.
            ...st,
            complete: i === STEPS.length - 1,
          }))}
        />
    </div>
  );
}
