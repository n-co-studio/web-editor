# Session — 0.3.1: bridge peer authentication and structured notes (KL-4 + KL-6)

- **Session ID:** 83ab3340-33c6-4a6a-b3b0-b8bd4e6ddf62
- **Type:** standard
- **Branch:** fix/security-0-3-1
- **Date:** 2026-10-27 / 28
- **Commit:** `22f2c2f`

## Why

0.3.0 shipped with two findings deferred as one protocol change. First, the bridge admitted any `localhost` origin, so script on the dev page could drive it (KL-4). Second, notes spliced page-built element references into the designer's words while the agent was told to follow notes (KL-6). Together they handed page script a trusted instruction channel to the agent.

## Decision: Option A, not B

The socket moved into the service worker, with the server pinned to the published extension ID. A pairing secret (Option B) was not used.

- A closes the two realistic actors, script on the dev page and another extension, at zero setup cost.
- B also closes a local process forging `Origin` or squatting the port. It costs a pairing step and the store listing's zero-setup claim. On a single-user machine a local process can already read the project, so those actors were accepted as residual risk and written into KL-4. B is additive on top of A if wanted later.
- A's stated cost, MV3 idle termination, was already moot: the manifest requires Chrome 116, from which WebSocket traffic keeps the worker alive.
- **Spike, before building:** an MV3 service worker in Chromium 153 (Chrome for Testing, headless) opened `ws://127.0.0.1` with no host permission, both with and without the localhost content-script matches. The server saw `Origin: chrome-extension://<id>`. **Branded Chrome 156 is unverified**; see Open.

## What changed

- **Transport.** `content/websocket-client.ts` is now a Port proxy. `service-worker/bridge-socket.ts` is the moved client and connects to `127.0.0.1`. `service-worker/bridge-port.ts` keeps one socket per tab. The tab id comes from `port.sender`, prefixed with a per-browser id held in `storage.session`, and it overwrites any tab id in a diff.
- **Server origin pin.** `bridge.ts` accepts only `chrome-extension://aifpecjojmlgdhgnkmkaobmfipdmppea`, plus well-formed `NCO_WEB_EDITOR_EXTENSION_IDS`. It logs once per origin when a pre-0.3.1 extension is refused. The misleading comment that hid KL-4 is replaced with one that states the residual risk.
- **Page cannot act for the designer.** The shadow root is `closed`, and host styles are `!important`. Every editor listener page script can reach goes through `trustedOnly` (`shared/trusted.ts`): selection click, global shortcuts, multi-select, ruler, drags, text-edit blur, paste and shields, notes, pick mode and Apply.
- **Structured notes.** `{ text, elements }` travels alongside the legacy `batchNote`. Ref fields are screened separately. The agent gets `designerText` plus `elementRefs`. Disk-restored notes become `untrustedRestoredText`, and `batches[]` carries `noteCount` only. `batchId` is pattern-checked everywhere. Restore and import are capped.
- **Send result.** A batch counts as sent only when the worker reports the socket sent it. Exactly the snapshot of sent notes is removed, after segment 0 succeeds.
- **Version skew.** A new extension accepts 0.4.0-protocol servers (`shared/protocol-compat.ts`). A new server refuses old extensions. **Release the extension first.**
- **Test runners.** Both now have `--test-timeout=30000`, so a leaked handle fails the run rather than stalling CI.
- **Docs.** CHANGELOG `[Unreleased]`. KL-4 and KL-6 resolved with residual risk stated. KL-7 additions. GT-8 and GT-9. The spec (`architecture.md`, `feature-005`, `data-contracts.md`) now says the service worker owns the socket; the old spec deliberately said the content script did. The product graph gains six nodes, and three pre-existing schema violations in it were fixed.

## How the fixes kept breaking, again

The pattern from 0.3.0 repeated: three rounds of review each found something the previous fix had introduced or missed.

- **Builder round 1.** My own revert pass found that `restoreQueue` honoured a disk file's `source: 'structured'`. A crafted `pending-queue.json` in a cloned repo would therefore have reached the agent as designer text. Three `isTrusted` gates also survived their own removal.
- **Review round 1.** Four reviewers, three of them independently, found the same hole: `batches[].batchNote` repeated every note's text unlabelled, which bypassed the new labelling. The reviewer found the async proxy reporting a dropped batch as sent, while clearing the notes. The adversarial pass found that the `isTrusted` gates covered only send and notes, so page script could select elements and fire Paste, Delete or Undo, and those edits rode out on the designer's next real Apply.
- **Review round 2.** The async send fix itself introduced two defects: notes added mid-send were wiped, and a partial failure duplicated notes.

