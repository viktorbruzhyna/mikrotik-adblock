#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# MikroTik RouterOS DNS AdBlock installer.
#
# Safe defaults:
#   gateway: 192.168.1.1
#   user:    admin
#   adlist:  StevenBlack hosts list over HTTPS with certificate validation
#
# Examples:
#   ./mikrotik-adblock.sh
#   ./mikrotik-adblock.sh --gateway 192.168.50.1
#   ./mikrotik-adblock.sh 192.168.50.1
#   ./mikrotik-adblock.sh --gateway 10.0.0.1 --lan 10.0.0.0/24
#   ./mikrotik-adblock.sh --dry-run

SCRIPT_NAME="${0##*/}"
VERSION="1.0.2"
DEFAULT_GATEWAY="192.168.1.1"
DEFAULT_USER="admin"
DEFAULT_ADLIST_URL="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
DEFAULT_CACHE_SIZE="32768KiB"
DEFAULT_TEST_DOMAIN="doubleclick.net"
MIN_ROUTEROS_MAJOR=7
MIN_ROUTEROS_MINOR=15

GATEWAY_IP="$DEFAULT_GATEWAY"
ROUTER_USER="$DEFAULT_USER"
LAN_CIDR=""
ADLIST_URL="$DEFAULT_ADLIST_URL"
CACHE_SIZE="$DEFAULT_CACHE_SIZE"
TEST_DOMAIN="$DEFAULT_TEST_DOMAIN"
FORCE_DNS=1
CREATE_BACKUP=1
DRY_RUN=0
INSECURE_ADLIST=0
POSITIONAL_GATEWAY_SEEN=0
WHITELIST=()
WHITELIST_COUNT=0

CONTROL_PATH="${TMPDIR:-/tmp}/mikrotik-adblock-$$"
SSH_OPTS=(
  -o "ControlMaster=auto"
  -o "ControlPersist=120"
  -o "ControlPath=$CONTROL_PATH"
  -o "ConnectTimeout=8"
  -o "ServerAliveInterval=15"
  -o "ServerAliveCountMax=2"
  -o "StrictHostKeyChecking=accept-new"
)

usage() {
  cat <<USAGE
Usage:
  $SCRIPT_NAME [gateway-ip] [options]

Options:
  -g, --gateway IP       MikroTik gateway IP (default: $DEFAULT_GATEWAY)
  -u, --user USER        SSH username (default: $DEFAULT_USER)
  -l, --lan CIDR         LAN network. Auto-detected from DHCP when omitted.
      --adlist URL        HTTPS hosts/adlist URL
      --cache SIZE        RouterOS DNS cache size (default: $DEFAULT_CACHE_SIZE)
      --whitelist DOMAIN  Exempt a domain from Adlist; may be repeated
      --test-domain NAME  Domain used for the final DNS test
      --no-force-dns      Do not intercept clients that use external DNS on port 53
      --no-backup         Do not create RouterOS backup/export before changes
      --insecure-adlist   Disable TLS certificate validation for the Adlist (not recommended)
      --dry-run           Read/preflight only; print changes without applying them
      --version           Show version
  -h, --help              Show this help

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME 192.168.50.1
  $SCRIPT_NAME --gateway 192.168.50.1 --user admin
  $SCRIPT_NAME --gateway 10.0.0.1 --lan 10.0.0.0/24
  $SCRIPT_NAME --whitelist example.com --whitelist telemetry.example.com
USAGE
}

log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

