#!/usr/bin/env bash
# Question channel — headless AskUserQuestion records and answers (Decision t-0064).
# Sourced by .claude/hooks/ask-user-deny.sh, runner.sh and queue-cli.sh. NOT executed standalone.
#
# Every function takes the automation directory (the MAIN repo's
# .claude/.automation) as its first argument, so the hook, the runner and the
# tests each point it at their own tree. Files live in <automation_dir>/questions/.
#
# File format (format_version 1) is a published contract — see Decision t-0064 § 5,
# amended by Decision t-0068:
#   q-<id>.payload.json  PreToolUse stdin, byte for byte (hook)
#   q-<id>.yaml          question record (hook)
#   q-<id>.answer.yaml   answer (operator interface; an external writer must
#                        write a temporary name and rename it into place;
#                        queue-cli.sh answer uses qc_write_answer, which links
#                        instead so the first writer wins)
#   q-<id>.closed        close marker (hook or runner), reason:
#                          parked        no answer in the live wait; the entry is
#                                        stopped on the question and an answer
#                                        written later resumes it (still answerable)
#                          agent-decided no answer; question_on_timeout: agent-decides
#                                        told the agent to choose and continue
#                          abandoned     the session ended during the live wait
#                        `expired` (t-0064) is no longer written; readers must
#                        still accept it in records written before t-0068.
#
# Every function returns non-zero instead of exiting: callers run under
# `set -euo pipefail` and an unreadable or malformed file must never abort them.
# bash 3.2 / git 2.5 floor: no associative arrays, no mapfile, no timeout.

QC_FORMAT_VERSION=1

# --- Directory for question files ---
qc_dir() {
  printf '%s/questions' "$1"
}

# --- Integer config field with default ---
# Mirrors queue-manager.sh _parse_config_field (config.local.yaml first, then
# config.yaml, `runner:` block) without depending on it: the hook does not
# source the queue libraries. A missing, empty or non-numeric value yields
# the default.
# Arguments: $1 automation dir, $2 field, $3 default
qc_config_int() {
  local adir="$1" field="$2" def="$3" value="" f
  for f in "$adir/config.local.yaml" "$adir/config.yaml"; do
    [ -f "$f" ] || continue
    value=$(sed -n "/^runner:/,/^[a-z]/{ /^  ${field}:/p; }" "$f" 2>/dev/null \
      | sed "s/.*${field}: *//" | tr -d '[:space:]' | head -1) || value=""
    [ -n "$value" ] && break
  done
  case "$value" in
    ''|*[!0-9]*) printf '%s' "$def" ;;
    *) printf '%s' "$value" ;;
  esac
}

# --- What an unanswered question does (Decision t-0068) ---
# `pause` (default) parks the entry on the question; `agent-decides` tells the
# agent to choose and continue. Absent, empty or any other value -> pause: an
# unreadable setting must never turn into "carry on without the operator".
qc_on_timeout() {
  local adir="$1" value="" f
  for f in "$adir/config.local.yaml" "$adir/config.yaml"; do
    [ -f "$f" ] || continue
    value=$(sed -n "/^runner:/,/^[a-z]/{ /^  question_on_timeout:/p; }" "$f" 2>/dev/null \
      | sed 's/.*question_on_timeout: *//; s/^"//; s/"[[:space:]]*$//' | tr -d '[:space:]' | head -1) || value=""
    [ -n "$value" ] && break
  done
  case "$value" in
    agent-decides) printf 'agent-decides' ;;
    *) printf 'pause' ;;
  esac
}

# --- Effective wait in seconds ---
# min(question_timeout_seconds, question_hook_timeout_seconds - 30), never < 0.
# The margin keeps the hook ahead of Claude Code's own hook timeout, which
# fails OPEN on PreToolUse (Decision t-0064 § 2). The default is 1800 since
# Decision t-0068: the live wait is now only the window before the entry parks.
qc_effective_timeout() {
  local adir="$1" qt ht cap
  qt=$(qc_config_int "$adir" question_timeout_seconds 1800)
  ht=$(qc_config_int "$adir" question_hook_timeout_seconds 600)
  cap=$((ht - 30))
  [ "$cap" -lt 0 ] && cap=0
  [ "$qt" -gt "$cap" ] && qt=$cap
  printf '%s' "$qt"
}

