#!/usr/bin/env bash
# State writer — captures governance agent verdicts as state files.
# Wired to SubagentStop (all agents) via .claude/settings.json.
# Only processes governance agents: critic, qa-verifier, reviewer, security-privacy, pragmatist.
# Extracts GATE_RESULT: sentinel from the last meaningful line of agent output
# (trailing blank lines and bare horizontal rules are skipped — see
# _last_meaningful_line). The report is read from .last_assistant_message, falling
# back to the SubagentHandback tool call in the subagent's transcript on harness
# builds that end subagents with a handback instead of a final message.
# Writes state files via shell I/O — never the Write tool.
# Never blocks (always exit 0) — enforcement happens at commit time.
# Phase advancement: advances phase on APPROVED results for critic and qa-verifier.
# critic APPROVED: advance review → verify. qa-verifier APPROVED: advance verify → commit.
# BLOCKED results: no phase advance (orchestrator handles loop-back).
#
# Critic routing:
#   - Combined output (both '## Cohesion Brief' and '## Diff-Review Brief' headers):
#     parse both sections, write cohesion-reviewed AND diff-review-complete from
#     one SubagentStop event. Phase advance follows the cohesion GATE_RESULT.
#   - Single cohesion mode (no diff-review header): write cohesion-reviewed.
#   - Single diff-review mode ('MODE: diff-review' sentinel): write diff-review-complete.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Read SubagentStop payload (before sourcing — cat/jq need no libraries) ---
INPUT=$(cat)

# --- Harness session_id plumbing (must precede first get_session_id call) ---
export _REPO_OS_STDIN_SID
_REPO_OS_STDIN_SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"

AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')

# --- Non-governance agent fast exit (Phase 2c — no sourcing needed) ---
# 96% of fires are non-governance agents. Exit immediately without sourcing
# libraries (~14ms saved per fire). No analytics for this path (unchanged).
case "$AGENT_TYPE" in
  critic|qa-verifier|reviewer|security-privacy|pragmatist) ;; # governance — continue below
  *) exit 0 ;;
esac

# --- Source libraries (only governance agent paths reach here) ---
source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_phase-helper.sh"
START_MS=$(now_ms)

# --- Worktree isolation guard (Decision 0028, updated by Decision 0030) ---
# Subagent worktrees: skip (verdicts reflect worktree content, not main working tree).
# Full worktree sessions (REPO_OS_SESSION_ID set): allow (independent governance lifecycle).
if is_worktree && ! is_full_worktree_session; then
  log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "skip" "$START_MS" "worktree_blocked"
  exit 0
fi

# --- Map agent type to state file (Bash 3 compatible) ---
STATE_FILE=""
case "$AGENT_TYPE" in
  critic)           STATE_FILE="cohesion-reviewed" ;;
  qa-verifier)      STATE_FILE="qa-verified" ;;
  reviewer)         STATE_FILE="reviewer-signed" ;;
  security-privacy) STATE_FILE="security-signed" ;;
  pragmatist)       STATE_FILE="pragmatist-signed" ;;
esac

# --- Extract last assistant message ---
LAST_MESSAGE=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)

