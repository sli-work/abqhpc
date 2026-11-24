#Requires -Version 5.1
<#
  Batch queue CLI for abqctl_queue.
  Requires an active abqctl_win SSH session (.\abqctl.ps1 connect <OTP>).
  Syncs remote/*.py|*.sh|schema.sql to HPC and controls enqueue / scheduler.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Arg1,

    [Parameter(Position = 2)]
    [string]$Arg2,

    [int]$Cpus = 8,
    [ValidateSet('both', 'explicit', 'off')]
    [string]$Double = 'both',
    [int]$Priority = 0,
    [string]$Node = '',
    [string]$QueueDir = '/public/home/tsyg/tsyg/abqctl_queue',
    [string]$AbqCtlWin = '',
    [int]$Limit = 200
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Unified repo: abqhpc/client + abqhpc/remote (also works if flat next to ../abqhpc/remote)
$RepoRoot = Split-Path -Parent $ScriptDir
$RemoteLocalDir = Join-Path $RepoRoot 'remote'
if (-not (Test-Path $RemoteLocalDir)) {
    $alt = Join-Path $RepoRoot 'abqhpc\remote'
    if (Test-Path $alt) {
        $RemoteLocalDir = $alt
        $RepoRoot = Join-Path $RepoRoot 'abqhpc'
    }
}
$StateDir = Join-Path $env:TEMP 'abqctl_ssh'
$StateFile = Join-Path $StateDir 'session.json'

if (-not $AbqCtlWin) {
    if (Test-Path (Join-Path $ScriptDir 'abqctl.ps1')) {
        $AbqCtlWin = $ScriptDir
    }
}

function ConvertTo-B64([string]$Text) {
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function ConvertFrom-B64([string]$B64) {
    if ([string]::IsNullOrEmpty($B64)) { return '' }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($B64))
}

function Read-State {
    if (-not (Test-Path $StateFile)) { return $null }
    try { return (Get-Content -Raw -Path $StateFile | ConvertFrom-Json) } catch { return $null }
}

function Send-HostRequest([hashtable]$Req, [int]$TimeoutSec = 180) {
    $st = Read-State
    if (-not $st -or -not $st.port -or -not $st.token) {
        throw '会话未连接。请先在 abqctl_win 中执行: .\abqctl.ps1 connect <6位动态码>'
    }
    $alive = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
    if (-not $alive) {
        throw '会话进程已退出。请重新 connect。'
    }
    $Req.token = [string]$st.token
    $client = New-Object System.Net.Sockets.TcpClient
    $client.ReceiveTimeout = $TimeoutSec * 1000
    $client.SendTimeout = 30000
    $client.Connect('127.0.0.1', [int]$st.port)
    try {
        $stream = $client.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding $false))
        $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8)
        $writer.NewLine = "`n"
        $writer.AutoFlush = $true
        $writer.WriteLine(($Req | ConvertTo-Json -Compress -Depth 4))
        $line = $reader.ReadLine()
        if ($null -eq $line) { throw '会话无响应，请重新连接。' }
        $resp = $line | ConvertFrom-Json
        if (-not $resp.ok) {
            $err = [string]$resp.error
            if ($resp.error_b64) { $err = ConvertFrom-B64 ([string]$resp.error_b64) }
            throw $err
        }
        if ($resp.out_b64) { return (ConvertFrom-B64 ([string]$resp.out_b64)) }
        return [string]$resp.out
    }
    finally {
        $client.Close()
    }
}

function Invoke-Remote([string]$RemoteCommand, [int]$TimeoutSec = 180) {
    $cmd = $RemoteCommand -replace "`r", ''
    return (Send-HostRequest @{ op = 'run'; cmd = $cmd } $TimeoutSec)
}

function Escape-BashSingle([string]$s) {
    return ($s -replace "'", "'\''")
}

function Sync-QueueRemote([switch]$Force) {
    if (-not (Test-Path $RemoteLocalDir)) {
        throw "本地 remote 目录不存在: $RemoteLocalDir"
    }
    $files = @(
        'schema.sql',
        'abqctl_db.py',
        'abqctl_node_scan.py',
        'abqctl_scheduler.py',
        'abqctl_scheduler.sh'
    )
    $qd = Escape-BashSingle $QueueDir
    Invoke-Remote "mkdir -p '$qd'" 30 | Out-Null

    $markerDir = Join-Path $StateDir 'queue_sync'
    if (-not (Test-Path $markerDir)) {
        New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
    }

    foreach ($name in $files) {
        $local = Join-Path $RemoteLocalDir $name
        if (-not (Test-Path $local)) { throw "缺少本地文件: $local" }
        $hash = (Get-FileHash -Algorithm SHA256 -Path $local).Hash
        $marker = Join-Path $markerDir ($name + '.sha256')
        if (-not $Force -and (Test-Path $marker)) {
            $old = (Get-Content -Raw -Path $marker).Trim()
            if ($old -eq $hash) { continue }
        }
        $raw = [IO.File]::ReadAllText($local)
        $raw = $raw -replace "`r", ''
        $b64 = ConvertTo-B64 $raw
        $remote = "$QueueDir/$name"
        $rq = Escape-BashSingle $remote
        $cmd = "printf '%s' '$b64' | base64 -d > '$rq'; chmod +x '$rq' 2>/dev/null; echo SYNC_OK:$name"
        $out = Invoke-Remote $cmd 120
        if ($out -notmatch 'SYNC_OK') { throw "同步失败 $name : $out" }
        Set-Content -Encoding ASCII -Path $marker -Value $hash
        Write-Host "synced $name"
    }
    $init = Invoke-Remote "cd '$qd' && python3 abqctl_db.py --queue-dir '$qd' init" 60
    Write-Host "queue init: $init"
}

function Invoke-Db([string]$DbArgs, [int]$TimeoutSec = 60) {
    $qd = Escape-BashSingle $QueueDir
    $script = "cd '$qd' && python3 abqctl_db.py --queue-dir '$qd' $DbArgs"
    return (Invoke-Remote $script $TimeoutSec)
}

function Show-SchedulerStatus {
    Sync-QueueRemote
    $qd = Escape-BashSingle $QueueDir
    $script = @"
QD='$qd'
cd "`$QD" || exit 1
echo '=== lease ==='
python3 abqctl_db.py --queue-dir "`$QD" lease-status 2>/dev/null || true
echo '=== pid file ==='
if [ -f scheduler.pid ]; then
  PID=`$(cat scheduler.pid 2>/dev/null)
  echo "scheduler.pid=`$PID"
  if [ -n "`$PID" ] && kill -0 "`$PID" 2>/dev/null; then
    echo 'process=alive'
    ps -p "`$PID" -o pid,etime,cmd --no-headers 2>/dev/null || true
  else
    echo 'process=dead'
  fi
else
  echo 'scheduler.pid=(missing)'
fi
if [ -f scheduler.stop ]; then echo 'stop_flag=present'; else echo 'stop_flag=absent'; fi
echo '=== log tail ==='
tail -n 20 scheduler.log 2>/dev/null || echo '(no log)'
"@
    Invoke-Remote $script 60
}

function Start-SchedulerRemote {
    Sync-QueueRemote -Force
    $qd = Escape-BashSingle $QueueDir
    $nodeHint = if ($Node) { Escape-BashSingle $Node } else { '' }
    $script = @"
QD='$qd'
NODE_HINT='$nodeHint'
cd "`$QD" || exit 1
rm -f scheduler.stop
if [ -f scheduler.pid ]; then
  OPID=`$(cat scheduler.pid 2>/dev/null)
  if [ -n "`$OPID" ] && kill -0 "`$OPID" 2>/dev/null; then
    echo "ALREADY_RUNNING pid=`$OPID"
    exit 0
  fi
fi
export ABQCTL_QUEUE_DIR="`$QD"
export ABQCTL_NODES="`${ABQCTL_NODES:-login05 login08 login10}"
nohup bash ./abqctl_scheduler.sh >> scheduler.log 2>&1 &
echo `$! > scheduler.pid
sleep 1
NPID=`$(cat scheduler.pid)
if kill -0 "`$NPID" 2>/dev/null; then
  echo "STARTED pid=`$NPID host=`$(hostname) node_hint=`$NODE_HINT"
  tail -n 5 scheduler.log 2>/dev/null || true
else
  echo "START_FAILED"
  tail -n 30 scheduler.log 2>/dev/null || true
  exit 1
fi
"@
    Invoke-Remote $script 90
}

function Stop-SchedulerRemote {
    $qd = Escape-BashSingle $QueueDir
    $script = @"
QD='$qd'
cd "`$QD" || exit 1
touch scheduler.stop
if [ -f scheduler.pid ]; then
  PID=`$(cat scheduler.pid 2>/dev/null)
  if [ -n "`$PID" ] && kill -0 "`$PID" 2>/dev/null; then
    kill "`$PID" 2>/dev/null || true
    sleep 1
    kill -9 "`$PID" 2>/dev/null || true
    echo "STOPPED pid=`$PID"
  else
    echo 'pid not alive; stop flag set'
  fi
else
  echo 'no pid file; stop flag set'
fi
"@
    Invoke-Remote $script 30
}

function Enqueue-Job([string]$InpPath) {
    if (-not $InpPath) { throw '用法: .\AbqQueue.ps1 enqueue <远程.inp> [-Cpus 8] [-Double both] [-Priority 0] [-Node login08]' }
    Sync-QueueRemote
    $inp = Escape-BashSingle $InpPath
    $nodeArg = if ($Node) { "--node $(Escape-BashSingle $Node)" } else { '' }
    $args = "enqueue '$inp' --cpus $Cpus --double $Double --priority $Priority $nodeArg"
    Invoke-Db $args
}

function List-Queue {
    Sync-QueueRemote
    $st = if ($Arg1) { "--status $(Escape-BashSingle $Arg1)" } else { '' }
    Invoke-Db "list $st --limit $Limit"
}

function Cancel-QueueJob([string]$Id) {
    if (-not $Id) { throw '用法: .\AbqQueue.ps1 cancel <id>' }
    Sync-QueueRemote
    Invoke-Db "cancel $Id"
}

function Stop-RemoteAbaqusJob([string]$JobName, [string]$Node) {
    if (-not $JobName) { return }
    $j = Escape-BashSingle $JobName
    $n = Escape-BashSingle $Node
    $hosts = if ($Node) { @($n) } else { @('login05', 'login08', 'login10') }
    $hostList = ($hosts -join ' ')
    $simple = @"
JOB='$j'
for h in $hostList; do
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no "`$h" \
    "pkill -f 'analysis.pyc -job `$JOB' 2>/dev/null || true; \
     pkill -f '/`$JOB\\.com' 2>/dev/null || true; \
     pkill -f 'eliT_DriverLM -job `$JOB' 2>/dev/null || true; \
     sleep 1; \
     pkill -9 -f 'analysis.pyc -job `$JOB|/`$JOB\\.com|eliT_DriverLM -job `$JOB' 2>/dev/null || true" \
    2>/dev/null || true
done
echo KILL_DONE job=`$JOB
"@
    Invoke-Remote $simple 60
}

function Stop-QueueJob([string]$Id) {
    if (-not $Id) { throw '用法: .\AbqQueue.ps1 stop <id>' }
    Sync-QueueRemote
    $raw = Invoke-Db "stop $Id"
    Write-Host $raw
    try {
        $line = ($raw -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
        if (-not $line) { return }
        $res = $line | ConvertFrom-Json
        if ($res.ok -and $res.action -eq 'kill' -and $res.job_name) {
            Write-Host ("正在终止远端进程 job={0} node={1}" -f $res.job_name, $res.node)
            Stop-RemoteAbaqusJob -JobName ([string]$res.job_name) -Node ([string]$res.node)
        }
    }
    catch {
        Write-Host ("stop 后续处理: " + $_.Exception.Message)
    }
}

function Delete-QueueJob([string]$Id) {
    if (-not $Id) { throw '用法: .\AbqQueue.ps1 delete <id>' }
    Sync-QueueRemote
    # If still running, stop first then delete
    $raw = Invoke-Db "get $Id"
    try {
        $line = ($raw -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
        $row = if ($line) { $line | ConvertFrom-Json } else { $null }
        if ($row -and $row.status -in @('running', 'starting', 'waiting')) {
            Stop-QueueJob -Id $Id | Out-Null
        }
    }
    catch {}
    Invoke-Db "delete $Id"
}

function Show-Nodes {
    Sync-QueueRemote
    $qd = Escape-BashSingle $QueueDir
    $script = @"
QD='$qd'
cd "`$QD"
echo '=== snapshots (db) ==='
python3 abqctl_db.py --queue-dir "`$QD" nodes
echo '=== live scan all ==='
python3 abqctl_node_scan.py all
"@
    Invoke-Remote $script 120
}

function Show-JobsRunning {
    Sync-QueueRemote
    $qd = Escape-BashSingle $QueueDir
    Invoke-Remote "cd '$qd' && python3 abqctl_node_scan.py all" 120
}

function Show-Help {
    @"
AbqQueue.ps1 — 批量队列 / 调度器控制（依赖 abqctl_win 已连接会话）

  .\AbqQueue.ps1 sync                 # 上传 remote/* 到超算队列目录
  .\AbqQueue.ps1 enqueue <远程.inp> [-Cpus 8] [-Double both] [-Priority 0] [-Node login08]
  .\AbqQueue.ps1 list [status]
  .\AbqQueue.ps1 cancel <id>          # 仅 waiting/starting
  .\AbqQueue.ps1 stop <id>            # 排队取消；运行中则杀进程
  .\AbqQueue.ps1 delete <id>          # 从队列删除（运行中会先 stop）
  .\AbqQueue.ps1 scheduler-status
  .\AbqQueue.ps1 scheduler-start [-Node login05]
  .\AbqQueue.ps1 scheduler-stop
  .\AbqQueue.ps1 nodes
  .\AbqQueue.ps1 jobs-running
  .\AbqQueue.ps1 gui

队列目录默认: $QueueDir
本地源码: $RepoRoot
"@ | Write-Host
}

switch ($Command) {
    'help' { Show-Help }
    '' { Show-Help }
    'gui' { & (Join-Path $ScriptDir 'AbqQueueGui.ps1') }
    'sync' { Sync-QueueRemote -Force }
    'enqueue' { Enqueue-Job -InpPath $Arg1 }
    'list' { List-Queue }
    'queue-list' { List-Queue }
    'cancel' { Cancel-QueueJob -Id $Arg1 }
    'queue-cancel' { Cancel-QueueJob -Id $Arg1 }
    'stop' { Stop-QueueJob -Id $Arg1 }
    'delete' { Delete-QueueJob -Id $Arg1 }
    'scheduler-status' { Show-SchedulerStatus }
    'scheduler-start' { Start-SchedulerRemote }
    'scheduler-stop' { Stop-SchedulerRemote }
    'nodes' { Show-Nodes }
    'jobs-running' { Show-JobsRunning }
    default { Show-Help }
}
