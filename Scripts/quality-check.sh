#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

failures=0

report_failure() {
  echo "::error::$1" >&2
  failures=1
}

report_warning() {
  echo "::warning::$1" >&2
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    report_failure "$1 is required for quality checks."
  fi
}

require_command rg

if (( failures != 0 )); then
  exit "$failures"
fi

echo "Checking for merge conflict markers..."
if rg -n '^(<<<<<<<|=======|>>>>>>>)' Candoa CandoaUITests Scripts .github; then
  report_failure "Merge conflict marker found."
fi

echo "Checking for debug logging in app sources..."
if rg -n '\b(print|debugPrint|dump)\s*\(' Candoa --glob '*.swift'; then
  report_failure "Debug logging found in app sources. Use structured UI/state instead of print-style logging."
fi

echo "Checking for unsafe Swift shortcuts..."
if rg -n '\b(try!|as!)\b|fatalError\s*\(' Candoa --glob '*.swift'; then
  report_failure "Unsafe Swift shortcut found in app sources."
fi

echo "Checking entitlement policy..."
# Sign in with Apple ships via the web flow (ASWebAuthenticationSession);
# the native capability must never enter any signing path. The browser
# passkey entitlement stays out until Apple assigns the managed capability
# (#14 flips it to required after assignment).
for forbidden in \
  com.apple.developer.applesignin \
  com.apple.developer.web-browser.public-key-credential; do
  if rg -n --fixed-strings "$forbidden" Candoa/Resources/*.entitlements; then
    report_failure "Forbidden entitlement $forbidden found in an entitlements file."
  fi
done

echo "Checking SwiftLint rules when available..."
if command -v swiftlint >/dev/null 2>&1; then
  swiftlint lint --config .swiftlint.yml --strict
else
  report_warning "swiftlint is not installed; skipping SwiftLint rules."
fi

echo "Reporting repeated Swift implementation lines..."
duplicate_report="$(
  find Candoa -name '*.swift' -print0 |
    xargs -0 awk '
      function trim(value) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        return value
      }
      {
        line = trim($0)
        if (line == "") next
        if (line ~ /^\/\//) next
        if (line ~ /^\/\*/) next
        if (line ~ /^\*/) next
        if (line ~ /^import /) next
        if (line ~ /^[{}]$/) next
        if (line ~ /^else[ {]*$/) next
        if (line ~ /^case /) next
        if (line ~ /^default:/) next
        if (length(line) < 42) next
        count[line] += 1
        if (count[line] <= 4) {
          locations[line] = locations[line] FILENAME ":" FNR " "
        }
      }
      END {
        for (line in count) {
          if (count[line] >= 6) {
            print count[line] "x " line " [" locations[line] "...]"
          }
        }
      }
    ' |
    sort -rn |
    head -20
)"

if [[ -n "$duplicate_report" ]]; then
  while IFS= read -r duplicate; do
    report_warning "Repeated implementation line: $duplicate"
  done <<< "$duplicate_report"
else
  echo "No high-frequency repeated implementation lines found."
fi

exit "$failures"
