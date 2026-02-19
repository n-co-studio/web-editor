# Known Issues

Structured index of resolved debugging issues. Populated by the HVST Record step after 2+ failed cycles.

Checked automatically when HVST failures reach threshold. Do not delete entries — they prevent repeat debugging.

| Symptom | Root Cause | Fix | Session |
|---------|-----------|-----|---------|
| Stop hook blocks session close even after session log was committed | Hook only checked `git diff` (uncommitted changes); committed updates were invisible | Added `git log --since="4 hours ago"` check to also detect recently committed session-log changes | Session 3 |