is_ipv4() {
  local ip=$1 a b c d octet
  IFS=. read -r a b c d <<< "$ip" || return 1
  [[ -n ${a:-} && -n ${b:-} && -n ${c:-} && -n ${d:-} ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
  done
}

is_cidr() {
  local value=$1 ip prefix
  [[ $value == */* ]] || return 1
  ip=${value%/*}
  prefix=${value#*/}
  is_ipv4 "$ip" || return 1
  [[ $prefix =~ ^[0-9]{1,2}$ ]] || return 1
  (( 10#$prefix >= 0 && 10#$prefix <= 32 ))
}

# Bash's regex above is deliberately strict, but avoid a trailing-space regex gotcha
# by using this portable domain validator instead.
is_domain() {
  local d=$1 label
  [[ -n $d && ${#d} -le 253 ]] || return 1
  [[ $d != .* && $d != *. && $d != *..* ]] || return 1
  IFS=. read -r -a labels <<< "$d"
  for label in "${labels[@]}"; do
    [[ -n $label && ${#label} -le 63 ]] || return 1
    [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

validate_url() {
  local url=$1
  [[ $url == https://* ]] || return 1
  [[ $url != *$'\n'* && $url != *$'\r'* && $url != *'"'* ]] || return 1
}

validate_cache_size() {
  [[ $1 =~ ^[0-9]+(KiB|MiB)$ ]]
}

while (($#)); do
  case "$1" in
    -g|--gateway)
      (($# >= 2)) || die "$1 requires an IP address"
      GATEWAY_IP=$2
      shift 2
      ;;
    -u|--user)
      (($# >= 2)) || die "$1 requires a username"
      ROUTER_USER=$2
      shift 2
      ;;
    -l|--lan)
      (($# >= 2)) || die "$1 requires a CIDR"
      LAN_CIDR=$2
      shift 2
      ;;
    --adlist)
      (($# >= 2)) || die "$1 requires a URL"
      ADLIST_URL=$2
      shift 2
      ;;
    --cache)
      (($# >= 2)) || die "$1 requires a size such as 32768KiB"
      CACHE_SIZE=$2
      shift 2
      ;;
    --whitelist)
      (($# >= 2)) || die "$1 requires a domain"
      WHITELIST[WHITELIST_COUNT]=$2
      ((WHITELIST_COUNT += 1))
      shift 2
      ;;
    --test-domain)
      (($# >= 2)) || die "$1 requires a domain"
      TEST_DOMAIN=$2
      shift 2
      ;;
    --no-force-dns)
      FORCE_DNS=0
      shift
      ;;
    --no-backup)
      CREATE_BACKUP=0
      shift
      ;;
    --insecure-adlist)
      INSECURE_ADLIST=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --version)
      printf "%s %s\n" "$SCRIPT_NAME" "$VERSION"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if (( POSITIONAL_GATEWAY_SEEN == 0 )); then
        GATEWAY_IP=$1
        POSITIONAL_GATEWAY_SEEN=1
        shift
      else
        die "Unexpected argument: $1"
      fi
      ;;
  esac
done

is_ipv4 "$GATEWAY_IP" || die "Invalid gateway IPv4 address: $GATEWAY_IP"
[[ $ROUTER_USER =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid SSH username"
[[ -z $LAN_CIDR ]] || is_cidr "$LAN_CIDR" || die "Invalid LAN CIDR: $LAN_CIDR"
validate_url "$ADLIST_URL" || die "Adlist must be a safe HTTPS URL without quotes/newlines"
validate_cache_size "$CACHE_SIZE" || die "Invalid cache size: $CACHE_SIZE (example: 32768KiB)"
is_domain "$TEST_DOMAIN" || die "Invalid test domain: $TEST_DOMAIN"
if (( WHITELIST_COUNT > 0 )); then
  for ((i = 0; i < WHITELIST_COUNT; i++)); do
    d=${WHITELIST[$i]}
    is_domain "$d" || die "Invalid whitelist domain: $d"
  done
fi

TARGET="${ROUTER_USER}@${GATEWAY_IP}"

cleanup() {
  ssh -o "ControlPath=$CONTROL_PATH" -O exit "$TARGET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

on_error() {
  local code=$?
  printf '\n[ERROR] Setup stopped (exit %d).\n' "$code" >&2
  if [[ -n ${BACKUP_NAME:-} ]]; then
    printf '[INFO] Pre-change RouterOS backup/export: %s.backup and %s.rsc\n' "$BACKUP_NAME" "$BACKUP_NAME" >&2
    printf '[INFO] Automatic restore is intentionally NOT performed because restore may reboot the router.\n' >&2
  fi
  exit "$code"
}
trap on_error ERR

ros_exec() {
  local command=$1

  # RouterOS commands are intentionally constructed on the client and passed as
  # one remote command string. SC2029 warns about client-side expansion, which
  # is the desired behavior here; command inputs are validated before use.
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$TARGET" "$command"
}

ros_read() {
  ros_exec "$1"
}

ros_write() {
  if (( DRY_RUN )); then
    printf '[DRY-RUN] %s\n' "$1"
  else
    ros_exec "$1"
  fi
}


replace_filter_rule() {
  local legacy_comment=$1
  local managed_comment=$2
  local rule_args=$3

  # Recreate managed rules instead of mutating existing ones with `set`.
  # RouterOS CLI row numbers such as `0` are not stable identifiers in scripts
  # or non-interactive SSH sessions. Also, the first firewall entry can be a
  # dynamic/built-in FastTrack counter rule, which is not a safe placement
  # target for a static rule. Insert before the first *static* rule instead.
  ros_write ":foreach i in=[/ip firewall filter find where comment=\"$legacy_comment\"] do={/ip firewall filter remove \$i}; :foreach i in=[/ip firewall filter find where comment=\"$managed_comment\"] do={/ip firewall filter remove \$i}; :local rules [/ip firewall filter find where dynamic=no]; :if ([:len \$rules] > 0) do={:local first [:pick \$rules 0]; /ip firewall filter add $rule_args comment=\"$managed_comment\" place-before=\$first} else={/ip firewall filter add $rule_args comment=\"$managed_comment\"}"
}

replace_nat_rule() {
  local legacy_comment=$1
  local managed_comment=$2
  local rule_args=$3

  # As above, use RouterOS internal IDs returned by `find` rather than CLI row
  # numbers, and avoid dynamic/built-in rules as placement targets.
  ros_write ":foreach i in=[/ip firewall nat find where comment=\"$legacy_comment\"] do={/ip firewall nat remove \$i}; :foreach i in=[/ip firewall nat find where comment=\"$managed_comment\"] do={/ip firewall nat remove \$i}; :local rules [/ip firewall nat find where dynamic=no]; :if ([:len \$rules] > 0) do={:local first [:pick \$rules 0]; /ip firewall nat add $rule_args comment=\"$managed_comment\" place-before=\$first} else={/ip firewall nat add $rule_args comment=\"$managed_comment\"}"
}

assert_filter_rule_valid() {
  local comment=$1 count invalid

  count=$(ros_read ":put [:len [/ip firewall filter find where comment=\"$comment\"]]" | tr -d '\r[:space:]' || true)
  [[ $count == 1 ]] || die "Managed firewall rule '$comment' expected exactly once; found: ${count:-unknown}"

  invalid=$(ros_read ":local x [/ip firewall filter find where comment=\"$comment\"]; :put [/ip firewall filter get [:pick \$x 0] invalid]" | tr -d '\r[:space:]' || true)
  if [[ $invalid != false ]]; then
    warn "RouterOS marked this managed rule invalid; rule details follow:"
    ros_read "/ip firewall filter print detail where comment=\"$comment\"" >&2 || true
    die "Managed firewall rule is invalid: $comment"
  fi
}

assert_nat_rule_present() {
  local comment=$1 count

  count=$(ros_read ":put [:len [/ip firewall nat find where comment=\"$comment\"]]" | tr -d '\r[:space:]' || true)
  [[ $count == 1 ]] || die "Managed NAT rule '$comment' expected exactly once; found: ${count:-unknown}"
}

routeros_version_ok() {
  local v=$1 major minor rest
  v=${v%% *}
  major=${v%%.*}
  rest=${v#*.}
  minor=${rest%%.*}
  [[ $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ ]] || return 1
  (( major > MIN_ROUTEROS_MAJOR || (major == MIN_ROUTEROS_MAJOR && minor >= MIN_ROUTEROS_MINOR) ))
}

printf '\nMikroTik DNS AdBlock setup\n'
printf '  Router:  %s\n' "$TARGET"
printf '  Adlist:  %s\n' "$ADLIST_URL"
printf '  TLS:     %s\n' "$([[ $INSECURE_ADLIST -eq 1 ]] && echo 'verification DISABLED' || echo 'verification enabled')"
printf '  Mode:    %s\n\n' "$([[ $DRY_RUN -eq 1 ]] && echo 'dry-run' || echo 'apply')"

log "Testing SSH connection"
ros_read ':put "SSH connection OK"' >/dev/null
ok "SSH connection established"

log "Checking RouterOS version"
VERSION_RAW=$(ros_read ':put [/system resource get version]' | tr -d '\r' | tail -n1)
VERSION=${VERSION_RAW%% *}
routeros_version_ok "$VERSION_RAW" || die "RouterOS 7.15+ is required; detected: $VERSION_RAW"
ok "RouterOS $VERSION"

if [[ -z $LAN_CIDR ]]; then
  log "Auto-detecting LAN CIDR from DHCP network configuration"
  LAN_CIDR=$(ros_read ":local x [/ip dhcp-server network find where gateway=\"$GATEWAY_IP\"]; :if ([:len \$x] > 0) do={:put [/ip dhcp-server network get [:pick \$x 0] address]}" 2>/dev/null | tr -d '\r' | tail -n1 || true)
  if ! is_cidr "$LAN_CIDR"; then
    IFS=. read -r o1 o2 o3 _ <<< "$GATEWAY_IP"
    LAN_CIDR="${o1}.${o2}.${o3}.0/24"
    warn "Could not auto-detect LAN from DHCP; falling back to $LAN_CIDR. Use --lan for non-/24 networks."
  else
    ok "Detected LAN: $LAN_CIDR"
  fi
fi

DHCP_COUNT=$(ros_read ":put [:len [/ip dhcp-server network find where address=\"$LAN_CIDR\"]]" | tr -d '\r[:space:]' || true)
if [[ $DHCP_COUNT =~ ^[0-9]+$ ]] && (( DHCP_COUNT > 0 )); then
  DHCP_AVAILABLE=1
else
  DHCP_AVAILABLE=0
  warn "No DHCP network entry found for $LAN_CIDR; DHCP DNS assignment will be skipped."
fi

WAN_LIST_COUNT=$(ros_read ':put [:len [/interface list find where name="WAN"]]' | tr -d '\r[:space:]' || true)
if [[ $WAN_LIST_COUNT =~ ^[0-9]+$ ]] && (( WAN_LIST_COUNT > 0 )); then
  WAN_LIST_AVAILABLE=1
else
  WAN_LIST_AVAILABLE=0
  warn "Interface list 'WAN' was not found; automatic WAN DNS guard will be skipped."
fi

if (( INSECURE_ADLIST == 0 )); then
  log "Verifying Adlist HTTPS certificate from the router"
  if ros_read "/tool fetch url=\"$ADLIST_URL\" check-certificate=yes-without-crl output=none" >/dev/null 2>&1; then
    ok "Adlist HTTPS certificate validated"
  else
    die "RouterOS could not validate the Adlist HTTPS certificate. Refusing to fall back to insecure TLS. Check time/DNS/certificate trust, or explicitly use --insecure-adlist."
  fi
else
  warn "Adlist TLS certificate validation is disabled by explicit request."
fi

if (( CREATE_BACKUP )); then
  STAMP=$(date '+%Y%m%d-%H%M%S')
  BACKUP_NAME="before-adblock-${STAMP}"
  log "Creating pre-change RouterOS backup and text export"
  ros_write "/system backup save name=$BACKUP_NAME"
  ros_write "/export file=$BACKUP_NAME"
  if (( ! DRY_RUN )); then
    ok "Created $BACKUP_NAME.backup and $BACKUP_NAME.rsc on the router"
  fi
fi

log "Configuring RouterOS DNS cache"
ros_write "/ip dns set allow-remote-requests=yes cache-size=$CACHE_SIZE"

SSL_VERIFY=$([[ $INSECURE_ADLIST -eq 1 ]] && echo no || echo yes)
log "Configuring Adlist"
ros_write ":local x [/ip dns adlist find where url=\"$ADLIST_URL\"]; :if ([:len \$x] = 0) do={/ip dns adlist add url=\"$ADLIST_URL\" ssl-verify=$SSL_VERIFY} else={/ip dns adlist set [:pick \$x 0] ssl-verify=$SSL_VERIFY disabled=no}"

if (( DHCP_AVAILABLE )); then
  log "Setting DHCP clients to use the MikroTik as DNS"
  ros_write "/ip dhcp-server network set [find where address=\"$LAN_CIDR\"] dns-server=$GATEWAY_IP"
fi

# Recreate managed firewall rules canonically on every apply. This also migrates
# rules created by versions <= 1.0.1, whose comments did not use the project prefix.
# WAN drops are created first; LAN allows are inserted afterwards at the top so they
# take precedence while still excluding WAN ingress when a WAN list is available.
if (( WAN_LIST_AVAILABLE )); then
  log "Protecting RouterOS DNS from WAN queries"
  replace_filter_rule "Block WAN DNS UDP" "mikrotik-adblock: block WAN DNS UDP" "chain=input in-interface-list=WAN protocol=udp dst-port=53 action=drop"
  replace_filter_rule "Block WAN DNS TCP" "mikrotik-adblock: block WAN DNS TCP" "chain=input in-interface-list=WAN protocol=tcp dst-port=53 action=drop"
  LAN_INTERFACE_GUARD="in-interface-list=!WAN "
else
  LAN_INTERFACE_GUARD=""
fi

# Explicit LAN DNS allows help strict input firewalls while preserving unrelated
# router services. Source CIDR is always required; !WAN additionally prevents a
# spoofed WAN packet from matching the LAN allow when the WAN list exists.
log "Ensuring LAN clients can query RouterOS DNS"
replace_filter_rule "Allow LAN DNS UDP" "mikrotik-adblock: allow LAN DNS UDP" "chain=input ${LAN_INTERFACE_GUARD}src-address=$LAN_CIDR protocol=udp dst-port=53 action=accept"
replace_filter_rule "Allow LAN DNS TCP" "mikrotik-adblock: allow LAN DNS TCP" "chain=input ${LAN_INTERFACE_GUARD}src-address=$LAN_CIDR protocol=tcp dst-port=53 action=accept"

if (( FORCE_DNS )); then
  log "Forcing external IPv4 DNS/53 requests through MikroTik"
  # dst-address-type=!local avoids NATing clients that already query the router itself.
  replace_nat_rule "Force LAN DNS UDP" "mikrotik-adblock: force LAN DNS UDP" "chain=dstnat src-address=$LAN_CIDR dst-address-type=!local protocol=udp dst-port=53 action=redirect to-ports=53"
  replace_nat_rule "Force LAN DNS TCP" "mikrotik-adblock: force LAN DNS TCP" "chain=dstnat src-address=$LAN_CIDR dst-address-type=!local protocol=tcp dst-port=53 action=redirect to-ports=53"
fi

if (( WHITELIST_COUNT > 0 )); then
  for ((i = 0; i < WHITELIST_COUNT; i++)); do
    d=${WHITELIST[$i]}
    log "Whitelisting $d"
    ros_write ":local x [/ip dns static find where name=\"$d\" type=FWD]; :if ([:len \$x] = 0) do={/ip dns static add name=\"$d\" type=FWD disabled=no comment=\"AdBlock whitelist\"} else={/ip dns static set [:pick \$x 0] disabled=no}"
  done
fi

if (( DRY_RUN )); then
  printf '\n[DRY-RUN] No configuration changes were applied.\n'
  exit 0
fi

log "Reloading Adlist"
ros_read '/ip dns adlist reload' >/dev/null 2>&1 || true

log "Waiting for Adlist to become available"
NAME_COUNT=0
for _ in {1..15}; do
  NAME_COUNT=$(ros_read ":local x [/ip dns adlist find where url=\"$ADLIST_URL\"]; :if ([:len \$x] > 0) do={:put [/ip dns adlist get [:pick \$x 0] name-count]} else={:put 0}" | tr -d '\r[:space:]' || true)
  [[ $NAME_COUNT =~ ^[0-9]+$ ]] || NAME_COUNT=0
  (( NAME_COUNT > 0 )) && break
  sleep 1
done

(( NAME_COUNT > 0 )) || die "Adlist was configured but contains 0 names. Check '/log print where topics~\"dns\"' on the router."
ok "Adlist loaded: $NAME_COUNT names"

log "Validating managed firewall rules"
assert_filter_rule_valid "mikrotik-adblock: allow LAN DNS UDP"
assert_filter_rule_valid "mikrotik-adblock: allow LAN DNS TCP"
if (( WAN_LIST_AVAILABLE )); then
  assert_filter_rule_valid "mikrotik-adblock: block WAN DNS UDP"
  assert_filter_rule_valid "mikrotik-adblock: block WAN DNS TCP"
fi
if (( FORCE_DNS )); then
  assert_nat_rule_present "mikrotik-adblock: force LAN DNS UDP"
  assert_nat_rule_present "mikrotik-adblock: force LAN DNS TCP"
fi
ok "Managed firewall/NAT rules validated"

printf '\n--- DNS Adlist ---\n'
ros_read '/ip dns adlist print'

printf '\n--- DHCP network ---\n'
if (( DHCP_AVAILABLE )); then
  ros_read "/ip dhcp-server network print detail where address=\"$LAN_CIDR\""
else
  printf 'Skipped (no matching DHCP network entry)\n'
fi

printf '\n--- DNS firewall rules ---\n'
ros_read '/ip firewall filter print stats where comment~"mikrotik-adblock:"'

if (( FORCE_DNS )); then
  printf '\n--- Forced DNS NAT rules ---\n'
  ros_read '/ip firewall nat print stats where comment~"mikrotik-adblock:"'
fi

printf '\n--- DNS test ---\n'
if command -v nslookup >/dev/null 2>&1; then
  TEST_OUTPUT=$(nslookup "$TEST_DOMAIN" "$GATEWAY_IP" 2>&1 || true)
  printf '%s\n' "$TEST_OUTPUT"
  if grep -Eq 'Address: +0\.0\.0\.0|Addresses:.*0\.0\.0\.0' <<< "$TEST_OUTPUT"; then
    ok "$TEST_DOMAIN is blocked through the MikroTik DNS"
  else
    warn "$TEST_DOMAIN did not return 0.0.0.0. This can happen if the selected list does not contain that domain or a local/VPN DNS agent intercepts the test."
  fi
else
  warn "nslookup is not available locally; skipped client-side DNS test."
fi

printf '\nSetup complete.\n'
printf 'LAN:      %s\n' "$LAN_CIDR"
printf 'DNS:      %s\n' "$GATEWAY_IP"
printf 'Adlist:   %s names\n' "$NAME_COUNT"
printf 'TLS:      %s\n' "$([[ $INSECURE_ADLIST -eq 1 ]] && echo 'not verified' || echo 'verified')"
printf 'Force 53: %s\n' "$([[ $FORCE_DNS -eq 1 ]] && echo 'enabled' || echo 'disabled')"

printf '\nNotes:\n'
printf '  - This intentionally does not change your upstream DNS servers.\n'
printf '  - Port 53 interception is IPv4 only. DoH (HTTPS/443), DoT (853), VPNs,\n'
printf '    and some IPv6 DNS configurations can bypass network-level DNS blocking.\n'
printf '  - Adlist updates itself periodically in RouterOS; no cron job is required.\n'
