# Known Issues

Structured index of resolved debugging issues. Populated by the HVST Record step after 2+ failed cycles.

Checked automatically when HVST failures reach threshold. Do not delete entries — they prevent repeat debugging.

| Symptom | Root Cause | Fix | Session |
|---------|-----------|-----|---------|

## Known Limitations

Deferred findings from review phases that are out of the current brief's scope and need a follow-up brief.

### KL-1 — `buildPageContext` strips unit from breakpoint token values and unconditionally appends `px`
- **File:** `packages/chrome-extension/src/content/batching/diff-builder.ts` (method `buildPageContext`, lines ~250–270)
- **Symptom:** Projects defining breakpoint tokens in `em` or `rem` (e.g. `48em`, `60rem`) produce a wrong `PageContext.breakpointValue` (e.g. `"48px"` instead of `"48em"`). The matching comparison `window.innerWidth >= bp.value` also fails because `parseFloat('48em') = 48` and `window.innerWidth` is in CSS px — the largest breakpoint always matches.
- **Discovered:** Session 149 diff-review (Brief 2 of breakpoint-awareness). Code is pre-existing on `main` (commit `dfd7a68 feat(diff): carry owning-rule provenance through to MCP`) and is not modified by this brief.
- **Scope:** A correct fix requires unit-aware breakpoint matching (`em`/`rem` → CSS px conversion using the document root font-size). Out of scope for the breakpoint-awareness task group.
- **Follow-up:** Open a dedicated brief for unit-aware breakpoint resolution in `buildPageContext`.

### KL-2 — Root `tsc --noEmit` type-checks nothing outside `packages/shared` (hollow A3.3 signal)
- **File:** `tsconfig.json` (repo root)
- **Symptom:** The root config has `"files": []` and `references: [{ "path": "packages/shared" }]`, so `npx tsc --noEmit` at the repo root exits 0 **unconditionally** regardless of the state of `packages/chrome-extension`, `packages/mcp-server`, or `packages/dev-plugin`. It reports success on code containing hard type errors.
- **Discovered:** Session `notes-multi-attach-20260816`. A dangling `this.anchoredElementRef` reference (TS2339, a field deleted earlier in the same diff) survived a root `npx tsc --noEmit` that exited 0; it was caught by the Critic, not by the build. Empirically confirmed both ways: with the offending line reinstated, `cd packages/chrome-extension && npm run typecheck` exits 2; with it removed, exits 0. The root command exits 0 in both cases.
- **Impact on gates:** Gate A3.3 (`tsc --noEmit --incremental`) is specified against the repo root. If the hook runs it from the root, A3.3 provides **no** type safety for any product package — the gate passes vacuously. This is a silent-false-negative class of gate failure, not a crash.
- **Workaround:** Type-check per package: `cd packages/<pkg> && npm run typecheck`. (`npx tsc --build` at root also traverses references correctly.) Note the root `package.json` likewise has no `test` script — tests are per-package.
- **Scope:** Fixing this means either adding the remaining packages to the root `references` array (and making them composite projects) or changing gate A3.3 to iterate packages. Both are outside a UI-behaviour brief.
- **Follow-up:** Open a dedicated brief to make root typecheck cover all packages and to align gate A3.3 with it.

