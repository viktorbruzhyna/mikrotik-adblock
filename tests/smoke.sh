#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/mikrotik-adblock.sh"

bash -n "$SCRIPT"

# RouterOS `get` does not reliably print a value over non-interactive SSH;
# the version probe must explicitly emit it with `:put`.
grep -Fq ":put [/system resource get version]" "$SCRIPT"

# CLI row numbers (for example place-before=0) are session-dependent.
# Inserting a static rule above the dynamic FastTrack counter stores it as
# invalid, so placement is a move inside one RouterOS script.
if grep -Fq 'place-before' "$SCRIPT"; then
  echo "Do not use place-before; a bad anchor stores the rule as invalid" >&2
  exit 1
fi
grep -Fq 'find where dynamic=no' "$SCRIPT"
grep -Fq 'mikrotik-adblock-rule.rsc' "$SCRIPT"
grep -Fq '/import file-name=mikrotik-adblock-rule.rsc' "$SCRIPT"
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
  *dynamic=no*)
    printf '%s\n' '*10'
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
grep -Fq 'in-interface-list=WAN' <<< "$DRY_RUN_OUTPUT"
if grep -Fq 'in-interface-list=!WAN' <<< "$DRY_RUN_OUTPUT"; then
  echo "Negated interface lists are invalid inside a RouterOS script" >&2
  exit 1
fi
grep -Fq 'find where dynamic=no' <<< "$DRY_RUN_OUTPUT"
grep -Fq ' move ' <<< "$DRY_RUN_OUTPUT"
grep -Fq 'protocol=6' <<< "$DRY_RUN_OUTPUT"
grep -Fq 'protocol=17' <<< "$DRY_RUN_OUTPUT"
if grep -Eq 'protocol=tcp|protocol=udp' <<< "$DRY_RUN_OUTPUT"; then
  echo "DNS rules must use protocol numbers 6 and 17" >&2
  exit 1
fi
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

add_line=$(grep -n 'filter add ' <<< "$DRY_RUN_OUTPUT" | grep 'allow LAN DNS UDP staging' | cut -d: -f1)
wan_add=$(grep -n 'filter add ' <<< "$DRY_RUN_OUTPUT" | grep 'block WAN DNS UDP staging' | cut -d: -f1)
if [[ -z $add_line || -z $wan_add || $add_line -ge $wan_add ]]; then
  echo "WAN DNS drops must be inserted after LAN allows so they sit above them" >&2
  exit 1
fi
remove_line=$(grep -n -m 1 'allow LAN DNS UDP"' <<< "$DRY_RUN_OUTPUT" | cut -d: -f1)
if [[ -z $add_line || -z $remove_line || $add_line -ge $remove_line ]]; then
  echo "Replacement rule must be added before the previous managed rule is removed" >&2
  exit 1
fi

WHITELIST_OUTPUT=$(PATH="$MOCK_DIR:$PATH" "$SCRIPT" --dry-run --gateway 192.168.1.1 --whitelist example.com)
grep -Fq 'name="example.com"' <<< "$WHITELIST_OUTPUT"
grep -Fq 'type=FWD' <<< "$WHITELIST_OUTPUT"
grep -Fq 'AdBlock whitelist' <<< "$WHITELIST_OUTPUT"

# Apply mode never reaches a router. tests/mock-ssh.sh records the rules the
# installer would create and answers the validation queries.
APPLY_BIN=$(mktemp -d)
cp "$ROOT/tests/mock-ssh.sh" "$APPLY_BIN/ssh"
chmod +x "$APPLY_BIN/ssh"
cat > "$APPLY_BIN/nslookup" <<'MOCK_NSLOOKUP'
#!/usr/bin/env bash
printf 'Server: 192.168.1.1\nAddress: 192.168.1.1#53\n\nName: doubleclick.net\nAddress: 0.0.0.0\n'
MOCK_NSLOOKUP
chmod +x "$APPLY_BIN/nslookup"

