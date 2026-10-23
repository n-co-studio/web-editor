#!/usr/bin/env bash
# Overlap report — read-only view of file overlap between open branches.
# Sourced by queue-cli.sh (`overlap` subcommand). NOT executed standalone.
#
# Answers three questions, for every open branch:
#   1. which files does it share with other open branches;
#   2. would merging a sharing pair conflict;
#   3. has main changed any of its files since the branch started.
#
# Why it exists: a brief is verified on its own branch against main as it was
# when the branch started. `_solo_merge_if_needed()` merges at close and
# re-verifies nothing, so two briefs that touch the same file can merge cleanly
# and produce behaviour neither branch was verified for. Nothing checked files
# across open branches at all. This report is the signal; acting on it is not
# this file's job.
#
# Shared files are a SIGNAL, not a status. Nothing here changes a queue entry's
# status, and nothing here writes state or takes a lock — Massimo polls it every
# few seconds.
#
# Read-only contract:
#   - no locks acquired, no files under .claude/.state written;
#   - main's working tree, index and HEAD are never touched. The only writes are
#     a scratch worktree under $TMPDIR plus its `.git/worktrees/<name>`
#     administrative entry, both removed before the predicting call returns.
#
# Public API:
#   overlap_report_build [repo_dir] [main_ref]   populate module state; 1 on error
#   overlap_report_text  [branch_filter]         human-readable render
#   overlap_report_json  [branch_filter]         machine-readable render
#
# Stateless single-branch helpers, for callers that need the question-3 answer
# for one branch without building (or stomping) a whole report:
#   overlap_report_main_changed <repo> <main_ref> <branch>          file list
#   overlap_report_main_commit  <repo> <main_ref> <branch> <files>  SHA
#
# Bash 3.2 compatible: indexed arrays only, explicit element counts (`${#a[@]}`
# on an empty array is an unbound-variable error under `set -u` in 3.2).

set -euo pipefail

# --- Module state ---------------------------------------------------------
# Parallel arrays indexed 0.._OR_N-1, one slot per open branch.
#   _OR_BRANCH       branch name
#   _OR_FILES        newline-terminated list of files the branch changed
#                    (committed since merge-base, plus live uncommitted ones)
#   _OR_UNCOMMITTED  subset of the above that is uncommitted working-tree state
#   _OR_MB           merge-base with main
#   _OR_SET          set label; starts at the branch's own index and is
#                    relabelled as sharing pairs are found
_OR_REPO="."
_OR_MAIN="main"
_OR_N=0
_OR_NPAIR=0
_OR_BRANCH=()
_OR_FILES=()
_OR_UNCOMMITTED=()
_OR_MB=()
_OR_SET=()

# Sharing pairs, indexed 0.._OR_NPAIR-1. A pair is recorded only when the two
# branches share at least one file.
#   _OR_PAIR_A/_B       branch indices
#   _OR_PAIR_CONFLICT   0 clean, 1 conflict, 2 undetermined
#   _OR_PAIR_CFILES     conflicted paths (newline-terminated)
#   _OR_PAIR_SHARED     shared paths (newline-terminated)
_OR_PAIR_A=()
_OR_PAIR_B=()
_OR_PAIR_CONFLICT=()
_OR_PAIR_CFILES=()
_OR_PAIR_SHARED=()

# Per-branch "main moved under me", indexed alongside _OR_BRANCH.
_OR_MC_FILES=()
_OR_MC_COMMIT=()

_OR_GENERATED_AT=""
_OR_CF=""
_OR_HAVE_MERGE_TREE=""
_OR_CONFLICT_METHOD=""

# A literal tab, for splitting git's conflicted-file-info lines. Written this
# way because an inline tab in a `case` pattern is invisible in review and
# survives neither reformatting nor copy-paste reliably.
_OR_TAB=$(printf '\t')

# A literal newline, for the trailing-newline trim in _or_add_line. `$'\n'`
# would do, but keeping both separators in the same style keeps the quoting of
# the `${var%...}` expansion that uses it readable.
_OR_NL='
'

