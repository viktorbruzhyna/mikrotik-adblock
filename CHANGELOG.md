# Changelog

All notable changes to this project will be documented here.

The format is inspired by [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses semantic versioning for tagged releases.

## [1.0.2] - 2026-10-02

### Fixed

- support empty whitelist arrays under macOS Bash 3.2 with `set -u`
- detect RouterOS version correctly over non-interactive SSH by explicitly printing `get` output with `:put`
- recreate managed firewall/NAT rules instead of mutating potentially stale rule state
- migrate legacy unprefixed rule comments created by versions <= 1.0.1
- avoid session-dependent RouterOS CLI row numbers such as `place-before=0`; placement now uses internal IDs returned by `find`
- avoid dynamic/built-in firewall rules as `place-before` targets by selecting the first static rule (`dynamic=no`)
- walk `find` results with `:foreach`, because a single match is not always an array and indexing it breaks `place-before` and `get`
- add a replacement firewall/NAT rule before removing the previous one
- keep the SSH control socket path short enough for the macOS Unix socket limit
- wait up to 90 seconds for a large Adlist download to report `name-count`
- validate managed firewall rules after apply and fail if a managed rule is missing or invalid

### Security

- constrain LAN DNS allow rules with `in-interface-list=!WAN` when a WAN interface list exists
- keep that `!WAN` matcher unquoted so RouterOS treats it as negation instead of a missing interface list name
- keep explicit WAN DNS drop rules ahead of the existing firewall policy
- enable remote DNS requests only after those firewall rules are installed

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
