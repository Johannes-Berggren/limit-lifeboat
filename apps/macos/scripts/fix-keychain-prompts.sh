#!/usr/bin/env bash
# Repairs the keychain partition list of the Claude Code CLI's credentials
# item so that natively-signed Claude Code builds (team Q6L2SF6YDW) can read
# it without demanding the login keychain password on every run. Without
# this, "Always Allow" never sticks: macOS re-prompts each time because the
# requesting binary's partition is not on the item's list. Idempotent; a
# re-run that finds nothing to add exits without any password prompt.
set -euo pipefail

SERVICE="Claude Code-credentials"
ACCOUNT="${USER}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
REQUIRED_PARTITIONS=(
  "apple-tool:"
  "apple:"
  "teamid:3DQ7YC2YH2"  # Limit Lifeboat (JB Ventures AS)
  "teamid:Q6L2SF6YDW"  # Claude Code (Anthropic PBC)
)

# set-generic-password-partition-list asks for the keychain password on the
# controlling terminal, so a non-interactive run can only fail at that step.
if [[ ! -t 0 ]]; then
  echo "Run this script from an interactive terminal: macOS asks for your login" >&2
  echo "keychain password (usually your macOS login password) to authorize the change." >&2
  exit 1
fi

# Metadata-only lookup (never -w: the secret must not be read here).
if ! security find-generic-password -s "$SERVICE" -a "$ACCOUNT" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "No '$SERVICE' keychain item found for account '$ACCOUNT'." >&2
  echo "Run \`claude\` and sign in with /login first, then re-run this script." >&2
  exit 1
fi

# The partition list only appears in the ACL dump (-a), which splits its
# output across stdout and stderr — both streams must be merged — and can
# contain raw NUL bytes that derail BSD awk unless stripped first. Within the
# block for our service+account, the list is the description line immediately
# following the "partition_id" authorization (other ACL entries have
# description lines too). dump-keychain also exits non-zero despite emitting
# complete output, so its status must be ignored.
current_list="$(
  { security dump-keychain -a "$KEYCHAIN" 2>&1 || true; } | tr -d '\000' | awk -v svce="\"svce\"<blob>=\"$SERVICE\"" -v acct="\"acct\"<blob>=\"$ACCOUNT\"" '
    /^keychain: / { in_item = 0; svce_ok = 0; acct_ok = 0 }
    index($0, svce) { svce_ok = 1 }
    index($0, acct) { acct_ok = 1 }
    svce_ok && acct_ok { in_item = 1 }
    in_item && /authorizations \(1\): partition_id/ { grab = 1; next }
    grab && /description:/ {
      sub(/^[[:space:]]*description:[[:space:]]*/, "")
      print
      exit
    }
  '
)"

if [[ -z "$current_list" ]]; then
  echo "Warning: could not parse the item's current partition list (macOS output format may have changed)." >&2
  echo "Seeding with the default list instead of merging." >&2
fi

# Merge: keep every existing entry (trimmed), append missing required ones.
merged=()
IFS=',' read -r -a existing <<< "$current_list"
for entry in "${existing[@]:-}"; do
  entry="${entry#"${entry%%[![:space:]]*}"}"
  entry="${entry%"${entry##*[![:space:]]}"}"
  [[ -n "$entry" ]] && merged+=("$entry")
done

added=()
for required in "${REQUIRED_PARTITIONS[@]}"; do
  present=0
  for entry in "${merged[@]:-}"; do
    if [[ "$entry" == "$required" ]]; then
      present=1
      break
    fi
  done
  if (( ! present )); then
    merged+=("$required")
    added+=("$required")
  fi
done

if (( ${#added[@]} == 0 )); then
  echo "Partition list already includes all required entries — nothing to do."
  exit 0
fi

merged_csv="$(IFS=','; echo "${merged[*]}")"
echo "Adding partition entries: ${added[*]}"
echo "New partition list: $merged_csv"
echo "Enter your login keychain password (usually your macOS login password) at the prompt."
security set-generic-password-partition-list -S "$merged_csv" -s "$SERVICE" -a "$ACCOUNT" "$KEYCHAIN" >/dev/null

# Verify the write landed by re-parsing.
verify_list="$(
  { security dump-keychain -a "$KEYCHAIN" 2>&1 || true; } | tr -d '\000' | awk -v svce="\"svce\"<blob>=\"$SERVICE\"" -v acct="\"acct\"<blob>=\"$ACCOUNT\"" '
    /^keychain: / { in_item = 0; svce_ok = 0; acct_ok = 0 }
    index($0, svce) { svce_ok = 1 }
    index($0, acct) { acct_ok = 1 }
    svce_ok && acct_ok { in_item = 1 }
    in_item && /authorizations \(1\): partition_id/ { grab = 1; next }
    grab && /description:/ {
      sub(/^[[:space:]]*description:[[:space:]]*/, "")
      print
      exit
    }
  '
)"
for required in "${added[@]}"; do
  if [[ ",$(echo "$verify_list" | tr -d '[:space:]')," != *",$required,"* ]]; then
    echo "Verification failed: '$required' is still missing from the partition list ($verify_list)." >&2
    exit 1
  fi
done

echo "Done. The NEXT claude invocation shows one final keychain dialog — click 'Always Allow'."
echo "That grant is stored against Claude Code's identifier+team code requirement, so it"
echo "persists across Claude Code updates. No further password prompts."
