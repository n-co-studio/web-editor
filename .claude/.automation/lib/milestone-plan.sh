#!/usr/bin/env bash
# milestone-plan.sh — apply a milestone plan to one project, all or nothing
# (Decision t-0080; plan schema .claude/.automation/schemas/milestone-plan.yaml).
#
# A plan is the project's complete new milestone list. Each milestone may name
# the old index it was (`from`), which covers rename and reorder; one without
# `from` is new. An old milestone no plan milestone comes from is deleted, and
# must have a move saying where its tasks go (another new index, or none).
# Optionally the project itself is renamed.
#
# The apply touches the registry and every queue entry (all statuses) and work
# order in the project. Phase 1 validates everything and stages the new files
# without touching a live one. Phase 2 backs up each original, moves the staged
# files into place with the registry last, and restores every moved file if a
# move fails. Caller holds the queue lock for both phases.
#
# Requires: project-registry.sh, queue-manager.sh, work-order-manager.sh.
# Bash 3.2 compatible: indexed arrays only.

# Parsed plan.
_MP_RENAME=""
_MP_NEW_COUNT=0
_MP_NEW_NAMES=()
_MP_NEW_FROM=()     # old index, 0 = new milestone
_MP_MOVE_COUNT=0
_MP_MOVE_FROM=()
_MP_MOVE_TO=()      # new index, 0 = none

# Parse a plan file. Returns 0, or 1 with a message on stderr. Indexes are
# plain decimals: a leading zero is refused, because `[ ]` reads 010 as ten but
# an array subscript reads it as octal (and 08 as an error).
milestone_plan_parse() {
  local f="$1" line v lineno=0 section="" version="" item_open=false seen=""
  _MP_RENAME=""; _MP_NEW_COUNT=0; _MP_NEW_NAMES=(); _MP_NEW_FROM=()
  _MP_MOVE_COUNT=0; _MP_MOVE_FROM=(); _MP_MOVE_TO=()
  [ -f "$f" ] || { echo "ERROR: plan file $f not found" >&2; return 1; }

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%"${line##*[![:space:]]}"}"
    case "${line#"${line%%[![:space:]]*}"}" in ''|'#'*) continue ;; esac
    case "$line" in
      'schema_version: '*|'rename_to: '*|'milestones:'*|'moves:'*)
        # Each top-level key once: a second milestones: would silently append.
        case "$seen" in *"|${line%%:*}|"*)
          echo "ERROR: plan $f line $lineno: ${line%%:*} appears twice" >&2; return 1 ;;
        esac
        seen="${seen}|${line%%:*}|" ;;
    esac
    case "$line" in
      'schema_version: '*)
        version=$(_strip_quotes "${line#schema_version: }") ;;
      'rename_to: '*)
        _project_registry_quoted "${line#rename_to: }" || {
          echo "ERROR: plan $f line $lineno: a name must be one double-quoted value, nothing after it" >&2; return 1; }
        _MP_RENAME=$(_strip_quotes "${line#rename_to: }")
        project_registry_valid_name "$_MP_RENAME" || {
          echo "ERROR: plan $f line $lineno: rename_to must be one non-blank line" >&2; return 1; } ;;
      'milestones:'|'milestones: []') section=milestones; item_open=false ;;
      'moves:'|'moves: []')           section=moves; item_open=false ;;
      '  - name: '*)
        [ "$section" = milestones ] || { echo "ERROR: plan $f line $lineno: a milestone name outside milestones:" >&2; return 1; }
        _project_registry_quoted "${line#  - name: }" || {
          echo "ERROR: plan $f line $lineno: a name must be one double-quoted value, nothing after it" >&2; return 1; }
        v=$(_strip_quotes "${line#  - name: }")
        project_registry_valid_name "$v" || { echo "ERROR: plan $f line $lineno: empty milestone name" >&2; return 1; }
        _MP_NEW_NAMES[_MP_NEW_COUNT]="$v"; _MP_NEW_FROM[_MP_NEW_COUNT]=0
        _MP_NEW_COUNT=$((_MP_NEW_COUNT + 1)); item_open=true ;;
      '    from: '*)
        v="${line#    from: }"
        case "$v" in ''|*[!0-9]*|0*|???????*) echo "ERROR: plan $f line $lineno: from must be an old milestone index (1 or more)" >&2; return 1 ;; esac
        if [ "$section" = milestones ] && [ "$item_open" = true ]; then
          [ "${_MP_NEW_FROM[_MP_NEW_COUNT - 1]}" = 0 ] || { echo "ERROR: plan $f line $lineno: a milestone has two from lines" >&2; return 1; }
          _MP_NEW_FROM[_MP_NEW_COUNT - 1]="$v"
        else
          echo "ERROR: plan $f line $lineno: from without a milestone" >&2; return 1
        fi ;;
      '  - from: '*)
        [ "$section" = moves ] || { echo "ERROR: plan $f line $lineno: a move outside moves:" >&2; return 1; }
        v="${line#  - from: }"
        case "$v" in ''|*[!0-9]*|0*|???????*) echo "ERROR: plan $f line $lineno: from must be an old milestone index (1 or more)" >&2; return 1 ;; esac
        _MP_MOVE_FROM[_MP_MOVE_COUNT]="$v"; _MP_MOVE_TO[_MP_MOVE_COUNT]=""
        _MP_MOVE_COUNT=$((_MP_MOVE_COUNT + 1)); item_open=true ;;
      '    to: '*)
        [ "$section" = moves ] && [ "$item_open" = true ] || { echo "ERROR: plan $f line $lineno: to without a move" >&2; return 1; }
        [ -z "${_MP_MOVE_TO[_MP_MOVE_COUNT - 1]}" ] || { echo "ERROR: plan $f line $lineno: a move has two to lines" >&2; return 1; }
        v="${line#    to: }"
        case "$v" in
          none) v=0 ;;
          ''|*[!0-9]*|0*|???????*) echo "ERROR: plan $f line $lineno: to must be a new milestone index or none" >&2; return 1 ;;
        esac
        _MP_MOVE_TO[_MP_MOVE_COUNT - 1]="$v" ;;
      *)
        echo "ERROR: plan $f line $lineno: unrecognised line (see .claude/.automation/schemas/milestone-plan.yaml)" >&2
        return 1 ;;
    esac
  done < "$f"

  case "$version" in
    1.*) ;;
    '') echo "ERROR: plan $f: no schema_version" >&2; return 1 ;;
    *)  echo "ERROR: plan $f: schema_version '$version' is not supported (this Repo OS reads 1.x)" >&2; return 1 ;;
  esac
  local i=0
  while [ "$i" -lt "$_MP_MOVE_COUNT" ]; do
    [ -n "${_MP_MOVE_TO[i]}" ] || { echo "ERROR: plan $f: the move from ${_MP_MOVE_FROM[i]} has no to" >&2; return 1; }
    i=$((i + 1))
  done
  return 0
}

