[CmdletBinding()]
param(
    [string]$SingBoxPath,
    [string]$WireGuardConfigPath,
    [switch]$SkipRuleUpdate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = $PSScriptRoot
$smartRouterRoot = Split-Path -Parent $scriptRoot
$repoRoot = Split-Path -Parent $smartRouterRoot
. (Join-Path $scriptRoot 'common.ps1')

function Read-WireGuardConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sections = [ordered]@{}
    $currentSection = $null
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) {
            continue
        }
        if ($trimmed -match '^\[(?<section>[^\]]+)\]$') {
            $currentSection = $Matches.section.ToLowerInvariant()
            if (-not $sections.Contains($currentSection)) {
                $sections[$currentSection] = [ordered]@{}
            }
            continue
        }
        if (-not $currentSection -or $trimmed -notmatch '^(?<key>[^=]+)=(?<value>.*)$') {
            continue
        }
        $key = $Matches.key.Trim().ToLowerInvariant()
        $value = $Matches.value.Trim()
        $sections[$currentSection][$key] = $value
    }

    if (-not $sections.Contains('interface') -or -not $sections['interface'].Contains('privatekey')) {
        throw 'The WireGuard config must contain [Interface] PrivateKey and Address.'
    }
    if (-not $sections['interface'].Contains('address')) {
        throw 'The WireGuard config is missing [Interface] Address.'
    }
    if (-not $sections.Contains('peer') -or -not $sections['peer'].Contains('publickey')) {
        throw 'The WireGuard config must contain a [Peer] PublicKey.'
    }
    foreach ($requiredPeerKey in @('endpoint', 'allowedips')) {
        if (-not $sections['peer'].Contains($requiredPeerKey)) {
            throw "The WireGuard config is missing [Peer] $requiredPeerKey."
        }
    }

    return $sections
}

function Get-EndpointParts {
    param([Parameter(Mandatory = $true)][string]$Endpoint)

    if ($Endpoint -match '^\[(?<host>[^\]]+)\]:(?<port>\d+)$') {
        return [pscustomobject]@{ Host = $Matches.host; Port = [int]$Matches.port }
    }
    if ($Endpoint -match '^(?<host>[^:]+):(?<port>\d+)$') {
        return [pscustomobject]@{ Host = $Matches.host; Port = [int]$Matches.port }
    }
    throw "Unsupported WireGuard Endpoint '$Endpoint'. Use host:port or [ipv6]:port."
}

function Assert-UsableSecretValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if (-not $Value -or $Value.StartsWith('<') -or $Value.EndsWith('>')) {
        throw "The local WireGuard config contains a placeholder or empty $Name."
    }
}

