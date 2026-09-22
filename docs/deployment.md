# Standard WireGuard deployment

This document describes the verified full-tunnel deployment on Ubuntu 26.04.
It does not add a routing daemon, a TUN interface, or another VPN layer.

## Server state

The server uses `eth0` for the public path and `wg0` for the VPN:

```text
wg0: 10.66.66.1/24
VPN: 10.66.66.0/24
WireGuard socket: UDP 51820
Compatibility input: UDP 443 -> UDP 51820
NAT: 10.66.66.0/24 out eth0 via MASQUERADE
MTU: 1340
```

The server-side template is [`../WireGuard/server.example.conf`](../WireGuard/server.example.conf).
Copy it to `/etc/wireguard/wg0.conf` on the server, replace the key
placeholders locally, and keep the file mode at `600`.

## IPv4 forwarding

Persist forwarding in `/etc/sysctl.d/99-wireguard.conf`:

```ini
net.ipv4.ip_forward = 1
```

Apply it with:

```bash
sudo sysctl --system
```

## iptables rules

The `wg0.conf` `PostUp`/`PostDown` hooks manage these rules idempotently:

```bash
sudo iptables -t nat -I PREROUTING 1 -i eth0 -p udp --dport 443 \
  -j REDIRECT --to-ports 51820
sudo iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o eth0 \
  -j MASQUERADE
```

The first rule makes UDP `443` a compatibility entry point. It does not move
the WireGuard listener: `ListenPort` remains `51820`. The second rule provides
IPv4 egress for all four full-tunnel clients.

Do not add a second copy by hand when the service is already active; the
example hooks first check for an existing rule.

## Firewall and service

Allow inbound UDP `443` and UDP `51820` in the Tencent Cloud Lighthouse
firewall, plus the required SSH access. Then start and enable the systemd
unit:

```bash
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
sudo systemctl is-enabled wg-quick@wg0
sudo systemctl is-active wg-quick@wg0
```

After changing `/etc/wireguard/wg0.conf`, use a controlled restart:

```bash
sudo systemctl restart wg-quick@wg0
sudo systemctl status wg-quick@wg0 --no-pager
```

The expected steady state is `enabled` and `active`.

## Client profiles

Use the four sanitized client templates in `WireGuard/`. Each profile must
retain the following values:

```ini
MTU = 1340
Endpoint = 43.160.239.253:443
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

The client addresses are `.2` for iPhone, `.3` for Windows, `.4` for Android,
and `.5` for macOS. The Windows WireGuard application's kill-switch remains
OFF.

MTU `1340` is fixed. It was selected from Windows iperf and PMTU testing,
where `1340` was stable and higher tested values such as `1420` were not.