# Old index -> new index (0 = none), for the project at registry position $1.
_MP_MAP=()
_MP_OLD_COUNT=0
_MP_OLD_NAMES=()

# Check the parsed plan against the registry's project at position $1 and build
# _MP_MAP. Returns 0, 1 refused, 3 rename_to taken (prints NAME_TAKEN).
_milestone_plan_check() {
  local pos="$1" i j o t seen="" k other
  _MP_OLD_COUNT=${_PR_MS_COUNT[pos]}
  _MP_OLD_NAMES=(); _MP_MAP=()
  j=1
  while [ "$j" -le "$_MP_OLD_COUNT" ]; do
    _MP_OLD_NAMES[j]=$(_project_registry_ms_name "$pos" "$j"); _MP_MAP[j]=-1
    j=$((j + 1))
  done

  i=0
  while [ "$i" -lt "$_MP_NEW_COUNT" ]; do
    k=$(project_registry_norm "${_MP_NEW_NAMES[i]}")
    case "$seen" in
      *"|$k|"*) echo "ERROR: milestone '${_MP_NEW_NAMES[i]}' is named twice (names ignore case and spacing)" >&2; return 1 ;;
    esac
    seen="${seen}|$k|"
    o=${_MP_NEW_FROM[i]}
    if [ "$o" -ne 0 ]; then
      if [ "$o" -gt "$_MP_OLD_COUNT" ]; then
        echo "ERROR: from $o — project '${_PR_NAMES[pos]}' has $_MP_OLD_COUNT milestones" >&2; return 1
      fi
      [ "${_MP_MAP[o]}" = -1 ] || { echo "ERROR: old milestone $o is named by two from lines" >&2; return 1; }
      _MP_MAP[o]=$((i + 1))
    fi
    i=$((i + 1))
  done

  i=0
  while [ "$i" -lt "$_MP_MOVE_COUNT" ]; do
    o=${_MP_MOVE_FROM[i]}; t=${_MP_MOVE_TO[i]}
    if [ "$o" -gt "$_MP_OLD_COUNT" ]; then
      echo "ERROR: move from $o — project '${_PR_NAMES[pos]}' has $_MP_OLD_COUNT milestones" >&2; return 1
    fi
    case "${_MP_MAP[o]}" in
      -1) ;;
      -2) echo "ERROR: old milestone $o has two moves" >&2; return 1 ;;
      *)  echo "ERROR: old milestone $o is kept (a from names it), so it cannot also be moved" >&2; return 1 ;;
    esac
    if [ "$t" -gt "$_MP_NEW_COUNT" ]; then
      echo "ERROR: move to $t — the plan has $_MP_NEW_COUNT milestones" >&2; return 1
    fi
    # -2 marks "moved" while the loop runs, so a second move is caught; the
    # real target is written once every move is checked.
    _MP_MAP[o]=-2
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$_MP_MOVE_COUNT" ]; do
    _MP_MAP[${_MP_MOVE_FROM[i]}]=${_MP_MOVE_TO[i]}
    i=$((i + 1))
  done

  j=1
  while [ "$j" -le "$_MP_OLD_COUNT" ]; do
    if [ "${_MP_MAP[j]}" = -1 ]; then
      echo "ERROR: old milestone $j '${_MP_OLD_NAMES[j]}' is deleted by this plan but has no move — add one with to: <index> or to: none" >&2
      return 1
    fi
    j=$((j + 1))
  done

  if [ -n "$_MP_RENAME" ] && other=$(project_registry_find "$_MP_RENAME") && [ "$other" != "$pos" ]; then
    printf 'NAME_TAKEN: %s\n' "${_PR_NAMES[other]}"
    return 3
  fi
  return 0
}

