#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${CANDOA_E2E_DESTINATION:-platform=macOS}"
DERIVED_DATA_PATH="${CANDOA_DERIVED_DATA_PATH:-}"
DERIVED_DATA_DIR=""
LIVE_E2E_MARKER="/tmp/candoa-live-e2e-enabled"
XCODEBUILD_ARGS=(
  -project Candoa.xcodeproj
  -scheme Candoa
  -configuration Debug
  -destination "$DESTINATION"
  -only-testing:CandoaUITests/CandoaEliLiveUITests
)

if [[ "${CANDOA_E2E_ADHOC_SIGNING:-0}" == "1" ]]; then
  XCODEBUILD_ARGS+=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY=-
    DEVELOPMENT_TEAM=
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
  )
fi

if [[ -n "$DERIVED_DATA_PATH" ]]; then
  DERIVED_DATA_DIR="$DERIVED_DATA_PATH"
else
  DERIVED_DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/candoa-ask-e2e-derived.XXXXXX")"
fi

XCODEBUILD_ARGS+=(-derivedDataPath "$DERIVED_DATA_DIR")

cleanup() {
  rm -f "$LIVE_E2E_MARKER"

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
  echo "Candoa is still running. Quit Candoa before running Ask E2E tests." >&2
  exit 1
fi

touch "$LIVE_E2E_MARKER"
xcodebuild "${XCODEBUILD_ARGS[@]}" test