## Revert pass (mutation testing)

Every guard was removed one at a time and the suite re-run. Scripts are in the session scratchpad (`mutate*.sh`).

| Guard | Fails |
|---|---|
| Localhost origins refused | 4 named tests |
| Extension ID pin | 8 |
| Env-ID format check | 4 |
| moz-extension refused | 2 |
| `sourceFile` screen on refs | 2 |
| `assetPath` screen | 4 |
| selector / textContent caps | 3 / 3 |
| `notes` supersede `batchNote` | 3 |
| Restore re-screens refs | 2 |
| Designer text sanitised | 1 |
| Restore demotes to `restored` | 2 |
| `batches` carries no text | 2 (after the test fix below) |
| `batchId` pattern | 3 |
| Closed shadow root | 1 |
| `127.0.0.1` target | 3 (in 5s, after the hang fix) |
| Send / add-note / + Ref / + Selected / pick `isTrusted` | 1 / 2 / 1 / 1 / 1 |
| `trustedOnly` helper hollowed out | 5 |
| Text-edit blur / paste gate | 1 / 1 |
| Port sender-id check | 1 |
| Diff tabId stamped by worker | 1 |
| Worker reports real send result | 1 |
| Snapshot removal (vs `clear()`) | 1 |
| `!important` host styles | 2 |

**Two test-harness defects were found by this pass, not by the tests:**
- Reverting the `127.0.0.1` target hung the extension suite for 35 minutes, because a client was never destroyed when an assertion threw.
- Reverting the `batches` guard was caught only by a timeout. Node's `assert.ok` re-reads the test source to build its message, and under tsx that stalls the file. **Use `assert.equal` or `assert.deepEqual` in these suites, not `assert.ok`, for anything a guard depends on.**

## Verification

- `mcp-server` 139/139 and `chrome-extension` 262/262. Typecheck and build are clean in shared, mcp-server and chrome-extension.
- Pragmatist, critic (cohesion and diff-review), reviewer, security and QA all APPROVED and recorded.
- The adversarial pass confirmed the bridge itself held: page script, another extension and a cloned repo could not open or drive the socket.
- Large scope (5,055 lines, 2,782 of them tests) was approved by the operator.

## Governance problems hit (GT-8, GT-9)

- **Stale session id on verdicts.** Every verdict was stamped with the previous session's id. The flat `.claude/.session-id` still held `5d149e99`, because that session's process was alive, and both the writer and the validator read the flat file. It passed only because they agree with each other.
- **Wrong-phase dispatch, my error and a repeat.** I dispatched reviewer and security from `review`. They must come from `verify`, and their verdicts were discarded to `escalations/`. Re-review approvals also vanished without a trace.
- **Phase reset on re-approval.** The large-scope re-approval reset the session to `build` (cycle 2), so the next QA verdict was discarded too. I had checked and wrongly concluded it would not reset.
- **Rule for next time:** check `.claude/.automation/escalations/` and the state files after every governance dispatch, not at commit.

## Open

- **Manual check in branded Chrome 156, needs the operator:**
  - The service worker reaches `127.0.0.1` with no Local Network Access prompt.
  - A page-console `new WebSocket('ws://127.0.0.1:7890')` is refused.
  - A dispatch works end to end.
  - The colour popover, keydown guards and ruler work under the closed root. linkedom cannot exercise closed-root semantics.
- **Release order:** extension 0.3.1 first, then the server. Nothing has been published. That needs operator approval per release.
- **Remaining 0.3.1 branches:**
  - KL-3 zod 4 (independent)
  - KL-5 SVG screening
  - KL-7 (now including the confirmed `export_session` directory-symlink write)
  - the setup screenshots (`SetupGuide.tsx:334`, `:393`, `HowToUse.tsx:92`)
  - GT-6 to GT-9 upstream in repo-OS-template
- **Not filed:** the drafted brief at `docs/ai/logs/pending-brief-bridge-peer-authentication.md`. This session went through the plan gate instead. It can be archived.
