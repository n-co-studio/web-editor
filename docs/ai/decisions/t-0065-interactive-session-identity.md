# Decision t-0065 — An interactive session's identity comes from Claude Code, not from files in the checkout

**Status:** Accepted
**Date:** 2026-11-09
**Supersedes:** the identity-resolution parts of the 2026-06-08 stdin plumbing (9b6ec01), the
2026-06-14 first-writer-wins rule (8fad983), the 2026-06-18 per-process sidecars (3647acf) and
R47's claim-on-adopt (8bbf2da). Headless and worktree identity (t-0030, `REPO_OS_SESSION_ID`) is
unchanged.
**Amends:** `.claude/hooks/_analytics-helper.sh`, `session-close-check.sh`, `state-writer.sh`,
`pre-commit-gates.sh`.

## Triggers

- type: file
- path: `\.claude/hooks/_analytics-helper\.sh`
- keywords: `session identity, session-id, sidecar, get_session_id, CLAUDE_CODE_SESSION_ID, CLAUDE_PID, _resolve_durable_pid, branch_claim, safety valve release, identity adopt, identity mint`

## Context

An interactive session found its id in shared files in the checkout: a flat
`.claude/.session-id` plus per-process sidecars `.claude/.session-id.<PPID>`, with fallbacks that
adopted, minted and seeded them. Each fallback was added to fix the previous incident, and every
incident on record is one session's id reaching another through those files:

- **R47:** a resumed window adopted an id without claiming it; a second window's SessionEnd
  sealed its branch.
- **R48 (a):** the agent's shell has no stdin id, resolved the flat file, and re-initialised
  another live window's phase-state.
- **R48 (b):** write-guard has no stdin id, minted one, and blocked every Edit/Write.
- **R48 (d):** the Stop safety valve deleted the sidecar; the next line's telemetry adopted a
  minted id; review verdicts landed under it.
- **Child web-editor GT-8:** SessionEnd's own cleanup re-seeded the ended id; the next
  conversation in that window inherited it.
- A `pragmatist-signed` written into the right directory carried another window's id, because
  state-writer stamped from the flat file but wrote to the sidecar's directory.

The files existed because the harness id was believed to **rotate on context-window turnover**
(8fad983). Nothing records such a rotation. The one logged "rotation" was a new task started
after the previous one closed (session-94bc943f log). Measured 2026-11-03: one conversation kept
a single id across two compactions and five days; every transcript in this project holds exactly
one id; subagent transcripts carry the parent's.

Claude Code documents (`env-vars.md`, `hooks.md`) that `CLAUDE_CODE_SESSION_ID` is set in **hook
processes and Bash tool commands**, equals the hook stdin `session_id`, and changes only on
`/clear` (SessionEnd `reason: clear`, then SessionStart `source: clear`) and on fork — both of
which begin a new conversation. `CLAUDE_PID` (2.1.214+) is the claude process id in the same
places.

## Decision

### 1. Resolution order

`get_session_id` returns the first of:

1. `REPO_OS_SESSION_ID` — headless, worktree and daemon sessions (t-0030). Unchanged.
2. `CLAUDE_CODE_SESSION_ID` — an interactive session: every hook, the agent's own shell, and
   subagents (which carry the parent's id).
3. `_REPO_OS_STDIN_SID` — a hook on a Claude Code that does not export the variable.
4. Neither: the flat `.claude/.session-id` if present, else a minted id written there. Reachable
   only outside Claude Code — test fixtures and manual shells (operator choice, 2026-11-09).

**Paths 1-3 read no identity file and write none.** Nothing that runs inside Claude Code creates,
adopts or rewrites `.claude/.session-id` or `.claude/.session-id.*`. That removes the failure
class rather than another instance of it: two windows cannot reach each other's id, and telemetry
after cleanup has nothing to recreate.

Compaction stability, the requirement the sidecars were built for (L4.11), holds because the id
itself is stable. `/clear` starts a new session, which is what it is.

### 2. Liveness from the registry

`_resolve_durable_pid` prefers `CLAUDE_PID`, so the registry's `pid:` is the claude process.
Before this it was often a short-lived tool shell, which is why the sidecar had become the
"decisive" liveness test. The sweep checks that pid first, so a live session keeps its record.
`_session_is_live`, which the sweep consults only once the registry pid is dead or the record is
gone, answers from `REPO_OS_SESSION_ID` / `CLAUDE_CODE_SESSION_ID` (the sweep is running inside
that session) and — read-only — a legacy sidecar with a live pid. The legacy read protects
sessions that started before this change, whose registry pid may be a dead tool shell; it can be
removed once no such session can still be running.

**Not inside a headless brief.** A daemon started from a Claude Code shell inherits the
operator's `CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID`. `get_session_id` is unaffected
(`REPO_OS_SESSION_ID` wins), but a brief's registry pid must not become the operator's claude
process: the brief would then look dead the moment the operator's window closed, and another
session's sweep would delete its state. `_resolve_durable_pid` therefore ignores `CLAUDE_PID`
whenever `REPO_OS_SESSION_ID` is set.

### 3. The Stop safety valve releases the claim, not the record

The valve used to call `unregister_session`, deleting the registry record (and, before this
decision, the sidecar). With identity no longer in files, that would leave a live session with no
liveness signal, and the next sweep would delete its state directory. The valve now appends
`branch_claim: released` to the record. The three overlap readers — the advisory in
`register_session`, `is_session_active` and `check_session_overlap` — skip a released record, so
the valve still unblocks other sessions, which is its purpose. `group-worktree-sweep.sh` and
`overlap-report.sh` also read `branch:` and keep seeing the real value; that is why the record is
not blanked. The release is still one-way: `register_session` rewrites the record only from
`init_phase`.

### 4. One id everywhere

Readers that bypassed `get_session_id` and read the flat file now call it: state-writer's
`session_id:` stamp, `pre-commit-gates.sh`'s state-file validation and its two stamps, and
session-close-check's zero-change fast path (which mirrors the order above in builtins, because
it runs before the helpers are sourced). A state file's stamp therefore always names the
directory it is written to.

