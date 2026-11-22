# Decision t-0079 — A repo keeps one project registry, and the queue checks tasks against it

**Status:** Accepted
**Date:** 2026-11-22
**Amends:** none. Extends the queue's free-text `project` / `milestone` fields (schema v1.4.0) and
applies Decisions t-0051/t-0052 (child-owned files) to a new path.
`.claude/.automation/queue-cli.sh`, `.claude/.automation/lib/project-registry.sh`,
`.claude/.automation/schemas/project-registry.yaml`, `.templatesyncignore`.

## Triggers

- type: file
- path: `\.claude/\.automation/lib/project-registry\.sh|docs/ai/project-registry\.yaml|\.claude/\.automation/schemas/project-registry\.yaml`
- keywords: `project-registry, project_registry, NAME_TAKEN, projects add, projects list`

## Context

Queue entries and work orders carry `project` and `milestone {name, index, total}` as free text, set
by `queue-cli.sh add` flags or Prompt T. Nothing records which projects a repo has, what their
milestones are called, what order they come in, or that a milestone exists before it has a task.
The child app Massimo needs all four. Its v1 spec (`docs/spec/compiled/v1/data-contracts.md`,
ProjectRegistry) asks for a repo file that Repo OS owns the path and schema of, with names unique
"ignoring case and spacing", and keeps no second copy of it. This is Massimo request R1. R2 (batch
milestone edits), R3 (edits on running entries) and R4 (Prompt T suggestions) build on it.

## Decision

1. **One registry per repo, at a fixed path.** `docs/ai/project-registry.yaml`, schema
   `project-registry` v1.0.0 (`.claude/.automation/schemas/project-registry.yaml`, SCHEMA-CHANGELOG
   v1.14.0). It holds `projects[]` of `{name, milestones[] of {index, name}}`, with indexes 1..N in
   order. The registry is the source for names, order and milestones with no task yet. A task's own
   fields stay the source for which milestone the task is in.
2. **The repo owns it.** The template ships no copy and lists the path in `.templatesyncignore`, so
   sync never writes it, and it is absent from the machinery manifest, so the withdrawn-file sweep
   never deletes it (t-0051, t-0052). Without the file, everything behaves as before. Nothing creates
   it except `projects add`, or an auto-add once a registry exists.
3. **Names match ignoring case and all whitespace, and the registry's spelling is canonical.**
4. **The queue checks tasks against it.** With a registry present, `add`, `follow-up-entry` and
   `edit` of `project` / `milestone.*`:
   - store the registry's spelling of a matched project, with a note when it differed;
   - add an unknown project to the registry, with no milestones, after the task is written, and
     print a note naming it so a typo is visible;
   - for a project with registered milestones: refuse an index outside 1..N, a name that is not the
     name at that index, or a total other than N; fill a missing name or total; resolve a name given
     without an index to its index;
   - for a project with none registered, accept the milestone fields as given.

   A follow-up checks only the milestone flags the operator passed. It inherits the parent's
   milestone as a whole, and only while it stays in the parent's project and names no milestone of
   its own. Inherited ones are refilled from the registry by index, so a rename since the parent does
   not refuse its follow-up. An edit checks the whole resulting tuple and writes the fields it fills
   alongside the one edited. A total of 0 means "not given", so `edit … milestone.total 0` writes N.
   Names must be one line, and a name with a newline is refused. An add of a brief that is already
   queued returns the existing entry and registers nothing.
5. **A registry that cannot be read is an error, never absent.** Any of these refuses the add or
   edit, which then writes nothing: an unrecognised line, a missing or non-1.x `schema_version`, two
   names that match, or milestone indexes that are not 1..N.
6. **Writes are atomic, and re-read first.** queue-cli writes under the queue lock. It re-reads the
   file just before writing and replaces it with a temp file and `mv` in the same directory. A change
   another writer made since queue-cli's first read is therefore kept. An outside writer such as
   Massimo should go through queue-cli. One that writes directly must replace the file atomically
   and keep the documented layout, which readers parse line by line.
7. **CLI.** `queue-cli.sh projects list` prints each project and its numbered milestones.
   `queue-cli.sh projects add <name> [--milestone NAME]...` registers a project with its milestones
   in order. A name that matches an existing one prints `NAME_TAKEN: <existing>` and exits 3. There
   is no `--json`: Massimo reads the YAML, whose schema is the contract.

## Known limits

- **Rename, reorder and delete are t-0080.** `projects add` only creates. `queue-cli.sh milestones
  <project> --file <plan.yaml>` changes a project's milestones and name everywhere at once.
- **Running entries:** t-0080 allows `project` and `milestone.*` edits on them. Every other field
  is still refused.
- **Auto-add can register a typo.** It prints a note rather than refusing, because the spec wants
  projects found on tasks registered.
- **Only queue-cli takes the lock.** Re-reading before the write keeps another writer's change, but
  a direct write in the instant between that re-read and the `mv` would be lost. An outside writer
  that goes through queue-cli avoids it.
- **The layout is strict.** Readers accept only the documented line layout (bash 3.2, no YAML
  library). Valid YAML in another layout, or a trailing comment after a quoted name, is refused as
  unreadable, not misread. Trailing whitespace and CRLF line ends are tolerated.
- **A write rewrites the file.** queue-cli writes the whole registry in that layout, so hand-written
  comments are dropped and `schema_version` is written as the version this Repo OS writes.