# Map one task's milestone fields. Args: name index total. Sets _MP_T_NAME
# _MP_T_INDEX _MP_T_TOTAL. Returns 1 (message in _MP_T_ERR) when the task's
# milestone matches nothing the plan can map.
_milestone_plan_map_task() {
  local nm="$1" i="${2:-0}" t="${3:-0}" j new=-1 k
  _MP_T_NAME="$nm"; _MP_T_INDEX="$i"; _MP_T_TOTAL="$t"; _MP_T_ERR=""
  case "$i$t" in *[!0-9]*) _MP_T_ERR="milestone index or total is not a number"; return 1 ;; esac
  [ -n "$i" ] || i=0
  [ -n "$t" ] || t=0

  if [ "$_MP_OLD_COUNT" -gt 0 ]; then
    if [ "$i" -gt 0 ]; then
      [ "$i" -le "$_MP_OLD_COUNT" ] || { _MP_T_ERR="milestone $i, but the project has $_MP_OLD_COUNT"; return 1; }
      new=${_MP_MAP[i]}
    elif [ -n "$nm" ]; then
      k=$(project_registry_norm "$nm"); j=1
      while [ "$j" -le "$_MP_OLD_COUNT" ]; do
        [ "$(project_registry_norm "${_MP_OLD_NAMES[j]}")" = "$k" ] && { new=${_MP_MAP[j]}; break; }
        j=$((j + 1))
      done
      [ "$new" != -1 ] || { _MP_T_ERR="milestone '$nm' is not one of the project's milestones"; return 1; }
    fi
  else
    # No milestones registered (an auto-added project): tasks keep their own
    # milestone names, so they are matched to the new list by name.
    if [ -n "$nm" ]; then
      k=$(project_registry_norm "$nm"); j=0
      while [ "$j" -lt "$_MP_NEW_COUNT" ]; do
        [ "$(project_registry_norm "${_MP_NEW_NAMES[j]}")" = "$k" ] && { new=$((j + 1)); break; }
        j=$((j + 1))
      done
      [ "$new" != -1 ] || { _MP_T_ERR="milestone '$nm' matches no milestone in the plan"; return 1; }
    elif [ "$i" -gt 0 ]; then
      _MP_T_ERR="milestone $i has no name to match against the plan"; return 1
    fi
  fi

  if [ "$new" = -1 ]; then
    # The task has no milestone; only a total it carries follows the new count.
    [ "$t" -eq 0 ] || _MP_T_TOTAL=$_MP_NEW_COUNT
  elif [ "$new" -eq 0 ]; then
    _MP_T_NAME=""; _MP_T_INDEX=0; _MP_T_TOTAL=0
  else
    _MP_T_NAME="${_MP_NEW_NAMES[new - 1]}"; _MP_T_INDEX=$new; _MP_T_TOTAL=$_MP_NEW_COUNT
  fi
  return 0
}

