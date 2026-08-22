<#
.SYNOPSIS
    Build the Windows portable (green) distribution of DouYin SparkFlow.

.DESCRIPTION
    Steps:
      1. PyInstaller onedir build (3 exe: sparkflow / login-desktop / cron-runner)
      2. Node SEA single-file protocol sender (protocol-sender.exe)
      3. Assemble the portable tree DouYinSparkFlow-win64/ (app/ + chrome/ + node/
         + start.bat / stop.bat / README.md)
      4. Zip it (unless -SkipZip)

    Build-machine layout (portable, no system installs required):
      <parent of this repo>/        e.g. C:\build
        douyin-sparkflow-main/      this repository
        .tools/python-full/         full CPython 3.12 (nuget package)
        .tools/browsers/            playwright chromium installs
        .tools/postject/            postject npm tarball (unpacked)
        .tools/portable/            build output (DouYinSparkFlow-win64 + zip)

.PARAMETER WorkRoot
    Output root (default <repo parent>\.tools\portable).

.PARAMETER ToolsRoot
    Build-tools root (default <repo parent>\.tools).

.PARAMETER SkipZip
    Skip Compress-Archive step.
#>
param(
    [string]$WorkRoot = "",
    [string]$ToolsRoot = "",
    [switch]$SkipZip
)

$ErrorActionPreference = "Stop"

$proj = Resolve-Path (Join-Path $PSScriptRoot "..")
if (-not $ToolsRoot) { $ToolsRoot = Join-Path (Split-Path $proj -Parent) ".tools" }
if (-not $WorkRoot) { $WorkRoot = Join-Path $ToolsRoot "portable" }
$appSrc = Join-Path $proj "DouYinSparkFlow"
$py = Join-Path $ToolsRoot "python-full\tools\python.exe"
$browsers = Join-Path $ToolsRoot "browsers"
$tmp = Join-Path $ToolsRoot "tmp"

$env:TMP = $tmp
$env:TEMP = $tmp
$env:PIP_DISABLE_PIP_VERSION_CHECK = "1"

if (-not (Test-Path $py)) { throw "build python not found: $py" }

# 1. PyInstaller onedir build -------------------------------------------------
Write-Host "[1/4] PyInstaller onedir build..."
if (Test-Path $WorkRoot) { Remove-Item $WorkRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $WorkRoot "dist") | Out-Null

