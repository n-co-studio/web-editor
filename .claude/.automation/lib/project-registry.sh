#!/usr/bin/env bash
# project-registry.sh — the repo's projects and their ordered milestones
# (Decision t-0079; schema .claude/.automation/schemas/project-registry.yaml).
#
# The registry is the source for project names, milestone names, their order,
# and milestones that have no task yet. Task fields stay the source for which
# milestone a task is in. The file belongs to the repo: the template ships no
# copy and template sync never writes or sweeps it (.templatesyncignore).
#
# Absent file: no validation, and nothing is created except by `projects add`
# or by the auto-add of a project found on a task. A file that exists but
# cannot be read is an error, never treated as absent — that would silently
# turn the checks off.
#
# Writers: every write here runs under the queue lock (the caller holds it),
# re-reads the file first, and replaces it atomically (temp file + mv in the
# same directory). An outside writer that edits the file directly must replace
# it atomically too.
#
# Requires: _yaml_escape_scalar and _strip_quotes (queue-manager.sh).
# Bash 3.2 compatible: indexed arrays only.

PROJECT_REGISTRY_SCHEMA_VERSION="1.0.0"

# Fixed path, relative to the repo root.
project_registry_file() {
  printf '%s/docs/ai/project-registry.yaml' "${REPO_ROOT:?REPO_ROOT not set}"
}

# Matching ignores case and all whitespace; the registry's spelling is canonical.
project_registry_norm() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

# A name value must be exactly one double-quoted scalar. Anything after the
# closing quote (a trailing comment, say) would otherwise be read as part of the
# name, so it is refused instead. Best effort, not a full scalar parser: it
# catches the shapes a hand edit produces, and the writer never emits others.
_project_registry_quoted() {
  case "$1" in
    '"'*'"') ;;
    *) return 1 ;;
  esac
  # The closing quote must not itself be escaped (\" ends inside the value),
  # unless the backslash before it is an escaped backslash (\\").
  case "$1" in
    *'\\"') return 0 ;;
    *'\"')  return 1 ;;
  esac
  return 0
}

# A name is one line: a newline or CR would be written inside the quoted value
# and make the file unreadable, which blocks every later add.
project_registry_valid_name() {
  case "$1" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  [ -n "$(project_registry_norm "$1")" ]
}

# Loaded state. Milestone names of project i are _PR_MS[_PR_MS_START[i]] ..
# _PR_MS[_PR_MS_START[i] + _PR_MS_COUNT[i] - 1], in index order.
_PR_COUNT=0
_PR_NAMES=()
_PR_MS_START=()
_PR_MS_COUNT=()
_PR_MS=()

# Load the registry. Returns 0 when loaded, 1 when the file is absent (state is
# empty), 2 when it exists but is invalid (message on stderr).
project_registry_load() {
  local f line n=-1 ms_open=false want_name=false expect_idx=0
  local v key
  f=$(project_registry_file)
  _PR_COUNT=0; _PR_NAMES=(); _PR_MS_START=(); _PR_MS_COUNT=(); _PR_MS=()
  [ -f "$f" ] || return 1

  local version="" lineno=0 seen=""
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # Trailing whitespace, a CR from a CRLF file included, carries nothing.
    line="${line%"${line##*[![:space:]]}"}"
    # Blank lines and comment lines (any indentation) carry nothing.
    case "${line#"${line%%[![:space:]]*}"}" in ''|'#'*) continue ;; esac
    case "$line" in
      'schema_version: '*)
        version=$(_strip_quotes "${line#schema_version: }") ;;
      'projects:'|'projects: []') ;;
      '  - name: '*)
        if [ "$want_name" = true ]; then
          echo "ERROR: project registry $f line $lineno: milestone $expect_idx has no name" >&2; return 2
        fi
        _project_registry_quoted "${line#  - name: }" || {
          echo "ERROR: project registry $f line $lineno: a name must be one double-quoted value, nothing after it" >&2; return 2; }
        v=$(_strip_quotes "${line#  - name: }")
        if [ -z "$v" ]; then
          echo "ERROR: project registry $f line $lineno: empty project name" >&2; return 2
        fi
        key=$(project_registry_norm "$v")
        case "$seen" in
          *"|$key|"*) echo "ERROR: project registry $f line $lineno: '$v' duplicates another project (names ignore case and spacing)" >&2; return 2 ;;
        esac
        seen="${seen}|$key|"
        n=$((n + 1))
        _PR_NAMES[n]="$v"; _PR_MS_START[n]=${#_PR_MS[@]}; _PR_MS_COUNT[n]=0
        ms_open=false; expect_idx=0 ;;
      '    milestones:'|'    milestones: []')
        [ "$n" -ge 0 ] || { echo "ERROR: project registry $f line $lineno: milestones before any project" >&2; return 2; }
        ms_open=true ;;
      '      - index: '*)
        if [ "$ms_open" != true ] || [ "$want_name" = true ]; then
          echo "ERROR: project registry $f line $lineno: unexpected milestone" >&2; return 2
        fi
        v=$(_strip_quotes "${line#      - index: }")
        expect_idx=$((expect_idx + 1))
        if [ "$v" != "$expect_idx" ]; then
          echo "ERROR: project registry $f line $lineno: milestone index '$v' — indexes must run 1..N in order (expected $expect_idx)" >&2; return 2
        fi
        want_name=true ;;
      '        name: '*)
        if [ "$want_name" != true ]; then
          echo "ERROR: project registry $f line $lineno: milestone name without an index" >&2; return 2
        fi
        _project_registry_quoted "${line#        name: }" || {
          echo "ERROR: project registry $f line $lineno: a name must be one double-quoted value, nothing after it" >&2; return 2; }
        v=$(_strip_quotes "${line#        name: }")
        if [ -z "$v" ]; then
          echo "ERROR: project registry $f line $lineno: empty milestone name" >&2; return 2
        fi
        _PR_MS[${#_PR_MS[@]}]="$v"
        _PR_MS_COUNT[n]=$((_PR_MS_COUNT[n] + 1))
        want_name=false ;;
      *)
        echo "ERROR: project registry $f line $lineno: unrecognised line (see .claude/.automation/schemas/project-registry.yaml)" >&2
        return 2 ;;
    esac
  done < "$f"

  if [ "$want_name" = true ]; then
    echo "ERROR: project registry $f: milestone $expect_idx has no name" >&2; return 2
  fi
  case "$version" in
    1.*) ;;
    '') echo "ERROR: project registry $f: no schema_version" >&2; return 2 ;;
    *)  echo "ERROR: project registry $f: schema_version '$version' is not supported (this Repo OS reads 1.x)" >&2; return 2 ;;
  esac
  _PR_COUNT=$((n + 1))
  return 0
}

