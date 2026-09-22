# Tencent Cloud Lighthouse WireGuard Egress

This repository contains the non-secret documentation and sanitized templates for a WireGuard IPv4 egress node on Tencent Cloud Lighthouse. The original WireGuard tunnel remains available as a standard full-tunnel mode. A Windows-first sing-box Smart Routing MVP is provided as an additive client mode.

## Architecture

The server remains a normal WireGuard IPv4 egress node. Smart Routing is a client-side layer:

```text
Application
    -> sing-box TUN
    -> local rule engine and split DNS
       -> DIRECT -> local Internet
       -> PROXY  -> sing-box WireGuard endpoint -> Lighthouse -> Internet
```

The Smart Router uses sing-box's current WireGuard endpoint and rule-set configuration. It does not reimplement WireGuard and it must not be started while the same Windows peer is running as a separate full-tunnel WireGuard interface.

## Deployment

- Standard WireGuard endpoint: `43.160.239.253:51820/UDP`
- Windows Smart Router compatibility endpoint: `43.160.239.253:443/UDP`, redirected server-side to UDP 51820
- Public interface: `eth0`
- VPN subnet: `10.66.66.0/24`
- Server address: `10.66.66.1/24`
- IPv4 forwarding: enabled and persisted in `/etc/sysctl.d/99-wireguard.conf`
- NAT: iptables-nft MASQUERADE on the detected default interface
- Service: `wg-quick@wg0.service`, enabled at boot

Configured peer addresses:

- iPhone: `10.66.66.2/32`
- Windows: `10.66.66.3/32`
- Android: `10.66.66.4/32`
- macOS: `10.66.66.5/32`

## Security

The real WireGuard configuration files are intentionally excluded from Git. They contain private keys and remain in the local `WireGuard/` directory only. Do not remove the ignore rules or commit generated QR files.

Use the sanitized templates in `WireGuard/` as format references only.

Never copy a real `PrivateKey`, `PreSharedKey`, API token, client config, or QR code into Git. The Smart Router installer reads the ignored `WireGuard/windows.conf` locally and writes an ignored generated JSON file; the generated file is never a repository artifact.

## Tencent Cloud firewall

The Lighthouse firewall must allow inbound `UDP 51820` and `UDP 443` from `0.0.0.0/0`. Keep SSH port 22 allowed. UDP 443 is a compatibility entry point for networks that drop return traffic on high UDP ports; standard WireGuard clients can continue using UDP 51820.

Persist the compatibility redirect in `/etc/wireguard/wg0.conf`:

```ini
PostUp = iptables -t nat -C PREROUTING -i eth0 -p udp --dport 443 -j REDIRECT --to-ports 51820 || iptables -t nat -I PREROUTING 1 -i eth0 -p udp --dport 443 -j REDIRECT --to-ports 51820
PostDown = while iptables -t nat -C PREROUTING -i eth0 -p udp --dport 443 -j REDIRECT --to-ports 51820 2>/dev/null; do iptables -t nat -D PREROUTING -i eth0 -p udp --dport 443 -j REDIRECT --to-ports 51820; done
```

## Client verification

After importing and activating a client configuration, verify that the public IP is `43.160.239.253`, then check the server for a recent handshake with:

```bash
sudo wg show wg0 latest-handshakes
sudo wg show wg0 transfer
```
## macOS

Install the official WireGuard macOS app, choose **Import tunnel(s) from file**, and select
`WireGuard/mac.conf`. Activate the tunnel and verify the public IP as above.

The macOS client uses a new key and address `10.66.66.5/32`. Add its public key to the
server's `wg0.conf` as a new peer before activating it:

```ini
[Peer]
PublicKey = <MAC_PUBLIC_KEY_FROM_WIREGUARD_MAC_CONF>
AllowedIPs = 10.66.66.5/32
```

## Standard WireGuard Mode

The existing iPhone, Windows, Android, and macOS examples continue to describe full-tunnel WireGuard:

```text
all traffic -> official WireGuard client -> Lighthouse
```

The existing server service (`wg-quick@wg0.service`), peer addresses, and client compatibility are unchanged.

## Smart Routing Mode

Smart Routing is currently Windows-first and is implemented under [`smart-router/`](smart-router/README.md). It uses a sing-box TUN and deterministic local rules:

```text
LAN/private -> DIRECT
China domain/IP rule-sets -> DIRECT
explicit custom proxy rules -> WireGuard
known global rule-set -> WireGuard
unknown traffic -> WireGuard (configurable)
```

The default route is configured as `proxy`. Users edit the ignored local Windows WireGuard config only; the installer converts it into the ignored sing-box config without exposing keys.

When another system-level VPN or proxy is active, Smart Router `DIRECT` means bypassing the
Lighthouse WireGuard path; it does not guarantee the ISP's native egress. The Windows installer
pins the Lighthouse WireGuard endpoint to the detected physical interface so it cannot recurse
through the Smart Router TUN.

## Windows Setup

See [`smart-router/README.md`](smart-router/README.md) for installation, start, stop, rule update, and diagnostics commands. Run PowerShell as Administrator. Use either Standard WireGuard Mode or Smart Routing Mode for the Windows peer at a time.

## Rule Priority

The effective priority is:

1. custom proxy/direct rules (proxy wins an accidental conflict)
2. the Lighthouse endpoint itself (always direct to avoid a handshake loop)
3. private/LAN addresses
4. explicit proxy/global domain rule-sets
5. China domain/IP rule-sets
6. configured default route (`proxy` in the MVP)

## DNS Routing

China and custom-direct domains use the local DNS transport. Proxy/global and unknown domains use encrypted DoH through the WireGuard endpoint. DNS is hijacked by the TUN on Windows to prevent ordinary multihomed DNS lookups from bypassing the policy.

## Updating Rules

`smart-router/scripts/update-rules.ps1` atomically downloads the official SagerNet sing-geosite and sing-geoip rule-sets, validates them with sing-box, writes checksums to `smart-router/rules.lock.json`, and keeps the last known-good cache if an update fails.

## Troubleshooting

Run `smart-router/scripts/diagnose-windows.ps1` as Administrator. It checks the sing-box process, TUN, rule caches, DNS, public IP, endpoint configuration, and the expected `baidu.com`, `github.com`, and `openai.com` policy decisions. `stop-windows.ps1` removes the Smart Router process and cleans only routes belonging to its named TUN if a stale adapter remains.

Smart Routing fails closed for the proxy path when its WireGuard endpoint is unavailable; direct/LAN traffic remains direct. A crashed process should leave normal Windows networking usable after the TUN cleanup. No AI or remote service is placed in the per-request routing path.
