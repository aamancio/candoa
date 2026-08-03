#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${CANDOA_E2E_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${CANDOA_DERIVED_DATA_PATH:-}"
DERIVED_DATA_DIR=""
XCODEBUILD_ARGS=(
  -project Candoa.xcodeproj
  -scheme Candoa
  -configuration Debug
  -destination "$DESTINATION"
)

if [[ "${CANDOA_E2E_ADHOC_SIGNING:-0}" == "1" ]]; then
  # Ad-hoc-signed apps carrying restricted entitlements (iCloud, associated
  # domains) are killed by the system at launch, so CI signs the app against
  # the stripped testing entitlements. The indirection through
  # CANDOA_APP_ENTITLEMENTS keeps this scoped to the app target — overriding
  # CODE_SIGN_ENTITLEMENTS directly would also sandbox the UI test runner,
  # which breaks XCUITest automation.
  XCODEBUILD_ARGS+=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY=-
    DEVELOPMENT_TEAM=
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    CANDOA_APP_ENTITLEMENTS=Candoa/Resources/CandoaCITesting.entitlements
    ENABLE_HARDENED_RUNTIME=NO
  )
fi

# Optional comma-separated -only-testing specs (e.g.
# "CandoaUITests/CandoaUITests/testSomething") so CI dispatches can rerun a
# single flaky test without paying for the whole suite.
if [[ -n "${CANDOA_E2E_ONLY_TESTING:-}" ]]; then
  IFS=',' read -ra ONLY_TESTING_SPECS <<< "$CANDOA_E2E_ONLY_TESTING"
  for only_testing_spec in "${ONLY_TESTING_SPECS[@]}"; do
    if [[ -n "$only_testing_spec" ]]; then
      XCODEBUILD_ARGS+=("-only-testing:${only_testing_spec}")
    fi
  done
fi

if [[ -n "$DERIVED_DATA_PATH" ]]; then
  DERIVED_DATA_DIR="$DERIVED_DATA_PATH"
else
  DERIVED_DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/candoa-e2e-derived.XXXXXX")"
fi

XCODEBUILD_ARGS+=(-derivedDataPath "$DERIVED_DATA_DIR")

cleanup() {
  if [[ -z "$DERIVED_DATA_PATH" && -n "$DERIVED_DATA_DIR" ]]; then
    rm -rf "$DERIVED_DATA_DIR"
  fi
}
trap cleanup EXIT

cd "$ROOT_DIR"

stop_candoa_processes() {
  local signal="$1"
  local pids

  pids="$(pgrep -x Candoa || true)"
  if [[ -z "$pids" ]]; then
    return
  fi

  pkill "-$signal" -x Candoa || true

  while IFS= read -r pid; do
    local ppid
    local parent_command

    if [[ -z "$pid" ]]; then
      continue
    fi

    ppid="$(ps -o ppid= -p "$pid" | tr -d ' ')"
    parent_command="$(ps -o comm= -p "$ppid" 2>/dev/null || true)"

    if [[ "$parent_command" == *debugserver* ]]; then
      kill "-$signal" "$ppid" || true
    fi
  done <<< "$pids"
}

if pgrep -x Candoa >/dev/null; then
  stop_candoa_processes TERM

  for _ in {1..20}; do
    if ! pgrep -x Candoa >/dev/null; then
      break
    fi
    sleep 0.25
  done
fi

if pgrep -x Candoa >/dev/null; then
  stop_candoa_processes KILL

  for _ in {1..20}; do
    if ! pgrep -x Candoa >/dev/null; then
      break
    fi
    sleep 0.25
  done
fi

if pgrep -x Candoa >/dev/null; then
  echo "Candoa is still running. Quit Candoa before running E2E tests." >&2
  exit 1
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" test
