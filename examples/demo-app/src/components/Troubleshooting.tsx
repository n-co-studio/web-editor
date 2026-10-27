/**
 * Troubleshooting — connection and reset guidance for the MCP bridge, as a tab
 * inside GuideTabs. Symptom / cause / fix entries on white: hairline
 * cards, sharp corners, no shadows.
 *
 * Most failure modes here trace back to one rule: exactly one server per
 * project directory, guarded by .nco-web-editor/server.lock.
 */

import type { ReactNode } from 'react';
import { stepBodyStyle } from './Stepper';

/**
 * Support routes: public issues first, email as the private fallback.
 *
 * Issues lead because an answer there is searchable and helps the next person
 * with the same problem, where an email helps exactly one. Email stays because
 * not everyone has a GitHub account, and a report about this tool often
 * carries page content or internal URLs that someone will not post publicly —
 * the subject matter is, by definition, somebody's own codebase.
 */
const ISSUES_URL = 'https://github.com/n-co-studio/web-editor/issues';
const SUPPORT_EMAIL = 'hello@nco.studio';

const SUPPORT_BODY = [
  'What I expected:',
  '',
  'What happened instead:',
  '',
  'Chrome version / OS:',
  'Extension version: 0.2.0',
  'Agent (Claude Code, Cursor, …):',
  'Editor connected? (toolbar dot):',
  'MCP server output:',
  '',
].join('\n');

const SUPPORT_MAILTO =
  `mailto:${SUPPORT_EMAIL}` +
  `?subject=${encodeURIComponent('AI Agent Visual Editor — help')}` +
  `&body=${encodeURIComponent(SUPPORT_BODY)}`;


