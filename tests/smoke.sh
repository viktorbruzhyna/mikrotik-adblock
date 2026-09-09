#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/mikrotik-adblock.sh"

bash -n "$SCRIPT"

HELP_OUTPUT=$("$SCRIPT" --help)
grep -q -- '--dry-run' <<< "$HELP_OUTPUT"
grep -q -- '192.168.1.1' <<< "$HELP_OUTPUT"
[[ "$("$SCRIPT" --version)" == "mikrotik-adblock.sh 1.0.0" ]]

set +e
"$SCRIPT" --gateway 999.1.1.1 >/tmp/mikrotik-adblock-smoke.out 2>&1
status=$?
set -e

if [[ $status -eq 0 ]]; then
  echo "Expected invalid IPv4 input to fail" >&2
  exit 1
fi

grep -q 'Invalid gateway IPv4 address' /tmp/mikrotik-adblock-smoke.out
rm -f /tmp/mikrotik-adblock-smoke.out

echo "Smoke tests passed"
