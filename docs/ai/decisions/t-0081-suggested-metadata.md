# Decision t-0081 — Prompt T suggests a registered project and milestone, marked until confirmed

**Status:** Accepted
**Date:** 2026-11-22
**Amends:** t-0067 (draft intake), with a pointer added to its Consequences.
`.claude/.automation/queue-cli.sh`, `.claude/.automation/lib/queue-manager.sh`,
`.claude/.automation/schemas/queue-entry.yaml`, `docs/ai/prompts/prompt-t-task-definition.md`.

## Triggers

- type: file
- path: `docs/ai/prompts/prompt-t-task-definition\.md|\.claude/\.automation/schemas/queue-entry\.yaml`
- keywords: `metadata_suggested, --suggested`

## Context

A Prompt T draft (t-0067) is queued with whatever project and milestone the operator named, which
in Massimo is usually none. The repo now has a project registry (t-0079), so the drafting agent
can see the projects and milestones that exist. Massimo wants the agent to propose one when the task
fits, and to show it as **Suggested** until the operator confirms it (Massimo request R4). Massimo
reads the queue entry, so the entry has to say which values are suggestions.

## Decision

1. **A new entry field.** `metadata_suggested` (boolean, default false; queue-entry schema
   v1.16.0). `show --json` and `list --json` report it as a JSON boolean. An entry written before
   this field reads as false.
2. **Set by `add --suggested`, for registered projects only.** The flag is applied after the entry
   is created, as `--independent` is. It is refused, and nothing is queued, when there is no
   registry, when `--project` is absent, or when the project is not registered. A suggestion is
   therefore always an existing project, and a guess can never auto-add one (t-0079 clause 4). The
   milestone flags stay optional and follow the registry rules. Re-adding a brief that is already
   queued returns the existing entry and does not mark it.
3. **Confirmed by the operator.** `queue-cli.sh edit <id> metadata_suggested false` confirms the
   value as it stands. Any edit of `project` or `milestone.*` also clears the mark, because the value
   is then the operator's choice. `edit <id> metadata_suggested true` sets it again. The field is
   editable on a running entry, like the values it describes (t-0080). Approving the draft does not
   change it: what Massimo's Submit means for a suggestion is Massimo's to decide. A follow-up does
   not inherit it.
4. **Prompt T suggests only what is listed.** In draft mode, before the `add`, the agent runs
   `queue-cli.sh projects list`. If the task clearly belongs to a listed project, it passes
   `--project` and `--suggested`, plus `--milestone-index` when one milestone clearly fits. It never
   invents a project or milestone. When nothing fits, or there is no registry, it passes no project
   flags. It names the suggestion and its reason in the summary. Values the operator named are
   passed without `--suggested`. Outside draft mode Prompt T is unchanged.

## Known limits

- **The agent restores its own mark by hand.** Changing its own suggestion in the revise loop is an
  edit, which clears the mark, so Prompt T runs `edit <id> metadata_suggested true` after it.
- **Only entries carry it.** A work order created with the entry keeps the project and milestone but
  not the mark. Massimo reads the mark from the entry.
- **"Clearly fits" is the agent's judgement.** The rule is that it suggests nothing rather than
  something doubtful, and the operator sees every suggestion as Suggested.
