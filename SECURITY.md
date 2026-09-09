# Security Policy

## Reporting a vulnerability

Please use a private GitHub Security Advisory for the repository when available rather than opening a public issue for an exploitable vulnerability.

Useful reports include:

- command-injection paths
- unsafe RouterOS firewall behavior
- accidental WAN DNS exposure
- TLS verification bypass
- secret leakage
- destructive or non-idempotent RouterOS operations

## Security model

The script executes RouterOS commands over SSH using the privileges of the supplied RouterOS account. Treat that account as privileged infrastructure access.

The script intentionally:

- verifies Adlist TLS certificates by default
- does not store SSH passwords
- does not change upstream DNS servers
- backs up RouterOS before changes unless disabled
- does not automatically restore or reboot the router
- blocks WAN access to RouterOS DNS when a standard `WAN` interface list exists

Always review changes and use `--dry-run` before applying them to unfamiliar configurations.
