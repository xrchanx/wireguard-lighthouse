# Tencent Cloud Lighthouse WireGuard Egress

This repository records the verified, non-secret configuration for the
Tencent Cloud Lighthouse WireGuard egress node. The supported architecture is
standard WireGuard full-tunnel mode: the official WireGuard client sends all
IPv4 traffic through the Lighthouse server.

The current mainline intentionally contains no second-generation router,
Smart Router, sing-box, or TUN layer. Earlier routing experiments remain in
Git history for auditability, but they are not part of the current deployment
or support path.

## Verified deployment state

| Item | Value |
| --- | --- |
| Server OS | Ubuntu 26.04 |
| Public interface | `eth0` |
| WireGuard interface | `wg0` |
| VPN subnet | `10.66.66.0/24` |
| Server address | `10.66.66.1/24` |
| WireGuard listen port | UDP `51820` |
| Compatibility entry point | UDP `443`, redirected to `51820` |
| NAT | iptables `MASQUERADE` out `eth0` |
| Service | `wg-quick@wg0.service`, enabled and active |
| Client MTU | `1340` |
| Windows kill-switch | OFF |

The four configured client addresses are:

- iPhone: `10.66.66.2/32`
- Windows: `10.66.66.3/32`
- Android: `10.66.66.4/32`
- macOS: `10.66.66.5/32`

All client profiles use:

```text
Endpoint = 43.160.239.253:443
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
MTU = 1340
```

MTU `1340` is the final value selected by Windows iperf and PMTU testing. In
the recorded test, `1340` was stable while `1420` was not; the observed
four-stream download was approximately `186 Mbps` (single-stream about
`91 Mbps`, with short peaks around `230–240 Mbps`). These are path-specific
measurements, not a bandwidth guarantee.

## Architecture

```text
iPhone / Windows / Android / macOS
    -> official WireGuard client
    -> UDP 443 compatibility entry point
    -> iptables REDIRECT to UDP 51820
    -> wg0 (10.66.66.1/24)
    -> iptables MASQUERADE on eth0
    -> Internet
```

UDP `51820` remains the WireGuard socket. UDP `443` is only a compatibility
entry point for networks that handle high UDP ports poorly; it is redirected
on the server before WireGuard receives the packet.

## Repository contents

- [`WireGuard/server.example.conf`](WireGuard/server.example.conf) — sanitized
  server interface, NAT, redirect, and peer layout.
- [`WireGuard/iphone.example.conf`](WireGuard/iphone.example.conf),
  [`WireGuard/windows.example.conf`](WireGuard/windows.example.conf),
  [`WireGuard/android.example.conf`](WireGuard/android.example.conf), and
  [`WireGuard/mac.example.conf`](WireGuard/mac.example.conf) — sanitized full-
  tunnel client templates.
- [`docs/deployment.md`](docs/deployment.md) — server installation and
  service lifecycle.
- [`docs/verification.md`](docs/verification.md) — client and server checks.
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — recovery and common
  failure checks.

## Deployment summary

On the server, create `/etc/wireguard/wg0.conf` from the sanitized server
example, replace only the local private/public-key placeholders, then enable
the service:

```bash
sudo systemctl enable --now wg-quick@wg0
sudo systemctl restart wg-quick@wg0
```

The Tencent Cloud firewall must allow inbound UDP `443` and UDP `51820` from
the intended client networks, in addition to SSH access. The exact iptables
rules and verification commands are in the deployment and verification
documents.

## Security

Only sanitized examples are tracked. Real WireGuard configuration files,
private keys, pre-shared keys, QR exports, API keys, and generated local state
must remain outside Git. The ignore rules deliberately exclude real files such
as `WireGuard/windows.conf`, `WireGuard/wg0.conf`, key files, and QR files.

Do not paste a complete client configuration or any `PrivateKey` value into
the repository. Public-key placeholders in the examples are documentation
only.

## Verification and troubleshooting

After activating a client, verify that its public IPv4 address is
`43.160.239.253`, then check the server for a recent handshake and traffic:

```bash
sudo wg show wg0 latest-handshakes
sudo wg show wg0 transfer
```

See [`docs/verification.md`](docs/verification.md) and
[`docs/troubleshooting.md`](docs/troubleshooting.md) for the complete checks.
