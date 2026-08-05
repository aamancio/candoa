#!/usr/bin/env bash
set -euo pipefail

# Prints a pass/fail summary for every .xcresult bundle found under the given
# paths, including each failure's message, so CI failures are readable at the
# end of the job log without downloading the result-bundle artifact. Also
# appends the same report as Markdown to $GITHUB_STEP_SUMMARY when set.
#
# Usage: e2e-failure-summary.sh <xcresult-or-directory> [...]
#
# Always exits 0: this is a diagnostic step and must not mask the test step's
# own status.

if (( $# == 0 )); then
  echo "Usage: $(basename "$0") <xcresult-or-directory> [...]" >&2
  exit 64
fi

bundles=()
for path in "$@"; do
  if [[ "$path" == *.xcresult && -d "$path" ]]; then
    bundles+=("$path")
  elif [[ -d "$path" ]]; then
    while IFS= read -r bundle; do
      bundles+=("$bundle")
    done < <(find "$path" -maxdepth 2 -name '*.xcresult' -type d | sort)
  fi
done

if (( ${#bundles[@]} == 0 )); then
  echo "No .xcresult bundles found under: $*"
  exit 0
fi

for bundle in "${bundles[@]}"; do
  summary_json="$(xcrun xcresulttool get test-results summary --path "$bundle" 2>/dev/null || true)"
  if [[ -z "$summary_json" ]]; then
    echo "Could not read test results from $bundle"
    continue
  fi

  BUNDLE_PATH="$bundle" python3 - <<'PYTHON' "$summary_json"
import json
import os
import sys

summary = json.loads(sys.argv[1])

result = summary.get("result", "Unknown")
passed = summary.get("passedTests", 0)
failed = summary.get("failedTests", 0)
skipped = summary.get("skippedTests", 0)
total = summary.get("totalTestCount", 0)
failures = summary.get("testFailures", [])

lines = []
lines.append(f"== {os.path.basename(os.environ['BUNDLE_PATH'])}")
lines.append(
    f"{result}: {passed} passed, {failed} failed, {skipped} skipped, {total} total"
)
for failure in failures:
    name = failure.get("testName") or failure.get("testIdentifierString") or "?"
    target = failure.get("targetName", "")
    text = failure.get("failureText", "").strip()
    prefix = f"{target}." if target else ""
    lines.append(f"FAILED {prefix}{name}")
    for text_line in text.splitlines():
        lines.append(f"    {text_line}")

print("\n".join(lines))

step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
if step_summary:
    with open(step_summary, "a", encoding="utf-8") as handle:
        icon = "✅" if result == "Passed" else "❌"
        handle.write(
            f"### {icon} {os.path.basename(os.environ['BUNDLE_PATH'])}\n\n"
            f"{result}: {passed} passed, {failed} failed, "
            f"{skipped} skipped, {total} total\n\n"
        )
        for failure in failures:
            name = failure.get("testName") or failure.get("testIdentifierString") or "?"
            target = failure.get("targetName", "")
            text = failure.get("failureText", "").strip()
            prefix = f"{target}." if target else ""
            handle.write(f"- **{prefix}{name}**\n\n  ```\n")
            for text_line in text.splitlines():
                handle.write(f"  {text_line}\n")
            handle.write("  ```\n")
PYTHON
done

exit 0