# Fallback: handback-terminated subagents (2026-10-13).
# Newer harness builds end a subagent with a SubagentHandback tool call carrying
# the report in .input.message, instead of a final assistant text block. That
# leaves .last_assistant_message empty, which silently discarded EVERY governance
# verdict — the same failure class as known-issue R8, but total rather than
# formatting-dependent: three consecutive Pragmatist APPROVED verdicts were lost
# before the cause was found, and the session deadlocked (no pragmatist-signed →
# no advance out of 'plan' → writes gated → this hook uneditable).
# Recover the report from the last handback call in the subagent's own transcript.
# agent_transcript_path is the SUBAGENT's transcript; transcript_path is the parent
# session's and contains no handback tool_use entries, so the order matters —
# reading the parent first yields an empty match and looks like an absent verdict.
# Both candidates are tried in turn and the first that EXISTS wins, so a renamed
# or not-yet-created subagent transcript falls through instead of dead-ending.
# When the harness emits a normal final message this path never fires, so the fix
# is additive, not a behaviour change.
if [ -z "$LAST_MESSAGE" ]; then
  _SW_TRIED=""
  for _tp_key in agent_transcript_path transcript_path; do
    TRANSCRIPT=$(echo "$INPUT" | jq -r --arg k "$_tp_key" '.[$k] // empty' 2>/dev/null || true)
    # Record what each key yielded. TRANSCRIPT survives the loop holding only the
    # LAST key tried, so a diagnostic built after `done` would describe the parent
    # transcript — which never contains handbacks — and mislead the next reader.
    if [ -z "$TRANSCRIPT" ]; then
      _SW_TRIED="$_SW_TRIED ${_tp_key}=empty-value"
    elif [ ! -f "$TRANSCRIPT" ]; then
      _SW_TRIED="$_SW_TRIED ${_tp_key}=file-missing"
    fi
    [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || continue

    # Parsed line by line with `fromjson?`, NOT with `jq -rs`. Slurping parses the
    # whole transcript as one stream, so a single malformed line — a torn trailing
    # write while the subagent's transcript is still being flushed is the realistic
    # case — makes jq exit non-zero and loses the verdict, which is the exact
    # failure this fallback exists to prevent. `fromjson?` drops only the bad line.
    # Each match is emitted as a compact JSON string, so one handback is one output
    # line regardless of newlines in the report; tail -1 therefore takes the LAST
    # handback whole, and the final jq decodes it back to text.
    # The handback is appended to the subagent's transcript AFTER this hook is
    # invoked. Measured 2026-10-24: hook at 13:08:04, handback written at
    # 13:08:04.8 — and the file already EXISTS by then, so the -f guard above
    # passes and the extraction simply finds nothing. Reading once therefore
    # loses the verdict, and because this path writes no rejection, nothing
    # surfaces: 14 verdicts were captured on 2026-10-22 and then zero on the
    # 23rd and 24th, with only `no_message` in the event log.
    #
    # It is a race, not a contract change: 2026-10-22 recovered 11 verdicts via
    # this very path with 2 misses, and the payload key set is identical between
    # the hits and the misses.
    #
    # So poll rather than read once. Bounded at ~3s, which covers the observed
    # lag with wide margin while keeping the hook responsive; the hook already
    # spends seconds on its other work. A verdict is worth 3s, and the failure
    # being replaced is a silent governance hole — the gate it feeds reports
    # success while verifying nothing.
    # Poll ONLY the subagent's own transcript. The parent's never contains a
    # handback tool_use — that is why the keys are tried in this order — so
    # polling it would spend another ~3.8s waiting for something that cannot
    # arrive, doubling the cost of a genuine miss to ~7.6s. Read it once.
    _hb_budget=30
    [ "$_tp_key" = "agent_transcript_path" ] || _hb_budget=1
    _handback=""
    _hb_waited=0
    while [ "$_hb_waited" -lt "$_hb_budget" ]; do
      _handback=$(jq -R -c '
        fromjson?
        | (.message?.content? // [])
        | .[]?
        | select(type == "object")
        | select(.type == "tool_use" and .name == "SubagentHandback")
        | .input?.message? // empty
      ' "$TRANSCRIPT" 2>/dev/null | tail -1 || true)
      [ -n "$_handback" ] && break
      sleep 0.1
      _hb_waited=$(( _hb_waited + 1 ))
    done

    if [ -n "$_handback" ]; then
      LAST_MESSAGE=$(printf '%s' "$_handback" | jq -r '.' 2>/dev/null || true)
    fi

    if [ -n "$LAST_MESSAGE" ]; then
      log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "recover" "$START_MS" \
        "handback_transcript" "src:$_tp_key waited:${_hb_waited}x100ms"
      break
    fi
    _SW_TRIED="$_SW_TRIED ${_tp_key}=no-handback-after-${_hb_waited}x100ms"
  done
fi

if [ -z "$LAST_MESSAGE" ]; then
  # Log the payload's top-level keys so the next occurrence is self-diagnosing.
  # An agent that produced nothing and a renamed payload field look identical from
  # the outside; telling them apart previously meant reading a subagent transcript
  # by hand, which is how the handback change stayed invisible for two days.
  PAYLOAD_KEYS=$(echo "$INPUT" | jq -r 'keys | join(",")' 2>/dev/null || true)
  # Logging the key NAMES alone made four different failures indistinguishable:
  # the key absent, the key present but its value empty, the path set but the
  # file missing, and the file present but the handback not yet written. The
  # last of those is what actually happened for two days, and telling it apart
  # from the others needed a controlled probe. Record which one it was.
  _SW_DIAG="tried:${_SW_TRIED:- none}"
  echo "WARNING: $AGENT_TYPE completed with empty output — state file not written (payload keys: ${PAYLOAD_KEYS:-none}; $_SW_DIAG)" >&2
  log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "skip" "$START_MS" "no_message" "keys:${PAYLOAD_KEYS:-none} $_SW_DIAG"
  exit 0
fi

# --- Critic routing (single-mode legacy + combined dual-section) ---
# Combined output has BOTH '## Cohesion Brief' and '## Diff-Review Brief' headers
# at column 0. When detected, both state files are written from one SubagentStop
# event (see "Combined output write" block below). Single-mode dispatches remain
# valid: cohesion-only → cohesion-reviewed; 'MODE: diff-review' → diff-review-complete.
CRITIC_COMBINED=false
if [ "$AGENT_TYPE" = "critic" ]; then
  if echo "$LAST_MESSAGE" | grep -q '^## Cohesion Brief' && \
     echo "$LAST_MESSAGE" | grep -q '^## Diff-Review Brief'; then
    CRITIC_COMBINED=true
  elif echo "$LAST_MESSAGE" | grep -q '^MODE: diff-review'; then
    STATE_FILE="diff-review-complete"
  fi
fi

# --- Verdict-rejection escalation writer (shared by all rejection paths) ---
# Every path that discards an earned verdict must report it identically. Before
# 2026-09-01 only the phase-mismatch path wrote an escalation; the two formatting
# rejections logged an NDJSON 'skip' line and nothing else, so a lost review was
# indistinguishable from an agent that had not finished yet.
#
# Deliberately tolerant of unset context: this is callable from the sentinel check,
# which runs before STATE_SID, TIMESTAMP, CURRENT_PHASE, DISPATCH_PHASE,
# DISPATCH_CYCLE, EXPECTED_PHASE and PHASE_SOURCE are assigned. (STATE_FILE is
# already routed by then, so its default is belt-and-braces rather than load-bearing.)
# Every interpolation is defaulted — the script runs under `set -euo pipefail`, so an
# undefaulted unset variable here would abort the hook and lose the report entirely.
#
# NOTE: writing an escalation is necessary but NOT sufficient. Two escalations of
# exactly this kind were written during the original t-0047 work, carried real
# BLOCKED verdicts, and were never read — the sessions still recorded success. See
# .claude/.automation/briefs/20260901-state-writer-verdict-loss.md item 2, which
# remains open: a discarded verdict must eventually change an outcome, not just
# leave a file behind.
# Args: <reason-slug> <human message>
_write_verdict_rejection() {
  local _vr_reason="$1" _vr_msg="$2"
  local _vr_dir _vr_ts _vr_file
  _vr_dir="$(get_main_repo_root)/.claude/.automation/escalations"
  mkdir -p "$_vr_dir" 2>/dev/null || true
  _vr_ts=$(date -u +%Y%m%dT%H%M%SZ)
  _vr_file="$_vr_dir/verdict-rejected-${AGENT_TYPE}-${_vr_ts}.yaml"
  # Escape for double-quoted YAML scalars: agent output reaches these fields.
  _vr_msg="${_vr_msg//\\/\\\\}"; _vr_msg="${_vr_msg//\"/\\\"}"
  local _vr_ctx="reason=${_vr_reason} agent=${AGENT_TYPE} dispatch_phase=${DISPATCH_PHASE:-(none)} dispatch_cycle=${DISPATCH_CYCLE:--} expected_phase=${EXPECTED_PHASE:-(n/a)} current_phase=${CURRENT_PHASE:-(unknown)} phase_source=${PHASE_SOURCE:-(n/a)} state_file=${STATE_FILE:-(unresolved)}"
  _vr_ctx="${_vr_ctx//\\/\\\\}"; _vr_ctx="${_vr_ctx//\"/\\\"}"
  {
    printf 'escalation:\n'
    printf '  id: "esc-verdict-rejected-%s-%s"\n' "$AGENT_TYPE" "$_vr_ts"
    printf '  queue_entry_id: "%s"\n' "${STATE_SID:-unknown}"
    printf '  type: "gate-failure"\n'
    printf '  severity: "blocking"\n'
    printf '  phase_at_exit: "%s"\n' "${CURRENT_PHASE:-(unknown)}"
    printf '  tag_at_exit: "%s"\n' "$(get_tag 2>/dev/null || echo unknown)"
    printf '  message: "%s"\n' "$_vr_msg"
    printf '  context: "%s"\n' "$_vr_ctx"
    printf '  created_at: "%s"\n' "${TIMESTAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    printf '  resolved: false\n'
    printf '  resolution: ""\n'
  } > "$_vr_file" 2>/dev/null || true
}

# --- Last MEANINGFUL line of an agent message ---
# Skips trailing blank lines (as the previous `NF{line=$0}` did) and, in
# addition, trailing markdown horizontal rules: ---, ***, ___ and their spaced
# variants (- - -). Nothing else is skipped, so any prose, heading or table row
# after the sentinel still fails the check.
#
# Why this does not weaken Decision t-0039: the contract is that GATE_RESULT:
# is TERMINAL — that no further verdict content follows it. A horizontal rule
# carries no content; it is punctuation an agent naturally emits between two
# sections. Treating it as content cost seven discarded reviews across critic
# (3), qa-verifier (2) and security-privacy (2), and it is not self-correcting:
# on 2026-10-12 the critic re-emitted the identical trailing `---` on
# re-dispatch, so the brief looped until it was force-stopped. The strictness
# was rejecting well-formed verdicts, including a diff-review section that was
# correctly terminated, because the sibling section ended in punctuation.
# Interval expressions are avoided for macOS awk (BWK) compatibility.
_last_meaningful_line() {
  awk '
    { t = $0; gsub(/[ \t]/, "", t)
      if (t == "") next
      if ((t ~ /^-+$/ || t ~ /^\*+$/ || t ~ /^_+$/) && length(t) >= 3) next
      last = $0 }
    END { print last }
  '
}

# --- Extract last meaningful line ---
LAST_LINE=$(echo "$LAST_MESSAGE" | _last_meaningful_line)

# --- Check for GATE_RESULT: sentinel ---
# The terminal position of GATE_RESULT: is a deliberate contract (Decision t-0039;
# documented to the agent at critic.md:158) — a rejection here means the agent
# violated its own output contract, not that the parser is too strict. Relax only
# for content-free punctuation (see _last_meaningful_line); never for prose.
if [[ "$LAST_LINE" != GATE_RESULT:* ]]; then
  {
    printf '=== VERDICT REJECTED: %s ===\n' "$AGENT_TYPE"
    printf '  agent:   %s\n' "$AGENT_TYPE"
    printf '  reason:  no GATE_RESULT: sentinel on the final non-empty line\n'
    printf '  saw:     %s\n' "${LAST_LINE:-(empty output)}"
    printf 'NEXT: Re-dispatch %s. Its output must END with the GATE_RESULT: line —\n' "$AGENT_TYPE"
    printf '      no trailing prose, footer, or separator after it. Do NOT forge a verdict file.\n'
    printf '=== END VERDICT REJECTED ===\n'
  } >&2
  _write_verdict_rejection "no_sentinel" \
    "Verdict from $AGENT_TYPE discarded — no GATE_RESULT: sentinel on the final non-empty line (saw: ${LAST_LINE:-empty}). State file NOT written."
  log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "skip" "$START_MS" "no_sentinel"
  exit 0
fi

# --- Write state file ---
REPO_ROOT="$(get_repo_root)"
STATE_DIR="$(get_session_state_dir)"
mkdir -p "$STATE_DIR" 2>/dev/null || true

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Session-bind state file (adversarial C1/C4/H4): embed session_id so
# pre-commit-gates.sh can reject forged/stale files from other sessions.
if [ -n "${REPO_OS_SESSION_ID:-}" ]; then
  STATE_SID="$REPO_OS_SESSION_ID"
else
  STATE_SID=$(cat "$REPO_ROOT/.claude/.session-id" 2>/dev/null || echo "")
fi

# --- Resolve dispatch-time phase for this agent ---
# Dispatch phase was recorded in session-resume.yaml by pretooluse-permission.sh
# when the Agent tool was called. Validating against dispatch phase (not current
# phase) prevents false rejection when the session advances while the agent runs.
DISPATCH_RECORD=$(get_dispatch_phase "$AGENT_TYPE" 2>/dev/null || true)
DISPATCH_PHASE=""
DISPATCH_CYCLE=""
if [ -n "$DISPATCH_RECORD" ]; then
  DISPATCH_PHASE=$(echo "$DISPATCH_RECORD" | grep -oE 'phase=[^ ]+' | cut -d= -f2 || true)
  DISPATCH_CYCLE=$(echo "$DISPATCH_RECORD" | grep -oE 'cycle=[^ ]+' | cut -d= -f2 || true)
fi

# --- Phase validation (adversarial C6/H3): verify phase matches agent type ---
# Uses dispatch-time phase when available (preferred: recorded by pretooluse-permission.sh
# at Agent tool call). Falls back to current phase when no dispatch record exists
# (backward compat: sessions without dispatch recording). This fixes the race where
# the session phase advances while the agent runs, causing valid verdicts to be
# rejected against the wrong (post-advance) phase.
CURRENT_PHASE=$(get_phase)
VALIDATE_PHASE="${DISPATCH_PHASE:-$CURRENT_PHASE}"
PHASE_SOURCE="current"
[ -n "$DISPATCH_PHASE" ] && PHASE_SOURCE="dispatch"
PHASE_OK=true
# EXPECTED_PHASE records which phase THIS agent type must be dispatched from, so
# the rejection message can name it. Without this the message compared dispatch
# against current and printed neither expectation, producing lines that read as a
# self-contradiction ("dispatch=review:current=review") for what was in fact a
# correct rejection of a review-phase security-privacy dispatch that belongs in verify.
EXPECTED_PHASE=""
if [ -n "$VALIDATE_PHASE" ]; then
  case "$AGENT_TYPE" in
    critic)
      # critic writes cohesion-reviewed (cohesion mode) or diff-review-complete (diff-review mode)
      # both during the review phase — STATE_FILE is already routed correctly above
      EXPECTED_PHASE="review"
      [ "$VALIDATE_PHASE" != "review" ] && PHASE_OK=false
      ;;
    qa-verifier)
      # qa-verifier writes qa-verified during verify phase
      EXPECTED_PHASE="verify"
      [ "$VALIDATE_PHASE" != "verify" ] && PHASE_OK=false
      ;;
    reviewer|security-privacy)
      # reviewer/security-privacy write during verify phase
      EXPECTED_PHASE="verify"
      [ "$VALIDATE_PHASE" != "verify" ] && PHASE_OK=false
      ;;
    pragmatist)
      # pragmatist writes during plan, review, or build phase (background dispatch from plan may complete during build).
      # Also allowed in synthesize phase: taskdef-brief dispatches pragmatist during synthesize for the
      # approval gate — without this, the gate is unsatisfiable in that session type.
      # plan/review/build covers Prompt B (product build); synthesize covers taskdef-brief only.
      EXPECTED_PHASE="plan|review|build|synthesize"
      [ "$VALIDATE_PHASE" != "plan" ] && [ "$VALIDATE_PHASE" != "review" ] && [ "$VALIDATE_PHASE" != "build" ] && [ "$VALIDATE_PHASE" != "synthesize" ] && PHASE_OK=false
      ;;
  esac
