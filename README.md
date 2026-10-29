# DouYin SparkFlow - Windows Next

抖音火花（DouYin Spark Flow）的 **Windows 增强修改版**，同时支持 **Linux Docker 一键部署**。

在原版基础上修复了 Windows 上两个致命问题，并新增 Linux 容器化安装方式。

## ✨ 特性

- 🪟 **Windows 原生运行**：Python + Playwright，绿色便携
- 🐳 **Linux Docker 一键安装**：一条命令完成构建、配置、启动、自愈
- 🖥️ Web 管理界面：账号管理、任务调度、发送控制、运行看板
- 🔧 **修复：好友列表为空**——虚拟列表 + 动态滚动容器扫描，实测正常抓取好友
- 🩹 **修复：Windows 服务崩溃**——进程探活改用 OpenProcess，解决 `WinError 87/11` 崩溃
- ⏰ 自动发送窗口调度：每日 10:00–18:00，每 20 分钟检查一次
- 💾 数据持久化：账号 cookies / 浏览器配置 / 日志独立存放，容器重建不丢失
- 🛡️ 安全构建：镜像排除 cookies 与账号数据

## 📦 快速开始

### 方式一：Windows（本机运行）

**前置**：Python 3.10+（未安装可在 [python.org](https://www.python.org/downloads/) 下载，勾选 Add to PATH）

```bat
git clone https://github.com/NVP12100F/DouYinSparkFlow-Windows-Next.git
cd DouYinSparkFlow-Windows-Next\DouYinSparkFlow
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
playwright install chromium
```

**启动**（回到仓库根目录）：

| 脚本 | 用途 |
|---|---|
| `启动-抖音火花.bat` | 前台启动，带实时日志，适合调试 |
| `启动服务-后台.bat` | 后台启动 + 看门狗自愈（推荐日常使用） |
| `停止服务.bat` | 停止全部服务 |

**首次使用**：

1. 浏览器打开 `http://127.0.0.1:8787`，初始化管理员账号
2. 打开 `http://127.0.0.1:18090`，扫码添加抖音账号
3. 在管理界面添加发送目标（好友），保存后自动进入调度

### 方式二：Linux（Docker 一键安装）

**前置**：安装 Docker（[官方文档](https://docs.docker.com/engine/install/)），当前用户可执行 `docker` 命令，建议执行 `sudo -i` 切换至ROOT用户后再执行此脚本，否则容易报没权限。

**一行命令安装（自动走 gh-proxy GitHub 加速 + 华为云镜像，适合国内网络）**：

```bash
bash <(curl -fsSL https://v4.gh-proxy.com/https://raw.githubusercontent.com/NVP12100F/DouYinSparkFlow-Windows-Next/main/install-remote.sh)
```

> 脚本自动：加速 clone 仓库到 `~/douyin-sparkflow` → 构建镜像（清华 pip / 阿里 apt / 华为云 Playwright 镜像）→ 生成容器配置 → 启动容器（开机自启）→ 健康检查 → 输出访问地址。
>
> 全部直连（海外网络）：命令末尾加 `--direct`。

**手动安装**（也可先 clone 再执行）：

```bash
git clone https://github.com/NVP12100F/DouYinSparkFlow-Windows-Next.git
cd DouYinSparkFlow-Windows-Next
chmod +x install-linux.sh
./install-linux.sh          # 默认华为云镜像；加 --direct 用官方镜像
```

脚本自动完成：**检查 Docker → 构建镜像（含国内 pip/apt 源加速）→ 生成容器配置 → 启动容器（开机自启）→ 健康检查 → 输出访问地址**。

| 自定义项 | 环境变量 | 默认值 |
|---|---|---|
| 宿主机数据目录 | `DATA_DIR` | `~/douyin-sparkflow-data` |
| Web 端口 | `WEB_PORT` | `8787` |
| 登录服务端口 | `LOGIN_PORT` | `18090` |

安装后访问：

- 管理界面：`http://<服务器IP>:8787`
- 扫码登录：`http://<服务器IP>:18090`

常用命令：

```bash
sudo docker logs -f douyin-sparkflow   # 查看日志
sudo docker restart douyin-sparkflow   # 重启
sudo docker stop douyin-sparkflow      # 停止
```

> 想把 Windows 已登录的账号迁到 Linux：把本地 `usersData.json` 复制到 `~/douyin-sparkflow-data/usersData.json` 后重启容器即可（异地 IP 可能导致 cookies 失效，失效就重新扫码）。

## ⚙️ 自动发送机制

- 每日 **10:00–18:00** 窗口内，每 **20 分钟**调度一次
- 只对**当天尚未发送**的目标账号发送
- 每个账号启动延迟 15–60 秒、消息间隔 25–70 秒、4 条消息变体随机
- 手动运行 / 补发不受发送窗口限制

## 🔧 常见问题

| 问题 | 解决 |
|---|---|
| 好友列表为空 | 确认账号已扫码登录且有效；新版已修复虚拟列表扫描，等待数秒即可 |
| 服务莫名崩溃 | Windows 用 `启动服务-后台.bat`（看门狗自动拉起）；Linux 容器默认 `--restart=always` 自愈 |
| 登录后 18090 打不开 | 检查端口占用；Docker 部署确认 `LOGIN_PORT` 未被占用 |
| 提示异地登录 / cookies 失效 | 重新扫码登录；建议保持低频发送降低风控风险 |

## 🛡️ 安全说明

- Docker 镜像构建通过 `.dockerignore` 排除 `usersData.json`、`config.json`、`state/`、`logs/`——**账号 cookies 不会进入镜像**
- 登录服务在 Windows 默认仅绑定本机；Docker 部署通过端口映射隔离，外部网络不可直达
- 本项目仅供学习研究，请遵守抖音平台规则与当地法律法规，风险自负

## 📄 许可证

[MIT](DouYinSparkFlow/LICENSE)。修改版保留原版权声明。
