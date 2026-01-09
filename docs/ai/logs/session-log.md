cat > docs/ai/logs/session-log.md <<'EOF'
# Session Log

Each session adds one entry. Keep entries high-signal and readable.

---

## Session <N> — <YYYY-MM-DD> — <Short Goal>

### Goal
- <What we were trying to achieve>

### Decisions Applied (Required)
- <List decision IDs that applied, e.g., 0001, 0002>
- <If none apply, explicitly say: "None">

### Plan Summary
- <Bullets of the chosen approach>

### Changes Made
- <Bullets of what changed>

### Verification (Gates Evidence)
- Commit gates satisfied: Yes/No
- Push gates satisfied: Yes/No (if pushed)
- Commands run + results:
  - <command> → <pass/fail summary>

### Failed Attempts (Brief)
- <1-line bullets: what was tried + why it failed>

### Commits
- <commit hash> — <message>

### Follow-ups
- <Next tasks / known issues>

EOF