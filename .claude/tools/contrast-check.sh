#!/usr/bin/env bash
# contrast-check.sh — WCAG 2.1 contrast ratio computation for design tokens.
#
# Computes relative luminance and contrast ratios using the corrected WCAG 2.1
# sRGB linearization threshold (0.04045). Pure shell + awk — no Node/Python.
#
# Usage:
#   contrast-check.sh --hex "#fg" "#bg"           # raw hex pair
#   contrast-check.sh --token <name> <name>        # resolve from variables.css
#   contrast-check.sh --audit                      # all token pairs, AA failures only
#
# Output format (single pair):
#   <fg> on <bg>: <ratio>:1 [AA <PASS|FAIL>] [AAA <PASS|FAIL>] [AA-large <PASS|FAIL>]
#
# Exit codes:
#   0 — all checks pass (or informational hex mode)
#   1 — one or more AA normal failures found
#   2 — usage error or token parse failure
#
# Thresholds (WCAG 2.1):
#   AA normal   >= 4.5:1
#   AAA normal  >= 7.0:1
#   AA large    >= 3.0:1
#
# Token file path:
#   Set REPO_OS_TOKENS_FILE env var to your CSS variables file path.
#   The --hex mode works without any token file.
#
# Decision 0003 — Agent Structure Standard

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOKENS_FILE="${REPO_OS_TOKENS_FILE:-}"

# ---------------------------------------------------------------------------
# WCAG luminance + contrast via awk
# Inputs: two hex colors (with or without #) as positional args
# Outputs: ratio:1 [AA PASS|FAIL] [AAA PASS|FAIL] [AA-large PASS|FAIL]
# ---------------------------------------------------------------------------
compute_contrast() {
  local fg="$1"
  local bg="$2"
  awk -v fg="$fg" -v bg="$bg" '
  BEGIN {
    lum_fg = relative_luminance(fg)
    lum_bg = relative_luminance(bg)

    if (lum_fg > lum_bg) {
      lighter = lum_fg; darker = lum_bg
    } else {
      lighter = lum_bg; darker = lum_fg
    }

    ratio = (lighter + 0.05) / (darker + 0.05)

    aa      = (ratio >= 4.5) ? "PASS" : "FAIL"
    aaa     = (ratio >= 7.0) ? "PASS" : "FAIL"
    aa_lg   = (ratio >= 3.0) ? "PASS" : "FAIL"

    printf "%.2f:1 [AA %s] [AAA %s] [AA-large %s]\n", ratio, aa, aaa, aa_lg
    exit (aa == "FAIL") ? 1 : 0
  }

  function hex2int(h,    hi, lo) {
    h = tolower(h)
    hi = index("0123456789abcdef", substr(h,1,1)) - 1
    lo = index("0123456789abcdef", substr(h,2,1)) - 1
    return hi * 16 + lo
  }

  function linearize(c) {
    # sRGB channel c in [0,1] -> linear
    # Corrected WCAG 2.1 threshold: 0.04045
    if (c == 0) return 0
    if (c <= 0.04045) return c / 12.92
    return (((c + 0.055) / 1.055) ^ 2.4)
  }

  function relative_luminance(hexstr,    r, g, b) {
    if (substr(hexstr,1,1) == "#") hexstr = substr(hexstr,2)
    r = linearize(hex2int(substr(hexstr,1,2)) / 255)
    g = linearize(hex2int(substr(hexstr,3,2)) / 255)
    b = linearize(hex2int(substr(hexstr,5,2)) / 255)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  }
  '
}

# ---------------------------------------------------------------------------
# Token resolution: extract #RRGGBB for --color-<name> from variables.css
# ---------------------------------------------------------------------------
resolve_token() {
  local name="$1"
  if [ -z "$TOKENS_FILE" ]; then
    echo "ERROR: REPO_OS_TOKENS_FILE is not set. Set it to your CSS variables file path." >&2
    exit 2
  fi
  if [ ! -f "$TOKENS_FILE" ]; then
    echo "ERROR: tokens file not found: $TOKENS_FILE" >&2
    exit 2
  fi
  local value
  value=$(grep -E "^\s*--color-${name}:\s*#[0-9A-Fa-f]{6}" "$TOKENS_FILE" \
    | sed -E 's/.*--color-[^:]+:[[:space:]]*(#[0-9A-Fa-f]{6}).*/\1/' \
    | head -1)
  if [ -z "$value" ]; then
    echo "ERROR: token '--color-${name}' not found in variables.css" >&2
    exit 2
  fi
  echo "$value"
}

