# Findings: Hook Trigger & Cost Audit

**Brief:** 1 of 4 — Hook Trigger & Cost Audit
**Group:** stop-hook-optimization
**Date:** 2026-03-03
**Status:** Complete

---

## 1. Analytics Data Summary

### Data Source & Quality

- **Location:** `~/.local/share/repo-os-analytics/repo-OS-template/events/*.ndjson`
- **Period:** 2026-02-24 through 2026-03-03 (8 files)
- **Total events:** 17,386 valid (after filtering ~80 malformed lines from 2026-02-24)
- **Unique sessions:** 460
- **Average hook fires per session:** 37.8
- **Format:** NDJSON v2 — fields: `v`, `ts`, `sid`, `hook`, `evt`, `tool`, `out`, `dur`, `reason`, `mode`, `branch`, `detail`, `path`, `session_type`

**Data quality notes:**
- ~80 malformed lines in `2026-02-24.ndjson` caused by unescaped Python/shell code fragments in the `path` field. Fixed in subsequent analytics updates.
- One `test-verify` event has an instrumentation bug (epoch timestamp in `dur` field). Excluded from duration analysis.
- All repos are in template mode during the analysis period (`mode: template`).

### Aggregate Metrics

| Metric | Value |
|--------|-------|
| Total hook fires | 17,386 |
| Total block events | 750 (4.3%) |
| Unique sessions | 460 |
| Avg fires/session | 37.8 |
| Sessions hitting stop hook | 455 (98.9%) |
| Sessions closing first attempt | 283 (62.2%) |
| Sessions needing 2+ attempts | 172 (37.8%) |
| Safety valve fires (attempt_limit) | 46 (10.1% of stop-triggering sessions) |
| Zero-change sessions | 165 (36.3% of stop-triggering sessions) |

---

## 2. Hook Trigger Frequency Classification

### 2.1 Trigger Frequency Table

| Hook | Trigger Event | Frequency Class | Fires | % of Total | Avg Duration (ms) | Block Rate |
|------|---------------|-----------------|-------|------------|-------------------|------------|
| write-guard.sh | Edit, Write, Bash PreToolUse | Per-tool-call | 7,099* | 40.8% | 44-58 ms | 3.5% |
| branch-guard.sh | Bash PreToolUse | Per-Bash-call | 5,065 | 29.1% | 41 ms | 2.6% |
| agent-git-guard.sh | Bash PreToolUse (subagents) | Per-subagent-Bash | 1,554 | 8.9% | 19 ms | 0% observed |
| hvst-failure-tracker.sh | Bash PostToolUse/Failure | Per-Bash-call | 560 | 3.2% | 34 ms | n/a (advisory) |
| session-close-check.sh | Stop | Per-session-close | 680 | 3.9% | 203 ms | 29.4% |
| permission-request.sh | PermissionRequest | Per-permission-dialog | 349 | 2.0% | 120 ms | 0.6% |
| state-writer.sh | SubagentStop | Per-subagent-exit | 163 | 0.9% | 12 ms | 0% (always exit 0) |
| plan-approval.sh | AskUserQuestion PostToolUse | Per-AskUserQuestion | 151 | 0.9% | 79 ms | 0% (always exit 0) |
| pre-commit-gates.sh | Bash(git commit:*) PreToolUse | Per-commit | 7 | <0.1% | 286 ms | 71.4% |
| pre-push-gates.sh | Bash(git push:*) PreToolUse | Per-push | 0 observed | -- | -- | -- |
| ask-user-deny.sh | AskUserQuestion PreToolUse | Per-AskUserQuestion | 0 observed | -- | -- | -- |

*\* write-guard.sh fires as multiple logical guards: mode-guard (6,920 events), state-guard (86 events), write-guard/Section 3 (93 events). Total: 7,099.*

### 2.2 Hooks per Tool Call Type

| Tool Call | Hooks Fired | Combined Overhead |
|-----------|-------------|-------------------|
| **Bash** (non-commit/push) | write-guard.sh + branch-guard.sh + hvst-failure-tracker.sh (3 hooks) | ~120 ms |
| **Edit** | write-guard.sh (1 hook) | ~44 ms |
| **Write** | write-guard.sh (1 hook) | ~44 ms |
| **Bash(git commit:\*)** | write-guard.sh + branch-guard.sh + pre-commit-gates.sh + hvst-failure-tracker.sh (4 hooks) | ~410 ms |
| **Bash(git push:\*)** | write-guard.sh + branch-guard.sh + pre-push-gates.sh + hvst-failure-tracker.sh (4 hooks) | ~160 ms |
| **AskUserQuestion** | ask-user-deny.sh (Pre) + plan-approval.sh (Post) (2 hooks) | ~80 ms |
| **SubagentStop** | state-writer.sh (1 hook) | ~12 ms |
| **PermissionRequest** | permission-request.sh (1 hook) | ~120 ms |
| **Stop** | session-close-check.sh (1 hook) | ~203 ms |

