#!/usr/bin/env bash
# review-findings.sh — the advisory review's findings as a file (Decision t-0082;
# schema .claude/.automation/schemas/review-findings.yaml).
#
# Prompt A writes each finding of its Refinement Report here, so a front end
# (Massimo's Specs page) can show them as data and record the operator's
# decisions, and Prompt A reads those decisions back. This tool is the only
# writer: an advisory session may write files only in its governance phase, so
# it runs this through Bash during synthesize and op-review.
#
# Usage:
#   review-findings.sh write <version> [--replace]   findings on stdin
#   review-findings.sh set <version> <id> <open|applied|dismissed|deferred> [--reason TEXT]
#   review-findings.sh check <version>
#
# File: docs/spec/review-findings/<version>.yaml, owned by the repo.
# Exit: 0 ok; 1 refused, invalid, or (check) a Blocking finding unresolved.
# Bash 3.2 compatible.
set -uo pipefail

RF_SCHEMA_VERSION="1.0.0"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

_rf_die() { echo "ERROR: $*" >&2; exit 1; }

_rf_file() { printf '%s/docs/spec/review-findings/%s.yaml' "$REPO_ROOT" "$1"; }

# A version becomes a file name: plain characters only, not an option.
_rf_valid_version() {
  case "$1" in
    ''|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# A value is one double-quoted scalar with nothing after the closing quote,
# \" and \\ escaped. The body is scanned, so an unescaped quote inside it, or
# a final backslash that escapes the closing quote, is refused.
_rf_quoted() {
  local body c esc=false
  case "$1" in '"'*'"') ;; *) return 1 ;; esac
  [ "${#1}" -ge 2 ] || return 1
  body="${1#\"}"; body="${body%\"}"
  while [ -n "$body" ]; do
    c="${body:0:1}"; body="${body:1}"
    if [ "$esc" = true ]; then esc=false
    elif [ "$c" = '\' ]; then esc=true
    elif [ "$c" = '"' ]; then return 1
    fi
  done
  [ "$esc" = false ]
}

# A reason of only whitespace explains nothing.
_rf_blank() { case "$1" in *[![:space:]]*) return 1 ;; esac; return 0; }
_rf_unquote() {
  local v="${1#\"}" out=""
  v="${v%\"}"
  while case "$v" in *'\'*) true ;; *) false ;; esac; do
    out="${out}${v%%\\*}"
    v="${v#*\\}"
    out="${out}${v:0:1}"
    v="${v:1}"
  done
  printf '%s' "${out}${v}"
}
_rf_quote() {
  local v="$1" out=""
  while case "$v" in *\\*) true ;; *) false ;; esac; do
    out="${out}${v%%\\*}\\\\"; v="${v#*\\}"
  done
  v="${out}${v}"; out=""
  while case "$v" in *'"'*) true ;; *) false ;; esac; do
    out="${out}${v%%\"*}\\\""; v="${v#*\"}"
  done
  printf '"%s"' "${out}${v}"
}

# Parsed state, one array per field, index = finding position.
RF_N=0
RF_ID=() RF_SEV=() RF_KIND=() RF_AGENT=() RF_FILE=() RF_SECTION=()
RF_FINDING=() RF_FIX=() RF_STATUS=() RF_REASON=()
RF_FIELDS="id severity kind agent spec_file section finding suggested_fix status reason"

_rf_set_field() {   # position key value
  case "$2" in
    id) RF_ID[$1]="$3" ;; severity) RF_SEV[$1]="$3" ;; kind) RF_KIND[$1]="$3" ;;
    agent) RF_AGENT[$1]="$3" ;; spec_file) RF_FILE[$1]="$3" ;; section) RF_SECTION[$1]="$3" ;;
    finding) RF_FINDING[$1]="$3" ;; suggested_fix) RF_FIX[$1]="$3" ;;
    status) RF_STATUS[$1]="$3" ;; reason) RF_REASON[$1]="$3" ;;
  esac
}
_rf_get_field() {   # position key
  case "$2" in
    id) printf '%s' "${RF_ID[$1]-}" ;; severity) printf '%s' "${RF_SEV[$1]-}" ;;
    kind) printf '%s' "${RF_KIND[$1]-}" ;; agent) printf '%s' "${RF_AGENT[$1]-}" ;;
    spec_file) printf '%s' "${RF_FILE[$1]-}" ;; section) printf '%s' "${RF_SECTION[$1]-}" ;;
    finding) printf '%s' "${RF_FINDING[$1]-}" ;; suggested_fix) printf '%s' "${RF_FIX[$1]-}" ;;
    status) printf '%s' "${RF_STATUS[$1]-}" ;; reason) printf '%s' "${RF_REASON[$1]-}" ;;
  esac
}

