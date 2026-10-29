@echo off
chcp 65001 >nul
setlocal
echo Stopping DouYinSparkFlow services...
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { ($_.Name -eq 'python.exe' -or $_.Name -eq 'cmd.exe') -and $_.CommandLine -match 'DouYinSparkFlow' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
timeout /t 3 /nobreak >nul
echo Done. Services stopped.
pause
