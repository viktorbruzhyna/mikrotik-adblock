# AGENTS.md

Guidance for AI coding agents and automated assistants working with this repository.

## Project goal

Maintain a small, auditable Bash installer for MikroTik RouterOS DNS-level ad blocking.

## Safety rules

1. **Prefer dry-run first.** When proposing execution, use `--dry-run` before applying changes unless the user explicitly says otherwise.
2. **Keep TLS verification enabled.** Do not add automatic fallback to insecure TLS. `--insecure-adlist` must remain explicit opt-in behavior.
3. **Do not change upstream DNS by default.** Preserve the user's existing RouterOS upstream DNS configuration.
4. **Do not automatically update RouterOS or firmware.** Firmware upgrades and reboots are outside this script's scope.
5. **Do not automatically restore backups.** Restore can reboot or disconnect the router. Report the backup names instead.
6. **Do not add broad DoH/DoT blocking by default.** It may break managed endpoints, VPNs, security agents, or legitimate HTTPS traffic.
7. **Keep rules idempotent.** Re-running the script must not create duplicate firewall, NAT, Adlist, or whitelist entries.
8. **Avoid secrets.** Never add passwords, SSH private keys, tokens, real user network addresses, corporate domains, SSIDs, MAC addresses, or backup contents to the repository.
9. **Use neutral examples.** Default/example gateway is `192.168.1.1`; other examples should use generic private ranges.
10. **Keep RouterOS changes narrow.** Do not rewrite unrelated firewall rules or DHCP configuration.

## Required checks for changes

At minimum run:

```bash
bash -n mikrotik-adblock.sh
bash tests/smoke.sh
```

When available:

```bash
shellcheck mikrotik-adblock.sh tests/smoke.sh
```

## RouterOS compatibility

The script requires RouterOS `7.15+` because it uses `/ip dns adlist`.

When adding RouterOS commands, verify them against current MikroTik documentation before changing behavior.

## Scope

In scope:

- RouterOS DNS Adlist
- DHCP DNS assignment
- narrow DNS firewall protection
- IPv4 TCP/UDP port 53 redirect
- whitelist handling
- backup/export before changes
- preflight and verification

Out of scope unless explicitly designed as a separate feature:

- RouterOS/firmware upgrades
- automatic reboot
- full firewall management
- VPN management
- blanket DoH/DoT blocking
- browser extensions
- Pi-hole/AdGuard Home installation