fi
# --- Directional acceptance (Decision t-0059) ---
# A verdict dispatched at or AFTER its expected phase is accepted, with the
# discrepancy recorded. A verdict dispatched BEFORE it is still rejected.
#
# Why: between 2026-10-20 and 22, twenty verdicts were discarded on this check
# and every one was dispatched at or after its expected phase — `verify` or
# `commit` for a critic expecting `review`. Each carried GATE_RESULT: APPROVED.
# Discarding them meant the gate they fed could never be satisfied, and because
# the phase model has no backward edge from `commit`, those sessions were stuck;
# five of them lost their work when their worktrees were removed. One of them,
# the HALT-race fix, was built, tested and approved before it was destroyed.
#
# Destroying a correct verdict — and a whole session's work with it — to protect
# the provenance of a phase label is the wrong trade. The check was right to
# exist and wrong to be fatal.
#
# The direction matters and is not symmetric. An EARLY dispatch is a real
# integrity problem: a critic dispatched at `plan`, before the code exists,
# would return APPROVED on an empty diff, and the commit gates check only that
# `dispatch_phase:` is present and non-empty — never its value. Accepting that
# would make A5 satisfiable without the built code ever being reviewed. So
# earlier-than-expected stays a hard rejection, as does a verdict with no
# terminal sentinel, which is unparseable rather than merely mis-sequenced.
#
# Way back: REPO_OS_STRICT_DISPATCH_PHASE=1 restores exact-match behaviour.
_phase_index() {
  # Position of $1 in the session type's ordered phase list, or empty.
  local _pi_want="$1" _pi_seq _pi_n=0 _pi_p
  _pi_seq=$(get_phases_for_type "$(get_session_type 2>/dev/null)" 2>/dev/null || echo "")
  [ -n "$_pi_seq" ] || return 0
  for _pi_p in $_pi_seq; do
    if [ "$_pi_p" = "$_pi_want" ]; then printf '%s' "$_pi_n"; return 0; fi
    _pi_n=$((_pi_n + 1))
  done
  return 0
}

