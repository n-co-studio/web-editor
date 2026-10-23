# Prompt D — Daemon Toggle

Toggle the automation daemon runner on or off. Running this prompt flips the current state.

## Procedure

1. Determine the **effective** value of `runner.enabled`, which is not necessarily the one in `config.yaml`. `_parse_config_field` reads `config.local.yaml` FIRST and any non-empty value there wins, and `runner.sh` bootstraps that file with `enabled: true`. So read BOTH files:
   - If `config.local.yaml` sets `runner.enabled`, that is the effective value and `config.yaml`'s is dead.
   - Otherwise `config.yaml`'s value is effective.

   Branch on the effective value in step 2/3, and report both when they disagree. Never report `config.yaml`'s value as "the" state — doing so is how a daemon that is still enabled gets reported as off.

2. **If effective `runner.enabled` is true** (currently on → turn off):
   - Write `runner.enabled: false` in `config.local.yaml`. This is the authoritative live-toggle file. If the file does not exist, create it in the bootstrap shape:
     ```
     runner:
       enabled: false
     ```
     If it exists, update the `enabled:` line within the `runner:` block (or insert it under `runner:` if the line is absent). Do not put a trailing comment on the `enabled:` line — `_parse_config_field` takes everything after the colon as the value, so a trailing comment is parsed as part of it and may be rejected.
   - Create `.claude/.automation/HALT` file (content: ISO 8601 timestamp). This is a GRACEFUL stop: the daemon checks the flag in its loop (at the top, and again after dequeue, before launch) and never during a session, so no new entry starts once the flag exists and a session already running finishes first. It does not interrupt the brief in flight — for that the operator runs `queue-cli.sh force-halt`, which is a separate deliberate act and not part of this toggle.
   - Report: "Daemon disabled. HALT file created — a session already running will finish first."

3. **If effective `runner.enabled` is false** (currently off → turn on):
   - Write `runner.enabled: true` in `config.local.yaml`. If the file does not exist, create it in the bootstrap shape:
     ```
     runner:
       enabled: true
     ```
     If it exists, update the `enabled:` line within the `runner:` block (or insert it under `runner:` if the line is absent). Do not put a trailing comment on the `enabled:` line.
   - Remove `.claude/.automation/HALT` file if it exists.
   - Check for `.claude/.automation/FORCE-HALT` and remove it too if present. A leftover FORCE-HALT ends the next daemon start at the top of its loop, so enabling the daemon without clearing it looks like the toggle silently did nothing.
   - Report: "Daemon enabled. HALT file removed (if present)." — and say so explicitly if a FORCE-HALT flag was also cleared.

4. Show the new state, effective value first:
   ```
   runner.enabled (effective): true/false   [from config.yaml | from config.local.yaml]
   runner.enabled (config.yaml): true/false
   HALT file: present/absent
   FORCE-HALT file: present/absent
   ```

## Rules

- REQUIRE: **never use the Agent tool with write-capable subagent types** (builder, qa-verifier, security-privacy, general-purpose, reviewer) or request worktree isolation. Only read-only advisory agents are permitted.
- REQUIRE: this is an ephemeral session. No branch, no session log, no commit.
- REQUIRE: only modify `config.local.yaml` (the `runner.enabled` field only), the `HALT` file and the `FORCE-HALT` file. Do not modify `config.yaml` or any other files. FORCE-HALT may only be REMOVED here (step 3), never created — creating it is `queue-cli.sh force-halt`, an explicit operator action that kills a running session.
- REQUIRE: do not start or stop launchd/systemd services. The operator manages service lifecycle separately.
