# abqhpc — 超算 Abaqus Windows 客户端 + 批量队列

Windows 原生工具（PowerShell + SSH.NET，**不依赖本机 Python**），连接东方超算提交/监控 Abaqus；并支持多客户端共享的 **SQLite 批量队列**，由超算登录节点上的 **nohup 调度器**按资源放行作业。

仓库：<https://github.com/sli-work/abqhpc>

## 目录结构

```
abqhpc/
  client/                 # Windows 客户端（本机运行）
    abqctl.ps1            # 连接 / 单作业 / 上传下载 / .sta
    AbqCtlGui.ps1         # 单作业 GUI
    AbqQueue.ps1          # 队列 CLI（入队、调度器启停）
    AbqQueueGui.ps1       # 批量队列 GUI
    abqctl.sh             # 同步到超算的单作业脚本
    lib/Renci.SshNet.dll
    打开任务面板.bat
    打开队列面板.bat
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

或双击 `打开任务面板.bat` 用 GUI 连接。

### 2. 单作业

```powershell
.\abqctl.ps1 run /public/home/tsyg/wh-data/hq/xxx.inp -Cpus 8 -Double both
.\abqctl.ps1 sta JOBNAME
.\abqctl.ps1 cancel JOBNAME
```

### 3. 批量队列

```powershell
.\AbqQueue.ps1 sync                 # 上传 remote/* 到超算
.\AbqQueue.ps1 scheduler-start      # nohup 拉起调度器（仅需一次）
.\AbqQueue.ps1 enqueue /public/home/tsyg/wh-data/hq/a.inp -Cpus 8
.\AbqQueue.ps1 list
.\AbqQueue.ps1 gui                  # 或双击 打开队列面板.bat
```

多台 Windows 可同时入队/看队列；**全局只有一个调度器**（lease）。客户端退出后调度器仍继续跑。

## 文档

完整说明见 [docs/使用说明.md](docs/使用说明.md)。

## 许可与账号

面向内部超算账号 `tsyg` 使用；请勿将动态码写入仓库或日志。