# Describe the change of one task's fields, or print nothing. Args: old project,
# new project, old name, old index, old total (new values in _MP_T_*).
_milestone_plan_describe() {
  local op="$1" np="$2" on="$3" oi="${4:-0}" ot="${5:-0}" out=""
  [ "$op" = "$np" ] || out="project \"$op\" -> \"$np\""
  if [ "$on" != "$_MP_T_NAME" ] || [ "${oi:-0}" != "$_MP_T_INDEX" ]; then
    if [ "${_MP_T_INDEX:-0}" -eq 0 ] && [ -z "$_MP_T_NAME" ]; then
      out="${out:+$out; }milestone ${oi} \"$on\" -> none"
    else
      out="${out:+$out; }milestone ${oi} \"$on\" -> ${_MP_T_INDEX} \"$_MP_T_NAME\""
    fi
  fi
  [ "${ot:-0}" = "$_MP_T_TOTAL" ] || out="${out:+$out; }total ${ot:-0} -> $_MP_T_TOTAL"
  printf '%s' "$out"
}

# Apply plan file $2 to project $1. Args: project plan_file dry_run(true|false).
# Prints one line per change. Returns 0, 1 refused or failed (nothing changed),
# 3 NAME_TAKEN. Caller holds the queue lock. queue-cli calls it as `... || rc=$?`,
# which turns errexit off for the whole body: every failure here is checked
# explicitly, and a new command must be too.
milestone_plan_apply() {
  local project="$1" plan="$2" dry="${3:-false}"
  local rc=0 pos old_name new_name qdir stage="" changes="" desc
  local n=0 st f k now wo_match
  local targets=() staged=()

  milestone_plan_parse "$plan" || return 1
  project_registry_load || rc=$?
  case "$rc" in
    1) echo "ERROR: no project registry ($(project_registry_file)) — create it with: queue-cli.sh projects add <name>" >&2; return 1 ;;
    2) return 1 ;;
  esac
  pos=$(project_registry_find "$project") || {
    echo "ERROR: project '$project' is not in the registry" >&2; return 1; }
  rc=0; _milestone_plan_check "$pos" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  old_name="${_PR_NAMES[pos]}"
  new_name="${_MP_RENAME:-$old_name}"
  k=$(project_registry_norm "$old_name")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  qdir=$(_queue_dir)

  # Registry lines first: the new list, then what happens to deleted ones.
  [ "$new_name" = "$old_name" ] || changes="registry: project \"$old_name\" -> \"$new_name\""$'\n'
  local i=0 o
  while [ "$i" -lt "$_MP_NEW_COUNT" ]; do
    o=${_MP_NEW_FROM[i]}
    if [ "$o" -eq 0 ]; then
      changes="${changes}registry: milestone $((i + 1)) \"${_MP_NEW_NAMES[i]}\" (new)"$'\n'
    elif [ "$o" -ne $((i + 1)) ] || [ "${_MP_OLD_NAMES[o]}" != "${_MP_NEW_NAMES[i]}" ]; then
      changes="${changes}registry: milestone $((i + 1)) \"${_MP_NEW_NAMES[i]}\" (was $o \"${_MP_OLD_NAMES[o]}\")"$'\n'
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$_MP_MOVE_COUNT" ]; do
    o=${_MP_MOVE_FROM[i]}
    if [ "${_MP_MOVE_TO[i]}" -eq 0 ]; then
      changes="${changes}registry: milestone $o \"${_MP_OLD_NAMES[o]}\" deleted, its tasks -> none"$'\n'
    else
      changes="${changes}registry: milestone $o \"${_MP_OLD_NAMES[o]}\" deleted, its tasks -> ${_MP_MOVE_TO[i]} \"${_MP_NEW_NAMES[_MP_MOVE_TO[i] - 1]}\""$'\n'
    fi
    i=$((i + 1))
  done

  if [ "$dry" != true ]; then
    stage=$(mktemp -d "$qdir/.milestone-plan.XXXXXX") || { echo "ERROR: could not create a staging directory in $qdir" >&2; return 1; }
  fi
  local refused=""

  # Work orders. Their project decides an entry's project when the entry has
  # none of its own, so their ids are remembered for the entry pass.
  local wo_ids="|"
  for f in "$(_wo_dir)"/*.yaml; do
    [ -f "$f" ] || continue
    _load_work_order "$f" || continue
    [ "$(project_registry_norm "$_WO_PROJECT")" = "$k" ] || continue
    wo_ids="${wo_ids}${_WO_ID}|"
    if ! _milestone_plan_map_task "$_WO_MILESTONE_NAME" "${_WO_MILESTONE_INDEX:-0}" "${_WO_MILESTONE_TOTAL:-0}"; then
      refused="${refused}  work order $_WO_ID: $_MP_T_ERR"$'\n'; continue
    fi
    desc=$(_milestone_plan_describe "$_WO_PROJECT" "$new_name" "$_WO_MILESTONE_NAME" "${_WO_MILESTONE_INDEX:-0}" "${_WO_MILESTONE_TOTAL:-0}")
    [ -n "$desc" ] || continue
    changes="${changes}work order $_WO_ID: $desc"$'\n'
    [ "$dry" = true ] && continue
    _WO_PROJECT="$new_name"; _WO_MILESTONE_NAME="$_MP_T_NAME"
    _WO_MILESTONE_INDEX="$_MP_T_INDEX"; _WO_MILESTONE_TOTAL="$_MP_T_TOTAL"; _WO_UPDATED_AT="$now"
    _write_work_order "$stage/$n.yaml" || { rm -rf "$stage"; echo "ERROR: could not stage work order $_WO_ID" >&2; return 1; }
    targets[n]="$f"; staged[n]="$stage/$n.yaml"; n=$((n + 1))
  done

  for st in pending-review approved running completed failed review blocked stopped; do
    for f in "$qdir/$st"/*.yaml; do
      [ -f "$f" ] || continue
      _load_queue_entry "$f" || continue
      wo_match=false
      case "$wo_ids" in *"|${_QE_WORK_ORDER_ID}|"*) [ -n "$_QE_WORK_ORDER_ID" ] && wo_match=true ;; esac
      if [ -n "$_QE_PROJECT" ]; then
        [ "$(project_registry_norm "$_QE_PROJECT")" = "$k" ] || continue
      else
        # No project of its own: it shows its work order's, so it belongs here
        # only through that work order and keeps its empty project field.
        [ "$wo_match" = true ] || continue
      fi
      if ! _milestone_plan_map_task "$_QE_MILESTONE_NAME" "${_QE_MILESTONE_INDEX:-0}" "${_QE_MILESTONE_TOTAL:-0}"; then
        refused="${refused}  entry $_QE_ID ($st): $_MP_T_ERR"$'\n'; continue
      fi
      local np="$_QE_PROJECT"
      [ -z "$np" ] || np="$new_name"
      desc=$(_milestone_plan_describe "$_QE_PROJECT" "$np" "$_QE_MILESTONE_NAME" "${_QE_MILESTONE_INDEX:-0}" "${_QE_MILESTONE_TOTAL:-0}")
      [ -n "$desc" ] || continue
      changes="${changes}entry $_QE_ID ($st): $desc"$'\n'
      [ "$dry" = true ] && continue
      _QE_PROJECT="$np"; _QE_MILESTONE_NAME="$_MP_T_NAME"
      _QE_MILESTONE_INDEX="$_MP_T_INDEX"; _QE_MILESTONE_TOTAL="$_MP_T_TOTAL"; _QE_UPDATED_AT="$now"
      _write_queue_entry "$stage/$n.yaml" || { rm -rf "$stage"; echo "ERROR: could not stage entry $_QE_ID" >&2; return 1; }
      targets[n]="$f"; staged[n]="$stage/$n.yaml"; n=$((n + 1))
    done
  done

  if [ -n "$refused" ]; then
    [ -z "$stage" ] || rm -rf "$stage"
    printf 'ERROR: these tasks have a milestone the plan cannot map — fix them with queue-cli.sh edit first; nothing was changed:\n%s' "$refused" >&2
    return 1
  fi

  if [ "$dry" = true ]; then
    if [ -z "$changes" ]; then echo "No changes."; else printf '%s' "$changes" | sed 's/^/would: /'; fi
    return 0
  fi

  # The registry, staged from the loaded state with the plan applied.
  local reg reg_staged
  reg=$(project_registry_file)
  _PR_NAMES[pos]="$new_name"
  _milestone_plan_set_registry "$pos"
  reg_staged=$(mktemp "$reg.staged.XXXXXX") || { rm -rf "$stage"; echo "ERROR: could not stage the registry" >&2; return 1; }
  _project_registry_write "$reg_staged" || { rm -f "$reg_staged"; rm -rf "$stage"; echo "ERROR: could not stage the registry" >&2; return 1; }

  # Phase 2. Back up and move each file; the registry goes last. backup/MANIFEST
  # names the live path of each backup, written before the file is replaced, so
  # a kill here leaves enough to restore by hand.
  local backup j=0 failed=""
  backup="$stage/backup"
  mkdir "$backup" || failed="could not create $backup"
  while [ -z "$failed" ] && [ "$j" -lt "$n" ]; do
    if [ ! -f "${targets[j]}" ]; then
      failed="${targets[j]} moved or vanished during the apply"
    elif ! cp -p "${targets[j]}" "$backup/$j" \
         || ! printf '%s\t%s\n' "$j" "${targets[j]}" >> "$backup/MANIFEST"; then
      failed="could not back up ${targets[j]}"
    elif ! mv -f "${staged[j]}" "${targets[j]}"; then
      failed="could not write ${targets[j]}"
    else
      j=$((j + 1)); continue
    fi
    break
  done
  if [ -z "$failed" ]; then
    if ! cp -p "$reg" "$backup/registry" \
       || ! printf 'registry\t%s\n' "$reg" >> "$backup/MANIFEST" \
       || ! mv -f "$reg_staged" "$reg"; then
      failed="could not write $reg"
    fi
  fi

  if [ -n "$failed" ]; then
    local r=0 lost=""
    while [ "$r" -lt "$j" ]; do
      mv -f "$backup/$r" "${targets[r]}" || lost="${lost}  backup/$r -> ${targets[r]}"$'\n'
      r=$((r + 1))
    done
    rm -f "$reg_staged"
    if [ -n "$lost" ]; then
      printf 'ERROR: %s. Could not restore these files; their originals are in %s:\n%s' "$failed" "$backup" "$lost" >&2
    else
      rm -rf "$stage"
      echo "ERROR: $failed — every file was restored; nothing was changed" >&2
    fi
    return 1
  fi

  rm -rf "$stage"
  _rebuild_queue_index || true
  if [ -z "$changes" ]; then echo "No changes."; else printf '%s' "$changes"; fi
  return 0
}

# Replace project $1's milestones in the loaded registry state with the plan's
# list. Milestones are stored flat, so the flat array is rebuilt in order.
_milestone_plan_set_registry() {
  local pos="$1" i j start ms=() starts=() counts=()
  i=0
  while [ "$i" -lt "$_PR_COUNT" ]; do
    starts[i]=${#ms[@]}
    if [ "$i" -eq "$pos" ]; then
      j=0
      while [ "$j" -lt "$_MP_NEW_COUNT" ]; do ms[${#ms[@]}]="${_MP_NEW_NAMES[j]}"; j=$((j + 1)); done
      counts[i]=$_MP_NEW_COUNT
    else
      start=${_PR_MS_START[i]}; j=0
      while [ "$j" -lt "${_PR_MS_COUNT[i]}" ]; do ms[${#ms[@]}]="${_PR_MS[$((start + j))]}"; j=$((j + 1)); done
      counts[i]=${_PR_MS_COUNT[i]}
    fi
    i=$((i + 1))
  done
  _PR_MS=(${ms[@]+"${ms[@]}"}); _PR_MS_START=(${starts[@]+"${starts[@]}"}); _PR_MS_COUNT=(${counts[@]+"${counts[@]}"})
}
