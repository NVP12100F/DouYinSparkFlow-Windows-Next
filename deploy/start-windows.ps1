<#
.SYNOPSIS
    Start DouYin SparkFlow natively on Windows (no Docker / WSL2 required).

.DESCRIPTION
    Boots the three Windows Native runtime pieces from source:
      1. scheduler   - scripts/cron_runner.py (pure-Python crontab reader)
      2. login-desktop - login_desktop_server.py (headful Chromium login window
                        replacing the X11/noVNC container)
      3. web         - main.py --web (foreground admin UI)

    The schedule spool (state/cron/root) is generated from config.json by the
    app itself when missing.

.PARAMETER SkipScheduler
    Do not start the background scheduler.

.PARAMETER SkipLoginDesktop
    Do not start the background login-desktop service (scan QR via the CLI
    login menu instead).

.PARAMETER WebHost
    Web UI bind host (default 127.0.0.1; use 0.0.0.0 for LAN access).

.PARAMETER WebPort
    Web UI port (default 8787).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File deploy/start-windows.ps1
#>
param(
    [switch]$SkipScheduler,
    [switch]$SkipLoginDesktop,
    [string]$WebHost = "127.0.0.1",
    [int]$WebPort = 8787
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$appRoot = Join-Path $repoRoot "DouYinSparkFlow"
if (-not (Test-Path (Join-Path $appRoot "main.py"))) {
    throw "DouYinSparkFlow source not found under $appRoot"
}

$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) {
    throw "Python is required. Install Python 3.9+ and make sure 'python' is on PATH."
}
# Reject the Microsoft Store stub (python.exe that only opens the Store).
& $python --version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "The 'python' on PATH is not runnable: $python. Install Python 3.9+ from python.org and re-run (or put a real python.exe earlier on PATH)."
}

Set-Location $appRoot

# 1. runtime directories
foreach ($d in @("logs", "state\cron", "state\login-profile", "state\browser-profiles")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $appRoot $d) | Out-Null
}

# 2. schedule spool (generated from config.json's dailySendWindow)
$cronSpool = Join-Path $appRoot "state\cron\root"
if (-not (Test-Path $cronSpool)) {
    Write-Host "[setup] generating schedule spool from config..."
    & $python -c "import sys; from webui.ops import sync_daily_schedule_from_config; r = sync_daily_schedule_from_config(); sys.exit(0 if r.returncode == 0 else 1)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[warn] could not pre-generate schedule spool; the web app will sync it on startup"
    }
}

# 3. scheduler (background)
if (-not $SkipScheduler) {
    $schedOut = Join-Path $appRoot "logs\scheduler.log"
    $schedErr = Join-Path $appRoot "logs\scheduler.err.log"
    Start-Process -FilePath $python -ArgumentList @("scripts\cron_runner.py", $cronSpool) `
        -WorkingDirectory $appRoot -WindowStyle Hidden `
        -RedirectStandardOutput $schedOut -RedirectStandardError $schedErr
    Write-Host "[scheduler] started (cron_runner.py watching state\cron\root) -> logs\scheduler.log"
}

# 4. login desktop (background)
if (-not $SkipLoginDesktop) {
    $ldOut = Join-Path $appRoot "logs\login_desktop.log"
    $ldErr = Join-Path $appRoot "logs\login_desktop.err.log"
    $env:LOGIN_DESKTOP_API_PORT = "18090"
    Start-Process -FilePath $python -ArgumentList @("login_desktop_server.py") `
        -WorkingDirectory $appRoot -WindowStyle Hidden `
        -RedirectStandardOutput $ldOut -RedirectStandardError $ldErr
    Write-Host "[login-desktop] started (http://127.0.0.1:18090) -> logs\login_desktop.log"
}

# 5. web UI (foreground)
Write-Host ""
Write-Host "[web] admin UI: http://$WebHost`:$WebPort  (press Ctrl+C to stop)"
& $python main.py --web --host $WebHost --port $WebPort