`pre-commit-gates.sh` reads the id through `peek_session_id`, which follows the same order but
never mints or writes: its state-file validation skips when there is no current session, and
`get_session_id` would have minted one (and written the flat file) instead.

The template-mode "known-issues updated this session" check used the flat file's mtime as the
session's start; it now uses the session's registry record, which `init_phase` writes.

`blocker-reporter.sh` is not changed: it runs only inside the runner, where
`REPO_OS_SESSION_ID` is set, and its fallback deliberately reads the session's own checkout.

### 5. Tests do not see the operator's session

Every suite runs inside a Claude Code Bash, where `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID` are
set. The hook test harness and the automation sandbox clear both, so fixtures exercise path 4 and
no suite can resolve the operator's real session. Cases that test paths 2 and 3 set the variables
themselves.

## What was removed

| Patch | Fate |
|---|---|
| Sidecar as identity (3647acf) | Removed |
| Adopt the flat id; R47 claim-on-adopt | Removed |
| Mint from stdin when a live foreign sidecar claims the flat id | Removed |
| Seed sidecar and flat file on first hook | Removed |
| `_sid_claimed_by_live_foreign` | Removed |
| `unregister_session` deleting sidecars by content | Removed |
| Stop valve `unregister_session` | Replaced by `branch_claim: released` |
| Flat-file reads in state-writer, pre-commit-gates, the close fast path | Replaced by `get_session_id` |
| `REPO_OS_SESSION_ID` beats the cache (L4.15) | Kept |
| Sweep reaping dead-pid sidecars | Kept, to clear legacy files |
| `cleanup_session_files` deleting the flat file when it is this session's | Kept, harmless |
| `_is_foreign_live_state` close-time guard | Kept. It fires only when the resolved state's id differs from the hook's stdin id, which since this decision means `CLAUDE_CODE_SESSION_ID` and stdin disagree; L4.9a builds that case, with a dead-owner control |
## Requirements and limits

- Interactive sessions need a Claude Code that exports `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID`
  (2.1.214+). On an older version hooks still resolve through the stdin id, but the agent's own
  shell has neither and falls back to path 4. Liveness degrades too: without `CLAUDE_PID` the
  registry pid can be a short-lived tool shell, no sidecar is written to cover for it, and another
  session's sweep can delete the running session's state directory. No refusal is added here.
- Two windows on one checkout now have separate identities but still share one working tree and
  one branch. Parallel interactive work needs a worktree per window; this decision does not
  provide that.
- The stale `phase-state.gates` overlap verdict (R48 c) is not addressed.

## Verification

`.claude/hooks/tests/test-session-identity-env.sh` (new) and the rewritten cases in
`layer4-session-identity-bundle.sh`. Pristine evidence:
`docs/ai/governance/pristine-evidence/session-identity-per-process.yaml` (t-0063).

## References

- `docs/ai/decisions/t-0030-worktree-session-isolation.md` — headless identity, unchanged
- `docs/ai/decisions/t-0047-session-lifecycle-stop-sessionend-split.md` — Stop vs SessionEnd
- `docs/ai/decisions/t-0063-mechanism-change-verifies-itself.md` — evidence requirement
- `docs/ai/logs/known-issues.md` — R47, R48