# --- git in the reporting repo ---
_or_git() {
  git -C "$_OR_REPO" "$@"
}

# --- Is $2 present as a whole line in newline-list $1? ---
# Newline-wrapping both sides makes this a whole-line test, so `lib/a.sh` does
# not match `lib/ab.sh` or `vendor/lib/a.sh`.
_or_has_line() {
  case "
$1
" in
    *"
$2
"*) return 0 ;;
  esac
  return 1
}

# --- Lines present in both newline-lists ---
# Output preserves the order of $1 and is newline-terminated.
# Arguments: $1 — list A; $2 — list B
_or_intersect() {
  local line out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if _or_has_line "$2" "$line"; then
      out="${out}${line}
"
    fi
  done <<EOF
$1
EOF
  printf '%s' "$out"
}

# --- Append a line to a newline-list unless already present ---
# Output: the new list on stdout.
#
# The list is re-terminated before appending. Callers accumulate with
# `out=$(_or_add_line "$out" "$x")`, and command substitution strips trailing
# newlines — so without this the second entry would be glued onto the first.
_or_add_line() {
  if _or_has_line "$1" "$2"; then
    printf '%s' "$1"
  elif [ -z "$1" ]; then
    printf '%s\n' "$2"
  else
    printf '%s\n%s\n' "${1%"$_OR_NL"}" "$2"
  fi
}

# --- Root of the repo holding the shared .claude/.state ---
# `_OR_REPO` may itself be a linked worktree, whose `.claude/.state` is its own
# copy; the session registry lives in the main repo. `--git-common-dir` resolves
# to the main repo's git dir from either, and is within the git 2.5 floor
# (AI.md Tooling Floor).
_or_state_root() {
  local common
  common=$(_or_git rev-parse --git-common-dir 2>/dev/null) || {
    printf '%s' "$_OR_REPO"
    return 0
  }
  if [ -z "$common" ]; then
    printf '%s' "$_OR_REPO"
    return 0
  fi
  case "$common" in
    /*) ;;
    *) common="$_OR_REPO/$common" ;;
  esac
  (cd "$common/.." 2>/dev/null && pwd) || printf '%s' "$_OR_REPO"
}

# --- Worktree path of a live session on branch $1, if the registry has one ---
# Output: absolute path, or empty.
_or_worktree_for_branch() {
  local sessions_dir f reg_branch reg_path
  sessions_dir="$(_or_state_root)/.claude/.state/sessions"
  if [ ! -d "$sessions_dir" ]; then
    printf ''
    return 0
  fi
  for f in "$sessions_dir"/*.yaml; do
    [ -f "$f" ] || continue
    reg_branch=$(grep '^branch: ' "$f" 2>/dev/null | head -1 | sed 's/^branch: *//') || true
    [ "$reg_branch" = "$1" ] || continue
    reg_path=$(grep '^worktree_path: ' "$f" 2>/dev/null | head -1 | sed 's/^worktree_path: *//') || true
    if [ -n "$reg_path" ] && [ -d "$reg_path" ]; then
      printf '%s' "$reg_path"
      return 0
    fi
  done
  printf ''
}

# --- Uncommitted paths in the worktree at $1 ---
# Output: newline-terminated list.
_or_uncommitted_files() {
  local line path out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # porcelain v1: two status columns, a space, then the path. Renames and
    # copies render as "orig -> new"; the new name is the one that matters.
    path="${line:3}"
    case "$path" in
      *" -> "*) path="${path##* -> }" ;;
    esac
    path="${path#\"}"
    path="${path%\"}"
    [ -n "$path" ] || continue
    out=$(_or_add_line "$out" "$path")
  done <<EOF
$(git -C "$1" status --porcelain 2>/dev/null || true)
EOF
  printf '%s' "$out"
}

