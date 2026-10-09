#!/usr/bin/env bash
# Stand-in for ssh(1). The installer talks to RouterOS only through ssh, so
# this process records firewall/NAT changes and answers the queries the
# installer uses to validate them.
set -u

if [[ -z ${MIKROTIK_MOCK_STATE:-} ]]; then
  printf 'mock ssh: MIKROTIK_MOCK_STATE is not set\n' >&2
  exit 1
fi

mkdir -p "$MIKROTIK_MOCK_STATE"
rules_file="$MIKROTIK_MOCK_STATE/rules"
log_file="$MIKROTIK_MOCK_STATE/commands.log"
rsc_file="$MIKROTIK_MOCK_STATE/rsc"
touch "$rules_file" "$log_file"

args="$*"
if [[ $args == *"-O exit"* ]]; then
  exit 0
fi

command=${!#}
printf '%s\n' "$command" >> "$log_file"

add_rule() {
  local menu=$1 invalid=$2 comment=$3
  printf '%s\t%s\t%s\n' "$menu" "$invalid" "$comment" >> "$rules_file"
}

remove_rule() {
  local menu=$1 comment=$2
  local tmp
  tmp=$(mktemp)
  awk -F '\t' -v menu="$menu" -v comment="$comment" '
    $1 != menu || $3 != comment { print }
  ' "$rules_file" > "$tmp"
  mv "$tmp" "$rules_file"
}

rename_rule() {
  local menu=$1 old=$2 new=$3
  local tmp
  tmp=$(mktemp)
  awk -F '\t' -v menu="$menu" -v old="$old" -v new="$new" '
    BEGIN { OFS = "\t" }
    $1 == menu && $3 == old { $3 = new }
    { print }
  ' "$rules_file" > "$tmp"
  mv "$tmp" "$rules_file"
}

count_rules() {
  local menu=$1 comment=$2
  awk -F '\t' -v menu="$menu" -v comment="$comment" '
    $1 == menu && $3 == comment { n++ }
    END { print n + 0 }
  ' "$rules_file"
}

print_invalid() {
  local menu=$1 comment=$2
  awk -F '\t' -v menu="$menu" -v comment="$comment" '
    $1 == menu && $3 == comment { print $2 }
  ' "$rules_file"
}

apply_removes() {
  local rest=$1 menu comment
  while [[ $rest =~ comment=\"([^\"]+)\"\]\ do=\{/ip\ firewall\ (filter|nat)\ remove ]]; do
    comment=${BASH_REMATCH[1]}
    menu=${BASH_REMATCH[2]}
    remove_rule "$menu" "$comment"
    rest=${rest#*"comment=\"${comment}\""}
  done
}

if [[ $command == ':put "SSH connection OK"' ]]; then
  printf '%s\n' 'SSH connection OK'
  exit 0
fi

if [[ $command == ':put [/system resource get version]' ]]; then
  printf '%s\n' "${MIKROTIK_MOCK_VERSION:-7.24.2 (stable)}"
  exit 0
fi

if [[ $command == *'/ip dhcp-server network find where gateway='* ]]; then
  printf '%s\n' '192.168.1.0/24'
  exit 0
fi

if [[ $command == *'/ip dhcp-server network find where address='* ]]; then
  printf '%s\n' "${MIKROTIK_MOCK_DHCP_COUNT:-1}"
  exit 0
fi

if [[ $command == ':put [:len [/interface list find where name="WAN"]]' ]]; then
  printf '%s\n' "${MIKROTIK_MOCK_WAN_COUNT:-1}"
  exit 0
fi

if [[ $command == /tool\ fetch* ]]; then
  if [[ ${MIKROTIK_MOCK_FETCH_FAIL:-0} == 1 ]]; then
    exit 1
  fi
  exit 0
fi

if [[ $command == *name-count* ]]; then
  printf '%s\n' "${MIKROTIK_MOCK_NAME_COUNT:-1200}"
  exit 0
fi

dollar='$'
if [[ $command == *" get ${dollar}i invalid"* ]]; then
  if [[ $command =~ /ip\ firewall\ (filter|nat)\ find\ where\ comment=\"([^\"]+)\" ]]; then
    print_invalid "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
  exit 0
fi

if [[ $command == *":put ${dollar}n"* && $command == *'find where comment='* ]]; then
  if [[ $command =~ /ip\ firewall\ (filter|nat)\ find\ where\ comment=\"([^\"]+)\" ]]; then
    count_rules "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '0\n'
  fi
  exit 0
fi

if [[ $command == /import\ file-name=mikrotik-adblock-rule.rsc ]]; then
  if [[ -f $rsc_file ]] && [[ $(cat "$rsc_file") =~ /ip\ firewall\ (filter|nat)\ add\ .*comment=\"([^\"]+)\" ]]; then
    add_rule "${BASH_REMATCH[1]}" false "${BASH_REMATCH[2]}"
  fi
  exit 0
fi

if [[ $command == /file\ add\ name=mikrotik-adblock-rule.rsc\ contents=\"* ]]; then
  body=${command#contents=\"}
  body=${body%\"}
  body=${body//\\\"/\"}
  printf '%s\n' "$body" > "$rsc_file"
  exit 0
fi

if [[ $command == /file\ remove* || $command == /system\ backup* || $command == /export\ file=* ]]; then
  exit 0
fi

if [[ $command == *' remove '* ]]; then
  apply_removes "$command"
  exit 0
fi

if [[ $command =~ comment=\"([^\"]+)\"\]\ do=\{/ip\ firewall\ (filter|nat)\ set\ \$i\ comment=\"([^\"]+)\" ]]; then
  rename_rule "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  exit 0
fi

if [[ $command =~ ^/ip\ firewall\ (filter|nat)\ add\  ]]; then
  menu=${BASH_REMATCH[1]}
  if [[ $command =~ comment=\"([^\"]+)\" ]]; then
    comment=${BASH_REMATCH[1]}
    invalid=false
    if [[ ${MIKROTIK_MOCK_TCP_INVALID:-0} == 1 && $command == *'protocol=6'* ]]; then
      invalid=true
    fi
    add_rule "$menu" "$invalid" "$comment"
  fi
  exit 0
fi

if [[ $command == '/ip dns adlist print' ]]; then
  printf '%s\n' 'url=https://example.invalid/hosts name-count=1200'
  exit 0
fi

if [[ $command == /ip\ firewall\ filter\ print* || $command == /ip\ firewall\ nat\ print* ]]; then
  awk -F '\t' '{ print $1, $3, "invalid=" $2 }' "$rules_file"
  exit 0
fi

exit 0
