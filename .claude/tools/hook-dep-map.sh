#!/usr/bin/env bash
# Hook Source-Dependency Map Generator
# Traces `source` statements across hook and automation shell scripts,
# producing forward and reverse dependency maps for blast-radius analysis.
#
# Usage:
#   hook-dep-map.sh [--text|--mermaid|--json] [--exclude-tests=off]
#
# Flags:
#   --text            Text output (default)
#   --mermaid         Mermaid graph syntax
#   --json            Machine-readable JSON
#   --exclude-tests=off  Include test files (excluded by default)
#
# No external dependencies — pure Bash.
# Read-only analysis — does not modify any files.

set -euo pipefail

# --- Self-locate ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Defaults ---
OUTPUT_FORMAT="text"
EXCLUDE_TESTS=true

# --- Flag parsing (queue-cli.sh convention) ---
while [ $# -gt 0 ]; do
  case "$1" in
    --text)    OUTPUT_FORMAT="text" ;;
    --mermaid) OUTPUT_FORMAT="mermaid" ;;
    --json)    OUTPUT_FORMAT="json" ;;
    --exclude-tests=off)  EXCLUDE_TESTS=false ;;
    --exclude-tests=on)   EXCLUDE_TESTS=true ;;
    --exclude-tests)      EXCLUDE_TESTS=true ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p; }' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
  esac
  shift
done

# --- Discovery: find all .sh files ---
# Skip gitignored runtime dirs: queue/, reports/, escalations/, briefs/, logs/
declare -a ALL_FILES=()

