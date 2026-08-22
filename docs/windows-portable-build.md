# Windows 绿色版（Portable）打包设计方案

> 状态：设计稿（v1）· 目标形态：**目录式绿色版（zip 分发），非 onefile 单 EXE**
> 原则：不修改核心业务代码（core/、webui/、utils/、login_desktop_server.py 零改动）；
> 全部适配通过**已测试的 Windows Native 运行层**（`_on_windows()` 分支、`state/cron/root` spool、
> `SPARKFLOW_NODE_BIN`、`LOGIN_DESKTOP_PROFILE_DIR`）自动生效。

---

## 1. 目标与约束

| 约束 | 说明 |
|---|---|
| 零系统依赖 | 不依赖系统 Python / Node.js / Docker Desktop / WSL2 |
| 不可消除依赖 | Chromium 二进制（必须随包分发，`PLAYWRIGHT_BROWSERS_PATH` 指向包内目录） |
| 打包形态 | PyInstaller **onedir**（每个入口一个 exe + `_internal/` 运行库目录） |
| 不改业务代码 | 复用已就绪的 `Environment.PACKED`（`utils/config.py`）与 `browser.py` 的本地 bundle 机制 |
| 分发方式 | zip（解压即用），附带 `start.bat` / `stop.bat` |

**实测体积基线**（本机，2026-08）：

| 组件 | 解压体积 | zip 后估算 | 说明 |
|---|---|---|---|
| Python 3.12 + 全依赖（site-packages） | 139 MB | ~60 MB | PyInstaller 收集后更小（剔 tests/docs） |
| 其中 playwright 包（含 driver/node） | 97 MB | ~40 MB | `--collect-all playwright` 全量收集 |
| Chromium（chrome-win + locales + ffmpeg） | 550 MB | ~230 MB | 裁剪 locales/ffmpeg 后约 470 MB |
| node.exe（官方 zip 版单文件） | 88 MB | ~55 MB | 仅协议发送路径需要；SEA 方案可降至 ~10 MB |
| **合计** | **~770–860 MB** | **~330–390 MB** | Chromium 为大头，不可消除 |

---

## 2. 绿色版目录布局

```
DouYinSparkFlow-win64/
├── app/                          # PyInstaller onedir 产物
│   ├── sparkflow.exe             # 入口1：main.py（--web / --doTask / 交互 CLI）
│   ├── login-desktop.exe         # 入口2：login_desktop_server.py（登录扫码服务 :18090）
│   ├── cron-runner.exe           # 入口3：scripts/cron_runner.py（调度，读 state\cron\root）
│   ├── _internal/                # Python 运行时 + 全部依赖（含 playwright driver）
│   ├── config.json               # 运行时生成（PACKED 模式自动落在 exe 旁）
│   ├── usersData.json            # 运行时生成
│   ├── webui_settings.json       # 运行时生成
│   ├── state/                    # cron spool / 浏览器 Profile / 登录 Profile
│   └── logs/
├── chrome/                       # Playwright Chromium（PLAYWRIGHT_BROWSERS_PATH）
├── node/                         # 协议发送运行时（见 §4 方案 A/B）
├── start.bat                     # 一键启动（web + scheduler + login-desktop）
├── stop.bat                      # 停止
├── uninstall.bat                 # 可选：清空 state/logs
└── README.txt                    # 使用说明 + 免责声明
```

