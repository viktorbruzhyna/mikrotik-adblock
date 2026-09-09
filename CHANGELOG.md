# Changelog

All notable changes to this project will be documented here.

The format is inspired by [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses semantic versioning for tagged releases.

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
