#!/usr/bin/env bash
# Eval state file writer — writes cohesion-reviewed, diff-review-complete, qa-verified
# after verified Critic (APPROVED) and QA (APPROVED) runs in worktree eval sessions.
# Sourced via: source .claude/.automation/lib/eval-state-writer.sh
# Then called:  eval_write_review_state "$state_dir"
# Decision t-0046 Amendment 1.
eval_write_review_state() {
  local state_dir="$1"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$state_dir"
  printf 'GATE_RESULT: APPROVED\ntimestamp: %s\nmode: cohesion\n' "$ts" > "$state_dir/cohesion-reviewed"
  printf 'GATE_RESULT: APPROVED\ntimestamp: %s\nmode: diff-review\n' "$ts" > "$state_dir/diff-review-complete"
  printf 'GATE_RESULT: APPROVED\ntimestamp: %s\n' "$ts" > "$state_dir/qa-verified"
}