关键点：
- **数据与程序同目录**：`utils/config.py` 的 PACKED 分支把 `_runtime_root()` 指向 `sys.executable` 所在目录，`config.json`/`usersData.json`/`webui_settings.json` 自动落盘在 `app/` 下 —— 便携、可整体拷贝迁移。
- **浏览器定位**：`browser.py::configure_playwright_environment()` PACKED 分支把 `PLAYWRIGHT_BROWSERS_PATH` 指向 `exe目录/../chrome`（即 `app/../chrome`）—— 布局正好匹配，无需改代码。
- **Node 定位**：`protocol_dispatch._node_executable()` 读取 `SPARKFLOW_NODE_BIN` —— 由 `start.bat` 注入 `node\` 路径。
- **Profile 目录**：`start.bat` 注入 `SPARKFLOW_BROWSER_PROFILE_ROOT=app\state\browser-profiles`、`LOGIN_DESKTOP_PROFILE_DIR=app\state\login-profile`（`login_desktop_server.py` 的 Windows 分支已支持环境变量）。

---

## 3. Python 应用打包（PyInstaller onedir）

### 3.1 入口与 spec

一个 spec 文件产三个 exe（`sparkflow` / `login-desktop` / `cron-runner`），共享同一 `Analysis`（只分析一次）：

```python
# build/portable.spec（构建脚本，不进入绿色版产物）
a = Analysis(
    ["main.py"],                      # 入口1
    datas=[("webui/templates", "webui/templates"),
           ("webui/static", "webui/static")],
    hiddenimports=["webui.app"],      # uvicorn.run("webui.app:app") 字符串导入保险
)
pyz = PYZ(a.pure)
exe_main = EXE(pyz, a.scripts, exclude_binaries=True, name="sparkflow", ...)
exe_login = EXE(pyz, a.scripts, exclude_binaries=True, name="login-desktop", ...)  # 见 3.4
exe_cron = EXE(pyz, a.scripts, exclude_binaries=True, name="cron-runner", ...)
coll = COLLECT(...)
```

- `main.py` 作为入口1（已有 `--web`/`--doTask`/交互三模式，零改动）。
- `login_desktop_server.py`、`scripts/cron_runner.py` 作为入口2/3（它们有 `__main__`，可直接作为 PyInstaller 入口脚本；`cron_runner` 需 `sys.argv[1]` 传 spool 路径）。
- `datas`：`webui/templates/`、`webui/static/`（Jinja2 模板与前端资源必须随包）。
- 模板目录解析：`webui/app.py` 用 `Path(__file__).resolve().parent` —— PyInstaller 收集后 `__file__` 指向 `_internal/webui/`，datas 把模板放对位置即可。
- `--collect-all playwright`：必须，否则 playwright 的 driver（内含 node 二进制与 package）缺失。
- `--collect-submodules uvicorn` / `fastapi` 按需（PyInstaller hook 通常已处理）。
- `--noconsole` 仅用于 login-desktop / cron-runner（后台服务）；`sparkflow.exe --web` 前台保留控制台（用户 Ctrl+C）。

### 3.2 构建机环境

- **PyInstaller 不支持嵌入式 Python 发行版**（缺少完整 venv/标准库布局），构建机需完整 CPython：
  `python-3.12.x-amd64.exe /quiet InstallAllUsers=0 TargetDir=<workspace>\tools\pybuild`（静默装到工作区，不污染系统）。
- 依赖安装：`pybuild\python.exe -m pip install -r requirements.txt pyinstaller`（清华镜像）。
- 构建：`pyinstaller --clean --noconfirm build/portable.spec`，产物在 `dist/app/`。
- 本环境注意：沙箱对 `tempfile` 机制目录的限制不影响构建（构建写 `dist/` 于工作区，手动目录）；pip/PyInstaller 下载写盘需权限升级（与依赖安装同模式，已有先例）。

### 3.3 已知坑与对策

| 坑 | 对策 |
|---|---|
| `uvicorn.run("webui.app:app")` 字符串导入 | `hiddenimports=["webui.app"]` + `--collect-submodules webui` |
| playwright driver 子进程（node）路径 | `--collect-all playwright`；运行时 driver 在 `_internal/playwright/driver/` |
| `Rich`/`click` 等动态导入 | PyInstaller 自带 hook 已覆盖（rich/click 常见） |
| 杀软误报 | `sparkflow.exe` 走 PyInstaller 默认加壳关闭（`upx=False`）；文档提示用户加白名单 |
| 多 exe 共享 Analysis 的 datas 重复 | 共享同一 `Analysis`/`COLLECT`，体积不翻倍 |

### 3.4 三个 exe 的入口脚本

入口脚本放在 `build/`（构建目录，不进产物），内容为 2-4 行的 `runpy` 引导（不改业务代码）：

- `sparkflow` 入口：`import runpy; runpy.run_path("main.py", run_name="__main__")` 或直接以 `main.py` 为入口。
- `login-desktop` 入口：`runpy.run_path("login_desktop_server.py", run_name="__main__")`。
- `cron-runner` 入口：`runpy.run_path("scripts/cron_runner.py", run_name="__main__")`（接收 spool 路径 argv）。

> 若 runpy 方案在 PyInstaller 下出现模块定位问题，退路：入口直接 `from login_desktop_server import ...` 风格显式 import（依旧不改业务文件本身）。

---

## 4. Node 运行时（协议发送路径）

`protocol_sender.mjs` 仅依赖 Node 内置模块（`fs/path/vm/buffer`）+ 全局 `fetch`，无 npm 依赖 —— 两种方案：

### 方案 A（推荐）：Node SEA 单文件（~10 MB）
1. 用 esbuild 把 `protocol_sender.mjs` 打成单文件 CJS bundle（`build/protocol-sender.cjs`）。
2. `node --experimental-sea-config sea-config.json` 生成 blob。
3. 复制 `node.exe` → `protocol-sender.exe`，用 `postject` 注入 blob。
4. 产物 `node/protocol-sender.exe`；`start.bat` 注入 `SPARKFLOW_NODE_BIN=node\protocol-sender.exe`。
- 优点：体积最小（~10 MB vs 88 MB）、单文件、无解压目录。
- 风险：SEA 为实验特性（Node 22 可用），`process.stdin` 全量读取在 SEA 中正常；需在冒烟测试中实测 `Missing JSON payload` 路径。

### 方案 B（备选）：官方 node.exe（~88 MB）
- 下载 `node-v22.x-win-x64.zip`，解压只保留 `node.exe` 到 `node/`。
- `SPARKFLOW_NODE_BIN=node\node.exe`。
- 优点：零构建步骤、官方稳定；缺点：体积 +78 MB。

> 建议：先按 A 实施，A 冒烟失败即回退 B（两者 `SPARKFLOW_NODE_BIN` 接口一致，切换成本为零）。

---

## 5. Chromium 随包

- 来源：构建机执行 `playwright install chromium`（`PLAYWRIGHT_BROWSERS_PATH=<build>\chrome`）。
- 复制 `chrome-win/` 到绿色版 `chrome/`。
- **裁剪**（可选，省 ~40 MB）：
  - `locales/` 只留 `zh-CN.pak`、`en-US.pak`（省 ~35 MB）；
  - 删除 `ffmpeg-*/`（本项目不使用 page.video，省 ~3.4 MB）。
- 版本一致性：`requirements.txt` 锁定 `playwright==1.56.0`，构建机与运行时同版本，浏览器 bundle 版本由 `playwright install` 决定。
- 校验：打包脚本记录 chromium 版本号（`chrome-win/chrome.exe` 文件版本），README 注明升级方式（换 chrome 目录即可，Playwright 主版本一致时兼容）。

---

## 6. 启动 / 停止脚本（绿色版内）

`start.bat`（调 `powershell -ExecutionPolicy Bypass -File app\..\scripts\start-portable.ps1`，或直接 bat 内联）：

```bat
set "APP_DIR=%~dp0app"
set "PLAYWRIGHT_BROWSERS_PATH=%~dp0chrome"
set "SPARKFLOW_NODE_BIN=%~dp0node\protocol-sender.exe"   REM 方案A；方案B为 node.exe
set "SPARKFLOW_BROWSER_PROFILE_ROOT=%APP_DIR%\state\browser-profiles"
set "LOGIN_DESKTOP_PROFILE_DIR=%APP_DIR%\state\login-profile"
REM 1) cron-runner.exe 后台启动（读 %APP_DIR%\state\cron\root）
REM 2) login-desktop.exe 后台启动（:18090）
REM 3) sparkflow.exe --web 前台（Ctrl+C 停止）
```

- 复用已验证的 `deploy/start-windows.ps1` 逻辑（等价流程），仅把 `python xxx.py` 换成三个 exe、注入环境变量。
- `stop.bat`：杀 `login-desktop.exe`/`cron-runner.exe`（按进程名），web 由 Ctrl+C 结束。
- 调度 spool 生成：首次运行由 web 启动时 `sync_daily_schedule_from_config()` 自动写 `state\cron\root`（Windows 分支已验证）；`start.bat` 也可预生成（同 `start-windows.ps1` 的 `[setup]` 步骤，命令换成 `sparkflow.exe --doTask` 前置或直接调用 ops 逻辑的 exe 子命令——保持与现有脚本一致）。

---

## 7. 验证方案（每步在干净目录实测）

| 步骤 | 验证内容 | 判据 |
|---|---|---|
| 1 | `sparkflow.exe --web` 启动 | `http://127.0.0.1:8787/login` 200；`config.json`/`webui_settings.json` 在 exe 旁生成 |
| 2 | `login-desktop.exe` 启动 | `http://127.0.0.1:18090/health` 200；`/status` 返回 running=false |
| 3 | `cron-runner.exe <spool>` 启动 | 日志出现 `[cron_runner] watching`；spool 存在且被 web 写 |
| 4 | `sparkflow.exe --doTask`（空账号） | 正常退出："No enabled accounts" 日志，无 traceback |
| 5 | 协议发送 dryRun | `SPARKFLOW_NODE_BIN=node\protocol-sender.exe` + 空 payload 冒烟：报 `Missing JSON payload`（证明 SEA/node 可执行 mjs） |
| 6 | 端到端 | 绿色版目录拷贝到新路径（模拟用户解压位置），重跑步骤 1-5 |
| 7 | 回归 | 在**源码树**上重跑 6 个测试文件（保证打包未改动源码行为） |

