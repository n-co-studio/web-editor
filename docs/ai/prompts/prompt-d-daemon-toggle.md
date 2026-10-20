# Prompt D — Daemon Toggle

Toggle the automation daemon runner on or off. Running this prompt flips the current state.

## Procedure

1. Read `.claude/.automation/config.yaml` and check the current value of `runner.enabled`.

2. **If `runner.enabled: true`** (currently on → turn off):
   - Set `runner.enabled: false` in `config.yaml`.
   - Create `.claude/.automation/HALT` file (content: ISO 8601 timestamp). This is a GRACEFUL stop: the daemon checks the flag only between entries, so a session already running finishes first. It does not interrupt the brief in flight — for that the operator runs `queue-cli.sh force-halt`, which is a separate deliberate act and not part of this toggle.
   - Report: "Daemon disabled. HALT file created — a session already running will finish first."

3. **If `runner.enabled: false`** (currently off → turn on):
   - Set `runner.enabled: true` in `config.yaml`.
   - Remove `.claude/.automation/HALT` file if it exists.
   - Check for `.claude/.automation/FORCE-HALT` and remove it too if present. A leftover FORCE-HALT ends the next daemon start at the top of its loop, so enabling the daemon without clearing it looks like the toggle silently did nothing.
   - Report: "Daemon enabled. HALT file removed (if present)." — and say so explicitly if a FORCE-HALT flag was also cleared.

4. Show the new state:
   ```
   runner.enabled: true/false
   HALT file: present/absent
   FORCE-HALT file: present/absent
   ```

## Rules

- REQUIRE: **never use the Agent tool with write-capable subagent types** (builder, qa-verifier, security-privacy, general-purpose, reviewer) or request worktree isolation. Only read-only advisory agents are permitted.
- REQUIRE: this is an ephemeral session. No branch, no session log, no commit.
- REQUIRE: only modify `config.yaml`, the `HALT` file and the `FORCE-HALT` file. Do not touch any other files. FORCE-HALT may only be REMOVED here (step 3), never created — creating it is `queue-cli.sh force-halt`, an explicit operator action that kills a running session.
- REQUIRE: do not start or stop launchd/systemd services. The operator manages service lifecycle separately.