# --- Open branches -------------------------------------------------------
# Unmerged feature/*, fix/* and hotfix/* heads, plus the branches of queue
# entries that are running, in review, or completed without a solo merge.
# Branches already contained in main are excluded, which is what drops merged
# and stale branches.
# Output: newline-terminated list.
_or_open_branches() {
  local out="" b entry_dir f reg_branch solo

  while IFS= read -r b; do
    [ -n "$b" ] || continue
    case "$b" in
      feature/*|fix/*|hotfix/*) ;;
      *) continue ;;
    esac
    out=$(_or_add_line "$out" "$b")
  done <<EOF
$(_or_git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null || true)
EOF

  # Queue entries can name a branch outside those three prefixes. A completed
  # entry whose branch was solo-merged is skipped here, and would be dropped by
  # the ancestor filter below in any case.
  for entry_dir in running review completed; do
    local qdir="$_OR_REPO/.claude/.automation/queue/$entry_dir"
    [ -d "$qdir" ] || continue
    for f in "$qdir"/*.yaml; do
      [ -f "$f" ] || continue
      reg_branch=$(grep '^  branch: ' "$f" 2>/dev/null | head -1 \
        | sed 's/^  branch: *//; s/^"//; s/"$//') || true
      solo=$(grep '^  solo_mode: ' "$f" 2>/dev/null | head -1 \
        | sed 's/^  solo_mode: *//; s/^"//; s/"$//') || true
      [ -n "$reg_branch" ] || continue
      [ "$solo" = "true" ] && continue
      out=$(_or_add_line "$out" "$reg_branch")
    done
  done

  # Filter: must exist, must not be main, must not already be in main.
  local filtered=""
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    [ "$b" = "$_OR_MAIN" ] && continue
    _or_git rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1 || continue
    _or_git merge-base --is-ancestor "$b" "$_OR_MAIN" >/dev/null 2>&1 && continue
    _or_git merge-base "$_OR_MAIN" "$b" >/dev/null 2>&1 || continue
    filtered=$(_or_add_line "$filtered" "$b")
  done <<EOF
$out
EOF
  printf '%s' "$filtered"
}

# --- Conflict prediction -------------------------------------------------
# Is `git merge-tree --write-tree` usable? It landed in git 2.38, and the
# runner's own container image (.claude/.automation/Dockerfile, FROM
# ubuntu:22.04) ships git 2.34.1 — so the fallback below is not hypothetical.
#
# Probed by merging main with itself: that is clean by construction, so exit 0
# means the option is understood. An older git rejects the unknown option and
# exits non-zero. The probe matters because below its introduction version git
# ECHOES an unknown long option back rather than failing cleanly in some
# subcommands (AI.md Tooling Floor), so capability must be established by
# behaviour rather than by parsing a version string.
_or_merge_tree_available() {
  if [ -z "$_OR_HAVE_MERGE_TREE" ]; then
    if [ "${REPO_OS_OVERLAP_NO_MERGE_TREE:-0}" = "1" ]; then
      _OR_HAVE_MERGE_TREE="no"
    elif _or_git merge-tree --write-tree "$_OR_MAIN" "$_OR_MAIN" >/dev/null 2>&1; then
      _OR_HAVE_MERGE_TREE="yes"
    else
      _OR_HAVE_MERGE_TREE="no"
    fi
  fi
  [ "$_OR_HAVE_MERGE_TREE" = "yes" ]
}

# --- Predict via merge-tree ---
# Sets _OR_CF. Returns 0 clean, 1 conflict, 2 undetermined (caller falls back).
#
# `--name-only` is deliberately not used: it was added to merge-tree later than
# `--write-tree`, so requiring it would narrow the supported window for no gain.
# The default output is a tree OID, then conflicted-file-info lines
# ("<mode> <oid> <stage>\t<path>", up to three stages per path), a blank line,
# then informational messages.
_or_predict_merge_tree() {
  local out rc=0 line path first=true
  _OR_CF=""
  out=$(_or_git merge-tree --write-tree "$1" "$2" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$rc" -ne 1 ]; then
    return 2
  fi
  while IFS= read -r line; do
    if [ "$first" = true ]; then
      first=false
      continue
    fi
    [ -n "$line" ] || break
    case "$line" in
      *"$_OR_TAB"*) path="${line##*"$_OR_TAB"}" ;;
      *) continue ;;
    esac
    path="${path#\"}"
    path="${path%\"}"
    [ -n "$path" ] || continue
    _OR_CF=$(_or_add_line "$_OR_CF" "$path")
  done <<EOF
