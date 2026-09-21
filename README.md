# Tencent Cloud Lighthouse WireGuard Egress

This repository contains the non-secret documentation and sanitized templates for a WireGuard IPv4 egress node on Tencent Cloud Lighthouse.

## Deployment

- Public endpoint: `43.160.239.253:51820/UDP`
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

## Security

The real WireGuard configuration files are intentionally excluded from Git. They contain private keys and remain in the local `WireGuard/` directory only. Do not remove the ignore rules or commit generated QR files.

Use the sanitized templates in `WireGuard/` as format references only.

## Tencent Cloud firewall

The Lighthouse firewall must allow inbound `UDP 51820` from `0.0.0.0/0`. Keep SSH port 22 allowed.

## Client verification

After importing and activating a client configuration, verify that the public IP is `43.160.239.253`, then check the server for a recent handshake with:

```bash
sudo wg show wg0 latest-handshakes
sudo wg show wg0 transfer
```