# Echo the position of a project (normalised match), or return 1.
project_registry_find() {
  local key i
  key=$(project_registry_norm "$1")
  [ -n "$key" ] || return 1
  i=0
  while [ "$i" -lt "$_PR_COUNT" ]; do
    if [ "$(project_registry_norm "${_PR_NAMES[i]}")" = "$key" ]; then
      printf '%s' "$i"; return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# Name of milestone <index> (1-based) of project position <i>.
_project_registry_ms_name() {
  local i="$1" idx="$2"
  printf '%s' "${_PR_MS[$((_PR_MS_START[i] + idx - 1))]}"
}

# Write the loaded state back, atomically. An optional path writes there instead
# (milestone-plan.sh stages the registry before moving it into place).
_project_registry_write() {
  local f tmp i j start
  f="${1:-$(project_registry_file)}"
  mkdir -p "$(dirname "$f")" || return 1
  tmp="$f.tmp.$$"
  {
    printf '# Project registry — schema .claude/.automation/schemas/project-registry.yaml (Decision t-0079)\n'
    printf 'schema_version: "%s"\n' "$PROJECT_REGISTRY_SCHEMA_VERSION"
    if [ "$_PR_COUNT" -eq 0 ]; then
      printf 'projects: []\n'
    else
      printf 'projects:\n'
    fi
    i=0
    while [ "$i" -lt "$_PR_COUNT" ]; do
      printf '  - name: "%s"\n' "$(_yaml_escape_scalar "${_PR_NAMES[i]}")"
      if [ "${_PR_MS_COUNT[i]}" -eq 0 ]; then
        printf '    milestones: []\n'
      else
        printf '    milestones:\n'
        start=${_PR_MS_START[i]}; j=0
        while [ "$j" -lt "${_PR_MS_COUNT[i]}" ]; do
          printf '      - index: %s\n' "$((j + 1))"
          printf '        name: "%s"\n' "$(_yaml_escape_scalar "${_PR_MS[$((start + j))]}")"
          j=$((j + 1))
        done
      fi
      i=$((i + 1))
    done
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# Add a project with the given milestone names. Caller holds the queue lock.
# Re-reads the file first, so another writer's change since the caller's read
# is kept. Returns 0 added, 3 name taken (prints NAME_TAKEN: <existing>),
# 2 registry invalid, 1 write failure.
project_registry_add() {
  local name="$1"; shift
  local rc=0 pos m
  project_registry_load || rc=$?
  [ "$rc" -eq 2 ] && return 2
  if pos=$(project_registry_find "$name"); then
    printf 'NAME_TAKEN: %s\n' "${_PR_NAMES[pos]}"
    return 3
  fi
  # Two milestones whose names match would make a name lookup ambiguous.
  local seen_ms="" mk
  for m in "$@"; do
    mk=$(project_registry_norm "$m")
    case "$seen_ms" in
      *"|$mk|"*) echo "ERROR: milestone '$m' is given twice (names ignore case and spacing)" >&2; return 1 ;;
    esac
    seen_ms="${seen_ms}|$mk|"
  done
  _PR_NAMES[_PR_COUNT]="$name"
  _PR_MS_START[_PR_COUNT]=${#_PR_MS[@]}
  _PR_MS_COUNT[_PR_COUNT]=0
  for m in "$@"; do
    _PR_MS[${#_PR_MS[@]}]="$m"
    _PR_MS_COUNT[_PR_COUNT]=$((_PR_MS_COUNT[_PR_COUNT] + 1))
  done
  _PR_COUNT=$((_PR_COUNT + 1))
  _project_registry_write || return 1
  return 0
}

# Resolve a task's project and milestone against the registry.
# Args: project ms_name ms_index ms_total name_explicit total_explicit
# Sets _REG_PROJECT _REG_MS_NAME _REG_MS_INDEX _REG_MS_TOTAL, and _REG_AUTOADD
# (true when the project is not registered yet; the caller adds it once the task
# is written). Returns 0, 1 on a validation error, 2 on an invalid registry. With
# no registry file it passes everything through unchanged.
project_registry_resolve() {
  local project="$1" ms_name="$2" ms_index="${3:-0}" ms_total="${4:-0}"
  local name_explicit="${5:-false}" total_explicit="${6:-false}"
  local rc=0 pos n j reg_name
  _REG_PROJECT="$project"; _REG_MS_NAME="$ms_name"
  _REG_MS_INDEX="$ms_index"; _REG_MS_TOTAL="$ms_total"; _REG_AUTOADD=false
  [ -n "$ms_index" ] || ms_index=0
  [ -n "$ms_total" ] || ms_total=0

  project_registry_load || rc=$?
  [ "$rc" -eq 1 ] && return 0
  [ "$rc" -eq 2 ] && return 2
  [ -n "$project" ] || return 0
  if ! project_registry_valid_name "$project"; then
    echo "ERROR: a project name must be one line" >&2; return 1
  fi
  if [ -n "$ms_name" ] && ! project_registry_valid_name "$ms_name"; then
    echo "ERROR: a milestone name must be one line" >&2; return 1
  fi

  if ! pos=$(project_registry_find "$project"); then
    _REG_AUTOADD=true
    return 0
  fi
  _REG_PROJECT="${_PR_NAMES[pos]}"
  if [ "$_REG_PROJECT" != "$project" ]; then
    echo "Note: project '$project' is registered as '$_REG_PROJECT'; using that spelling" >&2
  fi
  n=${_PR_MS_COUNT[pos]}
  [ "$n" -gt 0 ] || return 0   # no milestones registered: task fields stand

  if [ "$ms_index" -eq 0 ] && [ "$name_explicit" = true ] && [ -n "$ms_name" ]; then
    j=1
    while [ "$j" -le "$n" ]; do
      if [ "$(project_registry_norm "$(_project_registry_ms_name "$pos" "$j")")" = "$(project_registry_norm "$ms_name")" ]; then
        ms_index=$j; break
      fi
      j=$((j + 1))
    done
    if [ "$ms_index" -eq 0 ]; then
      echo "ERROR: project '$_REG_PROJECT' has no milestone named '$ms_name'" >&2; return 1
    fi
  fi
  if [ "$ms_index" -eq 0 ]; then
    if [ "$total_explicit" = true ] && [ "$ms_total" -ne 0 ] && [ "$ms_total" -ne "$n" ]; then
      echo "ERROR: project '$_REG_PROJECT' has $n milestones, not $ms_total" >&2; return 1
    fi
    return 0
  fi
  if [ "$ms_index" -gt "$n" ]; then
    echo "ERROR: project '$_REG_PROJECT' has $n milestones; there is no milestone $ms_index" >&2; return 1
  fi
  reg_name=$(_project_registry_ms_name "$pos" "$ms_index")
  if [ "$name_explicit" = true ] && [ -n "$ms_name" ] \
     && [ "$(project_registry_norm "$ms_name")" != "$(project_registry_norm "$reg_name")" ]; then
    echo "ERROR: milestone $ms_index of project '$_REG_PROJECT' is '$reg_name', not '$ms_name'" >&2; return 1
  fi
  if [ "$total_explicit" = true ] && [ "$ms_total" -ne 0 ] && [ "$ms_total" -ne "$n" ]; then
    echo "ERROR: project '$_REG_PROJECT' has $n milestones, not $ms_total" >&2; return 1
  fi
  _REG_MS_INDEX="$ms_index"; _REG_MS_NAME="$reg_name"; _REG_MS_TOTAL="$n"
  return 0
}

# Add an auto-detected project after its task is written. Caller holds the lock.
# A concurrent add of the same name is fine (NAME_TAKEN is swallowed).
project_registry_autoadd() {
  local name="$1" rc=0
  project_registry_add "$name" >/dev/null || rc=$?
  case "$rc" in
    0) echo "Note: project '$name' was not in the registry — added it (check the spelling if that is unexpected)" >&2; return 0 ;;
    3) return 0 ;;
    *) echo "WARNING: could not add project '$name' to the registry" >&2; return "$rc" ;;
  esac
}
