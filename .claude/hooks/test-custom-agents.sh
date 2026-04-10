#!/usr/bin/env bash
# Integration test for custom agent namespace.
# Verifies: write-guard carve-out, frontmatter validation, name collision, permission allowlist.
#
# Usage: .claude/hooks/test-custom-agents.sh
# Exit: 0 if all tests pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CUSTOM_DIR="$REPO_ROOT/.claude/agents/custom"
AGENTS_DIR="$REPO_ROOT/.claude/agents"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Custom Agents Integration Tests ==="
echo ""

# --- Test 1: Directory exists ---
echo "Test 1: Custom agents directory exists"
if [ -d "$CUSTOM_DIR" ]; then
  pass "Directory .claude/agents/custom/ exists"
else
  fail "Directory .claude/agents/custom/ does not exist"
fi

# --- Test 2: .gitkeep exists ---
echo "Test 2: .gitkeep exists"
if [ -f "$CUSTOM_DIR/.gitkeep" ]; then
  pass ".gitkeep exists"
else
  fail ".gitkeep missing"
fi

# --- Test 3: README.md exists ---
echo "Test 3: README.md exists"
if [ -f "$CUSTOM_DIR/README.md" ]; then
  pass "README.md exists"
else
  fail "README.md missing"
fi

# --- Test 4: Write-guard carve-out (child mode) ---
echo "Test 4: Write-guard carve-out for .claude/agents/custom/*"
source "$SCRIPT_DIR/_analytics-helper.sh"
source "$SCRIPT_DIR/_mode-guard-helper.sh"
if is_carved_out "child" ".claude/agents/custom/test.md"; then
  pass "Custom agent path is carved out in child mode"
else
  fail "Custom agent path NOT carved out in child mode"
fi

# --- Test 5: Template agents still blocked in child mode ---
echo "Test 5: Template agents blocked in child mode"
if ! is_carved_out "child" ".claude/agents/orchestrator.md"; then
  pass "Template agent path blocked in child mode"
else
  fail "Template agent path carved out in child mode (REGRESSION)"
fi

# --- Test 6: .claude/agents/ root not opened ---
echo "Test 6: .claude/agents/ root not inadvertently opened"
if ! is_carved_out "child" ".claude/agents/new-agent.md"; then
  pass ".claude/agents/ root still blocked in child mode"
else
  fail ".claude/agents/ root opened in child mode (REGRESSION)"
fi

# --- Test 7: Frontmatter validation — clean file passes ---
echo "Test 7: Frontmatter validation — clean file"
TEMP_CLEAN=$(mktemp /tmp/test-agent-clean-XXXXXX.md)
cat > "$TEMP_CLEAN" << 'EOF'
---
model: haiku
tools:
  - Read
---

# Clean Agent
EOF
if "$SCRIPT_DIR/validate-custom-agent.sh" "$TEMP_CLEAN" 2>/dev/null; then
  pass "Clean agent passes validation"
else
  fail "Clean agent fails validation"
fi
rm -f "$TEMP_CLEAN"

# --- Test 8: Frontmatter validation — restricted fields detected ---
echo "Test 8: Frontmatter validation — restricted fields detected"
TEMP_RESTRICTED=$(mktemp /tmp/test-agent-restricted-XXXXXX.md)
cat > "$TEMP_RESTRICTED" << 'EOF'
---
model: haiku
hooks:
  - preToolUse: some-hook
mcpServers:
  - name: evil-server
permissionMode: full
tools:
  - Read
---

# Restricted Agent
EOF
if ! "$SCRIPT_DIR/validate-custom-agent.sh" "$TEMP_RESTRICTED" 2>/dev/null; then
  pass "Restricted fields detected and rejected"
else
  fail "Restricted fields NOT detected"
fi

# --- Test 9: Frontmatter validation — strip mode ---
echo "Test 9: Frontmatter validation — strip mode"
if "$SCRIPT_DIR/validate-custom-agent.sh" "$TEMP_RESTRICTED" --strip 2>/dev/null; then
  # Verify fields were stripped
  if ! grep -q "^hooks:" "$TEMP_RESTRICTED" && ! grep -q "^mcpServers:" "$TEMP_RESTRICTED" && ! grep -q "^permissionMode:" "$TEMP_RESTRICTED"; then
    pass "Restricted fields stripped successfully"
  else
    fail "Restricted fields not fully stripped"
  fi
else
  fail "Strip mode failed"
fi
rm -f "$TEMP_RESTRICTED"

# --- Test 10: Name collision detection ---
echo "Test 10: Name collision with template agent"
TEMP_COLLISION=$(mktemp -d /tmp/test-collision-XXXXXX)
mkdir -p "$TEMP_COLLISION"
cat > "$TEMP_COLLISION/orchestrator.md" << 'EOF'
---
model: haiku
---

# Fake Orchestrator
EOF
# Simulate by placing file in custom dir temporarily
cp "$TEMP_COLLISION/orchestrator.md" "$CUSTOM_DIR/orchestrator.md"
if ! "$SCRIPT_DIR/validate-custom-agent.sh" "$CUSTOM_DIR/orchestrator.md" 2>/dev/null; then
  pass "Name collision with template agent detected"
else
  fail "Name collision NOT detected"
fi
rm -f "$CUSTOM_DIR/orchestrator.md" "$TEMP_COLLISION/orchestrator.md"
rmdir "$TEMP_COLLISION"

# --- Test 11: Custom agent resolution (permission allowlist) ---
echo "Test 11: Custom agent resolution function"
source "$SCRIPT_DIR/_permission-allowlist.sh"
# Create a temporary fixture agent for resolution testing
TEMP_AGENT_11="$CUSTOM_DIR/_test-fixture.md"
cat > "$TEMP_AGENT_11" << 'EOF'
---
model: haiku
---

# Test Fixture Agent
EOF
if is_custom_agent "_test-fixture"; then
  pass "is_custom_agent resolves fixture agent"
else
  fail "is_custom_agent does not resolve fixture agent"
fi
rm -f "$TEMP_AGENT_11"

# --- Test 12: Custom agent resolution — non-existent agent ---
echo "Test 12: Custom agent resolution — non-existent"
if ! is_custom_agent "nonexistent-agent"; then
  pass "is_custom_agent rejects non-existent agent"
else
  fail "is_custom_agent resolves non-existent agent"
fi

# --- Test 13: Custom agent resolution — path traversal rejected ---
echo "Test 13: Custom agent resolution — path traversal"
if ! is_custom_agent "../orchestrator"; then
  pass "Path traversal rejected"
else
  fail "Path traversal NOT rejected"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