### 2.3 Cumulative Session Overhead

For a typical session producing ~38 hook fires:
- **Bash-heavy sessions** (dominant): mode-guard + branch-guard account for ~70% of fires at ~42 ms each = ~1.1 seconds total from just the top-2 hooks across the session.
- **Per-session fixed cost**: session-close-check fires 1-3 times at ~203 ms = 200-600 ms.
- **Estimated total hook overhead per session**: 1.5-2.5 seconds (wall-clock).

---

## 3. session-close-check.sh Exit Path Map

### 3.1 Libraries Sourced

Every invocation sources three libraries before any logic executes:

| Library | Lines | Source-time Cost | Source-time Operations |
|---------|-------|------------------|-----------------------|
| `_analytics-helper.sh` | 607 | ~11 ms | 3 binary probes (`jq`, `shasum`/`sha256sum`/`openssl`), 1 OSTYPE check, repo root derivation |
| `_phase-helper.sh` | 679 | ~2 ms (incr.) | Phase sequence data structures (pure Bash case/echo -- no external forks) |
| `_cleanup-helper.sh` | 69 | ~1 ms (incr.) | Function definitions only (no source-time operations) |
| **Total** | **1,355** | **~14 ms** | |

**Measurement methodology:** `time (source <file>)` in Bash, 5 runs averaged, MacBook Pro (Apple Silicon). analytics-helper alone: ~11 ms; all three combined: ~12-14 ms. The incremental cost of phase-helper and cleanup-helper is minimal (~1-2 ms each) because they define functions without forking external processes.

**Process-scoping note:** Per-process caches (`_CACHED_BRANCH`, `_CACHED_SESSION_TYPE`, `_CACHED_SESSION_ID`, `_PS_VALIDATED`) provide within-invocation deduplication but give no cross-invocation benefit since each hook call spawns a new subprocess.

### 3.2 Exit Paths

| Exit | Line(s) | Reason | Analytics Frequency | Processing Before Exit | External Forks |
|------|---------|--------|---------------------|------------------------|----------------|
| **Safety valve** | 324-346 | 3+ stop attempts | 46 events (6.8%) | Library sourcing, stdin read, counter file I/O, `git diff --name-only` (x2), `get_solo()`, `get_branch()`, `seal_branch_if_applicable()`, `cleanup_session()` | 4-8 (git x2, grep, rm xN) |
| **No-init fast exit** | 352-368 | No phase-state file | 93 events (13.7%) | Library sourcing, stdin read, counter increment, file existence check, optional `record_closed_branch()` + `advisory_push_to_remote()` | 2-5 (grep, git push optional) |
| **Ephemeral exempt** | 374-380 | Session type = taskdef-query / taskdef-brief / audit | ~0 observed | Library sourcing, stdin read, counter increment, no-init check, `get_session_type()` | 1-2 (grep/sed on phase-state) |
| **Operator override** | 383-400 | SKIP_SESSION_LOG=1 | ~0 observed | Library sourcing, stdin read, counter increment, no-init check, ephemeral check, override log, overrides.log audit | 3-5 (wc, awk, sort) |
| **Zero-change** | 456-476 | No commits, no diff, no staged | 165 events (24.3%) | Library sourcing, stdin read, counter increment, no-init/ephemeral/override checks, session-log bootstrap, hash computation, `git diff --name-only` (x2), baseline SHA check, `git log --oneline`, optional merge detection | 6-10 (git x4, shasum, cat) |
| **BLOCKED (failure report)** | 557-568 | Blocking check(s) failed | 138 events (20.3%) | **Full processing path**: all above + session-log-modified check + known-issues checks + HVST counter check + deferrals check + failure message construction | 8-12 (git x4, shasum, cat, grep x2+) |
| **Agent-merge detection** | 629-637 | merge-source-branch file present | 9 events (1.3%) | Full non-blocked path + merge state file read + `record_closed_branch()` + `advisory_push_to_remote()` | 8-14 (git push, grep, rm xN) |
| **Solo merge** | 668-691 | Solo mode, mergeable branch | 1 event (0.1%) | Full non-blocked path + `git checkout main` + `git merge --ff-only` (or `--no-ff` fallback) + branch seal + push | 10-16 (git x6+, grep, rm xN) |
| **Normal close** | 716-730 | All checks pass | 87 events (12.8%) | Full non-blocked path + override audit + governance evidence check + next-brief reminder + branch seal + baseline update + cleanup | 10-15 (git x4, awk, grep x3, shasum) |

