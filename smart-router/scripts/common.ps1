Set-StrictMode -Version Latest

function Write-Status {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Write-Host ("[{0}] {1}" -f $Level.ToUpperInvariant(), $Message)
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator privileges are required. Open PowerShell as Administrator and retry.'
    }
}

function Get-SmartRouterRoot {
    param([Parameter(Mandatory = $true)][string]$ScriptRoot)
    return (Split-Path -Parent $ScriptRoot)
}

function Resolve-SingBoxPath {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
            throw "sing-box was not found at '$RequestedPath'."
        }
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $command = Get-Command sing-box.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        'C:\Program Files\sing-box\sing-box.exe',
        'C:\Program Files (x86)\sing-box\sing-box.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\sing-box\sing-box.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'sing-box was not found. Install the official sing-box Windows binary or pass -SingBoxPath.'
}

function Resolve-WireGuardPath {
    $command = Get-Command wireguard.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        'C:\Program Files\WireGuard\wireguard.exe',
        'C:\Program Files (x86)\WireGuard\wireguard.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Get-RunningWireGuardServices {
    return @(Get-Service -Name 'WireGuardTunnel$*' -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
}

function Get-SingBoxProcessesForConfig {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return @()
    }

    $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    return @(Get-CimInstance Win32_Process -Filter "Name = 'sing-box.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and $_.CommandLine.IndexOf($resolvedConfigPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        })
}

function Invoke-SingBoxCheck {
    param(
        [Parameter(Mandatory = $true)][string]$SingBoxPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    & $SingBoxPath check --disable-color -D $WorkingDirectory -c $ConfigPath
    return $LASTEXITCODE
}
