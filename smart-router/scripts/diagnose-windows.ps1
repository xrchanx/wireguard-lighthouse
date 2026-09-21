[CmdletBinding()]
param(
    [string]$SingBoxPath,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$scriptRoot = $PSScriptRoot
$smartRouterRoot = Split-Path -Parent $scriptRoot
. (Join-Path $scriptRoot 'common.ps1')

$failures = 0

function Report-Check {
    param(
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$Warning
    )

    if ($Passed) {
        Write-Status -Level 'PASS' -Message $Message
    }
    elseif ($Warning) {
        Write-Status -Level 'WARN' -Message $Message
    }
    else {
        Write-Status -Level 'FAIL' -Message $Message
        $script:failures++
    }
}

function Test-RuleSetMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Format,
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $true)][string]$SingBox
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $matchOutput = & $SingBox rule-set match $Path $Domain -f $Format --disable-color 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    return (-not [string]::IsNullOrWhiteSpace($matchOutput))
}

try {
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $smartRouterRoot 'config\config.windows.json'
    }

    $singBox = $null
    try {
        $singBox = Resolve-SingBoxPath -RequestedPath $SingBoxPath
        Report-Check -Passed $true -Message ("sing-box found: {0}" -f $singBox)
    }
    catch {
        Report-Check -Passed $false -Message $_.Exception.Message
    }

    $processes = @(Get-SingBoxProcessesForConfig -ConfigPath $ConfigPath)
    Report-Check -Passed ($processes.Count -gt 0) -Message 'Smart Router process is running.'

    $adapter = Get-NetAdapter -Name 'smart-router' -ErrorAction SilentlyContinue
    Report-Check -Passed ([bool]$adapter) -Message 'Smart Router TUN adapter is present.'

    $cacheFiles = @(
        'geosite-geolocation-cn.srs',
        'geosite-geolocation-!cn.srs',
        'geoip-cn.srs'
    ) | ForEach-Object { Join-Path $smartRouterRoot ("rules\cache\{0}" -f $_) }
    $cacheMissing = @($cacheFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    Report-Check -Passed ($cacheMissing.Count -eq 0) -Message 'Official China/global rule caches are present.'

    $customFiles = @('custom-direct.json', 'custom-proxy.json', 'direct.json', 'proxy.json') |
        ForEach-Object { Join-Path $smartRouterRoot ("rules\{0}" -f $_) }
    $customMissing = @($customFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    Report-Check -Passed ($customMissing.Count -eq 0) -Message 'Local direct/proxy rule sets are present.'

    try {
        $baidu = Resolve-DnsName -Name 'baidu.com' -ErrorAction Stop
        $github = Resolve-DnsName -Name 'github.com' -ErrorAction Stop
        Report-Check -Passed ($null -ne $baidu -and $null -ne $github) -Message 'DNS resolves both a China and an overseas test domain.'
    }
    catch {
        Report-Check -Passed $false -Message ("DNS resolution failed: {0}" -f $_.Exception.Message)
    }

    try {
        $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 15).ip
        Report-Check -Passed ([bool]$publicIp) -Message ("Current public IP: {0} (Smart Router proxy traffic should match the Lighthouse egress when tested from a proxied destination)." -f $publicIp) -Warning
    }
    catch {
        Report-Check -Passed $false -Message ("Public IP probe failed: {0}" -f $_.Exception.Message) -Warning
    }

    $configuredEndpoint = $null
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        try {
            $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
            $configuredEndpoint = @($config.endpoints | Where-Object { $_.tag -eq 'wg-lighthouse' })[0]
            Report-Check -Passed ([bool]$configuredEndpoint) -Message 'WireGuard endpoint is present in the generated config.'
            if ($configuredEndpoint) {
                $peer = @($configuredEndpoint.peers)[0]
                $endpointIp = $null
                if ([System.Net.IPAddress]::TryParse([string]$peer.address, [ref]$endpointIp)) {
                    Report-Check -Passed $true -Message ("WireGuard endpoint IP is configured: {0}:{1}. UDP handshake still requires a live peer." -f $peer.address, $peer.port) -Warning
                }
                else {
                    $resolved = Resolve-DnsName -Name ([string]$peer.address) -ErrorAction Stop
                    Report-Check -Passed ($null -ne $resolved) -Message ("WireGuard endpoint address resolves: {0}:{1}. UDP handshake still requires a live peer." -f $peer.address, $peer.port) -Warning
                }
            }
        }
        catch {
            Report-Check -Passed $false -Message ("WireGuard endpoint diagnostic failed: {0}" -f $_.Exception.Message) -Warning
        }
    }
    else {
        Report-Check -Passed $false -Message 'Generated Smart Router config is missing.'
    }

    if ($singBox) {
        $routeTests = @(
            [pscustomobject]@{ Domain = 'baidu.com'; Expected = 'DIRECT' },
            [pscustomobject]@{ Domain = 'github.com'; Expected = 'PROXY' },
            [pscustomobject]@{ Domain = 'openai.com'; Expected = 'PROXY' }
        )
        $directRule = Join-Path $smartRouterRoot 'rules\direct.json'
        $proxyRule = Join-Path $smartRouterRoot 'rules\proxy.json'
        $cnRule = Join-Path $smartRouterRoot 'rules\cache\geosite-geolocation-cn.srs'
        $overseasRule = Join-Path $smartRouterRoot 'rules\cache\geosite-geolocation-!cn.srs'
        foreach ($test in $routeTests) {
            $direct = (Test-RuleSetMatch -Path $directRule -Format 'source' -Domain $test.Domain -SingBox $singBox) -or (Test-RuleSetMatch -Path $cnRule -Format 'binary' -Domain $test.Domain -SingBox $singBox)
            $proxy = (Test-RuleSetMatch -Path $proxyRule -Format 'source' -Domain $test.Domain -SingBox $singBox) -or (Test-RuleSetMatch -Path $overseasRule -Format 'binary' -Domain $test.Domain -SingBox $singBox)
            $decision = if ($proxy) { 'PROXY' } elseif ($direct) { 'DIRECT' } else { 'PROXY' }
            Report-Check -Passed ($decision -eq $test.Expected) -Message ("{0} -> {1}" -f $test.Domain, $decision)
        }
    }

    if ($failures -gt 0) {
        Write-Status -Level 'FAIL' -Message ("Diagnostics completed with {0} failure(s)." -f $failures)
        exit 1
    }
    Write-Status -Level 'PASS' -Message 'Diagnostics completed.'
    exit 0
}
catch {
    Write-Status -Level 'FAIL' -Message $_.Exception.Message
    exit 1
}
