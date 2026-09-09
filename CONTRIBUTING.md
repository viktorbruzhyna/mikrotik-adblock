# Contributing

Contributions are welcome.

## Before opening a pull request

1. Keep changes focused on MikroTik DNS Adblock setup.
2. Preserve idempotency.
3. Preserve secure defaults.
4. Do not introduce secrets or environment-specific values.
5. Update documentation when behavior changes.
6. Add an entry to `CHANGELOG.md` for user-visible changes.

Run:

```bash
bash -n mikrotik-adblock.sh
bash tests/smoke.sh
```

If available:

```bash
shellcheck mikrotik-adblock.sh tests/smoke.sh
```

## Style

- Bash should remain readable without framework dependencies.
- Quote shell variables unless intentional word splitting is required.
- Prefer explicit errors over silent fallback.
- New RouterOS write operations should be idempotent where possible.
- Avoid destructive RouterOS operations.

## Security-sensitive changes

Changes involving firewall rules, SSH behavior, TLS verification, backup/restore, DNS exposure, or command construction deserve extra review.
