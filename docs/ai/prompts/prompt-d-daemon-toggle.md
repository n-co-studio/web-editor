# Prompt D — Daemon Toggle

Toggle the automation daemon runner on or off. Running this prompt flips the current state.

## Procedure

1. Read `.claude/.automation/config.yaml` and check the current value of `runner.enabled`.

2. **If `runner.enabled: true`** (currently on → turn off):
   - Set `runner.enabled: false` in `config.yaml`.
   - Create `.claude/.automation/HALT` file (content: ISO 8601 timestamp) to stop any running daemon immediately.
   - Report: "Daemon disabled. HALT file created."

3. **If `runner.enabled: false`** (currently off → turn on):
   - Set `runner.enabled: true` in `config.yaml`.
   - Remove `.claude/.automation/HALT` file if it exists.
   - Report: "Daemon enabled. HALT file removed (if present)."

4. Show the new state:
   ```
   runner.enabled: true/false
   HALT file: present/absent
   ```

## Rules

- REQUIRE: this is an ephemeral session. No branch, no session log, no commit.
- REQUIRE: only modify `config.yaml` and the `HALT` file. Do not touch any other files.
- REQUIRE: do not start or stop launchd/systemd services. The operator manages service lifecycle separately.