_DISPATCH_LATE=false
if [ "$PHASE_OK" = false ] && [ "${REPO_OS_STRICT_DISPATCH_PHASE:-0}" != "1" ]; then
  # Only meaningful when both phases resolve to a position in this session
  # type's sequence. An unresolvable phase falls through to rejection — fail
  # closed, since an unknown position cannot be shown to be at-or-after.
  # Index the phase the check ACTUALLY compared — VALIDATE_PHASE, which is
  # `${DISPATCH_PHASE:-$CURRENT_PHASE}`. Using DISPATCH_PHASE alone would make
  # this fall through to rejection whenever no dispatch was recorded, which is
  # precisely the case where the fallback to current phase is doing the work.
  _SW_DI=$(_phase_index "${VALIDATE_PHASE:-}")
  # EXPECTED_PHASE may be an alternation (pragmatist). Take the EARLIEST
  # acceptable position: being at or after the earliest permitted phase is what
  # "not early" means for a multi-phase expectation.
  _SW_EI=""
  for _sw_e in $(printf '%s' "${EXPECTED_PHASE:-}" | tr '|' ' '); do
    _sw_i=$(_phase_index "$_sw_e")
    if [ -n "$_sw_i" ]; then
      if [ -z "$_SW_EI" ] || [ "$_sw_i" -lt "$_SW_EI" ]; then _SW_EI="$_sw_i"; fi
    fi
  done
  if [ -n "$_SW_DI" ] && [ -n "$_SW_EI" ] && [ "$_SW_DI" -ge "$_SW_EI" ]; then
    PHASE_OK=true
    _DISPATCH_LATE=true
    echo "ADVISORY: verdict from $AGENT_TYPE was dispatched from '${DISPATCH_PHASE:-$VALIDATE_PHASE (no dispatch record; current phase used)}' but expected '${EXPECTED_PHASE}' — accepted because that is at or after the expected phase (Decision t-0059). The discrepancy is recorded in the verdict file. Dispatching review agents from their own phase remains correct; this is a safety net, not a licence." >&2
    log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "allow" "$START_MS" "phase_late_accepted:agent=${AGENT_TYPE}:dispatch=${DISPATCH_PHASE:-none}:expected=${EXPECTED_PHASE:-unknown}"
  fi
