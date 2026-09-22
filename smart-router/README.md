# Smart Router MVP

This directory adds a Windows-first split-routing client without changing the existing Lighthouse WireGuard server or the standard full-tunnel peer files.

## What it does

- Creates a sing-box TUN interface and sends normal application traffic through its local rule engine.
- Sends private/LAN traffic and China traffic directly.
- Sends explicit global/custom proxy traffic through a sing-box WireGuard endpoint to the Lighthouse server.
- Sends unknown traffic through the proxy path by default (`default_route = proxy` in the policy represented by `route.final`).
- Routes China DNS queries to a local UDP resolver and proxy/global/unknown DNS queries to encrypted DoH through the WireGuard endpoint.
- Updates official SagerNet rule-sets atomically and keeps the previous cache on failure.

This MVP is deterministic and local. It does not ask an AI service to classify live requests.

## Integration choice

The MVP uses Option A: sing-box owns a userspace WireGuard endpoint (`endpoints[].type = "wireguard"`) and routes selected TUN traffic to that endpoint. This is the current sing-box replacement for the removed/deprecated WireGuard outbound configuration.

This avoids running the official WireGuard Windows tunnel and the Smart Router as two competing full-tunnel interfaces. The original official WireGuard client remains supported for Standard WireGuard Mode; stop that tunnel before starting Smart Routing for the same peer.

## Requirements

- Windows 10/11 x64 (Administrator PowerShell).
- sing-box 1.14.1 or newer with WireGuard and TUN support. The scripts do not download binaries automatically; install sing-box from the official release page and put it in `PATH` or pass `-SingBoxPath`.
- The official WireGuard Windows client is recommended for Standard WireGuard Mode. Smart Routing itself uses sing-box's endpoint, but the installer reports whether the official client is present.
- The ignored local file `WireGuard/windows.conf` containing the existing Windows peer. It is read locally only and never copied into Git.

## First install

From an elevated PowerShell prompt in the repository root:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\smart-router\scripts\install-windows.ps1
```

If the WireGuard file is stored elsewhere:

```powershell
.\smart-router\scripts\install-windows.ps1 `
  -WireGuardConfigPath 'C:\private\windows.conf' `
  -SingBoxPath 'C:\Program Files\sing-box\sing-box.exe'
```

The installer resolves the WireGuard endpoint's current physical route and writes sing-box's
`bind_interface` into the generated endpoint configuration. To choose it explicitly:

```powershell
.\smart-router\scripts\install-windows.ps1 -BindInterface 'Wi-Fi'
```

This keeps the WireGuard UDP endpoint off the Smart Router TUN and any other VPN route. Re-run
the installer if the physical adapter is renamed or replaced.

The installer generates `smart-router/config/config.windows.json`. That file contains the local peer key and is ignored by Git. It also creates the local rule cache under `smart-router/rules/cache/`.

For the documented Lighthouse deployment, set the ignored Windows peer endpoint to
`43.160.239.253:443`. The server redirects UDP 443 to its unchanged WireGuard listener on UDP
51820, allowing existing standard clients to keep using port 51820.

## Start, stop, and diagnose

```powershell
.\smart-router\scripts\start-windows.ps1
.\smart-router\scripts\diagnose-windows.ps1
.\smart-router\scripts\stop-windows.ps1
```

To start without attempting an update (for an offline run with an existing cache):

```powershell
.\smart-router\scripts\start-windows.ps1 -SkipRuleUpdate
```

To refresh rules independently:

```powershell
.\smart-router\scripts\update-rules.ps1
```

## Rule priority

The route rules are ordered as follows:

1. `custom-proxy` and `custom-direct`; an accidental overlap is resolved as proxy first.
2. The WireGuard endpoint address itself is direct so the handshake cannot loop into the TUN.
3. Private/LAN addresses are direct.
4. Explicit proxy rules and the official non-CN geosite rule-set are proxied.
5. The local direct baseline, official China geosite rule-set, and China IP rule-set are direct.
6. The final route is the WireGuard endpoint.

Edit `rules/custom.json` in the local working tree:

```json
{
  "version": 1,
  "direct": ["intranet.example.cn"],
  "proxy": ["service.example.com"]
}
```

Run `update-rules.ps1` after editing. It regenerates `rules/custom-direct.json` and `rules/custom-proxy.json` and validates downloaded SRS files.

## DNS behavior

The TUN uses sing-box's current `dns_mode: hijack` and `strict_route` behavior on Windows. The DNS policy follows the same domain rule-sets:

- `custom-direct`, the local direct baseline, and the China geosite use `dns-direct` (`223.5.5.5` by default).
- `custom-proxy`, the proxy baseline, the non-CN geosite, and unknown queries use `dns-proxy` (Cloudflare DoH configured to detour through the WireGuard endpoint).

The public Lighthouse server currently documents IPv4 egress. The template keeps IPv6 TUN routes fail-closed for proxy traffic; add server-side IPv6 egress before treating IPv6 as a supported proxy path.

## Fail-safe behavior

- The standard WireGuard server and peer files are not rewritten.
- Smart Router start validates configuration before changing network state.
- A rule download is written to a temporary file and promoted only after SRS decompilation succeeds. A failed update never clears the previous cache.
- If the WireGuard endpoint is down, direct/LAN rules remain direct while proxy traffic fails rather than silently falling back to direct.
- Stopping sing-box lets its TUN cleanup run; the stop script also removes only routes attached to the named `smart-router` adapter if a stale adapter remains.

## Coexistence with third-party VPNs

Smart Router can coexist with a third-party system proxy or VPN. Its WireGuard endpoint is bound
to the physical interface selected during installation. Smart Router does not stop or reconfigure
the third-party product.

`DIRECT` means bypassing the Lighthouse WireGuard path. A third-party system-level VPN or proxy
may still process that connection, so `DIRECT` does not guarantee the ISP's native public egress.

## Windows administrator acceptance

The MVP was exercised on a real Windows administrator PowerShell session on 2026-09-21/22 with sing-box 1.14.1 and the local ignored `WireGuard/windows.conf`:

- The generated configuration passed `sing-box check`; local and downloaded rule-sets loaded, and split DNS returned answers for both China and proxy domains.
- Real HTTPS requests to `baidu.com`, `jd.com`, and `bilibili.com` used the direct path. Real requests to `github.com` and `openai.com` used the WireGuard proxy path; the latter returned an HTTP 403 response from the site, proving the HTTP path was reached.
- Direct and proxy public-IP probes showed different egresses. sing-box logs showed `outbound/direct` for direct traffic and `endpoint/wireguard[wg-lighthouse]` for proxy traffic.
- `127.0.0.1` and the local gateway were reachable. Normal stop, forced process termination, endpoint-failure isolation, and repeated start/stop/start recovery were exercised; endpoint failure kept direct traffic working and made proxy traffic fail without fallback.
- The start script waits for the TUN adapter and retries one transient Windows Wintun adapter collision. Windows reboot and server-side `wg show` counter collection were not performed in this environment.

## Current limitations

- Windows is the implemented MVP target. Android/iOS/macOS adaptation is intentionally left for a later phase.
- No dashboard, account system, node selection, AI classification, or control plane is included.
- The existing server's IPv4-only deployment is preserved. IPv6 proxying needs corresponding server-side routing and firewall support.