# Parse findings from file $1. Mode $2: input (from the agent: no header, no
# severity, status and reason optional) or file (the stored form: everything
# present). Returns 0, or 1 with a message on stderr.
_rf_parse() {
  local src="$1" mode="$2" line lineno=0 key raw v n=-1 seen_ids="|" seen_keys="|" saw_list=false
  local version_seen=false
  RF_N=0; RF_ID=(); RF_SEV=(); RF_KIND=(); RF_AGENT=(); RF_FILE=(); RF_SECTION=()
  RF_FINDING=(); RF_FIX=(); RF_STATUS=(); RF_REASON=()
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%"${line##*[![:space:]]}"}"
    case "${line#"${line%%[![:space:]]*}"}" in ''|'#'*) continue ;; esac
    # A CR inside a line (a trailing one is trimmed above) is not one line.
    case "$line" in *$'\r'*) echo "ERROR: line $lineno: a value must be one line (carriage return found)" >&2; return 1 ;; esac
    case "$line" in
      'schema_version: '*|'spec_version: '*)
        [ "$mode" = file ] || { echo "ERROR: line $lineno: give only the findings: list; the tool writes the header" >&2; return 1; }
        case "$line" in
          'schema_version: '*)
            v="${line#schema_version: }"; v="${v#\"}"; v="${v%\"}"
            case "$v" in 1.*) version_seen=true ;; *) echo "ERROR: line $lineno: schema_version '$v' is not supported (this Repo OS reads 1.x)" >&2; return 1 ;; esac ;;
          'spec_version: '*)
            # A file copied from another version must not answer for this one.
            v=$(_rf_unquote "${line#spec_version: }")
            if [ -n "${RF_EXPECT_VERSION:-}" ] && [ "$v" != "$RF_EXPECT_VERSION" ]; then
              echo "ERROR: line $lineno: spec_version '$v' is not '$RF_EXPECT_VERSION' (the file name)" >&2; return 1
            fi ;;
        esac
        continue ;;
      'findings:'|'findings: []')
        [ "$saw_list" = false ] || { echo "ERROR: line $lineno: findings: appears twice" >&2; return 1; }
        saw_list=true; continue ;;
      '  - id: '*)
        [ "$saw_list" = true ] || { echo "ERROR: line $lineno: a finding before findings:" >&2; return 1; }
        n=$((n + 1)); key=id; raw="${line#  - id: }"; seen_keys="|" ;;
      '    '[a-z]*': '*)
        [ "$n" -ge 0 ] || { echo "ERROR: line $lineno: a field before any '- id:'" >&2; return 1; }
        key="${line#    }"; key="${key%%: *}"; raw="${line#    $key: }" ;;
      *) echo "ERROR: line $lineno: unrecognised line (see .claude/.automation/schemas/review-findings.yaml)" >&2; return 1 ;;
    esac
    case " $RF_FIELDS " in *" $key "*) ;; *) echo "ERROR: line $lineno: unknown field '$key'" >&2; return 1 ;; esac
    if [ "$key" = severity ] && [ "$mode" = input ]; then
      echo "ERROR: line $lineno: do not give severity; the tool derives it from kind" >&2; return 1
    fi
    # Tracked by key, not by value, so an empty first line is caught too.
    case "$seen_keys" in *"|$key|"*)
      echo "ERROR: line $lineno: finding $((n + 1)) has two '$key' lines" >&2; return 1 ;;
    esac
    seen_keys="${seen_keys}$key|"
    _rf_quoted "$raw" || { echo "ERROR: line $lineno: $key must be one double-quoted value, nothing after it" >&2; return 1; }
    v=$(_rf_unquote "$raw")
    case "$key" in
      id)
        case "$v" in ''|*[!A-Za-z0-9_-]*) echo "ERROR: line $lineno: id '$v' must be letters, digits, - or _" >&2; return 1 ;; esac
        case "$seen_ids" in *"|$v|"*) echo "ERROR: line $lineno: id '$v' is used twice" >&2; return 1 ;; esac
        seen_ids="${seen_ids}$v|" ;;
      kind)     case "$v" in critical|recommendation|idea) ;; *) echo "ERROR: line $lineno: kind must be critical, recommendation or idea" >&2; return 1 ;; esac ;;
      severity) case "$v" in Blocking|Advisory) ;; *) echo "ERROR: line $lineno: severity must be Blocking or Advisory" >&2; return 1 ;; esac ;;
      status)   case "$v" in open|applied|dismissed|deferred) ;; *) echo "ERROR: line $lineno: status must be open, applied, dismissed or deferred" >&2; return 1 ;; esac ;;
    esac
    _rf_set_field "$n" "$key" "$v"
  done < "$src"

  [ "$saw_list" = true ] || { echo "ERROR: no findings: list" >&2; return 1; }
  if [ "$mode" = file ] && [ "$version_seen" = false ]; then
    echo "ERROR: no schema_version" >&2; return 1
  fi
  RF_N=$((n + 1))
  local i=0 f
  while [ "$i" -lt "$RF_N" ]; do
    for f in id kind agent spec_file section finding suggested_fix; do
      [ -n "$(_rf_get_field "$i" "$f")" ] || { echo "ERROR: finding $((i + 1)) (${RF_ID[$i]-?}) has no $f" >&2; return 1; }
    done
    [ -n "${RF_STATUS[$i]-}" ] || RF_STATUS[$i]=open
    [ -n "${RF_REASON[$i]-}" ] || RF_REASON[$i]=""
    case "${RF_KIND[$i]}" in critical) v=Blocking ;; *) v=Advisory ;; esac
    if [ "$mode" = file ] && [ "${RF_SEV[$i]-}" != "$v" ]; then
      echo "ERROR: finding ${RF_ID[$i]}: severity '${RF_SEV[$i]-}' does not match kind '${RF_KIND[$i]}'" >&2; return 1
    fi
    RF_SEV[$i]="$v"
    i=$((i + 1))
  done
  return 0
}

