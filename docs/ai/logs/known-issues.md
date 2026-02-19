# Known Issues

Structured index of resolved debugging issues. Populated by the HVST Record step after 2+ failed cycles.

Checked automatically when HVST failures reach threshold. Do not delete entries — they prevent repeat debugging.

| Symptom | Root Cause | Fix | Session |
|---------|-----------|-----|---------|
| Stop hook blocks session close even after session log was committed | Hook only checked `git diff` (uncommitted changes); committed updates were invisible. Initial fix used `pipe \| grep -q` which failed due to SIGPIPE (exit 141) — `grep -q` closes pipe early, `git log` gets SIGPIPE, `pipefail` returns 141 | Replaced `pipe \| grep -q .` with variable capture (`$()`) and `[ -n ]` test. Also added `git log --since="4 hours ago"` for committed changes | Session 3 |
