# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for the Windows portable (onedir) build.

Three executables map 1:1 to the source tree -- no business code changes:
  sparkflow.exe      <- main.py                  (web UI / --doTask / interactive CLI)
  login-desktop.exe  <- login_desktop_server.py  (scan-login API service, :18090)
  cron-runner.exe    <- scripts/cron_runner.py   (schedule consumer, reads state/cron/root)

All three share one COLLECT (app/). Chromium and the Node protocol sender are
NOT bundled here -- they live next to app/ (see build_portable.ps1).
"""

import os

from PyInstaller.utils.hooks import collect_all

REPO_ROOT = os.path.abspath(os.path.join(SPECPATH, os.pardir))  # douyin-sparkflow-main/
ROOT = os.path.join(REPO_ROOT, "DouYinSparkFlow")               # source tree root

# --- shared assets ---------------------------------------------------------
web_datas = [
    (os.path.join(ROOT, "webui", "templates"), "webui/templates"),
    (os.path.join(ROOT, "webui", "static"), "webui/static"),
]
pw_datas, pw_binaries, pw_hidden = collect_all("playwright")

common_datas = web_datas + pw_datas
common_binaries = pw_binaries
common_hidden = pw_hidden + [
    "webui.app",      # uvicorn.run("webui.app:app") string import
    "webui.auth",
    "webui.login_lock",
    "webui.ops",
    "webui.users",
]
common_excludes = ["tests", "pytest", "vendor", "docs"]


def _analysis(entry_script):
    return Analysis(
        [os.path.join(ROOT, entry_script)],
        pathex=[ROOT],
        binaries=common_binaries,
        datas=common_datas,
        hiddenimports=common_hidden,
        hookspath=[],
        runtime_hooks=[],
        excludes=common_excludes,
        noarchive=False,
    )


a_main = _analysis(os.path.join("main.py"))
a_login = _analysis(os.path.join("login_desktop_server.py"))
a_cron = _analysis(os.path.join("scripts", "cron_runner.py"))

pyz_main = PYZ(a_main.pure)
pyz_login = PYZ(a_login.pure)
pyz_cron = PYZ(a_cron.pure)

exe_main = EXE(
    pyz_main,
    a_main.scripts,
    [],
    exclude_binaries=True,
    name="sparkflow",
    console=True,  # web is a foreground app; Ctrl+C stops it
)
exe_login = EXE(
    pyz_login,
    a_login.scripts,
    [],
    exclude_binaries=True,
    name="login-desktop",
    console=True,  # hidden by start.bat (Start-Process /min), keeps logs visible in dev
)
exe_cron = EXE(
    pyz_cron,
    a_cron.scripts,
    [],
    exclude_binaries=True,
    name="cron-runner",
    console=True,
)

coll = COLLECT(
    exe_main,
    a_main.binaries,
    a_main.datas,
    exe_login,
    a_login.binaries,
    a_login.datas,
    exe_cron,
    a_cron.binaries,
    a_cron.datas,
    name="app",
)