function Code({ children }: { children: string }) {
  return (
    <pre
      style={{
        margin: 'var(--space-3) 0 0',
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

function Mono({ children }: { children: ReactNode }) {
  return <code style={{ fontFamily: 'var(--font-mono)' }}>{children}</code>;
}

type Entry = { symptom: string; cause: ReactNode; fix: ReactNode };

const ENTRIES: Entry[] = [
  {
    symptom: 'Chrome asks to allow access to devices on your network',
    cause: (
      <p>
        Expected. Chrome 142 and later ask before a page reaches a local address, and the editor talks
        to the MCP server over <Mono>ws://localhost</Mono>. Blocking or dismissing the prompt leaves the
        editor unable to reach the server, and the panel reports it as disconnected — the same symptom
        as a server that is not running.
      </p>
    ),
    fix: (
      <p>
        Click <strong>Allow</strong>. If it was already blocked, open site settings from the icon left of
        the address bar, set <strong>Local network access</strong> to Allow, and reload the page.
      </p>
    ),
  },
  {
    symptom: 'Your agent says the tools don’t exist',
    cause: (
      <p>
        The server runs <strong>one instance per project directory</strong>. If a second agent session
        is already running it, your session’s copy exits on startup and registers no tools — so
        <Mono> get_pending_visual_changes</Mono> and <Mono>acknowledge_visual_change</Mono> are simply
        absent. Adding the config to an already-running session has the same effect: MCP servers are
        spawned at session start.
      </p>
    ),
    fix: (
      <>
        <p>Find the holder, then either use that session or free it and restart yours.</p>
        <Code>{`cat .nco-web-editor/server.lock   # → holder PID
ps -p <PID> -o ppid=,command=    # → which agent owns it`}</Code>
      </>
    ),
  },
  {
    symptom: '“Another nco-web-editor MCP server is already running”',
    cause: (
      <p>
        The lock is held by a live process. A lock left behind by a crash is <em>not</em> a problem —
        the server checks whether the recorded PID is still alive and reclaims the file if it isn’t.
        So this message means a real second client, not a stale file.
      </p>
    ),
    fix: (
      <p>
        Quit the other agent session. Delete <Mono>.nco-web-editor/server.lock</Mono> by hand only when
        the PID inside it is genuinely dead.
      </p>
    ),
  },
  {
    symptom: 'The same edits keep coming back',
    cause: (
      <p>
        A diff leaves the queue only when the agent calls <Mono>acknowledge_visual_change</Mono> (or
        <Mono> reject_visual_change</Mono>). An agent that applies the change but never acknowledges it
        leaves the queue exactly as it found it, so the next poll returns the same work.
      </p>
    ),
    fix: (
      <p>
        Tell it to acknowledge each diff by id once applied. If it never had the tools, this is the
        first symptom in disguise — the queue is untouched because nothing could touch it.
      </p>
    ),
  },
  {
    symptom: 'The extension shows no server',
    cause: (
      <p>
        The bridge is not a background daemon — your agent launches it, and it stops when that session
        ends. It listens on <Mono>7890</Mono>, scanning up to <Mono>7899</Mono> if ports are taken.
      </p>
    ),
    fix: (
      <>
        <p>
          Start an agent session in the project, then reload the page. Override the base port with
          <Mono> NCO_WEB_EDITOR_PORT</Mono> if something else owns that range.
        </p>
        <Code>{`lsof -i :7890-7899   # what is listening, if anything`}</Code>
      </>
    ),
  },
  {
    symptom: 'The server is configured in two places',
    cause: (
      <p>
        Declaring <Mono>nco-web-editor</Mono> in both your agent’s settings file and a project
        <Mono> .mcp.json</Mono> gives it two launch paths for one lock — and project-level
        <Mono> .mcp.json</Mono> entries additionally wait on an approval prompt before they load at all.
      </p>
    ),
    fix: (
      <p>
        Keep one declaration, and put it where your agent actually reads it. Claude Code does{' '}
        <em>not</em> read <Mono>mcpServers</Mono> from <Mono>.claude/settings.json</Mono> — a block
        there is silently ignored, and the server simply never appears in <Mono>claude mcp list</Mono>.
        Project-scoped servers belong in <Mono>.mcp.json</Mono> at the repo root; approve it once when
        prompted and it loads on every session.
      </p>
    ),
  },
];

export default function Troubleshooting() {
  return (
    <div>
      <p
        style={{
          fontFamily: 'var(--font-sans)',
          fontWeight: 'var(--fw-regular)',
          fontSize: '1.125rem',
          lineHeight: 1.7,
          letterSpacing: '0.02em',
          color: 'var(--color-ink)',
          maxWidth: 'var(--measure)',
          marginBottom: 'var(--space-10)',
        }}
      >
        Most connection problems are the same problem: one server per project directory, and your
        agent is not the one holding it. The other is Chrome asking permission to reach it. Everything
        below is local — no accounts, nothing to sign in to.
      </p>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-5)', maxWidth: 'var(--measure)' }}>
        {ENTRIES.map(({ symptom, cause, fix }) => (
          <article key={symptom} className="nco-card" style={{ padding: 'var(--space-6)' }}>
            <h3
              style={{
                fontFamily: 'var(--font-display)',
                fontWeight: 'var(--fw-bold)',
                fontSize: '1.375rem',
                lineHeight: 0.9,
                letterSpacing: '-0.06em',
                textTransform: 'uppercase',
                color: 'var(--color-ink)',
              }}
            >
              {symptom}
            </h3>
            <div
              style={{
                fontFamily: 'var(--font-sans)',
                fontWeight: 'var(--fw-regular)',
                fontSize: '1.125rem',
                lineHeight: 1.7,
                letterSpacing: '0.02em',
                color: 'var(--color-ink)',
                display: 'flex',
                flexDirection: 'column',
                gap: 'var(--space-3)',
                marginTop: 'var(--space-3)',
              }}
            >
              {cause}
              <div style={{ borderTop: '1px solid var(--color-border)', paddingTop: 'var(--space-3)' }}>
                <span
                  style={{
                    display: 'block',
                    fontFamily: 'var(--font-mono)',
                    fontSize: 'var(--text-caption)',
                    textTransform: 'uppercase',
                    letterSpacing: 'var(--tracking-wide)',
                    color: 'var(--color-ink)',
                    marginBottom: 'var(--space-2)',
                  }}
                >
                  Fix
                </span>
                {fix}
              </div>
            </div>
          </article>
        ))}
      </div>

      <div style={{ maxWidth: 'var(--measure)', marginTop: 'var(--space-10)' }}>
        <h3
          style={{
            fontFamily: 'var(--font-display)',
            fontWeight: 'var(--fw-bold)',
            fontSize: '1.375rem',
            lineHeight: 0.9,
            letterSpacing: '-0.06em',
            textTransform: 'uppercase',
            color: 'var(--color-ink)',
          }}
        >
          Resetting the connection
        </h3>
        <p style={{ ...stepBodyStyle, marginTop: 'var(--space-3)' }}>
          Close every agent session that has the project open, then start one fresh. That single move
          releases the lock and gives the new session the server — the ordering is what matters, not the
          commands. Your queue is safe across restarts: it lives in{' '}
          <Mono>.nco-web-editor/pending-queue.json</Mono> and is reloaded on start.
        </p>
        <Code>{`# only if a session ended badly and left the lock behind
rm .nco-web-editor/server.lock

# discard the pending queue as well — this cannot be undone
rm .nco-web-editor/pending-queue.json`}</Code>
        <p style={{ ...stepBodyStyle, marginTop: 'var(--space-3)' }}>
          <Mono>editor-queue-status.yaml</Mono> in the project root is written by the server, not by you —
          it reports <Mono>status</Mono> and <Mono>pending_count</Mono> so a watching agent can react the
          moment a batch arrives. Leave it to the server; it is rewritten on every queue change.
        </p>
      </div>

      {/* Still stuck — the last block, because it is the fallback for
          everything above. A prefilled subject and body cost nothing and turn
          "it doesn't work" into a report that can actually be acted on: the
          four facts below are the ones every diagnosis starts from. */}
      <div style={{ marginTop: 'var(--space-10)', paddingTop: 'var(--space-6)', borderTop: '1px solid var(--color-divider)' }}>
        <h3
          style={{
            fontFamily: 'var(--font-display)',
            fontWeight: 'var(--fw-bold)',
            fontSize: '1.375rem',
            lineHeight: 0.9,
            letterSpacing: '-0.06em',
            textTransform: 'uppercase',
            color: 'var(--color-ink)',
          }}
        >
          Still stuck?
        </h3>
        <p style={{ ...stepBodyStyle, marginTop: 'var(--space-3)' }}>
          If your problem is not listed above, open an issue on{' '}
          <a
            href={ISSUES_URL}
            style={{ color: 'var(--color-ink)', textDecoration: 'underline' }}
          >
            GitHub
          </a>{' '}
          — answers there are searchable, so the next person with your problem finds it. If it
          involves page content or internal URLs you would rather not post publicly, email{' '}
          <a
            href={SUPPORT_MAILTO}
            style={{ color: 'var(--color-ink)', textDecoration: 'underline' }}
          >
            {SUPPORT_EMAIL}
          </a>{' '}
          instead; that link opens a message with the details below already in it. Either way,
          including them saves a round trip — they are the first things anyone would ask.
        </p>
        <ul style={{ ...stepBodyStyle, marginTop: 'var(--space-3)', paddingLeft: 'var(--space-5)' }}>
          <li>What you expected, and what happened instead</li>
          <li>Your Chrome version and operating system</li>
          <li>Whether the editor connected (the toolbar dot) and what the MCP server printed</li>
          <li>Which agent you are using</li>
        </ul>
      </div>
    </div>
  );
}
