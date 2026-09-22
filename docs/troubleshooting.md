# WireGuard troubleshooting

## Service will not start

Inspect the unit and its recent log:

```bash
sudo systemctl status wg-quick@wg0 --no-pager
sudo journalctl -u wg-quick@wg0 -n 100 --no-pager
```

After correcting the local configuration, restart the service:

```bash
sudo systemctl restart wg-quick@wg0
sudo systemctl is-active wg-quick@wg0
```

Check that `/etc/wireguard/wg0.conf` is mode `600`, the interface address is
`10.66.66.1/24`, `ListenPort` is `51820`, and all key values are valid local
values. Never copy those local values into Git.

## No handshake

Check the following in order:

1. The Lighthouse firewall allows UDP `443` and UDP `51820`.
2. The client endpoint is exactly `43.160.239.253:443`.
3. The server's `PREROUTING` rule redirects UDP `443` to `51820`.
4. The client public key is present in the matching server peer entry.
5. The server and client clocks are reasonable.

Inspect the redirect and the latest handshake:

```bash
sudo iptables -t nat -S PREROUTING
sudo wg show wg0 latest-handshakes
```

## Handshake exists but Internet traffic fails

Confirm forwarding, NAT, and the public interface:

```bash
sysctl net.ipv4.ip_forward
sudo iptables -t nat -S POSTROUTING
ip route get 1.1.1.1
```

The expected values are forwarding enabled, a MASQUERADE rule for
`10.66.66.0/24` out `eth0`, and an Internet route through `eth0`.

## Fragmentation or unstable throughput

Keep the client and server interface MTU at `1340`. This value was chosen by
Windows iperf and PMTU testing; do not return to `1420` or tune it upward as a
first response. Re-check the handshake and NAT rules before changing the
verified MTU.

## Windows-specific checks

The Windows kill-switch must remain OFF for this verified setup. Also make
sure the official WireGuard tunnel is the only system-level VPN path being
used for the Windows peer. Re-import the sanitized template only after
putting the real local keys back into a private local copy.