### KL-3 — `zod` advisory GHSA-mrhx-c7xc-m3w5 is unfixable until the MCP SDK supports zod 4
- **File:** `packages/mcp-server/package.json` (`zod: ^3.23.0`), `package-lock.json`
- **Symptom:** `npm audit --omit=dev` reports one high advisory — zod memory exhaustion while validating oversized constrained collections (CWE-400, availability only). It sits in a production-path dependency, so it reaches consumers.
- **CORRECTION 2026-10-27 — this is fixable, and the original diagnosis was wrong.** 0.3.0 shipped on the belief that the MCP SDK pinned zod 3.x. It does not. `@modelcontextprotocol/sdk@1.32.2` declares `zod: "^3.25 || ^4.0"` and `zod-to-json-schema@3.25.1` declares `zod: "^3.25 || ^4"`. **The only thing holding the tree at `zod@3.25.76` is our own `"zod": "^3.23.0"` in `packages/mcp-server/package.json`.** The earlier entry asserted an upstream constraint without checking the SDK's own manifest.
- **What the fix actually is:** widen our range to `^3.25 || ^4` (or go straight to `^4.6.6`) and migrate our own zod usage. That is real work — zod 4 changes the API, and `server.ts` builds every MCP tool's `inputSchema` with `z.object(...)` — but it is our migration, not a blocked upstream. There is no 3.x backport, so staying on 3 means keeping the advisory.
- **What a consumer sees today:** `npm audit --omit=dev` after installing `@nco-studio/web-editor-mcp@0.3.0` reports **2 high, no fix available** — the same advisory counted twice, once against `zod` and once against our package as its dependant. It reads worse than it is, and it is attached to our package name.
- **Exposure:** limited. The bridge binds loopback only (`packages/mcp-server/src/bridge.ts:514`, `host: '127.0.0.1'`) with a WebSocket Origin allowlist of `localhost`/`127.0.0.1`/`::1` (`bridge.ts:532-552`). Reaching it requires local access, and the impact is availability with no confidentiality or integrity component.
- **Discovered:** Session `5d149e99`, security sign-off, 2026-10-26. Accepted as non-blocking by that review on the two conditions recorded here: the loopback binding was verified in code, and the advisory is logged.
- **Target:** 0.3.1. No upstream trigger to wait for — the work is ours whenever it is scheduled.
- **Related:** the critical `proxy-addr` advisory (GHSA-jqcg-44mw-7w3h) in the same tree **was** cleared in this session, but note that the SDK bump alone did not do it — `express@5.2.1` held a transitive pin at `proxy-addr@2.0.7` and `npm audit fix` was needed on top. A direct-dependency bump is not evidence that a transitive advisory is gone; check `npm ls <pkg>`.

### KL-4 — the bridge authenticates its peer by `Origin` only, which the dev page itself satisfies (HACK-010)
- **File:** `packages/mcp-server/src/bridge.ts:539-553` (`isAllowedOrigin`), `packages/chrome-extension/src/content/websocket-client.ts:148`
- **Symptom:** the allowlist accepts any origin whose hostname is `localhost`, `127.0.0.1` or `::1`, on any port, plus any `chrome-extension://` origin with no ID pinning. There is no token, pairing or challenge. Script executing on the developer's own dev page therefore passes it and can drive the bridge directly, with the extension neither installed nor active.
- **Why the existing comment is misleading:** it claims the check "blocks drive-by connections from an arbitrary web page open in the same browser". That holds for a remote origin; it does not hold for `http://localhost:3000`, which is the page being edited and the one place untrusted content actually renders (seeded DB, prod dump, user-generated records, a compromised front-end dependency). The comment describes a protection the code does not provide, which is likely why this survived two earlier security passes.
- **Why it cannot be fixed in place:** the content script opens the socket from the page context, so the browser sends the *page's* origin. Localhost origins must be allowed for the product to work as currently built. Closing this means either moving the socket into the service worker and pinning the extension ID, or introducing a pairing secret — both cross-package protocol changes with four-way extension/server version skew, the same compatibility problem HACK-008 had.
- **Residual impact after `fe59ab6`:** that commit removed most of the consequence without touching the access. A client that reaches the bridge can no longer write a workflow file, an agent-config file or a `.php` into the project, crash the server, or steer the agent through `sourceFile`. It can still read the token and component registries (including `importPath`, so the project layout), inject diffs into the agent's queue, write bounded image/video files into asset directories, and claim another `tabId` to intercept that tab's pushes. Information disclosure and nuisance, not code execution.
- **Discovered:** adversarial security review, 2026-10-26, ahead of 0.3.0.
- **Deferred deliberately:** operator decision 2026-10-26 — ship 0.3.0 with the impact reduced and do the authentication work as its own release rather than rushing a protocol change. Full brief drafted; it needs filing through a `taskdef-brief` session, which is the only session type permitted to write `.claude/.automation/briefs/` (`write-guard.sh:449-464`).
- **Target:** 0.3.1, together with KL-6 — they are one protocol change, not two.
- **Reconsidered 2026-10-27:** this was deferred as a peer-authentication issue, which undersold it. The agent-facing framing now tells the agent to follow `notes`, and any script on a `localhost` page is an allowed peer, so the deferral also leaves a page-script peer holding a *trusted instruction channel*. The extension's shadow root is `mode: 'open'`, so page script can drive the note UI directly as well. Severity unchanged, but the reason it matters is broader than "who may connect".
- **Follow-up:** brief `20261027-013000-bridge-peer-authentication`.