$out
EOF
  return 1
}

# --- Predict via a scratch worktree trial merge ---
# Sets _OR_CF. Returns 0 clean, 1 conflict, 2 undetermined.
# The trial runs in a detached worktree under $TMPDIR which is thrown away
# afterwards, so no reset of any working tree is needed and main is untouched.
_or_predict_worktree() {
  local tmp wt rc=0
  _OR_CF=""
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/repo-os-overlap-XXXXXX" 2>/dev/null) || return 2
  wt="$tmp/wt"
  if ! _or_git worktree add --detach "$wt" "$1" >/dev/null 2>&1; then
    rm -rf "$tmp" 2>/dev/null || true
    return 2
  fi
  if git -C "$wt" merge --no-commit --no-ff "$2" >/dev/null 2>&1; then
    rc=0
  else
    rc=1
    # Captured, so unterminated — which is how the merge-tree path leaves it
    # too: `_or_add_line` does terminate, but every call there is wrapped in
    # `$( )`, which strips the trailing newline straight back off. The brief
    # requires the two paths to be directly comparable, so neither
    # re-terminates. Do not "fix" one side without the other.
    _OR_CF=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || true)
    if [ -z "$_OR_CF" ]; then
      # Non-zero with no unmerged paths is not a conflict we can name — e.g.
      # git refused the merge outright. Report undetermined rather than
      # inventing a clean or a conflict verdict.
      rc=2
    fi
  fi
  git -C "$wt" merge --abort >/dev/null 2>&1 || true
  _or_git worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -rf "$tmp" 2>/dev/null || true
  return "$rc"
}

# --- Predict, preferring merge-tree and falling back to the trial merge ---
# Sets _OR_CF and _OR_CONFLICT_METHOD. Returns 0 clean, 1 conflict, 2 undetermined.
_or_predict_conflict() {
  local rc=0
  if _or_merge_tree_available; then
    _or_predict_merge_tree "$1" "$2" || rc=$?
    if [ "$rc" -ne 2 ]; then
      _OR_CONFLICT_METHOD="merge-tree"
      return "$rc"
    fi
  fi
  rc=0
  _or_predict_worktree "$1" "$2" || rc=$?
  _OR_CONFLICT_METHOD="worktree"
  return "$rc"
}

# --- Most recent main commit touching any of the files in newline-list $2 ---
# Arguments: $1 — merge-base; $2 — newline list of paths
# Output: abbreviated SHA, or empty.
_or_last_main_commit() {
  local line n=0
  local paths=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    paths[$n]="$line"
    n=$((n + 1))
  done <<EOF
$2
EOF
  if [ "$n" -eq 0 ]; then
    printf ''
    return 0
  fi
  _or_git log -1 --format=%h "$1..$_OR_MAIN" -- "${paths[@]}" 2>/dev/null || printf ''
}

# --- Relabel every branch carrying set label $1 to label $2 ---
# Grouping is a flat relabel rather than union-find: branch counts here are
# single digits and set membership is never queried after construction, so
# path compression would be machinery without a payer.
_or_relabel() {
  local from="$1" to="$2" k=0
  if [ "$from" = "$to" ]; then
    return 0
  fi
  while [ "$k" -lt "$_OR_N" ]; do
    if [ "${_OR_SET[$k]}" = "$from" ]; then
      _OR_SET[$k]="$to"
    fi
    k=$((k + 1))
  done
}

