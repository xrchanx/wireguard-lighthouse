# Smart Routing architecture

## Data path

```text
Application
    |
    v
sing-box TUN (Windows WFP/auto_route)
    |
    v
ordered route rules
    |----------------------------|
    v                            v
DIRECT                       wg-lighthouse endpoint
local interface              WireGuard userspace tunnel
                                   |
                                   v
                           Tencent Cloud Lighthouse
                                   |
                                   v
                               Internet
```

The existing Lighthouse server remains a regular WireGuard server with its current `wg0` service and peer addresses. No server-side control plane is introduced.

## Why Option A

The MVP uses sing-box's current WireGuard endpoint rather than starting the official Windows WireGuard tunnel and trying to layer policy routing over an already-full-tunnel interface. The endpoint is userspace (`system: false`), so the Smart Router owns one system TUN and avoids two competing full-tunnel interfaces. It also gives sing-box one place to enforce route and DNS policy.

The official WireGuard client and the existing full-tunnel configuration remain supported as a separate Standard WireGuard Mode. The Windows scripts refuse to start Smart Routing while a `WireGuardTunnel$*` service is running.

## Rule order

The effective order in `config.windows.example.json` is:

1. custom proxy/direct sets, with proxy first for accidental conflicts;
2. the Lighthouse endpoint address forced to `DIRECT` to prevent a handshake loop;
3. `ip_is_private` for LAN, loopback, link-local, and other non-public addresses;
4. explicit proxy and `geosite-geolocation-!cn` to the WireGuard endpoint;
5. local/direct and `geosite-geolocation-cn` to `DIRECT`;
6. `geoip-cn` to `DIRECT` after the destination has been resolved;
7. the final route to the WireGuard endpoint.

The final route is deliberately proxy by default. Changing it to `direct` is a deliberate policy change and should be documented with its leak implications.

## DNS order

The TUN uses `dns_mode: hijack` and `strict_route: true`. The DNS module applies the same domain-oriented custom and geosite sets before the fallback:

- China/custom-direct -> local UDP resolver;
- global/custom-proxy -> DoH configured to detour through the WireGuard endpoint;
- unknown -> DoH through the WireGuard endpoint.

IP-only traffic is routed by the route rules. `geoip-cn` is intentionally used in route rules rather than as a legacy DNS address filter; sing-box 1.14 requires response-based DNS matching for that older pattern.

## Update and rollback

`update-rules.ps1` downloads only the pinned official SagerNet rule-set URLs. Each download is written to a temporary file, decompiled with the local sing-box binary, hashed, and atomically promoted. A failed download or validation leaves the existing cache and lock metadata unchanged for that source.

## Failure behavior

- If sing-box configuration validation fails, start aborts before creating a TUN.
- If the endpoint cannot handshake, direct and LAN rules still use `DIRECT`; proxy traffic does not silently fall back to `DIRECT`.
- If sing-box stops, its TUN cleanup is expected to restore normal networking. The stop script checks and removes only routes on the named Smart Router adapter when cleanup is incomplete.
- Rule update failure does not erase a known-good cache.