try {
    Assert-Administrator
    $singBox = Resolve-SingBoxPath -RequestedPath $SingBoxPath
    if (-not $WireGuardConfigPath) {
        $WireGuardConfigPath = Join-Path $repoRoot 'WireGuard\windows.conf'
    }
    if (-not (Test-Path -LiteralPath $WireGuardConfigPath -PathType Leaf)) {
        throw "The real local Windows peer config was not found at '$WireGuardConfigPath'. It is intentionally ignored by Git; provide it locally or pass -WireGuardConfigPath."
    }

    $wireGuard = Read-WireGuardConfig -Path $WireGuardConfigPath
    $interface = $wireGuard['interface']
    $peer = $wireGuard['peer']
    $privateKey = $interface['privatekey']
    $serverPublicKey = $peer['publickey']
    Assert-UsableSecretValue -Name 'PrivateKey' -Value $privateKey
    Assert-UsableSecretValue -Name 'PublicKey' -Value $serverPublicKey

    $clientAddress = @($interface['address'] -split '\s*,\s*' | Where-Object { $_ })[0]
    if (-not $clientAddress) {
        throw 'No usable client Address was found in the local WireGuard config.'
    }
    $endpoint = Get-EndpointParts -Endpoint $peer['endpoint']
    $allowedIps = @($peer['allowedips'] -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($allowedIps.Count -eq 0) {
        throw 'No AllowedIPs were found in the local WireGuard config.'
    }

    $templatePath = Join-Path $smartRouterRoot 'config\config.windows.example.json'
    $generatedPath = Join-Path $smartRouterRoot 'config\config.windows.json'
    $config = Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json

    $wgEndpoint = @($config.endpoints | Where-Object { $_.tag -eq 'wg-lighthouse' })[0]
    if (-not $wgEndpoint) {
        throw 'The Smart Router template does not contain the wg-lighthouse endpoint.'
    }
    $wgPeer = @($wgEndpoint.peers)[0]
    $wgEndpoint.address = @($clientAddress)
    $wgEndpoint.private_key = $privateKey
    $wgPeer.address = $endpoint.Host
    $wgPeer.port = $endpoint.Port
    $wgPeer.public_key = $serverPublicKey
    $wgPeer.allowed_ips = $allowedIps

    if ($peer.Contains('presharedkey') -and $peer['presharedkey']) {
        Assert-UsableSecretValue -Name 'PresharedKey' -Value $peer['presharedkey']
        $wgPeer | Add-Member -NotePropertyName 'pre_shared_key' -NotePropertyValue $peer['presharedkey'] -Force
    }
    elseif ($wgPeer.PSObject.Properties['pre_shared_key']) {
        $wgPeer.PSObject.Properties.Remove('pre_shared_key')
    }

    $endpointIp = $null
    $endpointIsIp = [System.Net.IPAddress]::TryParse($endpoint.Host, [ref]$endpointIp)
    $endpointRule = @($config.route.rules)[0]
    if ($endpointIsIp) {
        $endpointPrefix = if ($endpointIp.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { "$($endpoint.Host)/32" } else { "$($endpoint.Host)/128" }
        $endpointRule.ip_cidr = @($endpointPrefix)
        if ($endpointRule.PSObject.Properties['domain']) {
            $endpointRule.PSObject.Properties.Remove('domain')
        }
        $tun = @($config.inbounds | Where-Object { $_.tag -eq 'tun-smart-router' })[0]
        if ($tun -and $tun.route_exclude_address -notcontains $endpointPrefix) {
            $tun.route_exclude_address = @($tun.route_exclude_address) + $endpointPrefix
        }
    }
    else {
        $endpointRule.PSObject.Properties.Remove('ip_cidr')
        $endpointRule | Add-Member -NotePropertyName 'domain' -NotePropertyValue @($endpoint.Host) -Force
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $generatedPath) -Force | Out-Null
    $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $generatedPath -Encoding UTF8
    Write-Status -Level 'PASS' -Message 'Generated the ignored Smart Router config from the local WireGuard peer without printing key material.'

    $wireGuardPath = Resolve-WireGuardPath
    if ($wireGuardPath) {
        Write-Status -Level 'PASS' -Message ("Official WireGuard client found at {0}." -f $wireGuardPath)
    }
    else {
        Write-Status -Level 'WARN' -Message 'Official WireGuard client was not found. Smart Routing uses sing-box directly; Standard WireGuard Mode still requires the official client.'
    }

    if (-not $SkipRuleUpdate) {
        & (Join-Path $scriptRoot 'update-rules.ps1') -SingBoxPath $singBox
        if ($LASTEXITCODE -ne 0) {
            throw 'Rule update did not produce a complete usable cache. The generated config was not started.'
        }
    }
    else {
        Write-Status -Level 'WARN' -Message 'Skipped rule update at the user request.'
    }

    $checkExit = Invoke-SingBoxCheck -SingBoxPath $singBox -WorkingDirectory $smartRouterRoot -ConfigPath $generatedPath
    if ($checkExit -ne 0) {
        throw 'sing-box config check failed. Inspect the output above; no Smart Router process was started.'
    }
    Write-Status -Level 'PASS' -Message 'Generated Smart Router config passed sing-box check.'
    Write-Status -Level 'INFO' -Message 'Run start-windows.ps1 to activate Smart Routing. Do not run the official Windows full-tunnel peer at the same time.'
    exit 0
}
catch {
    Write-Status -Level 'FAIL' -Message $_.Exception.Message
    exit 1
}