# --- Build the report ----------------------------------------------------
# Arguments: $1 — repo dir (default .); $2 — main ref (default main)
# Returns 1 when the main ref cannot be resolved.
overlap_report_build() {
  _OR_REPO="${1:-.}"
  _OR_MAIN="${2:-main}"
  _OR_N=0
  _OR_NPAIR=0
  _OR_BRANCH=()
  _OR_FILES=()
  _OR_UNCOMMITTED=()
  _OR_MB=()
  _OR_SET=()
  _OR_PAIR_A=()
  _OR_PAIR_B=()
  _OR_PAIR_CONFLICT=()
  _OR_PAIR_CFILES=()
  _OR_PAIR_SHARED=()
  _OR_MC_FILES=()
  _OR_MC_COMMIT=()
  _OR_CF=""
  _OR_HAVE_MERGE_TREE=""
  _OR_CONFLICT_METHOD=""
  _OR_GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  _or_git rev-parse --verify --quiet "$_OR_MAIN" >/dev/null 2>&1 || return 1

  # --- Per-branch changed files ---
  local b mb files unc wt u
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    mb=$(_or_git merge-base "$_OR_MAIN" "$b" 2>/dev/null) || continue
    [ -n "$mb" ] || continue
    files=$(_or_git diff --name-only "$mb..$b" 2>/dev/null || true)
    if [ -n "$files" ]; then
      files="${files}
"
    fi
    unc=""
    wt=$(_or_worktree_for_branch "$b")
    if [ -n "$wt" ]; then
      unc=$(_or_uncommitted_files "$wt")
      while IFS= read -r u; do
        [ -n "$u" ] || continue
        files=$(_or_add_line "$files" "$u")
      done <<EOF
$unc
EOF
    fi
    _OR_BRANCH[$_OR_N]="$b"
    _OR_FILES[$_OR_N]="$files"
    _OR_UNCOMMITTED[$_OR_N]="$unc"
    _OR_MB[$_OR_N]="$mb"
    _OR_SET[$_OR_N]="$_OR_N"
    _OR_N=$((_OR_N + 1))
  done <<EOF
$(_or_open_branches)
EOF

  # --- Pairwise sharing, conflict prediction, set grouping ---
  local i j shared rc cfiles
  i=0
  while [ "$i" -lt "$_OR_N" ]; do
    j=$((i + 1))
    while [ "$j" -lt "$_OR_N" ]; do
      shared=$(_or_intersect "${_OR_FILES[$i]}" "${_OR_FILES[$j]}")
      if [ -n "$shared" ]; then
        rc=0
        _or_predict_conflict "${_OR_BRANCH[$i]}" "${_OR_BRANCH[$j]}" || rc=$?
        cfiles=""
        if [ "$rc" -eq 1 ]; then
          cfiles="$_OR_CF"
        fi
        _OR_PAIR_A[$_OR_NPAIR]="$i"
        _OR_PAIR_B[$_OR_NPAIR]="$j"
        _OR_PAIR_CONFLICT[$_OR_NPAIR]="$rc"
        _OR_PAIR_CFILES[$_OR_NPAIR]="$cfiles"
        _OR_PAIR_SHARED[$_OR_NPAIR]="$shared"
        _OR_NPAIR=$((_OR_NPAIR + 1))
        _or_relabel "${_OR_SET[$j]}" "${_OR_SET[$i]}"
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done

  # --- Files main changed under each branch ---
  local main_files overlap commit
  i=0
  while [ "$i" -lt "$_OR_N" ]; do
    main_files=$(_or_git diff --name-only "${_OR_MB[$i]}..$_OR_MAIN" 2>/dev/null || true)
    if [ -n "$main_files" ]; then
      main_files="${main_files}
"
    fi
    overlap=$(_or_intersect "${_OR_FILES[$i]}" "$main_files")
    commit=""
    if [ -n "$overlap" ]; then
      commit=$(_or_last_main_commit "${_OR_MB[$i]}" "$overlap")
    fi
    _OR_MC_FILES[$i]="$overlap"
    _OR_MC_COMMIT[$i]="$commit"
    i=$((i + 1))
  done
}

