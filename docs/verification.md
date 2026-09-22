# WireGuard verification

Run these checks after deployment or after a client profile is changed.

## Server checks

```bash
sudo systemctl is-enabled wg-quick@wg0
sudo systemctl is-active wg-quick@wg0
sudo wg show wg0
sudo ss -lunp | grep -E ':(443|51820)([[:space:]]|$)'
sudo iptables -t nat -S PREROUTING
sudo iptables -t nat -S POSTROUTING
```

The expected state is:

- `wg-quick@wg0` is enabled and active.
- WireGuard listens on UDP `51820`.
- `PREROUTING` contains UDP `443` redirected to `51820` on `eth0`.
- `POSTROUTING` contains `10.66.66.0/24` MASQUERADE out `eth0`.
- The four peer `AllowedIPs` entries are `.2/32`, `.3/32`, `.4/32`, and
  `.5/32`.

For peer activity and counters:

```bash
sudo wg show wg0 latest-handshakes
sudo wg show wg0 transfer
```

## Client checks

On each client, confirm that the imported profile has:

```text
Endpoint: 43.160.239.253:443
AllowedIPs: 0.0.0.0/0
PersistentKeepalive: 25
MTU: 1340
```

After activating the tunnel, verify that the public IPv4 address is
`43.160.239.253`. The WireGuard server should then show a recent handshake for
the matching peer.

On Windows, keep the official WireGuard application's kill-switch OFF. The
configuration is a normal full-tunnel profile and does not depend on a second
router or proxy process.

## Throughput and MTU record

The final MTU is `1340`, selected through Windows iperf and PMTU testing. The
recorded result at that setting was approximately `91 Mbps` for one download
stream and `186 Mbps` with four concurrent streams, with short peaks around
`230–240 Mbps`. These numbers describe the tested path and time; they are not
a contractual bandwidth limit.
