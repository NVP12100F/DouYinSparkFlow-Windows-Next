@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0DouYinSparkFlow"
set "PYEXE=%~dp0DouYinSparkFlow\.venv\Scripts\python.exe"
if not exist "%PYEXE%" ( exit /b 1 )

rem ---- runtime dirs ----
if not exist "logs" mkdir "logs"
if not exist "state\cron" mkdir "state\cron"
if not exist "state\login-profile" mkdir "state\login-profile"
if not exist "state\browser-profiles" mkdir "state\browser-profiles"

rem ---- generate cron file if missing ----
if not exist "state\cron\root" (
    "%PYEXE%" -c "import sys; from webui.ops import sync_daily_schedule_from_config; r=sync_daily_schedule_from_config(); sys.exit(0 if r.returncode==0 else 1)" >nul 2>&1
)

rem ---- start services if not running ----
netstat -ano | findstr /r /c:":8787 .*LISTENING" >nul 2>&1
if errorlevel 1 start "DouYin-Web" /min "%PYEXE%" main.py --web --host 127.0.0.1 --port 8787

netstat -ano | findstr /r /c:":18090 .*LISTENING" >nul 2>&1
if errorlevel 1 start "DouYin-LoginDesktop" /min "%PYEXE%" login_desktop_server.py

powershell -NoProfile -Command "$p = Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object { $_.CommandLine -match 'cron_runner' }; if (-not $p) { Start-Process -FilePath '%PYEXE%' -ArgumentList @('scripts\cron_runner.py', '%~dp0DouYinSparkFlow\state\cron\root') -WorkingDirectory '%~dp0DouYinSparkFlow' -WindowStyle Hidden }"

rem ---- watchdog: check every 20s, restart dead services ----
:watchdog
timeout /t 20 /nobreak >nul
netstat -ano | findstr /r /c:":8787 .*LISTENING" >nul 2>&1
if errorlevel 1 start "DouYin-Web" /min "%PYEXE%" main.py --web --host 127.0.0.1 --port 8787
netstat -ano | findstr /r /c:":18090 .*LISTENING" >nul 2>&1
if errorlevel 1 start "DouYin-LoginDesktop" /min "%PYEXE%" login_desktop_server.py
powershell -NoProfile -Command "$p = Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object { $_.CommandLine -match 'cron_runner' }; if (-not $p) { Start-Process -FilePath '%PYEXE%' -ArgumentList @('scripts\cron_runner.py', '%~dp0DouYinSparkFlow\state\cron\root') -WorkingDirectory '%~dp0DouYinSparkFlow' -WindowStyle Hidden }"
goto watchdog