# --- Set accessors -------------------------------------------------------
# How many branches carry set label $1?
_or_set_size() {
  local lbl="$1" i=0 c=0
  while [ "$i" -lt "$_OR_N" ]; do
    if [ "${_OR_SET[$i]}" = "$lbl" ]; then
      c=$((c + 1))
    fi
    i=$((i + 1))
  done
  printf '%s' "$c"
}

# Set labels with more than one member, in first-appearance order. A branch
# sharing nothing stays in a set of one and is not reported as a set.
_or_set_labels() {
  local i=0 lbl out=""
  while [ "$i" -lt "$_OR_N" ]; do
    lbl="${_OR_SET[$i]}"
    if ! _or_has_line "$out" "$lbl"; then
      if [ "$(_or_set_size "$lbl")" -gt 1 ]; then
        out=$(_or_add_line "$out" "$lbl")
      fi
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# Branches in set $1, in index order.
_or_set_branches() {
  local lbl="$1" i=0 out=""
  while [ "$i" -lt "$_OR_N" ]; do
    if [ "${_OR_SET[$i]}" = "$lbl" ]; then
      out=$(_or_add_line "$out" "${_OR_BRANCH[$i]}")
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# Union of the shared files of every pair inside set $1.
_or_set_files() {
  local lbl="$1" p=0 line out=""
  while [ "$p" -lt "$_OR_NPAIR" ]; do
    if [ "${_OR_SET[${_OR_PAIR_A[$p]}]}" = "$lbl" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        out=$(_or_add_line "$out" "$line")
      done <<EOF
${_OR_PAIR_SHARED[$p]}
EOF
    fi
    p=$((p + 1))
  done
  printf '%s' "$out"
}

# State of path $2 within set $1. Precedence: conflict_likely > shared.
_or_file_state() {
  local lbl="$1" path="$2" p=0
  while [ "$p" -lt "$_OR_NPAIR" ]; do
    if [ "${_OR_SET[${_OR_PAIR_A[$p]}]}" = "$lbl" ] && [ "${_OR_PAIR_CONFLICT[$p]}" = "1" ]; then
      if _or_has_line "${_OR_PAIR_CFILES[$p]}" "$path"; then
        printf 'conflict_likely'
        return 0
      fi
    fi
    p=$((p + 1))
  done
  printf 'shared'
}

# Branches in set $1 that touch path $2.
_or_file_branches() {
  local lbl="$1" path="$2" i=0 out=""
  while [ "$i" -lt "$_OR_N" ]; do
    if [ "${_OR_SET[$i]}" = "$lbl" ] && _or_has_line "${_OR_FILES[$i]}" "$path"; then
      out=$(_or_add_line "$out" "${_OR_BRANCH[$i]}")
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# Is path $2 uncommitted working-tree state on any branch in set $1?
_or_file_uncommitted() {
  local lbl="$1" path="$2" i=0
  while [ "$i" -lt "$_OR_N" ]; do
    if [ "${_OR_SET[$i]}" = "$lbl" ] && _or_has_line "${_OR_UNCOMMITTED[$i]}" "$path"; then
      printf 'true'
      return 0
    fi
    i=$((i + 1))
  done
  printf 'false'
}

# Index of branch $1, or empty.
_or_branch_index() {
  local i=0
  while [ "$i" -lt "$_OR_N" ]; do
    if [ "${_OR_BRANCH[$i]}" = "$1" ]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  printf ''
}

# --- JSON helpers --------------------------------------------------------
# Escape and quote a scalar. Backslashes first, then double quotes.
_or_json_str() {
  local val="$1" out=""
  while case "$val" in *\\*) true ;; *) false ;; esac; do
    out="${out}${val%%\\*}\\\\"
    val="${val#*\\}"
  done
  val="${out}${val}"
  out=""
  while case "$val" in *'"'*) true ;; *) false ;; esac; do
    out="${out}${val%%\"*}\\\""
    val="${val#*\"}"
  done
  printf '"%s"' "${out}${val}"
}