### KL-5 — SVG assets are refused over the bridge until they can be parsed properly
- **File:** `packages/mcp-server/src/bridge.ts` (`saveDataUrl`)
- **Behaviour:** a `data:image/svg+xml` payload arriving over the bridge is refused and logged. Raster images and video are unaffected. SVGs can still be added to the repo directly, which is outside this trust boundary.
- **Why:** SVG is the one allowlisted asset type that is a script-capable document rather than inert bytes, and an SVG written into `public/` is served from the dev origin — so a scripted one is stored XSS on the very page being edited. The first attempt screened it with regexes. A review defeated that screen five ways: a namespace-prefixed `<s:script>` (the `<\s*script` pattern does not match it), entity-encoded or tab-split `javascript:` (the XML parser decodes after the regex has looked), a DOCTYPE `<!ENTITY>` declaration, and a UTF-16 BOM (the check decodes as UTF-8 and sees NUL-interleaved text while the browser honours the BOM). A regex cannot screen SVG; pretending otherwise was worse than refusing, because it read as a control.
- **Proper fix:** parse with a real XML parser and allowlist elements and attributes, or reject any SVG carrying a DOCTYPE, an ENTITY, a non-UTF-8 BOM, or a prefixed or foreign-namespace element. That needs a parser dependency and a design decision about which SVG features to keep, so it is deliberately not a release-eve change.
- **Discovered:** review of commit `fe59ab6`, 2026-10-26.

