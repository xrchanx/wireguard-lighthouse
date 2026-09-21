[CmdletBinding()]
param(
    [string]$SingBoxPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = $PSScriptRoot
$smartRouterRoot = Split-Path -Parent $scriptRoot
. (Join-Path $scriptRoot 'common.ps1')

try {
    $singBox = Resolve-SingBoxPath -RequestedPath $SingBoxPath
    $cacheRoot = Join-Path $smartRouterRoot 'rules\cache'
    $rulesRoot = Join-Path $smartRouterRoot 'rules'
    $lockPath = Join-Path $smartRouterRoot 'rules.lock.json'
    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null

    $sources = @(
        [pscustomobject]@{
            Name = 'geosite-geolocation-cn'
            Url = 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs'
            FileName = 'geosite-geolocation-cn.srs'
        },
        [pscustomobject]@{
            Name = 'geosite-geolocation-!cn'
            Url = 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs'
            FileName = 'geosite-geolocation-!cn.srs'
        },
        [pscustomobject]@{
            Name = 'geoip-cn'
            Url = 'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs'
            FileName = 'geoip-cn.srs'
        }
    )

    function Write-JsonAtomic {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)]$Value
        )

        $temporaryPath = Join-Path (Split-Path -Parent $Path) ((Split-Path -Leaf $Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
            Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
        }
        finally {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    function Convert-CustomEntry {
        param(
            [Parameter(Mandatory = $true)][object[]]$Entries
        )

        $domains = New-Object System.Collections.Generic.List[string]
        $exactDomains = New-Object System.Collections.Generic.List[string]
        $ipCidrs = New-Object System.Collections.Generic.List[string]

        foreach ($entry in $Entries) {
            $value = ([string]$entry).Trim().ToLowerInvariant()
            if (-not $value) {
                continue
            }

            if ($value.StartsWith('=')) {
                $exactValue = $value.Substring(1).Trim()
                if ($exactValue) {
                    $exactDomains.Add($exactValue)
                }
                continue
            }

            $parsedAddress = $null
            if ($value.Contains('/') -or [System.Net.IPAddress]::TryParse($value, [ref]$parsedAddress)) {
                $ipCidrs.Add($value)
            }
            else {
                $domains.Add($value.TrimStart('.'))
            }
        }

        $rule = [ordered]@{}
        if ($domains.Count -gt 0) {
            $rule.domain_suffix = @($domains)
        }
        if ($exactDomains.Count -gt 0) {
            $rule.domain = @($exactDomains)
        }
        if ($ipCidrs.Count -gt 0) {
            $rule.ip_cidr = @($ipCidrs)
        }

        if ($rule.Count -eq 0) {
            return @()
        }
        return @([pscustomobject]$rule)
    }

    function Update-CustomRuleSets {
        $manifestPath = Join-Path $rulesRoot 'custom.json'
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        $directEntries = @($manifest.direct)
        $proxyEntries = @($manifest.proxy)

        $directRuleSet = [ordered]@{
            version = 5
            rules = @(Convert-CustomEntry -Entries $directEntries)
        }
        $proxyRuleSet = [ordered]@{
            version = 5
            rules = @(Convert-CustomEntry -Entries $proxyEntries)
        }

        Write-JsonAtomic -Path (Join-Path $rulesRoot 'custom-direct.json') -Value $directRuleSet
        Write-JsonAtomic -Path (Join-Path $rulesRoot 'custom-proxy.json') -Value $proxyRuleSet
        Write-Status -Level 'PASS' -Message 'Custom rule sets regenerated from rules/custom.json.'
    }

    Update-CustomRuleSets

    $existingLock = [ordered]@{
        schema_version = 1
        generated_at = $null
        sources = [ordered]@{}
    }
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        $loadedLock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
        if ($loadedLock.schema_version) {
            $existingLock.schema_version = $loadedLock.schema_version
        }
        if ($loadedLock.sources) {
            foreach ($property in $loadedLock.sources.PSObject.Properties) {
                $existingLock.sources[$property.Name] = [ordered]@{
                    url = [string]$property.Value.url
                    updated_at = $property.Value.updated_at
                    bytes = $property.Value.bytes
                    sha256 = $property.Value.sha256
                }
            }
        }
    }

    $updatedAny = $false
    $missingAfterFailure = $false
    $headers = @{ 'User-Agent' = 'wireguard-lighthouse-smart-router' }

    foreach ($source in $sources) {
        $targetPath = Join-Path $cacheRoot $source.FileName
        $temporaryPath = Join-Path $cacheRoot ('.' + $source.FileName + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $decompiledPath = Join-Path $cacheRoot ('.' + $source.FileName + '.' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            Write-Status -Level 'INFO' -Message ("Downloading {0}" -f $source.Name)
            Invoke-WebRequest -Uri $source.Url -Headers $headers -OutFile $temporaryPath -TimeoutSec 90
            $downloadedFile = Get-Item -LiteralPath $temporaryPath
            if ($downloadedFile.Length -lt 1024) {
                throw 'Downloaded file is unexpectedly small.'
            }

            & $singBox rule-set decompile $temporaryPath --output $decompiledPath --disable-color 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $decompiledPath -PathType Leaf)) {
                throw 'sing-box rule-set decompile validation failed.'
            }

            $hash = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
            Move-Item -LiteralPath $temporaryPath -Destination $targetPath -Force

            $existingLock.sources[$source.Name] = [ordered]@{
                url = $source.Url
                updated_at = (Get-Date).ToUniversalTime().ToString('o')
                bytes = $downloadedFile.Length
                sha256 = $hash
            }
            $updatedAny = $true
            Write-Status -Level 'PASS' -Message ("{0} validated and installed ({1} bytes)." -f $source.Name, $downloadedFile.Length)
        }
        catch {
            if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
                Write-Status -Level 'WARN' -Message ("{0} update failed; keeping the previous cache. {1}" -f $source.Name, $_.Exception.Message)
            }
            else {
                $missingAfterFailure = $true
                Write-Status -Level 'FAIL' -Message ("{0} update failed and no previous cache exists. {1}" -f $source.Name, $_.Exception.Message)
            }
        }
        finally {
            foreach ($temporaryArtifact in @($temporaryPath, $decompiledPath)) {
                if (Test-Path -LiteralPath $temporaryArtifact) {
                    Remove-Item -LiteralPath $temporaryArtifact -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if ($updatedAny) {
        $existingLock.generated_at = (Get-Date).ToUniversalTime().ToString('o')
        Write-JsonAtomic -Path $lockPath -Value $existingLock
        Write-Status -Level 'PASS' -Message 'rules.lock.json updated with source metadata and SHA-256 checksums.'
    }
    elseif (-not $missingAfterFailure) {
        Write-Status -Level 'WARN' -Message 'No upstream rule changed; existing lock and caches remain in use.'
    }

    if ($missingAfterFailure) {
        exit 1
    }
    exit 0
}
catch {
    Write-Status -Level 'FAIL' -Message $_.Exception.Message
    exit 1
}