### 3.3 Cost Ranking by Exit Path

| Path | Frequency | Avg Duration (ms) | Cumulative Impact |
|------|-----------|-------------------|-------------------|
| BLOCKED (exit 2) | 138 fires | ~250 ms | **HIGH** -- also triggers retry (next stop attempt), doubling effective cost + token injection |
| Zero-change | 165 fires | ~150 ms | **MEDIUM** -- high frequency but relatively lean processing |
| Normal close | 87 fires | ~200 ms | MEDIUM -- full path but occurs only once per successful session |
| Safety valve | 46 fires | ~180 ms | LOW-MEDIUM -- safety net, infrequent |
| No-init fast exit | 93 fires | ~80 ms | LOW -- fast path, moderate frequency |
| Other paths | 10 fires | varies | LOW -- rare |

---

## 4. Shared Library Sourcing Cost

### 4.1 Measurements

| Configuration | Wall-clock (avg of 5 runs) | Notes |
|---------------|---------------------------|-------|
| `_analytics-helper.sh` alone | **11 ms** | 3 binary probes: `jq`, hash cmd (`shasum`/`sha256sum`/`openssl`), OSTYPE check |
| + `_phase-helper.sh` | **13 ms** (+2 ms) | Pure Bash case statements, no external forks |
| + `_cleanup-helper.sh` | **14 ms** (+1 ms) | Function definitions only |
| + `_permission-allowlist.sh` (permission-request.sh only) | **~15 ms** (+1 ms) | Array definitions only |

**Hardware:** MacBook Pro (Apple Silicon M-series), macOS Darwin 25.3.0, Bash 5.x.

### 4.2 Source-Time Operations in _analytics-helper.sh

| Operation | Type | Purpose |
|-----------|------|---------|
| `case "${OSTYPE:-}"` | Bash built-in | Determine GNU date availability |
| `command -v jq` | Bash built-in (fast) | jq availability probe |
| `command -v shasum` | Bash built-in (fast) | Hash command selection |
| `command -v sha256sum` | Bash built-in (fast) | Hash command fallback |
| `cd ... && pwd` subshell | Subshell + fork | Derive repo root |

**Note:** `command -v` is a Bash built-in (no fork). The only true fork at source-time is the `cd ... && pwd` subshell for repo root derivation. The measured 11 ms is dominated by process startup and Bash parsing of 607 lines rather than fork overhead.

### 4.3 Per-Invocation vs. Cross-Invocation Caching

Caches populated at source-time or first use:

| Cache Variable | Set By | Scope | Cross-Invocation? |
|---------------|--------|-------|-------------------|
| `_REPO_OS_HAS_GNU_DATE` | Source-time | Process | No |
| `_REPO_OS_HAS_JQ` | Source-time | Process | No |
| `_REPO_OS_HASH_CMD` | Source-time | Process | No |
| `_REPO_OS_ROOT` | Source-time | Process | No |
| `_CACHED_BRANCH` | First `get_branch()` | Process | No |
| `_CACHED_SESSION_TYPE` | First `get_session_type()` | Process | No |
| `_CACHED_SESSION_ID` | First `get_session_id()` | Process | No |
| `_PS_VALIDATED` | First `_validate_phase_session()` | Process | No |
| `_SESSION_OVERLAP_CHECKED` | First `check_session_overlap()` | Process (PID-bound) | No |

**Conclusion:** All caches are process-scoped. Since each hook invocation is a fresh subprocess, these caches provide intra-invocation deduplication only. The 3 binary probes and repo root derivation execute on every single hook fire (~17,386 times in the analysis period).

---

## 5. Stop Hook Stderr Output -- Token Cost Analysis

### 5.1 BLOCKED Message Size

The BLOCKED error message (lines 560-568 of session-close-check.sh) is injected into model context via stderr when the hook returns exit 2.

| Scenario | Bytes | Characters | Est. Tokens (~4 chars/token) |
|----------|-------|------------|------------------------------|
| 1-failure BLOCKED (typical) | 342 | 342 | ~85 |
| 4-failure BLOCKED (worst case) | 682 | 682 | ~170 |
| Solo merge failure (line 682) | ~120 | ~120 | ~30 |