---

## 8. 构建产物与分发

```
dist/
├── DouYinSparkFlow-win64/     # 绿色版根目录（zip 对象）
└── DouYinSparkFlow-win64.zip  # Compress-Archive 输出（~330–390 MB）
```

- README.txt 内容：环境要求（Windows 10/11 x64，无需任何运行时）、启动/停止、数据位置、升级方式（替换 chrome/、app/ 保留 state/）、免责声明。
- 分发渠道（待定）：直链 / GitHub Release。

---

## 9. 风险与待确认决策点

| # | 决策点 | 推荐 | 备选 |
|---|---|---|---|
| D1 | Node 运行时方案 | A：SEA 单文件（~10 MB） | B：node.exe（88 MB） |
| D2 | Chromium 是否裁剪 locales/ffmpeg | 裁剪（省 ~40 MB） | 不裁剪（零风险） |
| D3 | 数据目录位置 | exe 旁（便携，PACKED 默认） | `%APPDATA%`（多实例隔离，需小改 config） |
| D4 | login-desktop 是否默认内置 | 内置（无 Docker 时的唯一扫码通道） | 可选组件（体积 -0，功能减） |
| D5 | 是否裁剪 playwright driver 内 node | 不裁（--collect-all 全量，最稳） | 手裁（-80 MB，风险高） |

---

## 10. 实施步骤（确认方案后执行）

1. 构建机准备：下载完整 CPython 3.12 静默安装到工作区（node 下载 + `/quiet`，本环境需权限升级）。
2. `build/portable.spec` + 三个入口引导脚本 + `build_portable.ps1`（一键构建：装依赖 → spec 构建 → 复制 chrome/node → 生成 start/stop.bat + README → Compress-Archive）。
3. 按 §7 逐项冒烟验证；Node SEA 冒烟失败则切换方案 B。
4. 源码树回归测试（6 个测试文件）。
5. 产出 zip + 体积报告。
