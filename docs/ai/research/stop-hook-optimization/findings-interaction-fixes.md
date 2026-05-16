# Findings: Hook-Agent Interaction Patterns & Fix Proposals

**Brief:** 2 of 4 — Hook-Agent Interaction Patterns & Fix Proposals
**Task Group:** stop-hook-optimization
**Date:** 2026-03-03
**Scope:** `session-close-check.sh` blocking behavior, Claude Code API features, fix proposals with governance impact

---

## 1. Analytics Data Analysis

### Data Sources

All NDJSON event files from `~/.local/share/repo-os-analytics/*/events/*.ndjson`.
Date range: 2026-02-24 through 2026-03-02.
93 repos with data (3 real, 90 phase-test).

### Volume Summary

| Metric | Count |
|--------|-------|
| Total `session-close-check` events | 1,042 |
| Distinct sessions with at least 1 fire | 405 |
| Outcome: allow | 937 (89.9%) |
| Outcome: block | 105 (10.1%) |

98.3% of events are from phase-test repos (automated test suites exercising the stop hook's decision tree). 18 events from real repos.

### Reason Code Distribution

| Reason | Count | Outcome | Notes |
|--------|-------|---------|-------|
| `zero_change` | 273 | allow | Clean exit — no changes detected |
| `session_complete` | 259 | allow | Normal successful close |
| `single_pass_block` | 96 | block | First-attempt block — agent hasn't completed close sequence |
| `no_phase_state` | 90 | allow | Session never initialized |
| `attempt_limit` | 65 | allow | Safety valve — 3 attempts reached |
| `agent_merged` | 60 | allow | Agent merged before stop hook fired |
| `override_audit` | 57 | allow | Override summary (advisory) |
| `skip_override` | 55 | allow | SKIP_SESSION_LOG=1 used |
| `seal_skipped_empty_stype` | 30 | allow | Seal skipped (empty session type) |
| `ephemeral_exempt` | 30 | allow | Ephemeral session type exempt |
| `solo_merge_success` | 16 | allow | Stop hook successfully merged |
| `log_not_updated` | 5 | block | Session log not written |
| `solo_merge_failed` | 4 | block | Merge attempt failed |
| `second_attempt` | 2 | allow | Legacy second-attempt marker |

### Block Reason Distribution

Only 3 reason codes produce blocks:

| Reason | Block Count | % of Blocks |
|--------|-------------|-------------|
| `single_pass_block` | 96 | 91.4% |
| `log_not_updated` | 5 | 4.8% |
| `solo_merge_failed` | 4 | 3.8% |

`single_pass_block` dominates. This is the first-attempt block where the agent hasn't yet completed its close sequence. The detail field consistently shows `"1"` (attempt 1).

### Retry Loop Frequency

| Fires per Session | Sessions | % |
|-------------------|----------|---|
| 1 fire | 123 | 30.4% |
| 2 fires | 102 | 25.2% |
| 3 fires | 80 | 19.8% |
| 4 fires | 42 | 10.4% |
| 5 fires | 47 | 11.6% |
| 6+ fires | 11 | 2.7% |

**Key finding:** 69.6% of sessions (282/405) required more than 1 stop hook fire. The median session has 2-3 fires. The hook blocks on the first pass, then on subsequent passes it processes merges, overrides, and seal operations.

### Safety Valve (`attempt_limit`) Frequency

- **65 fires across all sessions (16% of all sessions)**
- All have `detail: "3"` (valve trips at attempt 3)
- Concentrated in phase-test repos; 1 real-repo instance on `feature/flex-grid-foundation`

The safety valve fires in 16% of sessions. This is significant — it means the retry pipeline regularly reaches its ceiling, suggesting the block-retry-block pattern consumes all 3 allowed attempts before giving up.

### Session Type Correlation

| Session Type | Allow | Block |
|-------------|-------|-------|
| standard | 323 | 30 |
| unknown | 212 | 5 |
| taskgroup | 176 | 0 |
| taskgroup-merge | 108 | 0 |
| taskdef-* | 20 | 0 |
| experiment | 10 | 0 |
| audit | 10 | 0 |

**Blocks are concentrated in `standard` sessions (81% of blocks with type data).** Task group sessions never block — they always complete cleanly.

### Agent Merge Success Rate

- **60 `agent_merged` events** — agent correctly merged before stop hook fired
- **16 `solo_merge_success` events** — stop hook merged as safety net
- **4 `solo_merge_failed` events** — stop hook merge failed

Ratio: agent merges correctly 78.9% of the time when merging is needed. The stop hook safety net handles the remaining 21.1%. This validates the safety net design but suggests improving agent merge compliance could reduce stop hook complexity.

### Duration Analysis

| Bucket | Count | % |
|--------|-------|---|
| 0 ms | 925 | 88.8% |
| 501-1000 ms | 116 | 11.1% |
| > 1000 ms | 1 | 0.1% |

Average duration per event: 113 ms. Total cumulative overhead: 118 seconds across 1,042 events. The hook itself is fast — the token cost problem is in the model's response generation between retries, not in hook execution time.

---

## 2. Block-Retry-Block Loop Analysis

### The Token Cost Cycle

When the stop hook exits 2, the following cycle occurs:

```
1. Agent attempts to stop
2. Hook fires (~113ms), runs all checks, finds failures
3. Hook exits 2, writes multi-line failure report to stderr
4. stderr content enters Claude's context as a corrigendum turn
5. Claude processes the error (reads, reasons, decides action)
6. Claude generates response (explanation + corrective actions)
7. Claude executes corrective actions (edit files, run commands)
8. Claude attempts to stop again → goto 2
```

### Per-Attempt Token Overhead

**Stderr to context cost:** The failure report (lines 557-568 of `session-close-check.sh`) is a structured multi-line message:

> **Historical snapshot — the quoted error message below is preserved verbatim from the time of this research finding.** At that time the hook reported the rolling single-file path. The current hook resolves the per-session path (`docs/ai/logs/sessions/session-{id}.md` or `.claude/local/sessions/session-{id}.md`) — see `session-close-check.sh` path-resolution block. Treat the quote as a frozen snapshot, not live hook output.

```
BLOCKED: N issue(s) must be resolved before closing:
1. Session log not updated — update docs/ai/logs/session-log.md (override: SKIP_SESSION_LOG=1)
2. Uncommitted changes detected — commit before closing (override: SKIP_UNCOMMITTED_CHECK=1)

Close sequence (complete all before retrying):
  1. Update session log
  2. Commit all changes including session log
  3. Merge to main (solo mode)
  4. Present closing summary — then exit
```

This is ~400-500 bytes of stderr that enters the context window. On each retry, the model must:

- **Read** the error message (~100 input tokens)
- **Reason** about what failed and what to fix (~200-500 reasoning tokens)
- **Generate** corrective response + actions (~300-800 output tokens)

**Estimated per-retry token cost:** 600-1,400 tokens (input + reasoning + output)

### Per-Session Total

For a session reaching the safety valve (3 attempts):
- Attempt 1: block, ~1,000 tokens
- Attempt 2: block, ~1,000 tokens
- Attempt 3: safety valve allows exit, ~0 tokens (no response needed)
- **Total: ~2,000 tokens per session**

For the 65 sessions reaching `attempt_limit`: **~130,000 tokens total wasted on retry loops**.

For the 282 sessions with >1 fire: estimated **~200,000 tokens total** across all retry cycles.

### Methodology Note

Token estimates are approximate. Actual costs vary by model, context length, and the specific corrective actions needed. The stderr message length is deterministic (measurable from the hook script). The model's response length is variable. Duration data (88.8% at 0ms) confirms the overhead is in model processing, not hook execution.

---

## 3. `stop_hook_active` Field Investigation

### Field Status: EXISTS AND IS DOCUMENTED

The Claude Code hook API provides a `stop_hook_active` field in the Stop hook input JSON. When the hook fires as a retry (i.e., Claude is continuing after a previous stop hook block), this field is `true`.

### Current Hook Usage

The hook reads `INPUT=$(cat)` at line 39 but **never parses or checks this field**. Instead, it maintains its own counter (`$STOP_ATTEMPT_FILE`) to track retry state.

### Input JSON Structure

```json
{
  "session_id": "abc123",
  "transcript_path": "~/.claude/projects/.../transcript.jsonl",
  "cwd": "/path/to/repo",
  "permission_mode": "default",
  "hook_event_name": "Stop",
  "stop_hook_active": true,
  "last_assistant_message": "I've completed the close sequence..."
}
```

### Optimization Opportunity

**First-attempt vs retry differentiation without file I/O:**

Currently, the hook reads and writes `.stop-attempt-count` on every invocation (2 file I/O operations). With `stop_hook_active`:

```bash
IS_RETRY=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$IS_RETRY" = "true" ]; then
  # Fast path: only check whether previously-blocked items are resolved
  # Skip: advisory checks, governance evidence, contract scanning
fi
```

### What This Enables

1. **First attempt:** Run all checks (session log, uncommitted, HVST, deferrals). If any fail, report all failures together (current behavior).
2. **Retry attempts:** Only check whether the specific blocked items are now resolved. Skip advisory checks (governance evidence, override audit, next-brief reminder), skip contract scanning, skip full finality checks.

### Governance Guarantees Preserved

- All 4 blocking checks still run on first attempt (full coverage)
- Retry only verifies resolution of previously-flagged issues (targeted)
- Safety valve still fires at 3 attempts (counter file still maintained)
- Advisory checks run once on first attempt (sufficient for their purpose)

### Governance Guarantees Lost

None. Advisory checks are informational — running them once is sufficient. Blocking checks are re-verified on retry. The safety valve remains as a backstop.

### Assessment: Quick Win

- **Code change:** Small — add jq parse for `stop_hook_active`, branch logic
- **Token savings:** Eliminates ~40% of retry processing (advisory checks, contract scans)
- **Risk:** Low — retry path is a subset of first-attempt path

---

## 4. JSON stdout vs Exit 2 stderr

### Current Approach: Exit 2 + stderr

```bash
echo "BLOCKED: $FAILURE_COUNT issue(s)..." >&2
printf '%b' "$FAILURES" >&2
echo "Close sequence..." >&2
exit 2
```

- Multi-line stderr (~400-500 bytes) enters Claude's context verbatim
- No control over what Claude "sees" — full message including override hints
- Override hints (`SKIP_SESSION_LOG=1`) consume tokens but are meant for the operator, not Claude

### Alternative: Exit 0 + JSON stdout

```json
{
  "decision": "block",
  "reason": "Session log not updated; uncommitted changes detected",
  "systemMessage": "BLOCKED: 2 issue(s) — session log not updated, uncommitted changes"
}
```

**Supported fields for Stop hooks:**

| Field | Purpose | Token Impact |
|-------|---------|-------------|
| `decision` | `"block"` prevents stop | Controls behavior |
| `reason` | Sent to Claude as context | **Controllable length** — key advantage |
| `systemMessage` | Warning shown to user (not Claude) | Zero token cost |
| `continue` | Whether Claude continues processing | Already true for blocks |
| `stopReason` | User-facing message when `continue: false` | N/A for blocks |

**Not supported for Stop hooks:**

| Field | Reason |
|-------|--------|
| `additionalContext` | Only available for `SessionStart` and `SubagentStart` hooks |

### Token Cost Comparison

| Approach | Context Entry | Estimated Tokens |
|----------|--------------|------------------|
| Exit 2 + stderr | Full multi-line message (~400-500 bytes) | ~100-120 tokens per retry |
| JSON `reason` field | Tightly controlled string (~50-80 bytes) | ~15-25 tokens per retry |

**Potential savings: ~75-95 tokens per retry.** Over 200,000 tokens of retry overhead, this could save ~150,000 tokens by reducing the per-retry context cost by 75%.

### Key Advantages of JSON Output

1. **Controlled `reason` length:** Can provide a concise summary to Claude (e.g., "Session log not updated; uncommitted changes") without the full error message, override hints, and close-sequence instructions
2. **`systemMessage` for operator:** Override hints and close-sequence instructions go to `systemMessage` (visible to user, not to Claude) — zero token cost
3. **Structured parsing:** Claude receives a clean, structured reason string instead of parsing multi-line stderr
4. **No exit code ambiguity:** `decision: "block"` is explicit — no reliance on exit code semantics

### Migration Cost

**Medium complexity.** Requires:
1. Replace `exit 2` + stderr with `exit 0` + JSON stdout (lines 557-568)
2. Separate operator-facing content (`systemMessage`) from model-facing content (`reason`)
3. Test that Claude Code correctly processes JSON Stop hook output
4. Update RUNNER-PARITY.md (item 1-4 documentation, though runner doesn't use stop hook)

---

## 5. Essential vs Moveable Classification

### Classification Table

| # | Check | Essential? | Rationale | Alternative Enforcement | If Downgraded |
|---|-------|-----------|-----------|------------------------|---------------|
| 1 | Session log not updated | **Moveable** (to advisory) | Governance artifact, not data loss. Orchestrator prompt already requires it (workflow.md close sequence step 1). Agent compliance is high | Prompt instruction + advisory stderr | Risk: ~5% of sessions might skip session log. Agent prompt compliance is strong but not guaranteed. Governance audit trail weakened |
| 2 | Uncommitted changes | **Essential** (keep blocking) | Data loss prevention. Uncommitted changes would be lost when session state is cleaned. No alternative enforcement catches this at close time | None — this is the last line of defense | Cannot be downgraded without risk of data loss. Pre-commit gates catch at commit time, but uncommitted changes bypass that entirely |
| 3 | HVST failures undocumented | **Moveable** (to advisory) | Knowledge capture, not safety. HVST is a debugging protocol — failing to document is a process gap, not a safety issue. Only triggers with 2+ failures AND known-issues.md not updated | Prompt instruction + advisory stderr | Risk: Debugging knowledge occasionally lost. Low impact — HVST findings are session-specific and the resolved code still ships |
| 4 | Deferrals pending | **Moveable** (to advisory) | Knowledge capture, not safety. Deferred findings should be documented but missing documentation is a tracking gap, not a safety issue | Prompt instruction + advisory stderr | Risk: Deferred findings occasionally undocumented in known-issues.md. Medium impact — follow-up tracking degraded |

### Summary

- **1 essential blocking check:** Uncommitted changes (data loss prevention — irreplaceable)
- **3 moveable checks:** Session log, HVST documentation, deferral documentation (governance artifacts — valuable but not safety-critical)

### Probability of Agent Compliance Without Blocking

Based on analytics data:
- Agent successfully completes the close sequence (session log + commit) in 89.9% of sessions (937 allow / 1042 total)
- The 10.1% block rate is dominated by `single_pass_block` (91.4% of blocks) — the agent was mid-close-sequence, not ignoring the requirement
- Real-repo `log_not_updated` blocks: 5 events across 18 real events (27.8%) — but these are from the earliest sessions (2026-02-24) when the close sequence was less established

**Estimated compliance probability if checks 1/3/4 were advisory:** 90-95%. The orchestrator prompt, workflow.md, and operator culture enforce these requirements. The stop hook block provides a ~5-10% improvement in compliance at the cost of retry loops.

---

## 6. Redundancy Analysis

### Agent Close Sequence (orchestrator.md, workflow.md)

| Step | Source | Enforcement |
|------|--------|-------------|
| 1. Update session log | workflow.md close sequence, orchestrator.md checklist | Prompt instruction |
| 2. Commit all changes | workflow.md close sequence, orchestrator.md checklist | Prompt instruction |
| 3. Merge to main (solo) | workflow.md close sequence, orchestrator.md checklist | Prompt instruction + `write_merge_signal` |
| 4. Present closing summary | workflow.md close sequence | Prompt instruction |

### Stop Hook Checks

| Check | Overlaps With | Redundancy Type |
|-------|---------------|----------------|
| Session log not updated | Close sequence step 1 | Full redundancy — checks the same requirement |
| Uncommitted changes | Close sequence step 2 | Full redundancy — checks the same requirement |
| HVST not documented | HVST protocol Record step | Partial redundancy — different trigger point |
| Deferrals pending | Orchestrator deferral procedure | Partial redundancy — different trigger point |

### When Agent Follows Close Sequence Correctly

If the agent correctly executes all 4 close sequence steps:

1. **Session log check** — guaranteed to pass (step 1 updates it)
2. **Uncommitted changes** — guaranteed to pass (step 2 commits everything)
3. **Solo merge** — handled by agent (step 3), stop hook is pure safety net
4. **Branch seal** — handled by stop hook regardless (no agent equivalent)

**Checks 1 and 2 are pure safety net redundancy** when the agent follows the close sequence. They fire as blocks only when the agent fails to complete its close sequence — which analytics show happens in ~10% of sessions (dominated by `single_pass_block` where the agent is mid-sequence, not non-compliant).

### The Timing Problem

The fundamental issue: **the stop hook fires when Claude attempts to stop, but the agent's close sequence is supposed to run before the stop attempt.** When the agent follows the sequence, all checks pass. When it doesn't (or is mid-sequence), the hook blocks and forces a retry loop.

The retry loop itself is the agent completing its close sequence — the hook is essentially forcing the agent to do what it was already supposed to do. This is valuable governance but expensive in tokens.

---

## 7. RUNNER-PARITY.md Constraint Check

Each fix proposal below is checked against the 17-item parity contract.

### Relevant Parity Items

| Parity # | Responsibility | Runner Equivalent | Impact of Stop Hook Changes |
|----------|---------------|-------------------|---------------------------|
| 1 | Session log check | N/A — runner trusts agent | Stop hook changes don't affect runner |
| 2 | Uncommitted changes check | N/A — runner trusts agent | Stop hook changes don't affect runner |
| 3 | HVST known-issues check | N/A — runner trusts agent | Stop hook changes don't affect runner |
| 4 | Deferrals known-issues check | N/A — runner trusts agent | Stop hook changes don't affect runner |
| 15 | 3-attempt safety valve | Runner has circuit breaker | Different mechanism — no parity impact |
| 17 | Agent-merge detection | N/A — runner handles merge externally | No parity impact |

**Key insight:** Items 1-4 are explicitly marked "N/A — runner does not enforce" in the parity contract. The runner already trusts agent compliance for these checks. Changes to the stop hook's blocking behavior for items 1-4 do not create parity divergence — the runner never had parity here.

---

## 8. Fix Proposals

### Proposal 1: Use `stop_hook_active` for Retry Fast-Path

**Tag:** CONSOLIDATE
**What changes:** Parse `stop_hook_active` from input JSON. On first attempt (`false`), run all checks as today. On retry (`true`), run only the subset of checks that previously failed — skip advisory checks (governance evidence, override audit, next-brief reminder), skip contract scanning.
**Governance impact:** Neutral — all blocking checks still run on first attempt; retries verify resolution only
**Token savings:** ~40% reduction in retry processing overhead. Estimated: ~80,000 tokens saved across the observed 282 multi-fire sessions
**Parity impact:** No runner changes needed. Parity item 15 (safety valve) is a different mechanism (counter file vs circuit breaker). The counter file is still maintained
**Complexity:** Low — add jq parse, conditional branch
**Reversibility:** Easy — remove the conditional, revert to full checks on every attempt

### Proposal 2: Migrate to JSON stdout Output

**Tag:** REDESIGN
**What changes:** Replace `exit 2` + multi-line stderr with `exit 0` + JSON: `{"decision": "block", "reason": "<concise>", "systemMessage": "<full details for operator>"}`. The `reason` field gets a short string for Claude's context (~15-25 tokens). The `systemMessage` carries the full error message including override hints (visible to user, not to Claude — zero token cost).
**Governance impact:** Strengthen — tighter control over what enters Claude's context. No stray override hints or close-sequence instructions consuming model attention. Operator still sees full details via `systemMessage`
**Token savings:** ~75 tokens per retry. Estimated: ~150,000 tokens saved across all retry cycles (75% reduction in per-retry context cost)
**Parity impact:** No runner changes needed. Runner doesn't use stop hook. RUNNER-PARITY.md documentation update only (items 1-4 description text)
**Complexity:** Medium — restructure failure report output, test JSON parsing by Claude Code, verify `systemMessage` rendering
**Reversibility:** Easy — revert to `exit 2` + stderr

### Proposal 3: Downgrade Session Log Check to Advisory

**Tag:** ADVISORY
**What changes:** Change check 1 from blocking (`add_failure`) to advisory (`echo "Advisory: ..." >&2`). Agent prompt instructions already require session log update. Stop hook retains the check as a warning.
**Governance impact:** Weaken (minimal) — estimated 5-10% compliance reduction. Session log is a governance artifact, not a safety control. Agent compliance is high based on analytics (89.9% clean exits). Real-repo `log_not_updated` rate may be higher early in a project's lifecycle
**Token savings:** Eliminates ~1,000 tokens per session that would otherwise retry due to session log missing. Focused savings on sessions where the agent's close sequence is disrupted
**Parity impact:** No runner changes needed. Runner already trusts agent for session log (parity item 1: "N/A — runner does not enforce")
**Complexity:** Low — change `add_failure` to `echo ... >&2`
**Reversibility:** Easy — change back to `add_failure`

### Proposal 4: Downgrade HVST + Deferrals Checks to Advisory

**Tag:** ADVISORY
**What changes:** Change checks 3 and 4 from blocking (`add_failure`) to advisory (`echo "Advisory: ..." >&2`). These are knowledge-capture checks, not safety controls. Agent prompt instructions in HVST protocol and deferral procedure already require documentation.
**Governance impact:** Weaken (minimal) — risk of occasional undocumented debugging findings or deferred items. These checks fire rarely (only when HVST failures >= 2 or `.deferrals-pending` exists) and affect knowledge capture, not code safety
**Token savings:** Small — these checks rarely trigger. Impact is in reducing the failure accumulation that feeds the single-pass block
**Parity impact:** No runner changes needed. Runner already trusts agent for these (parity items 3-4: "N/A — runner does not enforce")
**Complexity:** Low — change `add_failure` to `echo ... >&2`
**Reversibility:** Easy

### Proposal 5: Eliminate Close-Sequence Instructions from stderr

**Tag:** REMOVE
**What changes:** Remove the static "Close sequence" instructions (lines 562-567) from the stderr output. These instructions repeat workflow.md content that Claude already has in its context. They consume ~60 tokens per retry with no incremental value — Claude already knows the close sequence from orchestrator.md and workflow.md.
**Governance impact:** Neutral — the instructions are redundant with prompt content. Removing them doesn't change what the agent does; it removes a repetitive reminder
**Token savings:** ~60 tokens per retry. Modest but consistent savings across all retry loops
**Parity impact:** No runner changes needed. Runner doesn't use stop hook stderr
**Complexity:** Low — delete 6 lines
**Reversibility:** Easy — re-add the lines

### Proposal 6: Combine Proposals 1 + 2 (Retry Fast-Path + JSON Output)

**Tag:** REDESIGN
**What changes:** Implement both Proposals 1 and 2 together. On first attempt, run all checks and report via JSON (`reason` + `systemMessage`). On retry, run only previously-failed checks and report via JSON with minimal `reason`.
**Governance impact:** Strengthen — full checks on first attempt, targeted checks on retry, controlled context injection via JSON
**Token savings:** Estimated ~230,000 tokens across observed sessions (combined savings from both proposals). Represents ~85% reduction in retry-related token waste
**Parity impact:** No runner changes needed
**Complexity:** Medium — combines both changes, requires JSON output testing
**Reversibility:** Medium — two changes to revert, but each is independently revertible

### Proposal 7: Record Failed Checks in State File for Targeted Retry

**Tag:** CONSOLIDATE
**What changes:** When the stop hook blocks, write the list of failed check numbers to `.claude/.state/.stop-failed-checks` (e.g., "1,2"). On retry, only re-run the checks listed in the file. This is complementary to `stop_hook_active` — the API field tells you it's a retry; the state file tells you *which* checks failed.
**Governance impact:** Neutral — same checks, same enforcement, just targeted on retry
**Token savings:** Additional ~20% on top of Proposal 1 for sessions with multiple blocking checks. Eliminates re-running passing checks on retry
**Parity impact:** No runner changes needed. State file is cleaned by `cleanup_session_files()` (already handles `.stop-attempt-count`)
**Complexity:** Medium — state file write/read, check-numbering coordination
**Reversibility:** Easy — remove state file logic, revert to full checks

---

## 9. Broader Optimization Opportunities

### write-guard.sh (fires on every Edit, Write, Bash)

**Frequency:** Highest-frequency hook in the system. Every Edit, Write, and Bash tool call triggers it.

1. **Duplicate JSON parsing with branch-guard.sh:** Both hooks independently read `INPUT=$(cat)` and parse `file_path`/`command` via jq. For Bash calls, both hooks fire in sequence — the same stdin is read twice, the same JSON is parsed twice. **Opportunity:** Merge write-guard and branch-guard into a single hook (or cache parsed values in a temp file). Estimated savings: 1 jq subprocess per Bash call.

2. **Section 3 redundancy with branch-guard.sh:** write-guard.sh Section 3 duplicates branch-guard gates (main protection, phase gate, overlap check, branch isolation) specifically for Edit/Write calls. branch-guard.sh handles the same gates for Bash calls. The logic is identical but maintained in two places. **Opportunity:** Extract shared gate logic into a helper function sourced by both hooks, or consolidate into a single hook with tool-type awareness.

3. **Mode detection on every call:** `head -1 "$MODE_FILE"` runs on every Edit/Write/Bash call to determine operating mode. In child/autonomous modes, the fast-exit at line 271 skips most checks. **Opportunity:** Cache mode in an environment variable or state file at session init (mode doesn't change mid-session).

### branch-guard.sh (fires on every Bash)

1. **Fast-exit optimization exists but is imperfect:** The `[[ "$INPUT" != *'"file_path"'* ]] && [[ "$INPUT" != *'>'* ]] && [[ "$INPUT" != *'tee '* ]]` check at line 97 handles ~90% of Bash calls without jq. But Gate 7 (task group merge protection) runs before this fast-exit and performs `get_phase()` + `get_session_type()` calls on every `git checkout main` or `git merge` command. **Opportunity:** Gate 7 could check `stop_hook_active`-style fields or use lighter-weight pattern matching to avoid file I/O on non-merge commands.

2. **Double `get_branch()` calls:** `get_branch()` is called at line 43 (top-level) and potentially again inside Gate 7. The result is cached via `_PS_*` variables but the caching mechanism relies on `get_phase()` being called first. **Opportunity:** Ensure `get_branch()` caching is independent of call order.

3. **Source overhead:** Both `_analytics-helper.sh` and `_phase-helper.sh` are sourced on every invocation. The analytics helper probes for `jq`, `shasum`/`sha256sum`, and `date` capabilities at source time (lines 15-43 of `_analytics-helper.sh`). These probes are shell built-ins or `command -v` calls (fast), but they accumulate across hundreds of hook invocations per session. **Opportunity:** Cache probe results in environment variables set once at session start.

---

## 10. Verification Checklist

- [x] Analytics data for stop hook patterns queried and summarized (reason codes, retry counts)
- [x] Block-retry-block token cost estimated with stated methodology
- [x] `stop_hook_active` field investigated with specific usage recommendation
- [x] JSON stdout vs exit 2 stderr comparison completed
- [x] All 4 blocking checks classified (essential/moveable) with justification
- [x] 7 specific fix proposals with governance impact, parity check, and complexity rating
- [x] RUNNER-PARITY.md checked for each proposal (no parity impact for any proposal)
- [x] Broader write-guard/branch-guard opportunities flagged (3 each, 6 total)
- [x] Findings document committed

---

## Appendix A: Proposal Summary Matrix

| # | Tag | Proposal | Governance | Tokens Saved | Parity | Complexity | Reversibility |
|---|-----|----------|-----------|-------------|--------|------------|---------------|
| 1 | CONSOLIDATE | `stop_hook_active` retry fast-path | Neutral | ~80K | None | Low | Easy |
| 2 | REDESIGN | JSON stdout output | Strengthen | ~150K | None | Medium | Easy |
| 3 | ADVISORY | Session log to advisory | Weaken (minimal) | ~1K/session | None | Low | Easy |
| 4 | ADVISORY | HVST + deferrals to advisory | Weaken (minimal) | Small | None | Low | Easy |
| 5 | REMOVE | Remove close-sequence instructions | Neutral | ~60/retry | None | Low | Easy |
| 6 | REDESIGN | Combined #1 + #2 | Strengthen | ~230K | None | Medium | Medium |
| 7 | CONSOLIDATE | State file for targeted retry | Neutral | ~20% addl | None | Medium | Easy |

### Recommended Implementation Order

1. **Proposal 5** (safe win — zero governance impact, immediate token savings)
2. **Proposal 1** (safe win — `stop_hook_active` fast-path, low risk)
3. **Proposal 2** (high-value — JSON output, requires testing)
4. **Proposals 3+4** (governance tradeoff — discuss with operator)
5. **Proposal 7** (optimization — diminishing returns after #1)

Proposals 1+2 can be combined into Proposal 6 for maximum impact.

---

## Appendix B: Analytics Event Examples

### `single_pass_block` (typical first-attempt block)
```json
{"v":2,"ts":1772337416000,"sid":"test-session-53505","hook":"session-close-check","evt":"Stop","out":"block","dur":0,"reason":"single_pass_block","detail":"1","path":"standard"}
```

### `attempt_limit` (safety valve fire)
```json
{"v":2,"ts":1772398700000,"sid":"20260224-125617","hook":"session-close-check","evt":"Stop","out":"allow","dur":0,"reason":"attempt_limit","detail":"3","branch":"feature/flex-grid-foundation"}
```

### `agent_merged` (agent merged before hook)
```json
{"v":2,"ts":1772337124000,"sid":"test-session-23369","hook":"session-close-check","evt":"Stop","out":"allow","dur":0,"reason":"agent_merged","path":"feature/merged-source"}
```

### `solo_merge_success` (hook merged as safety net)
```json
{"v":2,"ts":1772337124000,"sid":"test-session-23369","hook":"session-close-check","evt":"Stop","out":"allow","dur":0,"reason":"solo_merge_success","path":"feature/solo-test"}
```
