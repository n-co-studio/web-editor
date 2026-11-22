# Decision t-0080 — One command applies a milestone plan, all or nothing

**Status:** Accepted
**Date:** 2026-11-22
**Amends:** t-0079 (its "no rename, reorder or delete yet" and "running entries stay uneditable"
known limits). `.claude/.automation/lib/milestone-plan.sh`, `.claude/.automation/queue-cli.sh`,
`.claude/.automation/lib/queue-manager.sh` (`queue_edit`), `.claude/.automation/schemas/milestone-plan.yaml`.

## Triggers

- type: file
- path: `\.claude/\.automation/lib/milestone-plan\.sh|\.claude/\.automation/schemas/milestone-plan\.yaml`
- keywords: `milestone-plan, milestone_plan, rename_to, milestones --file`

## Context

t-0079 gave each repo a project registry. A milestone change still had to be made one task at a
time, with nothing stopping a half-done rename. Adding, renaming, deleting or reordering a
milestone, or renaming a project, changes the registry and every entry and work order in the
project, finished ones included. The child app Massimo edits milestones as one screen of changes
and needs them applied together (Massimo request R2). It also needs project and milestone to stay
editable while a task runs: they are display metadata, and refusing them made Massimo hold the
change until the task finished (R3).

## Decision

1. **Command.** `queue-cli.sh milestones <project> --file <plan.yaml> [--dry-run]`. Exit 0 applied,
   1 refused or failed with nothing changed, 3 with `NAME_TAKEN: <name>` when `rename_to` matches
   another project. It needs the registry and the project to be registered.
2. **A plan is the complete new list.** Schema `milestone-plan` v1.0.0
   (`.claude/.automation/schemas/milestone-plan.yaml`, SCHEMA-CHANGELOG v1.15.0), in the registry's
   strict line layout. Each milestone may name the old index it was (`from`): that covers rename
   and reorder. One without `from` is new. An old milestone no `from` names is deleted and must have
   a move, `to: <new index>` or `to: none`. `rename_to` renames the project.
3. **No silent loss.** The whole plan is refused if any of these holds: a deleted milestone with no
   move, a `from` used twice, an index out of range, a move for a kept milestone, two new names that
   match ignoring case and spacing, or a malformed line. It is also refused when a task's milestone
   cannot be mapped. The refusal lists those tasks.
4. **What it changes.** The registry's project gets the new name and list. Every entry, in all
   eight status directories, and every work order whose project matches gets the new spelling. Its
   milestone is mapped from the old index to the new index, name and total, or cleared on a move to
   none. A task with no milestone keeps none, and a non-zero total follows the new count. An entry
   with no project of its own belongs to the project through its work order; it is mapped, and its
   project field stays empty.
5. **Projects registered with no milestones.** A project auto-added by t-0079 has no registered
   milestones, but its tasks keep their own milestone names. Such tasks are matched to the new list
   by name, and `from` and `moves` are refused because there is nothing to name. This is the only way
   to adopt an auto-added project's milestones, so it stays, despite the plan review's advisory
   against a second mapping mode.
6. **All or nothing.** It runs under one queue lock. Phase 1 checks the plan and every affected
   file and writes the new versions to a staging directory (`queue/.milestone-plan.XXXXXX`, from
   `mktemp`), touching nothing live. Phase 2 backs up each original and moves each staged file into
   place, with the registry last. If any move fails, every file already moved is restored from its
   backup and the command exits 1. The queue index is rebuilt after a successful apply.
7. **It says what it did.** One line per change: the registry first, then each work order and entry
   with its id, status and old → new values. `--dry-run` prints the same lines prefixed `would:` and
   writes nothing.
8. **Project and milestone can change while a task runs.** `queue_edit` accepts `project`,
   `milestone.name`, `milestone.index` and `milestone.total` on a running entry. No session reads
   them: `runner.sh` and `prompt-assembler.sh` do not. Every other field stays refused on a running
   entry. The registry rules of t-0079 still apply.

## Known limits

- **A kill during phase 2 can leave a partial apply.** Restoring needs the process alive. The
  staging directory, with its `backup/` copies of every original already replaced, is then left in
  the queue directory. `backup/MANIFEST` maps each copy to its live path (one `N<TAB>path` line,
  written before that file is replaced), so the restore can be done by hand. A failed restore prints
  the staging path and each `backup/N -> path` it could not restore.
- **A kill during phase 1 leaves files but changes nothing.** The `queue/.milestone-plan.*`
  directory and a `docs/ai/project-registry.yaml.staged.*` file may be left behind. Both can be
  deleted. The staged registry file is in a tracked directory, so check for it before committing.
- **The index wins.** A task whose milestone index and name disagree is mapped by its index, and
  gets the new name. Only a task with no index is matched by name.
- **The daemon's running-entry writes.** The daemon rewrites a running entry by loading it and
  writing it straight back, sometimes without the queue lock. An edit that lands in that instant can
  be lost. The fields are display metadata, and running the edit again restores it. Phase 2 refuses
  and restores if a target file vanished, for example because the daemon moved the entry to another
  status.
- **Names only by index.** `from` names old milestones by index, not name. This is deliberate: a
  rename changes the name, and the index is what the plan and the tasks share.
- **No JSON output.** The lines are for people. Massimo can read the registry and entries
  afterwards, or the `--dry-run` lines before.