elif [ "$PHASE_OK" = false ] && [ "${REPO_OS_STRICT_DISPATCH_PHASE:-0}" = "1" ]; then
  # Argument order is (hook, env_var) — see _analytics-helper.sh. Reversing them
  # writes a transposed line into overrides.log, corrupting the audit record of
  # the one override t-0059 offers as its way out. A third argument is silently
  # dropped, so the explanatory detail belongs in the advisory below, not here.
  log_override "state-writer" "REPO_OS_STRICT_DISPATCH_PHASE" 2>/dev/null || true
  echo "ADVISORY: REPO_OS_STRICT_DISPATCH_PHASE=1 — exact dispatch-phase match enforced, t-0059 directional acceptance disabled. This reinstates the behaviour that destroyed five sessions' work on 2026-10-20/22." >&2
fi

if [ "$PHASE_OK" = false ]; then
  # --- Loud rejection: emit full context to stderr ---
  # A discarded verdict must never look like success. The dispatching agent
  # sees this on stderr and must NOT treat absence of a blocking signal as approval.
  {
    printf '=== VERDICT REJECTED: %s ===\n' "$AGENT_TYPE"
    printf '  agent:          %s\n' "$AGENT_TYPE"
    printf '  verdict:        %s\n' "$LAST_LINE"
    printf '  dispatch phase: %s (cycle %s) [from %s]\n' "${DISPATCH_PHASE:-(none recorded)}" "${DISPATCH_CYCLE:--}" "$PHASE_SOURCE"
    printf '  expected phase: %s\n' "${EXPECTED_PHASE:-(unknown)}"
    printf '  current phase:  %s\n' "${CURRENT_PHASE:-(unknown)}"
    printf '  state file:     %s (NOT written)\n' "$STATE_FILE"
    printf 'NEXT: Re-dispatch %s from %s. Do NOT forge a verdict file.\n' "$AGENT_TYPE" "${EXPECTED_PHASE:-the correct phase}"
    printf '=== END VERDICT REJECTED ===\n'
  } >&2

  # --- Write escalation file so the runner / operator can detect the loss ---
  _write_verdict_rejection "phase_mismatch" \
    "Verdict from $AGENT_TYPE discarded — phase mismatch. Dispatched from ${DISPATCH_PHASE:-(no record)} (cycle ${DISPATCH_CYCLE:--}), but this agent must be dispatched from ${EXPECTED_PHASE:-(unknown)}; arrived during ${CURRENT_PHASE:-(unknown)}. Verdict: $LAST_LINE. State file NOT written."

  log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "skip" "$START_MS" "phase_mismatch:agent=${AGENT_TYPE}:dispatch=${DISPATCH_PHASE:-none}:expected=${EXPECTED_PHASE:-unknown}:current=${CURRENT_PHASE:-unknown}"
  exit 0
fi