### KL-6 — notes carry a page-built element reference the server cannot separate from the designer's words
- **File:** `packages/chrome-extension/src/content/batching/notes-store.ts` (`formatElementRef`), `packages/mcp-server/src/bridge.ts` (`sanitizeNote`), `packages/mcp-server/src/server.ts` (framing)
- **Symptom:** every note has an element reference appended to it — asset path, text content, selector, and `sourceFile:sourceLine` — all read from the live DOM. Server-side the note is a single string, so the designer's typed words and the page-derived suffix cannot be told apart. The agent-facing text says notes are the designer asking for something, which makes a note a comparatively trusted channel carrying untrusted content.
- **Why it is not closed:** the fix is to send the reference as structured fields rather than splicing it into the text, so the server can screen `sourceFile` with `isPlausibleSourcePath`, allowlist `assetPath`, and cap and label `selector`/`textContent` separately from the designer's words. That is a protocol change across two independently-versioned packages, with the same four-way skew problem as KL-4, and should be done with capability negotiation in the handshake rather than as a flag day.
- **Mitigated in 0.3.0, not fixed:** note text is type-checked, capped at 4000 characters, has control characters stripped and line breaks collapsed (so a crafted `data-source-file` cannot forge what looks like another numbered instruction in the designer's voice), and the same normalisation runs on restore. The framing says a note's paths, URLs and selectors are data to verify. None of that separates the two sources; it only bounds the damage.
- **Note also:** the MCP server tells the user to add `.nco-web-editor/` to their project `.gitignore` (`bin/cli.ts:62`) but does not do it. A committed `pending-queue.json` is a shared instruction channel, which is why restore screening was added.
- **Discovered:** third security review round, 2026-10-27.
- **Target:** 0.3.1, together with KL-4.

### KL-7 — smaller hardening items deferred from the 0.3.0 security rounds
- **Per-field type validation of change entries.** `isValidDiff` checks the diff shape, `changes` being an array of non-null objects, and `batchId`. It does not type-check `changes[].property`/`toValue`, `attributeChanges` or `insertChanges`. Throws from those are contained per diff, so one bad entry is dropped rather than aborting the batch, but the entry is skipped silently after `DIFF_ACK` has already gone back — the designer is told the edit was received. Validate per field and report skips back to the extension.
- **Windows reserved device names.** The asset filename stem is not checked for `CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`. On Windows that yields a silent no-op write or a hang, not an escape.
- **Non-string `pendingUpload.filename`** throws in `assetFilename`; the caller catches and leaves the inline base64 in the diff.
- **Unbounded page-derived fields reaching the agent.** `assetPath`, `label`, `element.attributes`, `selector`, `textContent`, `sourceHref`, `outerHTML` and `cssText` are passed through with no length limit and no screening, covered only by the untrusted-data framing.
- **Duplicate diff ids within one batch** are queued twice; acknowledging removes one and the other is re-served.
- **Persist and status writes are unserialised.** `safePersistQueue` and `safeWriteStatusFile` are fire-and-forget and share a `.tmp` name, so two quick writes can interleave and leave the older content in place. Serialise through a promise chain and write via temp-file-plus-rename.
- **Discovered:** second and third security review rounds, 2026-10-26/27.
- **Target:** 0.3.1.

---

## Governance Tooling Defects (fix belongs upstream, in the Repo OS template)

Observed while working in this repo, but the faulty code is `.claude/hooks/*` and
`.claude/.automation/*`, which are synced from the template. Fixing them here
would be overwritten on the next sync. Each entry records what was observed, with
evidence, so the upstream fix can be written against real cases rather than a
description.

### GT-1 — Subagent hand-back destroys governance verdicts (highest cost)
- **File:** `.claude/hooks/state-writer.sh` (reads `.last_assistant_message` from the SubagentStop payload)
- **Symptom:** When a governance agent delivers its report through the harness hand-back mechanism, its final assistant message becomes a stub such as `"Report delivered to caller with GATE_RESULT: APPROVED."`. `state-writer.sh` looks for `GATE_RESULT:` on the last non-empty line, does not find it, writes a `reason=no_sentinel` escalation and **discards the verdict**. The commit gate then blocks on a review that actually passed.
- **Evidence (2026-09-24):** six verdicts lost this way in one session — Critic ×2, Reviewer ×3, Security ×1. See `.claude/.automation/escalations/verdict-rejected-*-20260925T*.yaml`.
- **Mitigations tried, and their limits:** instructing the agent in the dispatch prompt to repeat the full report verbatim as its closing message **does not reliably work** — the hand-back still replaces the final message. Explicitly instructing "do not call SubagentHandback" also failed for the Reviewer. **Resuming the finished agent via SendMessage and asking it to re-emit the report as a plain assistant message does work** — it recovered the Critic's cohesion and diff-review verdicts — but it failed three times for the Reviewer, so it is not a general remedy.
- **Impact:** A passing review is indistinguishable from an absent one at the gate. The documented escape is the operator-approved recovery signal (`touch .claude/.state/.recover-signal`), which skips *all* state-dependent checks — far broader than the one missing artefact.
- **Suggested direction:** have `state-writer.sh` fall back to scanning the whole transcript (or the hand-back payload) for a `GATE_RESULT:` line when the final message is a stub, rather than trusting the last line alone. Note the existing comment in the hook itself: an escalation is written but nothing reads it, so a discarded verdict still lets a session record success.

### GT-2 — High-risk scanner matches "token" with no context
- **File:** `.claude/hooks/pre-commit-gates.sh`, `RISK_CONTENT_PATTERN='(password|secret|token)'`
- **Symptom:** The scan runs over added lines with no notion of context, so design-system vocabulary trips it. A CSS-only commit was classified high-risk and required Reviewer **and** Security sign-offs because a code comment contained the phrase *"the token set in tokens.css"*.
- **Evidence (2026-09-24):** commit `07f8e95` (`feat(guide): ink on white paper`) — a stylesheet deletion with no logic change. Combined with GT-1, this turned a trivial change into six agent dispatches and an operator-approved bypass.
- **Why it matters here:** this product is *about* design tokens. The words `token`, `tokens.css`, `design tokens` and `--fe-*` token names appear throughout normal work, so the false-positive rate in this repo is close to 100%.
- **Suggested direction:** require an assignment-shaped or credential-shaped match (e.g. `token\s*[:=]\s*['"]`, or an entropy check on the value) rather than the bare word; or exempt `.css` files and comment lines.

### GT-3 — Automation daemon pushed to `origin` against an explicit constraint
- **File:** `.claude/.automation/` daemon / work-order runner
- **Symptom:** The `20260924-193009-editor-light-mode` brief stated *"No publish, tag or push; solo merge to local main only"* in both its Constraints section and its task contract, and the queue entry was added **without** `--push`. On completion the daemon pushed `main` to `origin` anyway.
- **Evidence (2026-09-24):** `git reflog show origin/main` records `update by push` at `2026-09-24 20:10:39 -0700`, matching the `entry-completed` event for entry `090f8bbb-e2fb-4e99-ae29-1d363ea44769` to the second. Nine local commits reached GitHub. No harm followed — the repository was private — but the constraint was ignored.
- **Why it matters:** push is the one irreversible step in the chain. A constraint the runner does not honour is worse than no constraint, because the brief author reasonably relies on it.
- **Suggested direction:** make push opt-in at the runner level (gated on the entry's `--push` flag) rather than something a brief must ask to be spared, and fail loudly if a brief forbids what the entry enables.

### GT-4 — Phase state is reused across sessions, so later verdicts are rejected for `phase_mismatch`
- **File:** `.claude/hooks/_phase-helper.sh` (`get_session_state_dir`), `.claude/hooks/state-writer.sh`
- **Symptom:** A new unit of work in a continuing session inherits the previous session's state directory, still holding that session's `current_phase` and its completed gate files. Governance agents dispatched for the *new* work are then rejected because the phase does not match what that agent type expects.
- **Evidence (2026-09-24):** state dir `.claude/.state/wt-sessions/9772a09d-…/` was left at `current_phase: commit` on branch `feature/guide-top-banner` from a finished cycle. Reviewer and Security verdicts for unrelated later work were discarded with `reason=phase_mismatch expected_phase=verify current_phase=commit`. Recovery needed `REPO_OS_ALLOW_REINIT=1`, a manual walk through `drift-check → plan → approval → build → review → verify`, and deletion of the stale gate files so the previous cycle's approvals could not be mistaken for the new one's.
- **Suggested direction:** treat a new branch (or a new brief/task contract) as the start of a new cycle and re-init automatically, rather than requiring an override and a hand-walk.

### GT-5 — `plan-approval.sh` does not fire on every qualifying AskUserQuestion
- **File:** `.claude/hooks/plan-approval.sh` (PostToolUse on AskUserQuestion)
- **Symptom:** An AskUserQuestion whose text satisfies all three documented gates (contains "plan"; contains an approval word; the answer contains an approval word) produced no `plan-approved` state file. Re-asking with the canonical template phrasing and an "Approve — auto" option label did write it.
- **Evidence (2026-09-24):** first question — header "Commit gate", body containing *"plan approval"* and an option labelled *"Approve the plan, replay gates"* — wrote nothing and logged nothing. The second, canonically phrased question wrote `plan-approved` immediately.
- **Relationship to R13:** `pre-commit-gates.sh:411` already anticipates this hook not firing and names it R13, so the failure mode is known; what is new is a case that appears to satisfy the matcher and still does not fire, which suggests the matcher (or the payload shape it reads) rather than dispatch timing.
- **Suggested direction:** log every AskUserQuestion payload the hook sees (it already emits a universal event) with the three gate outcomes, so a non-firing case can be diagnosed without re-running it.

### GT-6 — the release workflow runs dependency install scripts while holding the OIDC publish token
- **File:** `.github/workflows/release.yml` (publish job: `id-token: write`, `cache: 'npm'`, `npm ci`)
- **Symptom:** the publish job has `id-token: write` and runs a full `npm ci` with the npm cache restored. That executes lifecycle scripts for every dependency — `esbuild` is marked `hasInstallScript` in the lockfile — in the one job where the OIDC token endpoint is reachable.
- **Attack:** a compromised transitive dependency, or a poisoned cache restored into that job, runs a postinstall that mints an OIDC token and stages its own tarball. The 2FA approval is the only remaining barrier, and the approver sees a staged version that looks expected. `--provenance` is currently skipped for private repos, so the staged package carries no attestation either.
- **Why it is cheap to fix:** the publish job consumes artifacts the `verify` job already built. It never needs to run dependency code. Dropping `cache: 'npm'` from that job and using `npm ci --ignore-scripts` costs nothing legitimate.
- **Also worth doing:** pin third-party actions by commit SHA rather than `@v4`; have the approver compare the staged tarball hash against the one built in `verify`; assert the tag commit is on `main` and that the tag matches both `package.json` versions.
- **Why it is logged rather than fixed:** `.github/workflows/` is a governance path and is not editable in child mode. Operator decision 2026-10-26: fix upstream in `repo-OS-template` so every child repo benefits and the path lock stays meaningful.
- **Discovered:** adversarial security review, 2026-10-26.

### GT-7 — `template-sync.yml` interpolates a workflow input straight into a shell
- **File:** `.github/workflows/template-sync.yml:64` — `${{ github.event.inputs.source_repo }}`
- **Symptom:** a dispatch input is interpolated directly into a `run:` block, giving arbitrary command execution in a job with `contents: write` that pushes to `main`.
- **Exploitability:** low — it requires write access to dispatch the workflow in the first place. It matters as a privilege-escalation step rather than an entry point, and because the job also runs a script pulled from the template repo, so a compromise of `markpreston2/repo-OS-template` reaches this repo's `main`.
- **Fix:** pass the input through `env:` and validate it against an expected `owner/repo` pattern rather than interpolating into the shell.
- **Why it is logged rather than fixed:** same governance path lock and same upstream decision as GT-6.
- **Discovered:** adversarial security review, 2026-10-26.
