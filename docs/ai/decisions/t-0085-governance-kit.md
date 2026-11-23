# Decision t-0085 — The governance kit: modules as data, overrides, validation

**Status:** Accepted
**Date:** 2026-11-23
**Files:** `.claude/.automation/governance-kit.json`, `.claude/hooks/_governance-helper.sh`,
`.claude/hooks/pretooluse-permission.sh`, `.claude/hooks/hvst-failure-tracker.sh`,
`.claude/tools/governance-kit.sh`, `.claude/.automation/schemas/governance-kit.yaml`,
`.claude/.automation/schemas/governance-overrides.yaml`, `.templatesyncignore`, `AI.md`.

## Triggers

- type: file
- path: `\.claude/\.automation/governance-(kit|overrides)\.json|\.claude/hooks/_governance-helper\.sh|\.claude/tools/governance-kit\.sh`
- keywords: `governance-kit, governance-overrides, module_is_off, turn_off_safe`

## Context

The child app Massimo shows the repo's governance as a kit: modules the operator can turn off or
customize, grouped into agents, skills & prompts, workflows, hooks, rules, quality gates,
decisions, and merge & close. Massimo can also load custom kits. Repo OS had no list of its
modules. Nothing recorded which modules were safe to turn off, and there was nothing to check a
kit against (Massimo request R8).

## Decision

1. **The default kit is data.** `.claude/.automation/governance-kit.json` is template-owned and
   synced. It holds:
   - `kit {id: repo-os, name: Default governance}`. The kit's version is the template commit the
     repo is on, so it is not stored.
   - `statuses`: each of the 8 queue statuses, mapped to itself.
   - `session_types`: every session type and its phases.
   - `gates`: the A, B and C gates and the product-graph gate.
   - `agents`: the 24 Repo OS agents.
   - `schema_set`: the SCHEMA-CHANGELOG version.
   - `modules[] {id, category, name, files, turn_off_safe, why}`, with one module per agent,
     prompt, registered hook, workflow and gate, plus a few for rules and for merge & close.

   Decisions are one module listing `t-manifest.txt`, so adding a decision needs no kit edit.
   Massimo reads that list for its per-decision view. JSON and jq are used, not the line-based
   YAML of the registry, because a kit is nested data and Massimo's engine is TypeScript.

2. **What `turn_off_safe` means.** A module is safe to turn off only when turning it off removes
   advice or a capability and no gate or other module depends on it. Examples are the
   advisory-board agents, the simulated user reviews, the audit and eval-study prompts, the
   gate-conformance workflow and the failure-tracker hook. Every gate, guard hook and
   gate-required agent is unsafe, and its `why` says what depends on it.

3. **A repo's overrides.** `.claude/.automation/governance-overrides.json` is child-owned and
   listed in `.templatesyncignore`. It maps module ids to `off` or `customized`. In a child repo
   the mode guard already stops an agent session writing under `.claude/.automation/`, so
   Massimo or the operator writes it. `customized` means the repo has its own copy of the
   module's files, which only stays its own if those files are claimed in
   `.templatesyncignore.local`.

4. **Repo OS honours `off` where it controls the module (the operator's choice).**
   - `pretooluse-permission.sh` refuses to dispatch an agent turned off. The refusal is
     recoverable and tells the session to skip the agent.
   - `hvst-failure-tracker.sh` does nothing while it is turned off.
   - Prompts and workflows are started by the operator or Massimo, which do not offer a module
     turned off. Repo OS has nothing to enforce there.

   One rule decides all of this, `module_is_off` in `_governance-helper.sh`. It is true only
   when the override says `off`, the kit marks exactly one module with that id
   `turn_off_safe: true`, and the id is not on the helper's own never-off list. That list is the
   gate-required agents (critic, qa-verifier, reviewer, security-privacy, pragmatist, builder,
   orchestrator, dev-orchestrator) and every hook except the failure tracker. A test checks
   that the list covers every agent whose verdict the hooks record. A missing or unreadable file, or no
   jq, means the module stays on. The list lives in a hook, not in the kit, so editing the kit
   cannot switch off a gate.

5. **Validation.** `bash .claude/tools/governance-kit.sh validate [--kit FILE] [--root DIR]`
   prints one `CODE: detail` line per problem and exits 1 if there are any. Otherwise it prints
   `Kit valid: <id>` and exits 0. A usage error exits 2.
   - Kit codes: `KIT_UNREADABLE`, `FIELD_MISSING`, `STATUS_UNMAPPED`, `NO_PHASES`, `NO_GATES`,
     `NO_AGENTS`, `SCHEMA_VERSION` (major version 1 only), `MODULE_INVALID` and
     `MODULE_FILE_MISSING`.
   - Without `--kit`, the repo's overrides are checked as well, with `OVERRIDE_UNKNOWN`,
     `OVERRIDE_VALUE` and `OVERRIDE_NOT_SAFE`.
   - `WARN OVERRIDE_NOT_CLAIMED` notes a customized file the next sync would overwrite. It does
     not fail.

## Consequences

- `.claude/.automation/tests/test-governance-kit.sh` keeps the default kit true to the repo. It
  checks that:
  - the session types equal `get_phases_for_type`;
  - the statuses are queue-entry's eight;
  - every agent, prompt, registered hook and governing workflow has a module;
  - every listed file exists and is shipped;
  - `schema_set` is the latest changelog version.

  A new agent, prompt, hook, session type or schema version therefore fails the suite until the
  kit lists it. The suite also covers every problem code and `module_is_off`. layer3 and
  gate-conformance probe the two hooks.
- A custom kit that wants Repo OS to honour its overrides must keep the same module ids.

## Known limits

- An agent turned off is still dispatched when `REPO_OS_ALLOW_AGENT=1` is set, like every other
  agent rule. That is the logged emergency override, not a hole.
- The validator only checks that a module's files exist. It refuses absolute paths and paths
  containing `..`.
- The failure tracker is the only hook that can be turned off. A guard can't be, by design.
- `customized` is recorded, not enforced. The validator only warns when the files are not
  claimed.
