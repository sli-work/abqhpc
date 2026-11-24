# abqhpc — 超算 Abaqus Windows 客户端 + 批量队列

Windows 原生工具（PowerShell + SSH.NET，**不依赖本机 Python**），连接东方超算提交/监控 Abaqus；并支持多客户端共享的 **SQLite 批量队列**，由超算登录节点上的 **nohup 调度器**按资源放行作业。

仓库：<https://github.com/sli-work/abqhpc>

## 目录结构

```
abqhpc/
  client/                 # Windows 客户端（本机运行）
    abqctl.ps1            # 连接 / 单作业 / 上传下载 / .sta
    AbqCtlGui.ps1         # 统一 GUI（Tab：单作业 + 批量队列）
    AbqQueue.ps1          # 队列 CLI（入队、调度器启停）
    AbqQueueGui.ps1       # 兼容入口 → 打开统一 GUI 的队列 Tab
    abqctl.sh             # 同步到超算的单作业脚本
    lib/Renci.SshNet.dll
    打开任务面板.bat
    打开队列面板.bat      # 同上 GUI，默认切到「批量队列」
  remote/                 # 超算侧源码（经 sync 上传）
    schema.sql
    abqctl_db.py
    abqctl_node_scan.py
    abqctl_scheduler.py
    abqctl_scheduler.sh
  docs/
    使用说明.md
  README.md
```

远端队列目录默认：`/public/home/tsyg/tsyg/abqctl_queue/`  
默认数据根：`/public/home/tsyg/wh-data`

## 快速开始

### 1. 连接（OTP）

```powershell
cd client
.\abqctl.ps1 connect <6位动态码>
```

密码 = `tsyg6100` + 动态码；动态码**不落盘**。连接后保持一条 SSH/SFTP 会话。

或双击 `打开任务面板.bat`：

- **批量队列**：上传 `.inp`（可选手动文件或选文件夹批量上传全部 `.inp`）→ 入队 → 调度器放行  
- **监控 / 下载**：状态、`.sta`；下载文件/文件夹支持**断点续传**

### 2. 常用 CLI

```powershell
.\abqctl.ps1 upload-inps D:\cases\batch /public/home/tsyg/wh-data/hq
.\AbqQueue.ps1 sync
.\AbqQueue.ps1 scheduler-start
.\AbqQueue.ps1 enqueue /public/home/tsyg/wh-data/hq/a.inp -Cpus 8
.\abqctl.ps1 download-dir /public/home/tsyg/wh-data/hq/JOB D:\out   # 断点续传
.\abqctl.ps1 sta JOBNAME
```

多台 Windows 可同时入队/看队列；**全局只有一个调度器**（lease）。客户端退出后调度器仍继续跑。

### 作业工作目录

同一远端目录里可以有很多 `.inp`。调度真正开算时会按**任务名**（`.inp` 主文件名）建子目录再跑，例如：

- 入队：`/public/home/tsyg/wh-data/hq/A.inp`
- 实际目录：`/public/home/tsyg/wh-data/hq/A/`（内含软链 `A.inp`、`.sta` / `.odb` / `run_A.log` / `scratch/`）

若 `.inp` 已经在同名文件夹里（`.../A/A.inp`），则不再套一层。改调度逻辑后请在 GUI 点「同步脚本」并重启调度器。

## 文档

完整说明见 [docs/使用说明.md](docs/使用说明.md)。

## 许可与账号

面向内部超算账号 `tsyg` 使用；请勿将动态码写入仓库或日志。
