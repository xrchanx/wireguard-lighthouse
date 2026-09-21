[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = $PSScriptRoot
$smartRouterRoot = Split-Path -Parent $scriptRoot
. (Join-Path $scriptRoot 'common.ps1')

try {
    Assert-Administrator
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $smartRouterRoot 'config\config.windows.json'
    }

    $processes = @(Get-SingBoxProcessesForConfig -ConfigPath $ConfigPath)
    if ($processes.Count -eq 0) {
        Write-Status -Level 'INFO' -Message 'No Smart Router process matched the generated config.'
    }
    else {
        foreach ($process in $processes) {
            Write-Status -Level 'INFO' -Message ("Stopping Smart Router PID {0}." -f $process.ProcessId)
            Stop-Process -Id ([int]$process.ProcessId) -ErrorAction Stop
        }
        $deadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 250
            $remaining = @(Get-SingBoxProcessesForConfig -ConfigPath $ConfigPath)
        } while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)

        if ($remaining.Count -gt 0) {
            foreach ($process in $remaining) {
                Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
            }
            Write-Status -Level 'WARN' -Message 'A matching process required a force stop; inspect the runtime logs if the adapter remains.'
        }
        else {
            Write-Status -Level 'PASS' -Message 'Smart Router process stopped.'
        }
    }

    $adapter = Get-NetAdapter -Name 'smart-router' -ErrorAction SilentlyContinue
    if ($adapter) {
        $ownedPrefixes = @(
            '0.0.0.0/1',
            '128.0.0.0/1',
            '::/1',
            '8000::/1',
            '172.19.0.0/30',
            'fdfe:dcba:9876::/126'
        )
        $staleRoutes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue |
            Where-Object { $ownedPrefixes -contains $_.DestinationPrefix })
        foreach ($route in $staleRoutes) {
            Remove-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix $route.DestinationPrefix -NextHop $route.NextHop -PolicyStore $route.PolicyStore -Confirm:$false -ErrorAction SilentlyContinue
        }
        if ($staleRoutes.Count -gt 0) {
            Write-Status -Level 'PASS' -Message ("Removed {0} stale route(s) attached to the Smart Router adapter." -f $staleRoutes.Count)
        }
        else {
            Write-Status -Level 'INFO' -Message 'No stale Smart Router routes were found.'
        }
    }
    else {
        Write-Status -Level 'PASS' -Message 'The Smart Router adapter is not present; normal networking should be restored.'
    }

    exit 0
}
catch {
    Write-Status -Level 'FAIL' -Message $_.Exception.Message
    exit 1
}
