# MikroTik DNS AdBlock

A Bash installer for network-level DNS ad blocking on MikroTik RouterOS.

It configures RouterOS DNS Adlist, points DHCP clients at the router for DNS, optionally redirects external IPv4 DNS traffic on port 53 back to RouterOS DNS, and adds narrow firewall rules for DNS access.

The default blocklist is the [StevenBlack unified hosts list](https://github.com/StevenBlack/hosts).

## Features

- RouterOS `7.15+` preflight check
- SSH-based setup from macOS/Linux
- HTTPS Adlist certificate verification by default
- RouterOS backup and text export before changes
- DNS cache sizing for Adlist entries
- DHCP DNS configuration
- Idempotent firewall and NAT rules
- Optional forced IPv4 DNS/53 redirect
- Optional exact-domain whitelist entries
- `--dry-run` mode
- Does not overwrite upstream DNS servers
- Does not silently disable TLS verification

## Requirements

- MikroTik RouterOS `7.15` or newer
- SSH access to the router
- Bash
- `ssh`
- `nslookup` is optional and is used only for the final client-side test

The script assumes the router can reach the Adlist URL and resolve its hostname.

## Quick start

```bash
chmod +x mikrotik-adblock.sh
./mikrotik-adblock.sh --dry-run
./mikrotik-adblock.sh
```

The default gateway is:

```text
192.168.1.1
```

Use a different gateway:

```bash
./mikrotik-adblock.sh --gateway 192.168.50.1
```

Or pass it positionally:

```bash
./mikrotik-adblock.sh 192.168.50.1
```

For a non-default LAN network:

```bash
./mikrotik-adblock.sh \
  --gateway 10.0.0.1 \
  --lan 10.0.0.0/24
```

## Recommended first run

Always inspect the planned changes first:

```bash
./mikrotik-adblock.sh --gateway 192.168.50.1 --dry-run
```

Then apply:

```bash
./mikrotik-adblock.sh --gateway 192.168.50.1
```

## Options

```text
Usage:
  mikrotik-adblock.sh [gateway-ip] [options]

Options:
  -g, --gateway IP       MikroTik gateway IP (default: 192.168.1.1)
  -u, --user USER        SSH username (default: admin)
  -l, --lan CIDR         LAN network; auto-detected from DHCP when omitted
      --adlist URL        HTTPS hosts/adlist URL
      --cache SIZE        RouterOS DNS cache size (default: 32768KiB)
      --whitelist DOMAIN  Exempt an exact domain from Adlist; may be repeated
      --test-domain NAME  Domain used for the final DNS test
      --no-force-dns      Do not intercept external DNS on TCP/UDP port 53
      --no-backup         Do not create RouterOS backup/export before changes
      --insecure-adlist   Disable Adlist TLS certificate validation (not recommended)
      --dry-run           Preflight only; print changes without applying them
  -h, --help              Show help
```

## What the script changes

The script may configure the following RouterOS areas:

```text
/ip dns
/ip dns adlist
/ip dns static
/ip dhcp-server network
/ip firewall filter
/ip firewall nat
/system backup
/export
```

It does **not** replace the router's upstream DNS server configuration.

### DNS Adlist

RouterOS DNS is enabled for remote LAN requests and the DNS cache is enlarged. The Adlist is then configured using HTTPS certificate validation.

Default list:

```text
https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
```

MikroTik documents DNS Adlist as a built-in network-level blocking mechanism that returns `0.0.0.0` for listed names. RouterOS also periodically checks Adlists for updates.

### DHCP

When a matching DHCP network exists, clients are configured to use the MikroTik gateway as their DNS server.

### Firewall

The script adds narrow allow rules for LAN DNS requests. If an interface list named `WAN` exists, it also adds rules that block inbound DNS queries from interfaces classified as WAN.

This is important because enabling `allow-remote-requests=yes` turns RouterOS into a DNS resolver for clients, and the resolver should not be exposed to untrusted networks.

### Forced DNS

By default, IPv4 DNS requests from the configured LAN to external servers on TCP/UDP port 53 are redirected to RouterOS DNS.

For example, a client explicitly querying a public resolver on port 53 will still pass through the MikroTik DNS Adlist.

Disable this behavior with:

```bash
./mikrotik-adblock.sh --no-force-dns
```

## Whitelist

Whitelist an exact domain:

```bash
./mikrotik-adblock.sh --whitelist example.com
```

Multiple entries:

```bash
./mikrotik-adblock.sh \
  --whitelist example.com \
  --whitelist telemetry.example.com
```

The script uses RouterOS static DNS `FWD` entries, which MikroTik documents as the mechanism for exempting names from Adlist handling.

## TLS behavior

TLS certificate verification is enabled by default.

If certificate validation fails, the script stops instead of silently switching to insecure mode.

The escape hatch exists only for troubleshooting:

```bash
./mikrotik-adblock.sh --insecure-adlist
```

Using it is not recommended.

## Backup and recovery

Before applying changes, the script creates both:

```text
before-adblock-YYYYMMDD-HHMMSS.backup
before-adblock-YYYYMMDD-HHMMSS.rsc
```

These files are stored on the router.

Automatic restore is intentionally not performed on failure because restoring a RouterOS backup can reboot the router and disconnect the SSH session.

To skip backup creation:

```bash
./mikrotik-adblock.sh --no-backup
```

## Verification

Check the Adlist:

```routeros
/ip dns adlist print
```

A loaded list should show a non-zero `name-count`.

Check forced DNS counters:

```routeros
/ip firewall nat print stats where comment~"Force LAN DNS"
```

From a client, query the router directly:

```bash
nslookup doubleclick.net 192.168.50.1
```

If that domain is present in the active list, the expected IPv4 response is `0.0.0.0`.

## Limitations

This is DNS-level blocking, not a browser content blocker.

It cannot reliably block ads served from the same domains as wanted content. YouTube ads are a common example.

The forced-DNS feature covers IPv4 TCP/UDP port 53 only. These can bypass it:

- DNS over HTTPS (DoH) on HTTPS/443
- DNS over TLS (DoT) on 853
- VPN tunnels
- some IPv6 DNS configurations
- endpoint security or corporate DNS agents

The script deliberately does not try to block DoH/DoT because broad rules can break legitimate services and managed/corporate devices.

## Safety notes

- Run `--dry-run` first.
- Review your RouterOS firewall before applying changes to unusual configurations.
- Keep SSH restricted to trusted networks.
- Do not expose RouterOS recursive DNS to the Internet.
- Do not use `--insecure-adlist` unless you understand the TLS trade-off.
- Review third-party blocklists before trusting them.

## AI / agent use

See [`AGENTS.md`](AGENTS.md) for instructions intended for ChatGPT, Copilot, Cursor, Claude, and other coding/automation agents.

The main rules are: inspect first, prefer `--dry-run`, preserve TLS verification, do not change upstream DNS without an explicit request, and do not add aggressive DoH/DoT blocking automatically.


## Development

Run local checks:

```bash
bash -n mikrotik-adblock.sh
bash tests/smoke.sh
```

If ShellCheck is installed:

```bash
shellcheck mikrotik-adblock.sh tests/smoke.sh
```

GitHub Actions runs syntax checks, smoke tests, and ShellCheck on pushes and pull requests.

## References

- [MikroTik RouterOS DNS documentation](https://help.mikrotik.com/docs/spaces/ROS/pages/37748767/DNS)
- [StevenBlack hosts](https://github.com/StevenBlack/hosts)

## License

MIT. See [`LICENSE`](LICENSE).
