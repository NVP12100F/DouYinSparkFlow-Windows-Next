@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0DouYinSparkFlow"
set "PYEXE=%~dp0DouYinSparkFlow\.venv\Scripts\python.exe"
if not exist "%PYEXE%" (
    echo [错误] 未找到虚拟环境 .venv，请先完成安装。
    pause
    exit /b 1
)

rem ---- 运行时目录 ----
if not exist "logs" mkdir "logs"
if not exist "state\cron" mkdir "state\cron"
if not exist "state\login-profile" mkdir "state\login-profile"
if not exist "state\browser-profiles" mkdir "state\browser-profiles"

rem ---- 调度文件（缺失时自动生成）----
if not exist "state\cron\root" (
    "%PYEXE%" -c "import sys; from webui.ops import sync_daily_schedule_from_config; r=sync_daily_schedule_from_config(); sys.exit(0 if r.returncode==0 else 1)" >nul 2>&1
)

rem ---- 防重复启动：Web 端口已被占用则提示退出 ----
netstat -ano | findstr /r /c:":8787 .*LISTENING" >nul 2>&1
if %errorlevel%==0 (
    echo [提示] Web 管理界面已在运行，请直接访问 http://127.0.0.1:8787
    echo 如果界面打不开，请先在任务管理器中结束残留的 python 进程再重试。
    pause
    exit /b 0
)

rem ---- 防重复启动：登录服务端口已被占用则跳过 ----
netstat -ano | findstr /r /c:":18090 .*LISTENING" >nul 2>&1
if errorlevel 1 (
    start "DouYin-LoginDesktop" /min "%PYEXE%" login_desktop_server.py
) else (
    echo [提示] 登录服务已在运行，跳过重复启动。
)

rem ---- 启动调度器（后台）----
start "DouYin-Scheduler" /min "%PYEXE%" scripts\cron_runner.py state\cron\root

rem ---- 前台启动 Web 管理界面（仅本机）----
echo ==========================================
echo   DouYin SparkFlow Web 管理界面
echo   地址: http://127.0.0.1:8787
echo   首次访问请在页面初始化管理员账号
echo   按 Ctrl+C 停止 Web 服务
echo ==========================================
"%PYEXE%" main.py --web --host 127.0.0.1 --port 8787