**Methodology:** Token estimates use the ~4 characters per token heuristic for English text. Actual tokenization may vary by +/-20% depending on token boundaries with technical terms.

### 5.2 Per-Retry Token Cost

When session-close-check.sh blocks:
1. The ~85-170 token BLOCKED message is injected into model context
2. The model processes this, generates a response (addressing the failures), and attempts to close again
3. The close attempt fires the stop hook again (~203 ms overhead)
4. If still failing, the cycle repeats (up to 3 total attempts before safety valve)

**Per-retry cost floor:** ~85 input tokens (BLOCKED message) + model processing + response generation.
**Worst case (3 retries):** ~255-510 input tokens from BLOCKED messages alone, plus ~600 ms of hook execution time.

### 5.3 Retry Distribution

| Stop Attempts | Sessions | % | Token Cost (BLOCKED msgs) |
|---------------|----------|---|---------------------------|
| 1 (no retry) | 283 | 62.2% | 0 tokens |
| 2 (1 retry) | 120 | 26.4% | ~85-170 tokens |
| 3 (2 retries) | 51 | 11.2% | ~170-340 tokens |
| 4+ | 1 | 0.2% | ~255-510 tokens |
| Safety valve | 46 | 10.1% | 255-510 tokens (all 3 attempts exhausted) |

---

## 6. Existing Cost-Control Patterns

### 6.1 Fast-Exit Patterns

| Hook | Pattern | Trigger Condition | Frequency | Savings |
|------|---------|-------------------|-----------|---------|
| **branch-guard.sh** | Pre-stdin fast exit (line 97) | Bash input has no `>`, `tee`, or `file_path` | 56.3% of fires (2,849) | Avoids jq parse, all gate evaluations |
| **write-guard.sh** | Non-template fast exit (line 271) | Mode != template | 94.9% of fires (6,647) | Avoids full path classification |
| **session-close-check.sh** | No-init fast exit (line 352) | phase-state file absent | 13.7% of fires (93) | Skips all blocking checks |
| **session-close-check.sh** | Ephemeral exempt (line 374) | taskdef-query / taskdef-brief / audit | ~0 observed | Skips all blocking checks |
| **session-close-check.sh** | Zero-change fast path (line 456) | No commits, no diff, no staged | 24.3% of fires (165) | Downgrades to advisory |
| **ask-user-deny.sh** | Interactive fast exit (line 14) | CLAUDE_HEADLESS != 1 | ~100% interactive | Skips stdin read entirely |
| **hvst-failure-tracker.sh** | No-counter fast exit (line 31) | PostToolUse + no counter file | ~80-90% of fires | Exits before stdin read |
| **agent-git-guard.sh** | Non-commit/push exit (line 25) | Not git commit/push | 100% observed (1,554) | Still reads stdin + jq |

### 6.2 Caching Patterns

| Pattern | Where | Benefit |
|---------|-------|---------|
| `_CACHED_BRANCH` | _analytics-helper.sh:199 | Avoids redundant `git rev-parse` within invocation |
| `_CACHED_SESSION_TYPE` | _analytics-helper.sh:231 | Avoids redundant phase-state reads within invocation |
| `_PS_VALIDATED` | _phase-helper.sh:267 | Avoids redundant phase-state validation (audit C8) |
| `_SESSION_OVERLAP_CHECKED` | _analytics-helper.sh:234 | PID-bound overlap check cache (audit C7) |
| `_CACHED_ANALYTICS_DIR` | _analytics-helper.sh:272 | Avoids redundant `basename` fork per log call |
| `_CACHED_TODAY` | _analytics-helper.sh:273 | Avoids redundant `date` fork per log call |
| `_CACHED_STAGED_DIFF` | pre-commit-gates.sh:81 | Lazy-loaded staged diff shared by A4, high-risk, A1 |

### 6.3 Process-Cost Reduction Patterns

| Pattern | Where | Savings |
|---------|-------|---------|
| Single jq invocation for both fields | write-guard.sh:82 | Halves subprocess count |
| Zero-fork string matching `[[ ]]` | branch-guard.sh:58 | No jq/subshells for merge check |
| Pre-stdin override checks | write-guard.sh:42-66 | Exits before stdin `cat` |
| Bash built-in `command -v` | _analytics-helper.sh:31-43 | No fork for binary probes |
| Pure Bash phase sequences | _phase-helper.sh:20-56 | No file reads, no forks |

---

## 7. Top 5 Waste Sources

Ranked by cumulative session impact (frequency x per-occurrence cost).

