# Changelog

All notable changes to this project will be documented here.

The format is inspired by [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses semantic versioning for tagged releases.

## [1.0.3] - 2026-09-15

### Fixed

- recreate script-managed firewall and NAT rules in a canonical form instead of mutating possibly stale rules with `set`
- migrate legacy unprefixed rule comments created by versions <= 1.0.2
- validate every managed firewall rule after apply and fail if RouterOS marks it invalid
- require LAN DNS allow rules to enter from a non-WAN interface when a `WAN` interface list exists

## [1.0.2] - 2026-09-15

### Fixed
- Fixed RouterOS version detection over non-interactive SSH by explicitly emitting the value with `:put`.

- macOS Bash 3.2 compatibility when `set -u` is enabled and no `--whitelist` options are provided
- avoid direct expansion of an empty `WHITELIST` array by tracking entries explicitly

## [1.0.1] - 2026-09-09

### Fixed

- GitHub Actions ShellCheck failure caused by intentional RouterOS command expansion over SSH (`SC2029`)
- centralized RouterOS SSH command execution in a single `ros_exec` helper

## [1.0.0] - 2026-09-09

### Added

- RouterOS `7.15+` compatibility check
- configurable gateway, SSH user, LAN CIDR, Adlist URL, and DNS cache size
- gateway default of `192.168.1.1`
- automatic LAN CIDR detection from RouterOS DHCP configuration
- HTTPS Adlist certificate preflight and `ssl-verify=yes` by default
- RouterOS binary backup and text export before configuration changes
- DNS Adlist configuration using StevenBlack hosts by default
- DHCP DNS assignment to the MikroTik gateway
- LAN DNS firewall allow rules
- WAN DNS protection when an interface list named `WAN` exists
- optional forced IPv4 TCP/UDP DNS/53 redirect
- exact-domain whitelist support using RouterOS static `FWD` entries
- dry-run mode
- post-install Adlist and DNS verification
- AI-agent guidance in `AGENTS.md`
- GitHub Actions CI

### Security

- insecure Adlist TLS requires explicit `--insecure-adlist`
- no automatic downgrade when TLS validation fails
- no automatic backup restore or router reboot