# --- Per-criterion verdict capture (Decision t-0048) ---
# The cohesion brief carries two independent per-criterion tables:
#   ### Contract Verification — VERIFIED|UNVERIFIED|INCONCLUSIVE, judged on diff evidence
#   ### Completeness          — COMPLETE|INCOMPLETE|PARTIAL|N/A, judged on codebase state
# Before t-0048 only the two aggregate sentinels (COMPLETENESS:, COMPLETENESS_GATE:)
# survived this hook; the per-criterion rows lived and died in the agent transcript,
# so a consumer that needed to show WHICH criterion failed had nothing to bind to.
#
# Both tables are captured and kept separate, never merged: a criterion can be
# UNVERIFIED in the diff yet COMPLETE in the codebase (it was already satisfied
# before this session touched anything), and that divergence is signal rather than
# contradiction.
#
# ADVISORY ONLY — deliberately not gate-bearing. A parse miss degrades the sidecar;
# it never blocks a commit. COMPLETENESS_GATE remains the sole enforcement signal.
# Every write is best-effort so a malformed brief cannot abort the hook under
# `set -euo pipefail` and cost the session its real verdict files.
# Args: <cohesion message text>
_capture_criteria_verdicts() {
  local _cv_text="$1"
  local _cv_rows _cv_score _cv_gate _cv_durable_dir _cv_durable _cv_round _cv_lock

  if ! echo "$_cv_text" | grep -q '^### Contract Verification' && \
     ! echo "$_cv_text" | grep -q '^### Completeness'; then
    return 0
  fi

  # Parse both tables in one pass, keyed by each criterion's ordinal within its
  # section. Emits pre-escaped YAML list items on stdout.
  _cv_rows=$(echo "$_cv_text" | awk '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    # Anchor on the trailing VERDICT token rather than on the "text — VERDICT"
    # separator: criterion text routinely contains dashes, and the separator is an
    # em dash whose substr() width differs between byte- and character-oriented
    # awk builds. The verdict vocabulary is closed, so matching it is exact.
    # INCOMPLETE precedes COMPLETE in the alternation and the required leading
    # space keeps "INCOMPLETE" from matching as "...IN" + "COMPLETE".
    function split_row(line,   txt, vrd) {
      sub(/^[0-9]+\.[ \t]*/, "", line)
      sub(/[ \t]+$/, "", line)
      vrd = ""
      if (match(line, /[ \t](VERIFIED|UNVERIFIED|INCONCLUSIVE|INCOMPLETE|COMPLETE|PARTIAL|N\/A)$/)) {
        vrd = substr(line, RSTART + 1)
        txt = substr(line, 1, RSTART - 1)
      } else {
        txt = line
      }
      sub(/[ \t]*[-—]+[ \t]*$/, "", txt)
      sub(/[ \t]+$/, "", txt)
      CRIT = txt; VERD = vrd
    }
    /^### Contract Verification/ { sec = "cv"; cur = 0; next }
    /^### Completeness/          { sec = "cp"; cur = 0; next }
    /^#+ /                       { sec = ""; cur = 0; next }
    /^COMPLETENESS(_GATE)?: /    { sec = ""; cur = 0; next }
    sec != "" && /^[0-9]+\./ {
      idx = $0 + 0
      split_row($0)
      if (idx > max) max = idx
      if (text[idx] == "") text[idx] = CRIT
      if (sec == "cv") cvv[idx] = VERD; else cpv[idx] = VERD
      cur = idx; cursec = sec
      next
    }
    sec != "" && cur > 0 && /^[ \t]*-[ \t]*Evidence:/ {
      e = $0
      sub(/^[ \t]*-[ \t]*Evidence:[ \t]*/, "", e)
      sub(/[ \t]+$/, "", e)
      if (cursec == "cv") cve[cur] = e; else cpe[cur] = e
      next
    }
    END {
      for (i = 1; i <= max; i++) {
        if (text[i] == "" && cvv[i] == "" && cpv[i] == "") continue
        printf "  - index: %d\n", i
        printf "    criterion: \"%s\"\n", esc(text[i])
        printf "    contract_verification:\n"
        printf "      verdict: %s\n", (cvv[i] == "" ? "ABSENT" : cvv[i])
        printf "      evidence: \"%s\"\n", esc(cve[i])
        printf "    completeness:\n"
        printf "      verdict: %s\n", (cpv[i] == "" ? "ABSENT" : cpv[i])
        printf "      evidence: \"%s\"\n", esc(cpe[i])
      }
    }
  ' 2>/dev/null || true)

  [ -n "$_cv_rows" ] || return 0

  _cv_score=$(echo "$_cv_text" | grep -E '^COMPLETENESS: ' | tail -1 | sed 's/^COMPLETENESS: *//' || true)
  _cv_gate=$(echo "$_cv_text" | grep -E '^COMPLETENESS_GATE: ' | tail -1 | sed 's/^COMPLETENESS_GATE: *//' || true)
  _cv_score="${_cv_score//\\/\\\\}"; _cv_score="${_cv_score//\"/\\\"}"

  # --- Live sidecar: latest dispatch only, session-scoped, cleaned at close ---
  {
    printf 'schema: repo-os/criteria-verdicts@1\n'
    printf 'timestamp: "%s"\n' "$TIMESTAMP"
    # Unquoted, matching every other state file: _cleanup-helper.sh::_delete_if_owned
    # strips the `session_id: ` prefix but not surrounding quotes, so a quoted value
    # would never equal the closing sid and the sidecar would survive session close.
    printf 'session_id: %s\n' "$STATE_SID"
    printf 'agent: critic\n'
    printf 'dispatch_phase: "%s"\n' "${DISPATCH_PHASE:-${CURRENT_PHASE:-unknown}}"
    printf 'dispatch_cycle: %s\n' "${DISPATCH_CYCLE:-1}"
    printf 'completeness_score: "%s"\n' "$_cv_score"
    printf 'completeness_gate: %s\n' "${_cv_gate:-ABSENT}"
    printf 'criteria:\n'
    printf '%s\n' "$_cv_rows"
  } > "$STATE_DIR/criteria-verdicts.yaml" 2>/dev/null || true

  # --- Durable artifact: one file per session, one block per Critic dispatch ---
  # Remediation re-dispatches Critic, so rounds accumulate rather than overwrite.
  # That append is what makes the round-over-round view (a criterion going
  # INCOMPLETE -> COMPLETE) reconstructable after the state dir is cleaned at close.
  _cv_durable_dir="$(get_main_repo_root)/docs/ai/governance/criteria-verdicts"
  mkdir -p "$_cv_durable_dir" 2>/dev/null || true
  _cv_durable="$_cv_durable_dir/${STATE_SID}.yaml"

  # Counting existing rounds and appending the next one are two steps; without a
  # lock two overlapping dispatches can read the same count and both append a
  # `round: N`, or interleave partial writes. Same read-modify-append hazard
  # `record_closed_branch()` in _cleanup-helper.sh guards, so reuse its pattern.
  _cv_append_round() {
    if [ ! -f "$_cv_durable" ]; then
      {
        printf 'schema: repo-os/criteria-verdicts@1\n'
        printf 'session_id: "%s"\n' "$STATE_SID"
        printf 'rounds:\n'
      } > "$_cv_durable" 2>/dev/null || true
      _cv_round=1
    else
      _cv_round=$(( $(grep -c '^  - round: ' "$_cv_durable" 2>/dev/null || echo 0) + 1 ))
    fi
    {
      printf '  - round: %s\n' "$_cv_round"
      printf '    timestamp: "%s"\n' "$TIMESTAMP"
      printf '    dispatch_phase: "%s"\n' "${DISPATCH_PHASE:-${CURRENT_PHASE:-unknown}}"
      printf '    dispatch_cycle: %s\n' "${DISPATCH_CYCLE:-1}"
      printf '    completeness_score: "%s"\n' "$_cv_score"
      printf '    completeness_gate: %s\n' "${_cv_gate:-ABSENT}"
      printf '    criteria:\n'
      printf '%s\n' "$_cv_rows" | sed 's/^/    /'
    } >> "$_cv_durable" 2>/dev/null || true
  }

  _cv_lock="$(get_main_repo_root)/.claude/.state/.criteria-verdicts-lock"
  mkdir -p "$(dirname "$_cv_lock")" 2>/dev/null || true
  if command -v flock > /dev/null 2>&1; then
    (
      flock -w 5 9 2>/dev/null || true
      _cv_append_round
    ) 9>"$_cv_lock"
  else
    # No flock — best-effort, matching record_closed_branch()'s fallback.
    _cv_append_round
  fi
}

# --- Combined output write (critic dual-section) ---
# When CRITIC_COMBINED=true, split LAST_MESSAGE at the '## Diff-Review Brief'
# header, validate each section ends with GATE_RESULT, and write both
# cohesion-reviewed and diff-review-complete from this single SubagentStop
# event. Single-mode output falls through to the standard single-file write below.
if [ "$CRITIC_COMBINED" = true ]; then
  COHESION_PART=$(echo "$LAST_MESSAGE" | awk '/^## Diff-Review Brief/{exit} {print}')
  DIFF_REVIEW_PART=$(echo "$LAST_MESSAGE" | awk '/^## Diff-Review Brief/{found=1} found{print}')
  COHESION_LAST=$(echo "$COHESION_PART" | _last_meaningful_line)
  DIFF_REVIEW_LAST=$(echo "$DIFF_REVIEW_PART" | _last_meaningful_line)

  if [[ "$COHESION_LAST" != GATE_RESULT:* ]] || [[ "$DIFF_REVIEW_LAST" != GATE_RESULT:* ]]; then
    # Per Decision t-0039 each section must terminate with its own GATE_RESULT:.
    # Trailing PROSE between the sections makes the cohesion half's last
    # meaningful line something else, and BOTH verdicts are discarded. A bare
    # horizontal rule no longer counts — see _last_meaningful_line. This is the
    # exact failure that looped a brief to death on 2026-10-12.
    {
      printf '=== VERDICT REJECTED: %s (combined) ===\n' "$AGENT_TYPE"
      printf '  cohesion section ends with:    %s\n' "${COHESION_LAST:-(empty)}"
      printf '  diff-review section ends with: %s\n' "${DIFF_REVIEW_LAST:-(empty)}"
      printf 'NEXT: Re-dispatch. Each section must END with its own GATE_RESULT: line —\n'
      printf '      nothing between the cohesion GATE_RESULT: and the Diff-Review header,\n'
      printf '      and nothing after the final GATE_RESULT:. Do NOT forge a verdict file.\n'
      printf '=== END VERDICT REJECTED ===\n'
    } >&2
    _write_verdict_rejection "combined_no_sentinel" \
      "Both verdicts from $AGENT_TYPE discarded — combined output missing a terminal GATE_RESULT: in one or both sections (cohesion ended with: ${COHESION_LAST:-empty}; diff-review ended with: ${DIFF_REVIEW_LAST:-empty}). Neither state file written."
    log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "skip" "$START_MS" "combined_no_sentinel"
    exit 0
  fi

  # See the single-mode write below for why the discrepancy is recorded here.
  _DISPATCH_NOTE=""
  if [ "${_DISPATCH_LATE:-false}" = true ]; then
    _DISPATCH_NOTE="dispatch_phase_discrepancy: dispatched from ${DISPATCH_PHASE:-$VALIDATE_PHASE}, expected ${EXPECTED_PHASE:-unknown} — accepted as at-or-after (t-0059)
"
  fi

  printf 'timestamp: %s\nagent: %s\nsession_id: %s\ndispatch_phase: %s\n%s%s\n' \
    "$TIMESTAMP" "$AGENT_TYPE" "$STATE_SID" "${DISPATCH_PHASE:-$CURRENT_PHASE}" "$_DISPATCH_NOTE" "$COHESION_LAST" \
    > "$STATE_DIR/cohesion-reviewed" 2>/dev/null || true

  COMBINED_COMPLETENESS_LINE=$(echo "$COHESION_PART" | grep -E '^COMPLETENESS: ' | tail -1 || true)
  COMBINED_COMPLETENESS_GATE_LINE=$(echo "$COHESION_PART" | grep -E '^COMPLETENESS_GATE: ' | tail -1 || true)
  if [ -n "$COMBINED_COMPLETENESS_LINE" ]; then
    printf '%s\n' "$COMBINED_COMPLETENESS_LINE" >> "$STATE_DIR/cohesion-reviewed" 2>/dev/null || true
  fi
  if [ -n "$COMBINED_COMPLETENESS_GATE_LINE" ]; then
    printf '%s\n' "$COMBINED_COMPLETENESS_GATE_LINE" >> "$STATE_DIR/cohesion-reviewed" 2>/dev/null || true
  fi

  _capture_criteria_verdicts "$COHESION_PART"

  printf 'timestamp: %s\nagent: %s\nsession_id: %s\ndispatch_phase: %s\n%s%s\n' \
    "$TIMESTAMP" "$AGENT_TYPE" "$STATE_SID" "${DISPATCH_PHASE:-$CURRENT_PHASE}" "$_DISPATCH_NOTE" "$DIFF_REVIEW_LAST" \
    > "$STATE_DIR/diff-review-complete" 2>/dev/null || true

  COHESION_GATE_VALUE=$(echo "$COHESION_LAST" | sed 's/^GATE_RESULT: *//' | awk '{print $1}')
  if [ -n "$(get_phase)" ] && [ "$COHESION_GATE_VALUE" = "APPROVED" ]; then
    advance_phase "verify" 2>/dev/null || true
  fi

  refresh_manifest_entry "cohesion-reviewed" 2>/dev/null || true
  refresh_manifest_entry "diff-review-complete" 2>/dev/null || true
  COMBINED_DETAIL=$(printf 'cohesion=%.20s diff=%.20s' "$COHESION_LAST" "$DIFF_REVIEW_LAST" | tr -d '\n' | cut -c1-64)
  log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "write" "$START_MS" "cohesion-reviewed+diff-review-complete" "$COMBINED_DETAIL"
  exit 0
fi

# Discrepancy record (t-0059). Written into the verdict file itself, not only
# to stderr, so a later reader of the evidence can see the verdict was accepted
# out of sequence. Empty for the normal case, so the file shape is unchanged.
_DISPATCH_NOTE=""
if [ "${_DISPATCH_LATE:-false}" = true ]; then
  _DISPATCH_NOTE="dispatch_phase_discrepancy: dispatched from ${DISPATCH_PHASE:-$VALIDATE_PHASE}, expected ${EXPECTED_PHASE:-unknown} — accepted as at-or-after (t-0059)
"
fi

printf 'timestamp: %s\nagent: %s\nsession_id: %s\ndispatch_phase: %s\n%s%s\n' \
  "$TIMESTAMP" "$AGENT_TYPE" "$STATE_SID" "${DISPATCH_PHASE:-$CURRENT_PHASE}" "$_DISPATCH_NOTE" "$LAST_LINE" \
  > "$STATE_DIR/$STATE_FILE" 2>/dev/null || true

# --- Completeness capture (critic cohesion mode only) ---
# Appends COMPLETENESS: score and COMPLETENESS_GATE: verdict to cohesion-reviewed state file.
# COMPLETENESS_GATE: APPROVED|NEEDS_WORK is the downstream blocking signal read by
# outcome-detector.sh, pre-commit-gates.sh, and session-close-check.sh.
# Distinct from GATE_RESULT (cohesion verdict — always the last non-empty line).
# Skip for diff-review mode: diff-review-complete does not use completeness scoring.
if [ "$AGENT_TYPE" = "critic" ] && [ "$STATE_FILE" = "cohesion-reviewed" ]; then
  COMPLETENESS_LINE=$(echo "$LAST_MESSAGE" | grep -E '^COMPLETENESS: ' | tail -1 || true)
  COMPLETENESS_GATE_LINE=$(echo "$LAST_MESSAGE" | grep -E '^COMPLETENESS_GATE: ' | tail -1 || true)
  if [ -n "$COMPLETENESS_LINE" ]; then
    printf '%s\n' "$COMPLETENESS_LINE" >> "$STATE_DIR/$STATE_FILE" 2>/dev/null || true
  fi
  if [ -n "$COMPLETENESS_GATE_LINE" ]; then
    printf '%s\n' "$COMPLETENESS_GATE_LINE" >> "$STATE_DIR/$STATE_FILE" 2>/dev/null || true
  fi

  _capture_criteria_verdicts "$LAST_MESSAGE"
fi

# --- Phase advancement based on agent verdict ---
# Only advance on APPROVED results (BLOCKED loops back to build via orchestrator).
# Fail-silent: if phase-state absent, skip advancement.
GATE_VALUE=$(echo "$LAST_LINE" | sed 's/^GATE_RESULT: *//' | awk '{print $1}')

if [ -n "$(get_phase)" ]; then
  case "$AGENT_TYPE" in
    critic)
      # critic cohesion mode (cohesion-reviewed): advance review → verify on APPROVED only
      # critic diff-review mode (diff-review-complete): no phase advancement
      # (cohesion-reviewed is the primary phase gate; diff-review is a parallel check)
      if [ "$STATE_FILE" = "cohesion-reviewed" ] && [ "$GATE_VALUE" = "APPROVED" ]; then
        advance_phase "verify" 2>/dev/null || true
      fi
      ;;
    qa-verifier)
      # qa-verifier (qa-verified): advance verify → commit on APPROVED only
      if [ "$GATE_VALUE" = "APPROVED" ]; then
        advance_phase "commit" 2>/dev/null || true
      fi
      ;;
    # reviewer, security-privacy: no phase advancement (sub-steps within verify)
  esac
fi

# Capture GATE_RESULT value for analytics (truncate to 64 chars)
refresh_manifest_entry "$STATE_FILE" 2>/dev/null || true
GATE_RESULT_DETAIL=$(printf '%.64s' "$LAST_LINE")
log_hook_event "state-writer" "SubagentStop" "$AGENT_TYPE" "write" "$START_MS" "$STATE_FILE" "$GATE_RESULT_DETAIL"
exit 0