### Rank 1: Stop Hook BLOCKED Retries

- **Mechanism:** 38% of sessions fail the first close attempt (172/455 sessions), triggering a retry cycle. Each retry adds ~203 ms hook execution + ~85-170 tokens of BLOCKED message to model context.
- **Cumulative cost:** 172 sessions x 1+ retries x (203 ms + 85 tokens) = ~35 seconds of hook time + ~15,000 input tokens across the analysis period.
- **Root causes:** Session log not updated (most common), uncommitted changes, known-issues not updated.
- **Evidence:** `single_pass_block` (138), `second_attempt` (65), `attempt_limit` (46).

### Rank 2: Zero-Change Session Overhead

- **Mechanism:** 165 sessions (36% of stop-hook triggers) execute full library sourcing + stdin read + counter increment + hash computation + git diff/log chain only to discover no changes.
- **Per-occurrence cost:** ~150 ms wall-clock, 6-10 subprocess forks.
- **Cumulative cost:** 165 x 150 ms = ~25 seconds of hook time.
- **Optimization note:** The zero-change path already downgrades to advisory, but still executes substantial I/O before reaching the detection point (line 456).

### Rank 3: write-guard.sh + branch-guard.sh Double-Fire on Bash Calls

- **Mechanism:** Every Bash tool call triggers write-guard.sh AND branch-guard.sh. Both read stdin, both parse JSON. A single `git status` incurs both hooks.
- **Per-occurrence cost:** ~44 ms (write-guard) + ~41 ms (branch-guard) = ~85 ms per Bash call.
- **Mitigation:** Fast-exit paths reduce effective cost (94.9% for write-guard in template mode, 56.3% for branch-guard). Remaining ~45% of branch-guard fires evaluate fully.

### Rank 4: Library Sourcing Repetition

- **Mechanism:** Every hook invocation re-sources `_analytics-helper.sh` (11 ms), re-probing binaries and re-deriving repo root. Across 17,386 fires = ~191 seconds of pure sourcing overhead.
- **Note:** Inherent to subprocess-per-hook architecture. Each hook is a fresh Bash process.

### Rank 5: Safety Valve Token Waste

- **Mechanism:** 46 sessions (10.1%) exhaust all 3 close attempts, burning 3 x 203 ms + 3 x 85-170 tokens in BLOCKED messages -- all wasted because the safety valve exits unconditionally.
- **Cumulative cost:** 46 x 609 ms = ~28 seconds hook time + ~12,000-23,000 input tokens.

---

## 8. Session-Close-Check Reason Distribution

| Reason | Count | % | Category |
|--------|-------|---|----------|
| zero_change | 165 | 24.3% | Fast exit |
| single_pass_block | 138 | 20.3% | Block (triggers retry) |
| no_phase_state | 93 | 13.7% | Fast exit |
| session_complete | 87 | 12.8% | Normal close |
| second_attempt | 65 | 9.6% | Retry tracking |
| attempt_limit | 46 | 6.8% | Safety valve |
| no_pr | 32 | 4.7% | Block reason |
| log_not_updated | 20 | 2.9% | Block reason |
| seal_skipped_empty_stype | 14 | 2.1% | Guard behavior |
| uncommitted_changes | 10 | 1.5% | Block reason |
| agent_merged | 9 | 1.3% | Merge detection |
| solo_merge_success | 1 | 0.1% | Solo merge |

---

## 9. Methodology & Limitations

### Measurements
- **Wall-clock timings:** `time (source <file>)` in Bash, 5 runs averaged, MacBook Pro (Apple Silicon M-series), macOS Darwin 25.3.0.
- **Analytics durations:** `dur` field from NDJSON events, calculated as `end_ms - start_ms` within each hook script.
- **Token estimates:** ~4 characters per token heuristic for English text. Actual tokenization varies +/-20%.
- **Fork counts:** Manual code audit, counting external command references along each exit path. Some forks are conditional.

### Limitations
- All data is from a single repo (`repo-OS-template`) in template mode. Child/autonomous repos may show different patterns (especially mode-guard fast-exit rates).
- The 8-day analysis window includes the period when analytics infrastructure was being built.
- Wall-clock timings are hardware-specific. Slower machines or CI would show proportionally higher overhead.
- `pre-push-gates.sh` and `ask-user-deny.sh` had zero observed fires -- cost profile estimated from code analysis only.
- Legacy hook names in analytics (`branch-guard-edit`, `state-guard`) reflect pre-consolidation architecture but now fire as sections within `write-guard.sh`.