cleanup_apply() {
  rm -rf "$APPLY_BIN" "${APPLY_STATE:-}"
}
trap 'cleanup_mock; cleanup_apply' EXIT

seed_legacy_rules() {
  local state=$1
  : > "$state/rules"
  cat >> "$state/rules" <<'RULES'
filter	false	Allow LAN DNS UDP
filter	false	Allow LAN DNS TCP
filter	false	Block WAN DNS UDP
filter	false	Block WAN DNS TCP
nat	false	Force LAN DNS UDP
nat	false	Force LAN DNS TCP
RULES
}

rule_count() {
  local state=$1 menu=$2 comment=$3
  awk -F '\t' -v menu="$menu" -v comment="$comment" '
    $1 == menu && $3 == comment { n++ }
    END { print n + 0 }
  ' "$state/rules"
}

expect_one() {
  local state=$1 menu=$2 comment=$3 count
  count=$(rule_count "$state" "$menu" "$comment")
  if [[ $count != 1 ]]; then
    echo "Expected exactly one ${menu} rule '${comment}'; found ${count}" >&2
    exit 1
  fi
}

expect_zero() {
  local state=$1 menu=$2 comment=$3 count
  count=$(rule_count "$state" "$menu" "$comment")
  if [[ $count != 0 ]]; then
    echo "Expected no ${menu} rule '${comment}'; found ${count}" >&2
    exit 1
  fi
}

run_apply() {
  local state=$1
  shift
  mkdir -p "$state"
  PATH="$APPLY_BIN:$PATH" MIKROTIK_MOCK_STATE="$state" \
    "$SCRIPT" --gateway 192.168.1.1 --lan 192.168.1.0/24 "$@"
}

APPLY_STATE=$(mktemp -d)
seed_legacy_rules "$APPLY_STATE"
APPLY_OUTPUT=$(run_apply "$APPLY_STATE")
grep -Fq '[OK] RouterOS 7.24.2' <<< "$APPLY_OUTPUT"
grep -Fq '[OK] Adlist loaded: 1200 names' <<< "$APPLY_OUTPUT"
grep -Fq '[OK] doubleclick.net is blocked through the MikroTik DNS' <<< "$APPLY_OUTPUT"
grep -Fq 'Setup complete.' <<< "$APPLY_OUTPUT"
grep -Fq 'Created before-adblock-' <<< "$APPLY_OUTPUT"
if grep -Fq 'in-interface-list=!WAN' <<< "$APPLY_OUTPUT"; then
  echo "Apply mode must not use a negated WAN interface list" >&2
  exit 1
fi

firewall_line=$(grep -n -m 1 'mikrotik-adblock: block WAN DNS UDP' "$APPLY_STATE/commands.log" | cut -d: -f1)
dns_line=$(grep -n -m 1 'allow-remote-requests=yes' "$APPLY_STATE/commands.log" | cut -d: -f1)
if [[ -z $firewall_line || -z $dns_line || $firewall_line -ge $dns_line ]]; then
  echo "WAN DNS rules must be installed before allow-remote-requests" >&2
  exit 1
fi

for comment in \
  "mikrotik-adblock: allow LAN DNS UDP" \
  "mikrotik-adblock: allow LAN DNS TCP" \
  "mikrotik-adblock: block WAN DNS UDP" \
  "mikrotik-adblock: block WAN DNS TCP"
do
  expect_one "$APPLY_STATE" filter "$comment"
  expect_zero "$APPLY_STATE" filter "$comment staging"
done
for comment in \
  "mikrotik-adblock: force LAN DNS UDP" \
  "mikrotik-adblock: force LAN DNS TCP"
do
  expect_one "$APPLY_STATE" nat "$comment"
done
for comment in \
  "Allow LAN DNS UDP" \
  "Allow LAN DNS TCP" \
  "Block WAN DNS UDP" \
  "Block WAN DNS TCP"