# Render newline-list $1 as a JSON array of strings.
_or_json_arr() {
  local line first=true
  printf '['
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$first" = true ]; then
      first=false
    else
      printf ','
    fi
    _or_json_str "$line"
  done <<EOF
$1
EOF
  printf ']'
}

# --- Does set $1 contain branch $2 (empty $2 means "no filter")? ---
_or_set_selected() {
  if [ -z "$2" ]; then
    return 0
  fi
  _or_has_line "$(_or_set_branches "$1")" "$2"
}

# --- JSON render ---------------------------------------------------------
# Arguments: $1 — optional branch filter. With a filter, only the set
# containing that branch and that branch's main_changed entry are emitted;
# the rest of the set is kept, because the point of a filter is to see who the
# branch shares with.
#
# `conflict_method` is not in the shape the brief fixed. It is here because the
# two prediction paths are not interchangeable in practice — one environment
# has merge-tree and the other does not — so a consumer reading a verdict needs
# to know which produced it, and the parity test needs it to prove it really
# exercised both paths rather than running merge-tree twice.
overlap_report_json() {
  local filter="${1:-}"
  local lbl path setid=0 first_set=true first_file first_mc=true i

  printf '{'
  printf '"generated_at":'
  _or_json_str "$_OR_GENERATED_AT"
  printf ',"conflict_method":'
  _or_json_str "$_OR_CONFLICT_METHOD"
  printf ',"sets":['
  while IFS= read -r lbl; do
    [ -n "$lbl" ] || continue
    setid=$((setid + 1))
    _or_set_selected "$lbl" "$filter" || continue
    if [ "$first_set" = true ]; then
      first_set=false
    else
      printf ','
    fi
    printf '{"id":%s,"branches":' "$setid"
    _or_json_arr "$(_or_set_branches "$lbl")"
    printf ',"files":['
    first_file=true
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      if [ "$first_file" = true ]; then
        first_file=false
      else
        printf ','
      fi
      printf '{"path":'
      _or_json_str "$path"
      printf ',"branches":'
      _or_json_arr "$(_or_file_branches "$lbl" "$path")"
      printf ',"state":'
      _or_json_str "$(_or_file_state "$lbl" "$path")"
      printf ',"uncommitted":%s}' "$(_or_file_uncommitted "$lbl" "$path")"
    done <<EOF
$(_or_set_files "$lbl")
EOF
    printf ']}'
  done <<EOF
$(_or_set_labels)
EOF
  printf '],"main_changed":['
  i=0
  while [ "$i" -lt "$_OR_N" ]; do
    if [ -n "${_OR_MC_FILES[$i]}" ]; then
      if [ -z "$filter" ] || [ "${_OR_BRANCH[$i]}" = "$filter" ]; then
        if [ "$first_mc" = true ]; then
          first_mc=false
        else
          printf ','
        fi
        printf '{"branch":'
        _or_json_str "${_OR_BRANCH[$i]}"
        printf ',"files":'
        _or_json_arr "${_OR_MC_FILES[$i]}"
        printf ',"by_commit":'
        _or_json_str "${_OR_MC_COMMIT[$i]}"
        printf '}'
      fi
    fi
    i=$((i + 1))
  done
  printf ']}\n'
}

