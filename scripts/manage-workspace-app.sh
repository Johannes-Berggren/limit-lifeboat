#!/usr/bin/env bash
# Finds an LLMUsageMonitor process by its exact executable path. This avoids
# stopping an installed copy or an app launched from another Conductor
# workspace.
set -euo pipefail

MODE="${1:-}"
TARGET_EXECUTABLE="${2:-}"

if [[ "$MODE" != "check" && "$MODE" != "terminate" ]] || [[ -z "$TARGET_EXECUTABLE" ]]; then
  echo "Usage: $0 {check|terminate} /absolute/path/to/LLMUsageMonitor" >&2
  exit 2
fi

if [[ -e "$TARGET_EXECUTABLE" ]]; then
  TARGET_EXECUTABLE="$(realpath "$TARGET_EXECUTABLE")"
fi

matching_pids() {
  local pid executable
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    executable="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1 || true)"
    if [[ "$executable" == "$TARGET_EXECUTABLE" ]]; then
      echo "$pid"
    fi
  done < <(lsof -a -t -d txt "$TARGET_EXECUTABLE" 2>/dev/null || true)
}

mapfile_compat() {
  local line
  PIDS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && PIDS+=("$line")
  done < <(matching_pids)
}

mapfile_compat
if (( ${#PIDS[@]} == 0 )); then
  exit 0
fi

if [[ "$MODE" == "check" ]]; then
  echo "Refusing to replace $TARGET_EXECUTABLE while it is running (PID ${PIDS[*]})." >&2
  echo "Quit that copy of LLM Usage Monitor and run the build again. Replacing a live bundle prevents macOS Keychain from verifying the process and causes repeated password prompts." >&2
  exit 1
fi

echo "Stopping workspace copy of LLM Usage Monitor (PID ${PIDS[*]}) before archive."
kill "${PIDS[@]}" 2>/dev/null || true

for _ in {1..50}; do
  remaining=()
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      remaining+=("$pid")
    fi
  done
  if (( ${#remaining[@]} == 0 )); then
    exit 0
  fi
  PIDS=("${remaining[@]}")
  sleep 0.1
done

echo "LLM Usage Monitor did not exit; refusing to archive a workspace containing its running bundle (PID ${PIDS[*]})." >&2
exit 1