# Write the parsed state to $2 (atomically, temp file + mv in the same directory).
_rf_write() {
  local version="$1" f="$2" tmp i k
  mkdir -p "$(dirname "$f")" || return 1
  tmp=$(mktemp "$f.tmp.XXXXXX") || return 1
  {
    printf '# Review findings — schema .claude/.automation/schemas/review-findings.yaml (Decision t-0082)\n'
    printf 'schema_version: "%s"\n' "$RF_SCHEMA_VERSION"
    printf 'spec_version: %s\n' "$(_rf_quote "$version")"
    if [ "$RF_N" -eq 0 ]; then printf 'findings: []\n'; else printf 'findings:\n'; fi
    i=0
    while [ "$i" -lt "$RF_N" ]; do
      printf '  - id: %s\n' "$(_rf_quote "${RF_ID[$i]}")"
      for k in severity kind agent spec_file section finding suggested_fix status reason; do
        printf '    %s: %s\n' "$k" "$(_rf_quote "$(_rf_get_field "$i" "$k")")"
      done
      i=$((i + 1))
    done
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  # mktemp creates 0600; the file is an ordinary tracked file.
  chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# A value is written on one line: a newline would break the layout.
_rf_one_line() { case "$1" in *$'\n'*|*$'\r'*) return 1 ;; esac; return 0; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  write)
    version="${1:-}"; [ $# -gt 0 ] && shift
    _rf_valid_version "$version" || _rf_die "write requires <version> (letters, digits, . _ -)"
    replace=false
    while [ $# -gt 0 ]; do
      case "$1" in --replace) replace=true; shift ;; *) _rf_die "unknown write option: $1" ;; esac
    done
    f=$(_rf_file "$version")
    if [ -e "$f" ] && [ "$replace" != true ]; then
      _rf_die "$f exists and may hold the operator's decisions; pass --replace for a new review round"
    fi
    input_file=$(mktemp "${TMPDIR:-/tmp}/review-findings.XXXXXX") || _rf_die "could not read stdin"
    cat > "$input_file"
    _rf_parse "$input_file" input; rc=$?
    rm -f "$input_file"
    [ "$rc" -eq 0 ] || _rf_die "nothing was written"
    _rf_write "$version" "$f" || _rf_die "could not write $f"
    printf 'Wrote %s finding(s) to %s\n' "$RF_N" "$f"
    ;;

  set)
    version="${1:-}" id="${2:-}" status="${3:-}"
    [ $# -ge 3 ] && shift 3 || _rf_die "set requires <version> <id> <status>"
    _rf_valid_version "$version" || _rf_die "invalid version '$version'"
    reason="" reason_given=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --reason) [ $# -ge 2 ] || _rf_die "--reason requires text"; reason="$2"; reason_given=true; shift 2 ;;
        *) _rf_die "unknown set option: $1" ;;
      esac
    done
    case "$status" in open|applied|dismissed|deferred) ;; *) _rf_die "status must be open, applied, dismissed or deferred" ;; esac
    _rf_one_line "$reason" || _rf_die "--reason must be one line"
    f=$(_rf_file "$version")
    [ -f "$f" ] || _rf_die "no findings file $f"
    RF_EXPECT_VERSION="$version"
    _rf_parse "$f" file || _rf_die "$f is not a valid findings file; nothing was changed"
    i=0 pos=-1
    while [ "$i" -lt "$RF_N" ]; do [ "${RF_ID[$i]}" = "$id" ] && { pos=$i; break; }; i=$((i + 1)); done
    [ "$pos" -ge 0 ] || _rf_die "no finding '$id' in $f"
    if [ "$status" = dismissed ] && [ "${RF_SEV[$pos]}" = Blocking ] && _rf_blank "$reason"; then
      _rf_die "dismissing Blocking finding $id needs --reason (an explicit rejection)"
    fi
    RF_STATUS[$pos]="$status"
    # A reason belongs to the decision it explains: a new decision replaces it.
    if [ "$reason_given" = true ]; then RF_REASON[$pos]="$reason"; else RF_REASON[$pos]=""; fi
    _rf_write "$version" "$f" || _rf_die "could not write $f"
    printf '%s: %s\n' "$id" "$status"
    ;;

  check)
    version="${1:-}"
    _rf_valid_version "$version" || _rf_die "check requires <version>"
    f=$(_rf_file "$version")
    [ -f "$f" ] || _rf_die "no findings file $f"
    RF_EXPECT_VERSION="$version"
    _rf_parse "$f" file || _rf_die "$f is not a valid findings file"
    i=0 unresolved="" blocking=0 open_adv=0
    while [ "$i" -lt "$RF_N" ]; do
      if [ "${RF_SEV[$i]}" = Blocking ]; then
        blocking=$((blocking + 1))
        case "${RF_STATUS[$i]}" in
          applied) ;;
          dismissed) _rf_blank "${RF_REASON[$i]}" && unresolved="${unresolved}  ${RF_ID[$i]}: dismissed without a reason"$'\n' ;;
          *) unresolved="${unresolved}  ${RF_ID[$i]}: ${RF_STATUS[$i]} — ${RF_FINDING[$i]}"$'\n' ;;
        esac
      elif [ "${RF_STATUS[$i]}" = open ]; then
        open_adv=$((open_adv + 1))
      fi
      i=$((i + 1))
    done
    if [ -n "$unresolved" ]; then
      printf 'UNRESOLVED: Blocking findings must be applied or dismissed with a reason:\n%s' "$unresolved"
      exit 1
    fi
    printf 'OK: %s Blocking finding(s) resolved; %s Advisory finding(s) still open (they do not block)\n' "$blocking" "$open_adv"
    ;;

  *)
    sed -n '11,17p' "$0" >&2
    exit 1 ;;
esac
