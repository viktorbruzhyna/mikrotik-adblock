#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/mikrotik-adblock.sh"

bash -n "$SCRIPT"

# RouterOS `get` does not reliably print a value over non-interactive SSH;
# the version probe must explicitly emit it with `:put`.
grep -Fq ":put [/system resource get version]" "$SCRIPT"

# CLI row numbers (for example place-before=0) are session-dependent and must
# not be used in RouterOS automation. Rules should use internal IDs from find.
if grep -Fq 'place-before=0' "$SCRIPT"; then
  echo "RouterOS automation must not use CLI row number 0 for place-before" >&2
  exit 1
fi
grep -Fq "place-before=\\\$first" "$SCRIPT"
grep -Fq 'find where dynamic=no' "$SCRIPT"
if grep -Fq '[:pick' "$SCRIPT"; then
  echo "Do not index RouterOS find results; a single match is not always an array" >&2
  exit 1
fi

if grep -Fq "\${WHITELIST[@]}" "$SCRIPT"; then
  echo "Direct empty-array expansion of WHITELIST is not Bash 3.2 + nounset safe" >&2
  exit 1
fi

HELP_OUTPUT=$("$SCRIPT" --help)
grep -q -- '--dry-run' <<< "$HELP_OUTPUT"
grep -q -- '192.168.1.1' <<< "$HELP_OUTPUT"
[[ "$("$SCRIPT" --version)" == "mikrotik-adblock.sh 1.0.2" ]]

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

# Exercise the non-interactive SSH path with a fake RouterOS endpoint. This
# catches regressions where `get` is used without `:put` and therefore returns
# an empty value over SSH.
MOCK_DIR=$(mktemp -d)
cleanup_mock() {
  rm -rf "$MOCK_DIR"
}
trap cleanup_mock EXIT

cat > "$MOCK_DIR/ssh" <<'MOCK_SSH'
#!/usr/bin/env bash
set -u

args="$*"
if [[ $args == *"-O exit"* ]]; then
  exit 0
fi

command=${!#}
case "$command" in
  ':put "SSH connection OK"')
    printf '%s\n' 'SSH connection OK'
    ;;
  ':put [/system resource get version]')
    printf '%s\n' '7.24.2 (stable)'
    ;;
  *'/ip dhcp-server network find where gateway='*)
    printf '%s\n' '192.168.1.0/24'
    ;;
  *'/ip dhcp-server network find where address='*)
    printf '%s\n' '1'
    ;;
  ':put [:len [/interface list find where name="WAN"]]')
    printf '%s\n' '1'
    ;;
  /tool\ fetch*)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCK_SSH
chmod +x "$MOCK_DIR/ssh"

DRY_RUN_OUTPUT=$(PATH="$MOCK_DIR:$PATH" "$SCRIPT" --dry-run --gateway 192.168.1.1)
grep -Fq '[OK] RouterOS 7.24.2' <<< "$DRY_RUN_OUTPUT"
grep -Fq '[DRY-RUN] No configuration changes were applied.' <<< "$DRY_RUN_OUTPUT"
grep -Fq 'mikrotik-adblock: allow LAN DNS UDP' <<< "$DRY_RUN_OUTPUT"
grep -Fq '/ip firewall filter remove' <<< "$DRY_RUN_OUTPUT"
grep -Fq '/ip firewall filter find where dynamic=no' <<< "$DRY_RUN_OUTPUT"
grep -Fq '/ip firewall nat find where dynamic=no' <<< "$DRY_RUN_OUTPUT"
grep -Fq 'in-interface-list=!WAN' <<< "$DRY_RUN_OUTPUT"
if grep -Fq 'in-interface-list="!WAN"' <<< "$DRY_RUN_OUTPUT"; then
  echo "Negated WAN list must stay unquoted or RouterOS treats it as a missing list name" >&2
  exit 1
fi
ros_place='place-before=$'"first"
grep -Fq "$ros_place" <<< "$DRY_RUN_OUTPUT"
if grep -Fq 'type=FWD' <<< "$DRY_RUN_OUTPUT"; then
  echo "Empty whitelist must not create a static FWD entry" >&2
  exit 1
fi

firewall_line=$(grep -n -m 1 'mikrotik-adblock: block WAN DNS UDP' <<< "$DRY_RUN_OUTPUT" | cut -d: -f1)
dns_line=$(grep -n -m 1 'allow-remote-requests=yes' <<< "$DRY_RUN_OUTPUT" | cut -d: -f1)
if [[ -z $firewall_line || -z $dns_line || $firewall_line -ge $dns_line ]]; then
  echo "WAN DNS rules must be installed before allow-remote-requests" >&2
  exit 1
fi

add_line=$(grep -n 'allow LAN DNS UDP staging' <<< "$DRY_RUN_OUTPUT" | grep -F "$ros_place" | cut -d: -f1)
remove_line=$(grep -n 'remove' <<< "$DRY_RUN_OUTPUT" | grep 'comment="mikrotik-adblock: allow LAN DNS UDP"' | cut -d: -f1)
if [[ -z $add_line || -z $remove_line || $add_line -ge $remove_line ]]; then
  echo "Replacement rule must be added before the previous managed rule is removed" >&2
  exit 1
fi

WHITELIST_OUTPUT=$(PATH="$MOCK_DIR:$PATH" "$SCRIPT" --dry-run --gateway 192.168.1.1 --whitelist example.com)
grep -Fq 'name="example.com"' <<< "$WHITELIST_OUTPUT"
grep -Fq 'type=FWD' <<< "$WHITELIST_OUTPUT"
grep -Fq 'AdBlock whitelist' <<< "$WHITELIST_OUTPUT"

echo "Smoke tests passed"