do
  expect_zero "$APPLY_STATE" filter "$comment"
done

# A second run starts from the rules the first run left behind.
APPLY_AGAIN=$(run_apply "$APPLY_STATE")
grep -Fq 'Setup complete.' <<< "$APPLY_AGAIN"
expect_one "$APPLY_STATE" filter "mikrotik-adblock: allow LAN DNS UDP"
expect_one "$APPLY_STATE" filter "mikrotik-adblock: allow LAN DNS TCP"
expect_one "$APPLY_STATE" nat "mikrotik-adblock: force LAN DNS UDP"
expect_one "$APPLY_STATE" nat "mikrotik-adblock: force LAN DNS TCP"

# Script adds with protocol=6 are stored invalid until an .rsc import.
TCP_STATE=$(mktemp -d)
TCP_OUTPUT=$(MIKROTIK_MOCK_TCP_INVALID=1 run_apply "$TCP_STATE")
grep -Fq 'Setup complete.' <<< "$TCP_OUTPUT"
import_count=$(grep -c '/import file-name=mikrotik-adblock-rule.rsc' "$TCP_STATE/commands.log" || true)
if [[ $import_count -lt 3 ]]; then
  echo "TCP rules must be imported when a script add is invalid; imports: $import_count" >&2
  exit 1
fi
expect_one "$TCP_STATE" filter "mikrotik-adblock: allow LAN DNS TCP"
expect_one "$TCP_STATE" filter "mikrotik-adblock: block WAN DNS TCP"
expect_one "$TCP_STATE" nat "mikrotik-adblock: force LAN DNS TCP"
if awk -F '\t' '$2 != "false" { found = 1 } END { exit found ? 0 : 1 }' "$TCP_STATE/rules"; then
  echo "TCP recovery left an invalid rule behind" >&2
  exit 1
fi
rm -rf "$TCP_STATE"

OLD_STATE=$(mktemp -d)
set +e
OLD_OUTPUT=$(MIKROTIK_MOCK_VERSION='7.14 (stable)' run_apply "$OLD_STATE" 2>&1)
old_status=$?
set -e
if [[ $old_status -eq 0 ]]; then
  echo "RouterOS older than 7.15 must be rejected" >&2
  exit 1
fi
grep -Fq 'RouterOS 7.15+ is required' <<< "$OLD_OUTPUT"
rm -rf "$OLD_STATE"

INSECURE_STATE=$(mktemp -d)
INSECURE_OUTPUT=$(run_apply "$INSECURE_STATE" --insecure-adlist)
grep -Fq 'verification DISABLED' <<< "$INSECURE_OUTPUT"
if grep -Fq 'check-certificate=yes-without-crl' "$INSECURE_STATE/commands.log"; then
  echo "--insecure-adlist must stay opt-in and must not also probe the certificate" >&2
  exit 1
fi
grep -Fq 'ssl-verify=no' "$INSECURE_STATE/commands.log"
rm -rf "$INSECURE_STATE"

SECURE_STATE=$(mktemp -d)
run_apply "$SECURE_STATE" >/dev/null
grep -Fq 'check-certificate=yes-without-crl' "$SECURE_STATE/commands.log"
grep -Fq 'ssl-verify=yes' "$SECURE_STATE/commands.log"
rm -rf "$SECURE_STATE"

NO_FORCE_STATE=$(mktemp -d)
run_apply "$NO_FORCE_STATE" --no-force-dns >/dev/null
expect_zero "$NO_FORCE_STATE" nat "mikrotik-adblock: force LAN DNS UDP"
expect_zero "$NO_FORCE_STATE" nat "mikrotik-adblock: force LAN DNS TCP"
expect_one "$NO_FORCE_STATE" filter "mikrotik-adblock: allow LAN DNS UDP"
rm -rf "$NO_FORCE_STATE"

echo "Smoke tests passed"