_discover() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' file; do
    local rel="${file#"$REPO_ROOT"/}"
    # Skip gitignored runtime directories
    case "$rel" in
      .claude/.automation/queue/*|.claude/.automation/reports/*|\
      .claude/.automation/escalations/*|.claude/.automation/briefs/*|\
      .claude/.automation/logs/*) continue ;;
    esac
    # Skip test files if flag is on
    if $EXCLUDE_TESTS; then
      case "$rel" in
        .claude/hooks/tests/*|.claude/.automation/tests/*) continue ;;
      esac
    fi
    ALL_FILES+=("$rel")
  done < <(find "$dir" -name '*.sh' -type f -print0 2>/dev/null)
}

_discover "$REPO_ROOT/.claude/hooks"
_discover "$REPO_ROOT/.claude/.automation"

# Sort for stable output
IFS=$'\n' ALL_FILES=($(printf '%s\n' "${ALL_FILES[@]}" | sort)); unset IFS

# --- Extract source dependencies ---
# Parallel arrays for edges: from, raw target, conditional flag, resolved path
declare -a EDGE_FROM=()
declare -a EDGE_TO=()
declare -a EDGE_CONDITIONAL=()
declare -a EDGE_RESOLVED=()

_resolve_path() {
  local raw="$1"
  local from_file="$2"
  local from_dir
  from_dir="$(dirname "$REPO_ROOT/$from_file")"

  # Strip quotes
  raw="${raw%\"}"
  raw="${raw#\"}"
  raw="${raw%\'}"
  raw="${raw#\'}"

  # Strip trailing error handling using parameter expansion
  # Remove 2>/dev/null and everything after
  raw="${raw%% 2>*}"
  # Remove || ... and everything after
  raw="${raw%% ||*}"
  # Remove trailing &
  raw="${raw%% &}"
  # Remove trailing whitespace
  raw="${raw%% }"

  # Resolve known variable patterns
  local resolved=""
  case "$raw" in
    '$SCRIPT_DIR/'*|'"$SCRIPT_DIR"/'*)
      local suffix="${raw#*SCRIPT_DIR/}"
      suffix="${suffix#\"/}"
      suffix="${suffix%\"}"
      resolved="$(cd "$from_dir" && realpath -q "$suffix" 2>/dev/null || echo "")"
      ;;
    '$_REPO_OS_ROOT/'*|'"$_REPO_OS_ROOT"/'*|'$REPO_ROOT/'*|'"$REPO_ROOT"/'*)
      local suffix
      for prefix in '$_REPO_OS_ROOT/' '"$_REPO_OS_ROOT"/' '$REPO_ROOT/' '"$REPO_ROOT"/'; do
        if [[ "$raw" == "${prefix}"* ]]; then
          suffix="${raw#"$prefix"}"
          suffix="${suffix%\"}"
          break
        fi
      done
      [ -f "$REPO_ROOT/$suffix" ] && resolved="$REPO_ROOT/$suffix"
      ;;
    '$LIB_DIR/'*|'"$LIB_DIR"/'*)
      local suffix="${raw#*LIB_DIR/}"
      suffix="${suffix#\"/}"
      suffix="${suffix%\"}"
      # LIB_DIR is .claude/.automation/lib in automation scripts
      [ -f "$REPO_ROOT/.claude/.automation/lib/$suffix" ] && resolved="$REPO_ROOT/.claude/.automation/lib/$suffix"
      ;;
    '$_BRIDGE_AUTOMATION_DIR/'*|'"$_BRIDGE_AUTOMATION_DIR"/'*)
      local suffix="${raw#*_BRIDGE_AUTOMATION_DIR/}"
      suffix="${suffix#\"/}"
      suffix="${suffix%\"}"
      [ -f "$REPO_ROOT/.claude/.automation/$suffix" ] && resolved="$REPO_ROOT/.claude/.automation/$suffix"
      ;;
    '$PARENT_DIR/'*|'"$PARENT_DIR"/'*)
      local suffix="${raw#*PARENT_DIR/}"
      suffix="${suffix#\"/}"
      suffix="${suffix%\"}"
      local parent_dir
      parent_dir="$(dirname "$from_dir")"
      [ -f "$parent_dir/$suffix" ] && resolved="$parent_dir/$suffix"
      ;;
    '$ADV_SANDBOX/'*|'"$ADV_SANDBOX"/'*)
      resolved=""  # Test sandbox — unresolvable statically
      ;;
    '$real_hooks_dir/'*|'"$real_hooks_dir"/'*)
      local suffix="${raw#*real_hooks_dir/}"
      suffix="${suffix#\"/}"
      suffix="${suffix%\"}"
      [ -f "$REPO_ROOT/.claude/hooks/$suffix" ] && resolved="$REPO_ROOT/.claude/hooks/$suffix"
      ;;
    '$script_dir/'*|'"$script_dir"/'*)
      local suffix="${raw#*script_dir/}"
      suffix="${suffix#\"/}"
      suffix="${suffix%\"}"
      resolved="$(cd "$from_dir" && realpath -q "$suffix" 2>/dev/null || echo "")"
      ;;
    /*)
      [ -f "$raw" ] && resolved="$raw"
      ;;
    *)
      if [ -f "$from_dir/$raw" ]; then
        resolved="$(realpath -q "$from_dir/$raw" 2>/dev/null || echo "")"
      fi
      ;;
  esac

  if [ -n "$resolved" ]; then
    echo "${resolved#"$REPO_ROOT"/}"
  fi
}

_is_conditional() {
  local file="$1"
  local line_num="$2"
  local full_path="$REPO_ROOT/$file"

  # Check current line for error-handling patterns
  local source_line
  source_line=$(sed -n "${line_num}p" "$full_path" 2>/dev/null || true)
  case "$source_line" in
    *'2>'*|*'|| true'*|*'|| exit'*) return 0 ;;
  esac

  # Check previous line for conditional
  if [ "$line_num" -gt 1 ]; then
    local prev_line
    prev_line=$(sed -n "$((line_num - 1))p" "$full_path" 2>/dev/null || true)
    case "$prev_line" in
      *'if '*|*'if ['*|*'[[ '*|*'] &&'*|*'&& source'*|*'|| source'*) return 0 ;;
    esac
  fi

  return 1
}

# Parse all source statements
for file in "${ALL_FILES[@]}"; do
  while IFS= read -r match; do
    [ -z "$match" ] && continue
    line_num="${match%%:*}"
    line_content="${match#*:}"

    # Extract the sourced path
    sourced_raw="$(echo "$line_content" | sed -nE 's/^[[:space:]]*(source|\.)[[:space:]]+//p')"
    [ -z "$sourced_raw" ] && continue

    # Strip inline comments (but not # inside quotes)
    sourced_raw="$(echo "$sourced_raw" | sed 's/[[:space:]]*#[^"]*$//')"

    # Detect conditional
    conditional=false
    if _is_conditional "$file" "$line_num"; then
      conditional=true
    fi

    # Resolve path
    resolved="$(_resolve_path "$sourced_raw" "$file")"

    EDGE_FROM+=("$file")
    EDGE_TO+=("$sourced_raw")
    EDGE_CONDITIONAL+=("$conditional")
    EDGE_RESOLVED+=("${resolved:-}")
  done < <(grep -n '^\s*\(source\|\.\)\s\+' "$REPO_ROOT/$file" 2>/dev/null || true)
done

# --- Build adjacency maps ---
# Bash 3 compatible: parallel arrays instead of associative arrays
declare -a FWD_KEYS=()
declare -a FWD_VALS=()
declare -a REV_KEYS=()
declare -a REV_VALS=()
declare -a UNRESOLVED=()

_fwd_lookup() {
  local key="$1"
  for i in "${!FWD_KEYS[@]}"; do
    [ "${FWD_KEYS[$i]}" = "$key" ] && echo "$i" && return
  done
  echo "-1"
}

_rev_lookup() {
  local key="$1"
  for i in "${!REV_KEYS[@]}"; do
    [ "${REV_KEYS[$i]}" = "$key" ] && echo "$i" && return
  done
  echo "-1"
}

for i in "${!EDGE_FROM[@]}"; do
  ef="${EDGE_FROM[$i]}"
  er="${EDGE_RESOLVED[$i]}"
  eraw="${EDGE_TO[$i]}"
  ec="${EDGE_CONDITIONAL[$i]}"

  if [ -z "$er" ]; then
    UNRESOLVED+=("$ef → $eraw")
    continue
  fi

  label="$er"
  [ "$ec" = "true" ] && label="$label [conditional]"

  # Forward map
  idx=$(_fwd_lookup "$ef")
  if [ "$idx" = "-1" ]; then
    FWD_KEYS+=("$ef")
    FWD_VALS+=("$label")
  else
    FWD_VALS[$idx]="${FWD_VALS[$idx]}|$label"
  fi

  # Reverse map (direct)
  rev_entry="$ef"
  [ "$ec" = "true" ] && rev_entry="$rev_entry [conditional]"
  idx=$(_rev_lookup "$er")
  if [ "$idx" = "-1" ]; then
    REV_KEYS+=("$er")
    REV_VALS+=("$rev_entry")
  else
    case "|${REV_VALS[$idx]}|" in
      *"|$rev_entry|"*) ;;
      *) REV_VALS[$idx]="${REV_VALS[$idx]}|$rev_entry" ;;
    esac
  fi
done

# --- Transitive closure for reverse map ---
_transitive_consumers() {
  local target="$1"
  local visited="$2"

  local idx
  idx=$(_rev_lookup "$target")
  [ "$idx" = "-1" ] && return

  local IFS='|'
  local entries
  read -ra entries <<< "${REV_VALS[$idx]}"
  unset IFS

  for entry in "${entries[@]}"; do
    local clean="${entry% \[conditional\]}"
    case "|$visited|" in
      *"|$clean|"*) continue ;;
    esac
    echo "$entry"
    _transitive_consumers "$clean" "$visited|$clean"
  done
}

# Build transitive reverse map
declare -a TREV_KEYS=()
declare -a TREV_VALS=()

for i in "${!REV_KEYS[@]}"; do
  rk="${REV_KEYS[$i]}"
  TREV_KEYS+=("$rk")
  direct="${REV_VALS[$i]}"

  IFS='|' read -ra entries <<< "$direct"; unset IFS

  all_consumers="$direct"
  for entry in "${entries[@]}"; do
    clean="${entry% \[conditional\]}"
    transitive=$(_transitive_consumers "$clean" "$rk|$clean") || true
    if [ -n "$transitive" ]; then
      while IFS= read -r tentry; do
        tclean="${tentry% \[conditional\]}"
        case "|$all_consumers|" in
          *"|$tclean|"*|*"|$tclean \[conditional\]|"*) ;;
          *) all_consumers="$all_consumers|$tentry [transitive]" ;;
        esac
      done <<< "$transitive"
    fi
  done
  TREV_VALS+=("$all_consumers")
done

# --- Output: Text ---
_output_text() {
  echo "=== Hook Source-Dependency Map ==="
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Tests excluded: $EXCLUDE_TESTS"
  echo ""

  echo "--- Forward Map (file → sources) ---"
  echo ""
  local sorted_indices
  sorted_indices=$(for i in "${!FWD_KEYS[@]}"; do echo "$i ${FWD_KEYS[$i]}"; done | sort -k2 | awk '{print $1}')
  for i in $sorted_indices; do
    echo "${FWD_KEYS[$i]}:"
    IFS='|' read -ra targets <<< "${FWD_VALS[$i]}"; unset IFS
    for t in "${targets[@]}"; do
      echo "  → $t"
    done
    echo ""
  done

  echo "--- Reverse Map (helper ← consumers, transitive) ---"
  echo ""
  local rev_sorted
  rev_sorted=$(for i in "${!TREV_KEYS[@]}"; do echo "$i ${TREV_KEYS[$i]}"; done | sort -k2 | awk '{print $1}')
  for i in $rev_sorted; do
    echo "${TREV_KEYS[$i]}:"
    IFS='|' read -ra consumers <<< "${TREV_VALS[$i]}"; unset IFS
    for c in "${consumers[@]}"; do
      echo "  ← $c"
    done
    echo ""
  done

  echo "--- Unresolved Paths ---"
  echo ""
  if [ ${#UNRESOLVED[@]} -eq 0 ]; then
    echo "(none)"
  else
    for u in "${UNRESOLVED[@]}"; do
      echo "  ? $u"
    done
  fi
  echo ""
}

# --- Output: Mermaid ---
_output_mermaid() {
  echo "graph LR"

  _mermaid_id() {
    echo "$1" | sed 's/[^a-zA-Z0-9]/_/g'
  }

  _mermaid_label() {
    echo "$1" | awk -F/ '{if(NF>=2) print $(NF-1)"/"$NF; else print $NF}'
  }

  for i in "${!FWD_KEYS[@]}"; do
    local from="${FWD_KEYS[$i]}"
    local from_id from_label
    from_id=$(_mermaid_id "$from")
    from_label=$(_mermaid_label "$from")

    IFS='|' read -ra targets <<< "${FWD_VALS[$i]}"; unset IFS

    for t in "${targets[@]}"; do
      local clean="$t"
      local is_cond=false
      case "$t" in
        *" [conditional]"*)
          is_cond=true
          clean="${t% \[conditional\]}"
          ;;
      esac
      local to_id to_label
      to_id=$(_mermaid_id "$clean")
      to_label=$(_mermaid_label "$clean")

      if $is_cond; then
        echo "  ${from_id}[\"${from_label}\"] -.->|conditional| ${to_id}[\"${to_label}\"]"
      else
        echo "  ${from_id}[\"${from_label}\"] --> ${to_id}[\"${to_label}\"]"
      fi
    done
  done
}

# --- Output: JSON ---
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  echo "$s"
}

_output_json() {
  echo "{"
  echo "  \"generated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"tests_excluded\": $EXCLUDE_TESTS,"

  # Forward map
  echo "  \"forward_map\": {"
  local first=true
  local sorted_indices
  sorted_indices=$(for i in "${!FWD_KEYS[@]}"; do echo "$i ${FWD_KEYS[$i]}"; done | sort -k2 | awk '{print $1}')
  for i in $sorted_indices; do
    $first || echo ","
    first=false
    printf "    \"%s\": [" "$(_json_escape "${FWD_KEYS[$i]}")"
    IFS='|' read -ra targets <<< "${FWD_VALS[$i]}"; unset IFS
    local ft=true
    for t in "${targets[@]}"; do
      $ft || printf ", "
      ft=false
      local clean="$t" cond=false
      case "$t" in *" [conditional]"*) cond=true; clean="${t% \[conditional\]}";; esac
      printf "{\"target\": \"%s\", \"conditional\": %s}" "$(_json_escape "$clean")" "$cond"
    done
    printf "]"
  done
  echo ""
  echo "  },"

  # Reverse map
  echo "  \"reverse_map\": {"
  first=true
  local rev_sorted
  rev_sorted=$(for i in "${!TREV_KEYS[@]}"; do echo "$i ${TREV_KEYS[$i]}"; done | sort -k2 | awk '{print $1}')
  for i in $rev_sorted; do
    $first || echo ","
    first=false
    printf "    \"%s\": [" "$(_json_escape "${TREV_KEYS[$i]}")"
    IFS='|' read -ra consumers <<< "${TREV_VALS[$i]}"; unset IFS
    local fc=true
    for c in "${consumers[@]}"; do
      $fc || printf ", "
      fc=false
      local clean="$c" cond=false trans=false
      case "$c" in *" [transitive]"*) trans=true; clean="${c% \[transitive\]}";; esac
      case "$clean" in *" [conditional]"*) cond=true; clean="${clean% \[conditional\]}";; esac
      printf "{\"consumer\": \"%s\", \"conditional\": %s, \"transitive\": %s}" "$(_json_escape "$clean")" "$cond" "$trans"
    done
    printf "]"
  done
  echo ""
  echo "  },"

  # Unresolved
  echo "  \"unresolved\": ["
  if [ ${#UNRESOLVED[@]} -gt 0 ]; then
    local fu=true
    for u in "${UNRESOLVED[@]}"; do
      $fu || echo ","
      fu=false
      printf "    \"%s\"" "$(_json_escape "$u")"
    done
    echo ""
  fi
  echo "  ]"
  echo "}"
}

# --- Dispatch ---
case "$OUTPUT_FORMAT" in
  text)    _output_text ;;
  mermaid) _output_mermaid ;;
  json)    _output_json ;;
esac