Push-Location $proj
try {
    & $py -m PyInstaller --clean --noconfirm `
        --workpath (Join-Path $WorkRoot "build") `
        --distpath (Join-Path $WorkRoot "dist") `
        (Join-Path $proj "build\portable.spec")
    if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed rc=$LASTEXITCODE" }
}
finally { Pop-Location }

# 2. Node SEA single-file protocol sender -------------------------------------
# Uses build/sea-prep.js (mechanical ESM->CJS for the 4 builtin imports) and
# Node's own SEA machinery -- no esbuild/npm needed. postject injects the
# blob; it is resolved from the workspace .tools copy (this repo's build
# machine) or from PATH when unavailable.
Write-Host "[2/4] Node SEA protocol-sender.exe..."
$seaDir = Join-Path $WorkRoot "sea"
New-Item -ItemType Directory -Force -Path $seaDir | Out-Null

& node (Join-Path $proj "build\sea-prep.js") (Join-Path $appSrc "core\protocol_sender.mjs") $seaDir
if ($LASTEXITCODE -ne 0) { throw "sea-prep failed rc=$LASTEXITCODE" }

& node --experimental-sea-config (Join-Path $seaDir "sea-config.json")
if ($LASTEXITCODE -ne 0) { throw "sea-config failed rc=$LASTEXITCODE" }

$nodeExe = (Get-Command node).Source
if (-not $nodeExe) { throw "node.exe not found; Node.js 20.19+/22.12+ is required for the SEA build" }
Copy-Item $nodeExe (Join-Path $seaDir "protocol-sender.exe")

$postjectCli = Join-Path $ToolsRoot "postject\package\dist\cli.js"
$fuse = "NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2"
if (Test-Path $postjectCli) {
    & node $postjectCli (Join-Path $seaDir "protocol-sender.exe") NODE_SEA_BLOB `
        (Join-Path $seaDir "sea-prep.blob") --sentinel-fuse $fuse
    if ($LASTEXITCODE -ne 0) { throw "postject failed rc=$LASTEXITCODE" }
} else {
    Write-Host "[warn] postject not found at $postjectCli; falling back to npx"
    & npm.cmd exec --yes postject@1.0.0-alpha.6 (Join-Path $seaDir "protocol-sender.exe") NODE_SEA_BLOB `
        (Join-Path $seaDir "sea-prep.blob") --sentinel-fuse $fuse
    if ($LASTEXITCODE -ne 0) { throw "postject (npx) failed rc=$LASTEXITCODE" }
}

# 3. Assemble portable tree ---------------------------------------------------
Write-Host "[3/4] Assembling DouYinSparkFlow-win64..."
$root = Join-Path $WorkRoot "DouYinSparkFlow-win64"
New-Item -ItemType Directory -Force -Path $root | Out-Null

# app/
Copy-Item (Join-Path $WorkRoot "dist\app") (Join-Path $root "app") -Recurse

# chrome/ (playwright browsers with versioned subdirs, trimmed locales)
New-Item -ItemType Directory -Force -Path (Join-Path $root "chrome") | Out-Null
Copy-Item (Join-Path $browsers "chromium-1194") (Join-Path $root "chrome\chromium-1194") -Recurse
Copy-Item (Join-Path $browsers "chromium_headless_shell-1194") (Join-Path $root "chrome\chromium_headless_shell-1194") -Recurse
Get-ChildItem (Join-Path $root "chrome\chromium-1194\chrome-win\locales") -Filter "*.pak" |
    Where-Object { $_.BaseName -notin @("zh-CN", "en-US") } | Remove-Item

# node/
New-Item -ItemType Directory -Force -Path (Join-Path $root "node") | Out-Null
Copy-Item (Join-Path $seaDir "protocol-sender.exe") (Join-Path $root "node\protocol-sender.exe")

# start.bat / stop.bat / README.txt
@"
@echo off
setlocal
set "ROOT=%~dp0"
set "APP=%ROOT%app"
set "PLAYWRIGHT_BROWSERS_PATH=%ROOT%chrome"
set "SPARKFLOW_NODE_BIN=%ROOT%node\protocol-sender.exe"
set "SPARKFLOW_BROWSER_PROFILE_ROOT=%APP%\state\browser-profiles"
set "LOGIN_DESKTOP_PROFILE_DIR=%APP%\state\login-profile"
if not exist "%APP%\state\cron" mkdir "%APP%\state\cron"
start "sparkflow-scheduler" /min "%APP%\cron-runner.exe" "%APP%\state\cron\root"
start "sparkflow-login-desktop" /min "%APP%\login-desktop.exe"
echo DouYin SparkFlow admin UI: http://127.0.0.1:8787  (Ctrl+C to stop)
"%APP%\sparkflow.exe" --web --host 127.0.0.1 --port 8787
"@ | Set-Content (Join-Path $root "start.bat") -Encoding ascii

@"
@echo off
taskkill /IM login-desktop.exe /F 2>nul
taskkill /IM cron-runner.exe /F 2>nul
taskkill /IM sparkflow.exe /F 2>nul
echo Stopped.
"@ | Set-Content (Join-Path $root "stop.bat") -Encoding ascii

# README (portable-README.md in build/)
Copy-Item (Join-Path $proj "build\portable-README.md") (Join-Path $root "README.md") -Force

# 4. Zip ---------------------------------------------------------------------
if (-not $SkipZip) {
    Write-Host "[4/4] Compressing..."
    Compress-Archive -Path (Join-Path $root "*") -DestinationPath (Join-Path $WorkRoot "DouYinSparkFlow-win64.zip") -CompressionLevel Optimal
}

Write-Host ""
Write-Host "DONE: $root"
if (-not $SkipZip) {
    $zip = Get-Item (Join-Path $WorkRoot "DouYinSparkFlow-win64.zip")
    Write-Host ("zip: {0} ({1:N1} MB)" -f $zip.FullName, ($zip.Length / 1MB))
}
