[CmdletBinding()]
param(
    [string]$SingBoxPath,
    [string]$ConfigPath,
    [switch]$SkipRuleUpdate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = $PSScriptRoot
$smartRouterRoot = Split-Path -Parent $scriptRoot
. (Join-Path $scriptRoot 'common.ps1')

try {
    Assert-Administrator
    $singBox = Resolve-SingBoxPath -RequestedPath $SingBoxPath
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $smartRouterRoot 'config\config.windows.json'
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Generated config '$ConfigPath' does not exist. Run install-windows.ps1 first."
    }

    $runningWireGuard = @(Get-RunningWireGuardServices)
    if ($runningWireGuard.Count -gt 0) {
        $names = ($runningWireGuard | ForEach-Object { $_.Name }) -join ', '
        throw "An official full-tunnel WireGuard service is already running ($names). Stop it before starting Smart Routing to avoid two competing full-tunnel interfaces."
    }

    $existing = @(Get-SingBoxProcessesForConfig -ConfigPath $ConfigPath)
    if ($existing.Count -gt 0) {
        Write-Status -Level 'PASS' -Message ("Smart Router is already running (PID {0})." -f (($existing | ForEach-Object { $_.ProcessId }) -join ', '))
        exit 0
    }

    if (-not $SkipRuleUpdate) {
        & (Join-Path $scriptRoot 'update-rules.ps1') -SingBoxPath $singBox
        if ($LASTEXITCODE -ne 0) {
            throw 'Rule update failed and at least one required cache is unavailable. Smart Router was not started.'
        }
    }
    else {
        Write-Status -Level 'WARN' -Message 'Skipped rule update at the user request.'
    }

    $staleAdapter = Get-NetAdapter -Name 'smart-router' -ErrorAction SilentlyContinue
    if ($staleAdapter) {
        throw 'The Smart Router adapter already exists without a matching Smart Router process. Run stop-windows.ps1 and wait for adapter cleanup before starting again.'
    }

    $checkExit = Invoke-SingBoxCheck -SingBoxPath $singBox -WorkingDirectory $smartRouterRoot -ConfigPath $ConfigPath
    if ($checkExit -ne 0) {
        throw 'sing-box config check failed. Smart Router was not started.'
    }
    Write-Status -Level 'PASS' -Message 'sing-box config check passed.'

    $runtimeRoot = Join-Path $smartRouterRoot 'runtime'
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    $stdoutPath = Join-Path $runtimeRoot 'sing-box.stdout.log'
    $stderrPath = Join-Path $runtimeRoot 'sing-box.stderr.log'
    $startArguments = @(
        'run',
        '--disable-color',
        '-D',
        ('"{0}"' -f $smartRouterRoot),
        '-c',
        ('"{0}"' -f ((Resolve-Path -LiteralPath $ConfigPath).Path))
    )
    $process = $null
    $adapter = $null
    $started = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $staleAdapter = Get-NetAdapter -Name 'smart-router' -ErrorAction SilentlyContinue
        if ($staleAdapter) {
            throw 'The Smart Router adapter already exists without a matching Smart Router process. Run stop-windows.ps1 and wait for adapter cleanup before starting again.'
        }

        $process = Start-Process -FilePath $singBox -ArgumentList $startArguments -WorkingDirectory $smartRouterRoot -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -WindowStyle Hidden -PassThru
        $deadline = (Get-Date).AddSeconds(30)
        $adapter = $null
        do {
            Start-Sleep -Milliseconds 500
            $process.Refresh()
            if (-not $process.HasExited) {
                $adapter = Get-NetAdapter -Name 'smart-router' -ErrorAction SilentlyContinue
            }
        } while (-not $process.HasExited -and (-not $adapter -or $adapter.Status -ne 'Up') -and (Get-Date) -lt $deadline)

        $process.Refresh()
        if (-not $process.HasExited -and $adapter -and $adapter.Status -eq 'Up') {
            $started = $true
            break
        }

        $errorTail = if (Test-Path -LiteralPath $stderrPath) { (Get-Content -LiteralPath $stderrPath -Tail 20) -join [Environment]::NewLine } else { '' }
        $transientWindowsTunError = $errorTail -match 'Cannot create a file when that file already exists|Element not found'
        if ($process.HasExited -and $attempt -lt 2 -and $transientWindowsTunError) {
            Write-Status -Level 'WARN' -Message 'Windows TUN creation hit a transient Wintun adapter collision; waiting 20 seconds and retrying once.'
            Start-Sleep -Seconds 20
            continue
        }

        if ($process.HasExited) {
            throw "sing-box exited during startup with code $($process.ExitCode). $errorTail"
        }
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw 'sing-box is running but the Smart Router TUN adapter did not become ready within 30 seconds.'
    }

    if (-not $started) {
        throw 'Smart Router did not become ready after the allowed startup attempts.'
    }

    Write-Status -Level 'PASS' -Message ("Smart Router started (PID {0}). Logs: {1}" -f $process.Id, $runtimeRoot)
    Write-Status -Level 'INFO' -Message 'Run diagnose-windows.ps1 to verify DNS, route policy, endpoint state, and public IP.'
    exit 0
}
catch {
    Write-Status -Level 'FAIL' -Message $_.Exception.Message
    exit 1
}