# --- Allocate the next question id ---
# Monotonic sequence in questions/.seq. Uniqueness does NOT rest on the lock:
# an id is CLAIMED by creating its payload file with noclobber (O_EXCL), which
# exactly one process can win, and an id that already has any file (a stale
# answer or close marker left after .seq was lost) is skipped. The mkdir lock
# only keeps the counter from going backwards under contention; a lock older
# than 30s is taken as left by a killed writer and removed once.
# Output: q-NNNNNN (its payload file now exists, empty). Returns 1 when the
# directory is not writable or no id can be claimed.
qc_next_id() {
  local qdir lock seq n=0 mtime now stale_removed="" locked=false id tries=0
  qdir=$(qc_dir "$1")
  mkdir -p "$qdir" 2>/dev/null || return 1
  # Not writable: waiting cannot fix that, and spinning would outlast the
  # hook timeout (which fails open).
  [ -w "$qdir" ] || return 1
  lock="$qdir/.seq.lock"
  while :; do
    if mkdir "$lock" 2>/dev/null; then locked=true; break; fi
    n=$((n + 1))
    if [ "$n" -gt 100 ]; then
      # Lock gone between attempts, or never creatable: proceed unlocked —
      # the O_EXCL claim below still guarantees a unique id.
      [ -d "$lock" ] || break
      mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "")
      now=$(date +%s)
      case "$mtime" in ''|*[!0-9]*) break ;; esac
      if [ $((now - mtime)) -gt 30 ] && [ -z "$stale_removed" ]; then
        rmdir "$lock" 2>/dev/null || true
        stale_removed=1
        n=0
        continue
      fi
      break
    fi
    sleep 0.1
  done

  seq=$(cat "$qdir/.seq" 2>/dev/null | tr -d '[:space:]') || seq=""
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  # 10#: leading zeros must not be read as octal.
  seq=$(( 10#$seq ))
  while [ "$tries" -lt 1000 ]; do
    tries=$((tries + 1))
    seq=$((seq + 1))
    id=$(printf 'q-%06d' "$seq")
    if [ -e "$qdir/${id}.yaml" ] || [ -e "$qdir/${id}.answer.yaml" ] || [ -e "$qdir/${id}.closed" ]; then
      continue
    fi
    if ( set -C; : > "$qdir/${id}.payload.json" ) 2>/dev/null; then
      { printf '%s\n' "$seq" > "$qdir/.seq.tmp.$$" && mv "$qdir/.seq.tmp.$$" "$qdir/.seq"; } 2>/dev/null \
        || rm -f "$qdir/.seq.tmp.$$" 2>/dev/null || true
      [ "$locked" = true ] && { rmdir "$lock" 2>/dev/null || true; }
      printf '%s' "$id"
      return 0
    fi
  done
  [ "$locked" = true ] && { rmdir "$lock" 2>/dev/null || true; }
  return 1
}

# --- Write the question record ---
# Arguments: $1 automation dir, $2 question id, $3 payload file (raw stdin),
#   $4 session id, $5 entry id, $6 phase, $7 deadline epoch
# Returns 1 when either file cannot be written.
qc_write_question() {
  local adir="$1" id="$2" payload="$3" sid="$4" entry="$5" phase="$6" deadline="$7"
  local qdir tmp parsed=false body=""
  qdir=$(qc_dir "$adir")
  mkdir -p "$qdir" 2>/dev/null || return 1

  # Payload first, byte for byte: it is the authoritative copy.
  tmp="$qdir/.${id}.payload.tmp.$$"
  if ! { cp "$payload" "$tmp" && mv "$tmp" "$qdir/${id}.payload.json"; } 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi

  if command -v jq >/dev/null 2>&1; then
    # tojson emits a double-quoted JSON string, which is also a valid YAML scalar.
    if body=$(jq -r '
        (.tool_input.questions // []) as $qs
        | if ($qs | length) == 0 then "questions: []"
          else
            "questions:",
            ($qs | to_entries[]
              | "  - index: \(.key)",
                "    question: \(.value.question // "" | tojson)",
                "    header: \(.value.header // "" | tojson)",
                "    multi_select: \(.value.multiSelect // false | tojson)",
                (if ((.value.options // []) | length) == 0 then "    options: []"
                 else
                   "    options:",
                   ((.value.options // [])[]
                     | "      - label: \(.label // "" | tojson)",
                       "        description: \(.description // "" | tojson)")
                 end))
          end' "$payload" 2>/dev/null); then
      parsed=true
    else
      body=""
    fi
  fi

  tmp="$qdir/.${id}.yaml.tmp.$$"
  if ! {
    printf 'format_version: %s\n' "$QC_FORMAT_VERSION"
    printf 'question_id: "%s"\n' "$id"
    printf 'session_id: "%s"\n' "$sid"
    printf 'entry_id: "%s"\n' "$entry"
    printf 'phase: "%s"\n' "$phase"
    printf 'created_at: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'created_epoch: %s\n' "$(date +%s)"
    printf 'deadline_epoch: %s\n' "$deadline"
    printf 'parsed: %s\n' "$parsed"
    [ -n "$body" ] && printf '%s\n' "$body"
    true
  } > "$tmp" 2>/dev/null || ! mv "$tmp" "$qdir/${id}.yaml" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

# --- Read a valid answer ---
# Prints one line per answered question:
#   question N: selected "A", "B"; free text "..."
# with the operator's strings exactly as written in the file. Returns 1 for
# no answer: file absent, wrong format_version, wrong question_id, no answers
# block, or nothing selected and no free text in it.
qc_read_answer() {
  _qc_read_answer_file "$(qc_dir "$1")/${2}.answer.yaml" "$2"
}

# Arguments: $1 answer file, $2 question id it must name
_qc_read_answer_file() {
  local f="$1" id="$2"
  [ -f "$f" ] || return 1
  grep -q "^format_version: ${QC_FORMAT_VERSION}[[:space:]]*\$" "$f" 2>/dev/null || return 1
  grep -q "^question_id: \"${id}\"[[:space:]]*\$" "$f" 2>/dev/null || return 1
  grep -q '^answers:' "$f" 2>/dev/null || return 1
  grep -q '^  - question_index:' "$f" 2>/dev/null || return 1
  grep -Eq '^      - .+|^    free_text: "[^"]|^    selected: \[.+\]' "$f" 2>/dev/null || return 1
  awk '
    function flush() {
      printf "question %d: selected %s; free text %s\n", qi + 1, (sel == "" ? "(none)" : sel), (ft == "" ? "(none)" : ft)
    }
    /^  - question_index:/ {
      if (n) flush()
      n = 1; qi = $0; sub(/^  - question_index: */, "", qi); sel = ""; ft = ""; insel = 0; next
    }
    /^    selected:/ {
      insel = 1; v = $0; sub(/^    selected: */, "", v)
      if (v != "" && v != "[]") sel = v
      next
    }
    /^      - / && insel {
      v = $0; sub(/^      - /, "", v); sel = (sel == "" ? v : sel ", " v); next
    }
    /^    free_text:/ { insel = 0; v = $0; sub(/^    free_text: */, "", v); ft = v; next }
    { insel = 0 }
    END { if (n) flush() }
  ' "$f" 2>/dev/null || return 1
}

# --- Write an answer (operator interface, Decision t-0068 § 3) ---
# Validates $3 as an answer to $2 BEFORE it becomes visible, then publishes it
# from a private temporary file with a hard link, so a hook polling the live
# wait never reads a half-written or invalid file. Never replaces an existing
# q-<id>.answer.yaml, valid or not: a valid one may already have been
# delivered, and an invalid one is the operator's to inspect and remove.
# Returns 1 when the question has no record or the write fails, 2 when $3 is
# not a valid answer to $2, 3 when an answer file already exists.
# Arguments: $1 automation dir, $2 question id, $3 answer file to publish
qc_write_answer() {
  local adir="$1" id="$2" src="$3" qdir tmp
  qdir=$(qc_dir "$adir")
  [ -f "$qdir/${id}.yaml" ] || return 1
  [ -e "$qdir/${id}.answer.yaml" ] || [ -L "$qdir/${id}.answer.yaml" ] && return 3
  # mktemp: a random name created O_EXCL. The directory is writable by the
  # session that asked, so a predictable name could be a planted symlink and
  # cp would write through it.
  tmp=$(mktemp "$qdir/.${id}.answer.XXXXXX" 2>/dev/null) || return 1
  cp "$src" "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  if ! _qc_read_answer_file "$tmp" "$id" >/dev/null 2>&1; then
    rm -f "$tmp" 2>/dev/null || true
    return 2
  fi
  # ln, not mv: a hard link fails if the target exists, so of two concurrent
  # writers exactly one publishes and an answer is never replaced.
  if ! ln "$tmp" "$qdir/${id}.answer.yaml" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 3
  fi
  rm -f "$tmp" 2>/dev/null || true
}

# --- The answer as the agent receives it ---
# One wording for the live wait (hook) and a resume (runner), so the agent
# cannot tell a late answer from a prompt one (Decision t-0068 § 3).
# Arguments: $1 question id, $2 the qc_read_answer output
qc_answer_message() {
  printf 'OPERATOR ANSWER to %s (AskUserQuestion is answered through the question channel in headless mode; the tool itself does not run):\n%s\nContinue the task using this answer.\n' "$1" "$2"
}

# --- question_id named by a control/<entry>/resume.yaml (empty if none) ---
qc_resume_question_id() {
  sed -n 's/^question_id: *//p' "$1" 2>/dev/null | head -1 | sed 's/^"//; s/"$//'
}

# --- Build an answer file from free-text answers ---
# One text per question, in question order (question_index 0, 1, ...). Each is
# written as free_text with backslashes and double quotes escaped and every
# line break flattened to a space, so the line stays one YAML scalar.
# Arguments: $1 question id, $2 operator, $3.. texts. Prints the YAML.
qc_text_answer() {
  local id="$1" op="$2" i=0 t
  shift 2
  printf 'format_version: %s\nquestion_id: "%s"\noperator: "%s"\nanswered_at: "%s"\nanswers:\n' \
    "$QC_FORMAT_VERSION" "$id" "$(_qc_yaml_str "$op")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for t in "$@"; do
    printf '  - question_index: %d\n    selected: []\n    free_text: "%s"\n' "$i" "$(_qc_yaml_str "$t")"
    i=$((i + 1))
  done
}

# Escape for a double-quoted YAML scalar on one line.
_qc_yaml_str() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# --- Number of questions in a record (0 when unparsed) ---
qc_question_count() {
  grep -c '^  - index:' "$(qc_dir "$1")/${2}.yaml" 2>/dev/null || true
}

# --- One-line summary of a question record ---
# `1) <question> [<label> | <label>]; 2) ...`, for an escalation message. Quotes
# and backslashes are dropped so the result can sit inside a quoted scalar.
qc_question_summary() {
  local f
  f="$(qc_dir "$1")/${2}.yaml"
  [ -f "$f" ] || return 1
  awk '
    function unq(s) { sub(/^"/, "", s); sub(/"$/, "", s); gsub(/\\"/, "\047", s); gsub(/["\\]/, "", s); return s }
    function flush() { if (q != "") { out = out (out == "" ? "" : "; ") n ") " q (opts == "" ? "" : " [" opts "]") } }
    /^  - index:/ { flush(); n++; q = ""; opts = ""; next }
    /^    question:/ { v = $0; sub(/^    question: */, "", v); q = unq(v); next }
    /^      - label:/ { v = $0; sub(/^      - label: */, "", v); opts = (opts == "" ? unq(v) : opts " | " unq(v)); next }
    END { flush(); printf "%s", out }
  ' "$f" 2>/dev/null
}

# --- Close reason of a question (empty when not closed) ---
qc_close_reason() {
  sed -n 's/^reason: *//p' "$(qc_dir "$1")/${2}.closed" 2>/dev/null | tr -d '[:space:]' | head -1
}

# --- Parked question ids for an entry, oldest first ---
# Parked = closed with reason parked (answered or not). $3, when given, keeps
# only questions created at or after that epoch: the runner passes the launch
# time, because a resumed entry reuses its session id and an earlier park of
# the same entry must not be read as this launch's.
qc_parked_for_entry() {
  local adir="$1" entry="$2" since="${3:-0}" qdir f id created
  [ -n "$entry" ] || return 0
  qdir=$(qc_dir "$adir")
  [ -d "$qdir" ] || return 0
  for f in "$qdir"/q-*.yaml; do
    [ -f "$f" ] || continue
    case "$f" in *.answer.yaml) continue ;; esac
    grep -q "^entry_id: \"${entry}\"[[:space:]]*\$" "$f" 2>/dev/null || continue
    id=$(basename "$f" .yaml)
    [ "$(qc_close_reason "$adir" "$id")" = "parked" ] || continue
    created=$(sed -n 's/^created_epoch: *//p' "$f" 2>/dev/null | tr -d '[:space:]' | head -1) || created=""
    case "$created" in ''|*[!0-9]*) created=0 ;; esac
    [ "$created" -ge "$since" ] || continue
    printf '%s\n' "$id"
  done
  return 0
}

# --- Close a question ---
# Arguments: $1 automation dir, $2 question id,
#   $3 reason (parked | agent-decided | abandoned — Decision t-0068)
qc_close() {
  local qdir tmp
  qdir=$(qc_dir "$1")
  tmp="$qdir/.${2}.closed.tmp.$$"
  { printf 'reason: %s\nclosed_at: "%s"\n' "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp" \
      && mv "$tmp" "$qdir/${2}.closed"; } 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }
}

# --- Is a question open? ---
# Open = record exists, no close marker, no valid answer, deadline not passed.
qc_is_open() {
  local adir="$1" id="$2" qdir deadline now
  qdir=$(qc_dir "$adir")
  [ -f "$qdir/${id}.yaml" ] || return 1
  [ -f "$qdir/${id}.closed" ] && return 1
  qc_read_answer "$adir" "$id" >/dev/null 2>&1 && return 1
  deadline=$(sed -n 's/^deadline_epoch: *//p' "$qdir/${id}.yaml" 2>/dev/null | tr -d '[:space:]' | head -1) || deadline=""
  case "$deadline" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ "$now" -lt "$deadline" ]
}

# --- Open question ids for an entry, one per line ---
qc_open_for_entry() {
  local adir="$1" entry="$2" qdir f id
  [ -n "$entry" ] || return 0
  qdir=$(qc_dir "$adir")
  [ -d "$qdir" ] || return 0
  for f in "$qdir"/q-*.yaml; do
    [ -f "$f" ] || continue
    case "$f" in *.answer.yaml) continue ;; esac
    grep -q "^entry_id: \"${entry}\"[[:space:]]*\$" "$f" 2>/dev/null || continue
    id=$(basename "$f" .yaml)
    if qc_is_open "$adir" "$id"; then
      printf '%s\n' "$id"
    fi
  done
  return 0
}

# --- Does an entry have an open question? (paused, Decision t-0064 § 3) ---
qc_entry_has_open_question() {
  [ -n "$(qc_open_for_entry "$1" "$2" 2>/dev/null)" ]
}

# --- Close every open question for an entry ---
# Used by the runner after the child exits, so a retry of the entry is not
# reported as paused on a question nobody is waiting on.
qc_close_open_for_entry() {
  local adir="$1" entry="$2" reason="${3:-abandoned}" id
  for id in $(qc_open_for_entry "$adir" "$entry" 2>/dev/null); do
    qc_close "$adir" "$id" "$reason" || true
  done
  return 0
}