# ---------------------------------------------------------------------------
# Validate that tokens file is parseable
# ---------------------------------------------------------------------------
check_tokens_file() {
  if [ -z "$TOKENS_FILE" ]; then
    echo "ERROR: REPO_OS_TOKENS_FILE is not set. Set it to your CSS variables file path." >&2
    exit 2
  fi
  if [ ! -f "$TOKENS_FILE" ]; then
    echo "ERROR: tokens file not found: $TOKENS_FILE" >&2
    exit 2
  fi
  local count
  count=$(grep -cE "^\s*--color-[a-z][^:]*:\s*#[0-9A-Fa-f]{6}" "$TOKENS_FILE" 2>/dev/null || true)
  if [ "${count:-0}" -eq 0 ]; then
    echo "ERROR: no color tokens parsed from variables.css — expected '--color-<name>: #RRGGBB;' format" >&2
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# --hex mode
# ---------------------------------------------------------------------------
mode_hex() {
  local fg="$1"
  local bg="$2"
  local fg_label="${fg#\#}"
  local bg_label="${bg#\#}"
  local result
  local exit_code=0
  result=$(compute_contrast "$fg" "$bg") || exit_code=$?
  echo "#${fg_label} on #${bg_label}: ${result}"
  return $exit_code
}

# ---------------------------------------------------------------------------
# --token mode
# ---------------------------------------------------------------------------
mode_token() {
  local fg_name="$1"
  local bg_name="$2"
  local fg_hex bg_hex result
  fg_hex=$(resolve_token "$fg_name")
  bg_hex=$(resolve_token "$bg_name")
  local exit_code=0
  result=$(compute_contrast "$fg_hex" "$bg_hex") || exit_code=$?
  echo "${fg_name} on ${bg_name}: ${result}"
  return $exit_code
}

# ---------------------------------------------------------------------------
# --audit mode: check all color token pairs, output only AA normal failures
# ---------------------------------------------------------------------------
mode_audit() {
  check_tokens_file
  local names=()
  local hexes=()
  while IFS= read -r line; do
    local name hex
    name=$(echo "$line" | sed -E 's/.*--color-([^:]+):.*/\1/')
    hex=$(echo "$line"  | sed -E 's/.*:[[:space:]]*(#[0-9A-Fa-f]{6}).*/\1/')
    names+=("$name")
    hexes+=("$hex")
  done < <(grep -E "^\s*--color-[a-z][^:]*:\s*#[0-9A-Fa-f]{6}" "$TOKENS_FILE")

  local count=${#names[@]}
  if [ "$count" -eq 0 ]; then
    echo "ERROR: no color tokens found" >&2
    exit 2
  fi

  local any_fail=0
  for (( i=0; i<count; i++ )); do
    for (( j=0; j<count; j++ )); do
      [ "$i" -eq "$j" ] && continue
      local fg_name="${names[$i]}"
      local bg_name="${names[$j]}"
      local fg_hex="${hexes[$i]}"
      local bg_hex="${hexes[$j]}"
      local result exit_code
      exit_code=0
      result=$(compute_contrast "$fg_hex" "$bg_hex") || exit_code=$?
      if [ "$exit_code" -ne 0 ]; then
        echo "${fg_name} on ${bg_name}: ${result}"
        any_fail=1
      fi
    done
  done

  if [ "$any_fail" -eq 0 ]; then
    echo "All token color pairs pass AA normal (>= 4.5:1)"
  fi
  return $any_fail
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<'EOF'
Usage:
  contrast-check.sh --hex "#RRGGBB" "#RRGGBB"    Compute contrast for a hex pair
  contrast-check.sh --token <name> <name>         Resolve tokens from variables.css and compute
  contrast-check.sh --audit                       List all token pairs failing AA normal (>= 4.5:1)

Token file: set REPO_OS_TOKENS_FILE env var to your CSS variables file path
Exit codes: 0=pass, 1=AA failure(s), 2=usage/parse error
EOF
  exit 2
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if [ $# -eq 0 ]; then
  usage
fi

case "$1" in
  --hex)
    [ $# -eq 3 ] || usage
    mode_hex "$2" "$3"
    ;;
  --token)
    [ $# -eq 3 ] || usage
    mode_token "$2" "$3"
    ;;
  --audit)
    [ $# -eq 1 ] || usage
    mode_audit
    ;;
  *)
    usage
    ;;
esac