# --- Text render ---------------------------------------------------------
# Arguments: $1 — optional branch filter (same semantics as the JSON render).
overlap_report_text() {
  local filter="${1:-}"
  local lbl path setid=0 any_set=false any_mc=false i state unc branches

  printf 'Overlap report — generated %s' "$_OR_GENERATED_AT"
  if [ -n "$_OR_CONFLICT_METHOD" ]; then
    printf ' (conflict prediction: %s)' "$_OR_CONFLICT_METHOD"
  fi
  printf '\n'
  printf 'Open branches: %s\n' "$_OR_N"

  while IFS= read -r lbl; do
    [ -n "$lbl" ] || continue
    setid=$((setid + 1))
    _or_set_selected "$lbl" "$filter" || continue
    any_set=true
    printf '\nSet %s: %s\n' "$setid" "$(_or_set_branches "$lbl" | tr '\n' ' ')"
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      state=$(_or_file_state "$lbl" "$path")
      unc=$(_or_file_uncommitted "$lbl" "$path")
      branches=$(_or_file_branches "$lbl" "$path" | tr '\n' ' ')
      printf '  %-15s %s' "$state" "$path"
      if [ "$unc" = "true" ]; then
        printf ' (uncommitted)'
      fi
      printf '  [%s]\n' "$branches"
    done <<EOF
$(_or_set_files "$lbl")
EOF
  done <<EOF
$(_or_set_labels)
EOF

  if [ "$any_set" = false ]; then
    printf '\nNo shared files between open branches.\n'
  fi

  i=0
  while [ "$i" -lt "$_OR_N" ]; do
    if [ -n "${_OR_MC_FILES[$i]}" ]; then
      if [ -z "$filter" ] || [ "${_OR_BRANCH[$i]}" = "$filter" ]; then
        if [ "$any_mc" = false ]; then
          any_mc=true
          printf '\nMain changed since branch point:\n'
        fi
        printf '  %s (last main commit %s)\n' "${_OR_BRANCH[$i]}" "${_OR_MC_COMMIT[$i]:-unknown}"
        printf '%s\n' "${_OR_MC_FILES[$i]%"$_OR_NL"}" | sed 's/^/    /'
      fi
    fi
    i=$((i + 1))
  done
}

# --- Stateless single-branch helpers -------------------------------------
# `overlap_report_build` answers question 3 for every open branch at once and
# parks the answer in `_OR_MC_*`. A close-time caller has one branch and is
# often mid-report itself, so these two take their repo and refs as arguments
# and read or write no `_OR_*` state at all — calling them cannot stomp a built
# report, and they need no build first. The only shared code is `_or_intersect`
# (and the `_or_has_line` it calls), which are pure string functions.

# --- Files BOTH the branch and main changed since their merge-base --------
# Arguments: $1 — repo dir; $2 — main ref; $3 — branch ref
# Output:    newline-terminated list of overlapping paths; empty when none.
# Returns:   1 when the merge-base cannot be computed (missing ref, unrelated
#            histories). That is "cannot tell", NOT "no overlap" — a caller
#            gating a merge on this must fail closed on a non-zero return.
overlap_report_main_changed() {
  local repo="$1" main_ref="$2" branch="$3"
  local mb branch_files main_files

  mb=$(git -C "$repo" merge-base "$main_ref" "$branch" 2>/dev/null) || return 1
  [ -n "$mb" ] || return 1

  branch_files=$(git -C "$repo" diff --name-only "$mb..$branch" 2>/dev/null || true)
  main_files=$(git -C "$repo" diff --name-only "$mb..$main_ref" 2>/dev/null || true)

  # Terminated exactly as overlap_report_build terminates its own lists, so the
  # two producers of a main-changed list cannot drift apart.
  if [ -n "$main_files" ]; then
    main_files="${main_files}
"
  fi

  _or_intersect "$branch_files" "$main_files"
}

# --- Most recent main commit touching any of the given paths --------------
# Arguments: $1 — repo dir; $2 — main ref; $3 — branch ref;
#            $4 — newline list of paths (typically the helper above's output)
# Output:    abbreviated SHA, or empty when there is no such commit.
overlap_report_main_commit() {
  local repo="$1" main_ref="$2" branch="$3"
  local mb line n=0
  local paths=()

  mb=$(git -C "$repo" merge-base "$main_ref" "$branch" 2>/dev/null) || return 0
  [ -n "$mb" ] || return 0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    paths[$n]="$line"
    n=$((n + 1))
  done <<EOF
$4
EOF

  # `"${paths[@]}"` on an empty array is an unbound-variable error under
  # `set -u` in bash 3.2, so the count is checked rather than the expansion.
  [ "$n" -gt 0 ] || return 0

  git -C "$repo" log -1 --format=%h "$mb..$main_ref" -- "${paths[@]}" 2>/dev/null || true
}
