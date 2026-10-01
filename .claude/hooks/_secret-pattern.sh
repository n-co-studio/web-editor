#!/usr/bin/env bash
# Centralized secret-scanning regex — single source of truth.
# Sourced by pre-commit-gates.sh (A4 gate) and session-close-check.sh (safety valve).
#
# ## Consumers (auto-generated — run .claude/tools/hook-dep-map.sh for live data)
#   Hooks: pre-commit-gates, session-close-check
#
# Every alternative requires at least one character of trailing key material
# (ghp_[A-Za-z0-9], AKIA[A-Z0-9], npm_[A-Za-z0-9]{20,} …). sk_live_ and
# sk_test_ were the two exceptions: bare prefixes matching the literal alone.
# That made the scanner reject the template's own documentation — t-0046 and
# docs/ai/eval/_nomenclature.md both discuss `sk_live_` in prose — so any child
# repo that synced those files could not commit them. Brought in line with the
# siblings; a real Stripe key carries 24+ trailing characters and still matches.

# shellcheck disable=SC2034  # Variable used by sourcing scripts
_REPO_OS_SECRET_PATTERN='sk_live_[A-Za-z0-9]|sk_test_[A-Za-z0-9]|sk-ant-api[0-9]+-[A-Za-z0-9_-]+|ghp_[A-Za-z0-9]|github_pat_[A-Za-z0-9]|glpat-[A-Za-z0-9]|npm_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9]|sk-proj-[A-Za-z0-9]|pypi-[A-Za-z0-9]|AKIA[A-Z0-9]|AIza[A-Za-z0-9]|-----BEGIN.*PRIVATE KEY-----|://[^/:@[:space:]]+:[^/@[:space:]]+@[^[:space:]]+|password[[:space:]]*=[[:space:]]*["\x27][^"\x27]|secret[[:space:]]*=[[:space:]]*["\x27][^"\x27]|token[[:space:]]*=[[:space:]]*["\x27][^"\x27]'
