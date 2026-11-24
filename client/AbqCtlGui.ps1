#Requires -Version 5.1
# Windows WinForms GUI — background workers so the UI never blocks on SSH.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cli = Join-Path $ScriptDir 'abqctl.ps1'
$StateFile = Join-Path $env:TEMP 'abqctl_ssh\session.json'
$XferProgressFile = Join-Path $env:TEMP 'abqctl_ssh\xfer_progress.json'

$form = New-Object System.Windows.Forms.Form
$form.Text = '超算 Abaqus 面板（SSH.NET / 无 Python）'
$form.Size = New-Object System.Drawing.Size(1100, 900)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(900, 720)
$DefaultRemoteRoot = '/public/home/tsyg/wh-data'
$fontUi = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.Font = $fontUi

# Top fixed controls + bottom draggable split views
$pnlTop = New-Object System.Windows.Forms.Panel
$pnlTop.Dock = 'Top'
$pnlTop.Height = 420
$pnlTop.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 4)

# --- session ---
$gbSess = New-Object System.Windows.Forms.GroupBox
$gbSess.Text = '连接会话（密码 = tsyg6100 + 6位动态码，动态码不保存）'
$gbSess.Location = New-Object System.Drawing.Point(4, 2)
$gbSess.Size = New-Object System.Drawing.Size(1070, 78)
$gbSess.Anchor = 'Top,Left,Right'
$pnlTop.Controls.Add($gbSess)

$lblOtp = New-Object System.Windows.Forms.Label
$lblOtp.Text = '动态码'
$lblOtp.Location = New-Object System.Drawing.Point(16, 30)
$lblOtp.Size = New-Object System.Drawing.Size(56, 22)
$lblOtp.TextAlign = 'MiddleLeft'
$gbSess.Controls.Add($lblOtp)

$txtOtp = New-Object System.Windows.Forms.TextBox
$txtOtp.Location = New-Object System.Drawing.Point(76, 28)
$txtOtp.Size = New-Object System.Drawing.Size(110, 24)
$txtOtp.MaxLength = 14
$txtOtp.Font = New-Object System.Drawing.Font('Consolas', 12)
$gbSess.Controls.Add($txtOtp)

$lblOtpHint = New-Object System.Windows.Forms.Label
$lblOtpHint.Text = '只填 6 位数字，勿加 tsyg6100'
$lblOtpHint.Location = New-Object System.Drawing.Point(76, 54)
$lblOtpHint.Size = New-Object System.Drawing.Size(220, 18)
$lblOtpHint.ForeColor = [System.Drawing.Color]::DimGray
$gbSess.Controls.Add($lblOtpHint)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = '连接 / 保持会话'
$btnConnect.Location = New-Object System.Drawing.Point(200, 26)
$btnConnect.Size = New-Object System.Drawing.Size(140, 28)
$gbSess.Controls.Add($btnConnect)

$lblSess = New-Object System.Windows.Forms.Label
$lblSess.Text = '会话: 未连接'
$lblSess.Location = New-Object System.Drawing.Point(360, 30)
$lblSess.Size = New-Object System.Drawing.Size(580, 22)
$lblSess.TextAlign = 'MiddleLeft'
$gbSess.Controls.Add($lblSess)

# --- transfer ---
$gbXfer = New-Object System.Windows.Forms.GroupBox
$gbXfer.Text = '文件传输（默认远端 /public/home/tsyg/wh-data）'
$gbXfer.Location = New-Object System.Drawing.Point(4, 86)
$gbXfer.Size = New-Object System.Drawing.Size(1070, 118)
$gbXfer.Anchor = 'Top,Left,Right'
$pnlTop.Controls.Add($gbXfer)

$lblRemoteDir = New-Object System.Windows.Forms.Label
$lblRemoteDir.Text = '远端路径'
$lblRemoteDir.Location = New-Object System.Drawing.Point(12, 28)
$lblRemoteDir.Size = New-Object System.Drawing.Size(60, 22)
$lblRemoteDir.TextAlign = 'MiddleLeft'
$gbXfer.Controls.Add($lblRemoteDir)

$txtRemotePath = New-Object System.Windows.Forms.TextBox
$txtRemotePath.Location = New-Object System.Drawing.Point(76, 26)
$txtRemotePath.Size = New-Object System.Drawing.Size(430, 24)
$txtRemotePath.Text = $DefaultRemoteRoot
$txtRemotePath.Anchor = 'Top,Left,Right'
$gbXfer.Controls.Add($txtRemotePath)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = '预览远端'
$btnBrowse.Location = New-Object System.Drawing.Point(516, 24)
$btnBrowse.Size = New-Object System.Drawing.Size(84, 28)
$gbXfer.Controls.Add($btnBrowse)

$btnUpload = New-Object System.Windows.Forms.Button
$btnUpload.Text = '上传 inp'
$btnUpload.Location = New-Object System.Drawing.Point(608, 24)
$btnUpload.Size = New-Object System.Drawing.Size(84, 28)
$gbXfer.Controls.Add($btnUpload)

$btnDownload = New-Object System.Windows.Forms.Button
$btnDownload.Text = '下载文件'
$btnDownload.Location = New-Object System.Drawing.Point(700, 24)
$btnDownload.Size = New-Object System.Drawing.Size(84, 28)
$gbXfer.Controls.Add($btnDownload)

$btnDownloadDir = New-Object System.Windows.Forms.Button
$btnDownloadDir.Text = '下载文件夹'
$btnDownloadDir.Location = New-Object System.Drawing.Point(792, 24)
$btnDownloadDir.Size = New-Object System.Drawing.Size(100, 28)
$gbXfer.Controls.Add($btnDownloadDir)

$progXfer = New-Object System.Windows.Forms.ProgressBar
$progXfer.Location = New-Object System.Drawing.Point(76, 58)
$progXfer.Size = New-Object System.Drawing.Size(970, 16)
$progXfer.Minimum = 0
$progXfer.Maximum = 1000
$progXfer.Value = 0
$progXfer.Anchor = 'Top,Left,Right'
$gbXfer.Controls.Add($progXfer)

$lblXferProg = New-Object System.Windows.Forms.Label
$lblXferProg.Text = '进度: 空闲'
$lblXferProg.Location = New-Object System.Drawing.Point(76, 78)
$lblXferProg.Size = New-Object System.Drawing.Size(970, 20)
$lblXferProg.TextAlign = 'MiddleLeft'
$lblXferProg.Anchor = 'Top,Left,Right'
$lblXferProg.Font = New-Object System.Drawing.Font('Consolas', 9)
$gbXfer.Controls.Add($lblXferProg)

$lblXferHint = New-Object System.Windows.Forms.Label
$lblXferHint.Text = '预览目录/文件；进度含百分比与网速；下方输出区可拖动分隔条调整大小'
$lblXferHint.Location = New-Object System.Drawing.Point(76, 98)
$lblXferHint.Size = New-Object System.Drawing.Size(970, 16)
$lblXferHint.ForeColor = [System.Drawing.Color]::DimGray
$gbXfer.Controls.Add($lblXferHint)

# --- submit ---
$gbSub = New-Object System.Windows.Forms.GroupBox
$gbSub.Text = '直接 abaqus 提交'
$gbSub.Location = New-Object System.Drawing.Point(4, 210)
$gbSub.Size = New-Object System.Drawing.Size(1070, 96)
$gbSub.Anchor = 'Top,Left,Right'
$pnlTop.Controls.Add($gbSub)

$lblInp = New-Object System.Windows.Forms.Label
$lblInp.Text = '远程 inp'
$lblInp.Location = New-Object System.Drawing.Point(12, 28)
$lblInp.AutoSize = $true
$gbSub.Controls.Add($lblInp)

$txtInp = New-Object System.Windows.Forms.TextBox
$txtInp.Location = New-Object System.Drawing.Point(80, 24)
$txtInp.Width = 870
$txtInp.Text = '/public/home/tsyg/wh-data/hq/DYSTQF_CX_1123.inp'
$gbSub.Controls.Add($txtInp)

$lblCpus = New-Object System.Windows.Forms.Label
$lblCpus.Text = 'CPU核数'
$lblCpus.Location = New-Object System.Drawing.Point(12, 60)
$lblCpus.AutoSize = $true
$gbSub.Controls.Add($lblCpus)

$numCpus = New-Object System.Windows.Forms.NumericUpDown
$numCpus.Location = New-Object System.Drawing.Point(80, 56)
$numCpus.Minimum = 1
$numCpus.Maximum = 64
$numCpus.Value = 8
$numCpus.Width = 70
$gbSub.Controls.Add($numCpus)

$btn4 = New-Object System.Windows.Forms.Button; $btn4.Text='4'; $btn4.Width=32; $btn4.Location=New-Object System.Drawing.Point(160,55)
$btn8 = New-Object System.Windows.Forms.Button; $btn8.Text='8'; $btn8.Width=32; $btn8.Location=New-Object System.Drawing.Point(196,55)
$btn16 = New-Object System.Windows.Forms.Button; $btn16.Text='16'; $btn16.Width=36; $btn16.Location=New-Object System.Drawing.Point(232,55)
$btn32 = New-Object System.Windows.Forms.Button; $btn32.Text='32'; $btn32.Width=36; $btn32.Location=New-Object System.Drawing.Point(272,55)
$btn40 = New-Object System.Windows.Forms.Button; $btn40.Text='40'; $btn40.Width=36; $btn40.Location=New-Object System.Drawing.Point(312,55)
foreach ($b in @($btn4,$btn8,$btn16,$btn32,$btn40)) { $gbSub.Controls.Add($b) }
$btn4.Add_Click({ $numCpus.Value = 4 })
$btn8.Add_Click({ $numCpus.Value = 8 })
$btn16.Add_Click({ $numCpus.Value = 16 })
$btn32.Add_Click({ $numCpus.Value = 32 })
$btn40.Add_Click({ $numCpus.Value = 40 })

$lblDouble = New-Object System.Windows.Forms.Label
$lblDouble.Text = 'double'
$lblDouble.Location = New-Object System.Drawing.Point(370, 60)
$lblDouble.AutoSize = $true
$gbSub.Controls.Add($lblDouble)

$cmbDouble = New-Object System.Windows.Forms.ComboBox
$cmbDouble.Location = New-Object System.Drawing.Point(430, 56)
$cmbDouble.Width = 100
$cmbDouble.DropDownStyle = 'DropDownList'
[void]$cmbDouble.Items.AddRange(@('both','explicit','off'))
$cmbDouble.SelectedItem = 'both'
$gbSub.Controls.Add($cmbDouble)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = '提交运行'
$btnRun.Location = New-Object System.Drawing.Point(560, 54)
$btnRun.Width = 90
$gbSub.Controls.Add($btnRun)

$btnList = New-Object System.Windows.Forms.Button
$btnList.Text = '列出目录 inp'
$btnList.Location = New-Object System.Drawing.Point(660, 54)
$btnList.Width = 100
$gbSub.Controls.Add($btnList)

# --- ops ---
$gbOps = New-Object System.Windows.Forms.GroupBox
$gbOps.Text = '任务 / .sta 监控'
$gbOps.Location = New-Object System.Drawing.Point(4, 312)
$gbOps.Size = New-Object System.Drawing.Size(1070, 96)
$gbOps.Anchor = 'Top,Left,Right'
$pnlTop.Controls.Add($gbOps)

$lblJob = New-Object System.Windows.Forms.Label
$lblJob.Text = '作业名'
$lblJob.Location = New-Object System.Drawing.Point(12, 28)
$lblJob.AutoSize = $true
$gbOps.Controls.Add($lblJob)

$txtJob = New-Object System.Windows.Forms.TextBox
$txtJob.Location = New-Object System.Drawing.Point(70, 24)
$txtJob.Width = 220
$txtJob.Text = 'DYSTQF_CX_1123'
$gbOps.Controls.Add($txtJob)

$btnFill = New-Object System.Windows.Forms.Button
$btnFill.Text = '从 inp 填入'
$btnFill.Location = New-Object System.Drawing.Point(300, 22)
$btnFill.Width = 90
$gbOps.Controls.Add($btnFill)

$btnStatus = New-Object System.Windows.Forms.Button
$btnStatus.Text = '查看状态'
$btnStatus.Location = New-Object System.Drawing.Point(400, 22)
$btnStatus.Width = 80
$gbOps.Controls.Add($btnStatus)

$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Text = '查看日志'
$btnLog.Location = New-Object System.Drawing.Point(490, 22)
$btnLog.Width = 80
$gbOps.Controls.Add($btnLog)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = '取消任务'
$btnCancel.Location = New-Object System.Drawing.Point(580, 22)
$btnCancel.Width = 80
$gbOps.Controls.Add($btnCancel)

$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Text = '全部状态'
$btnAll.Location = New-Object System.Drawing.Point(670, 22)
$btnAll.Width = 80
$gbOps.Controls.Add($btnAll)

$lblInt = New-Object System.Windows.Forms.Label
$lblInt.Text = 'STA刷新秒'
$lblInt.Location = New-Object System.Drawing.Point(12, 58)
$lblInt.AutoSize = $true
$gbOps.Controls.Add($lblInt)

$numInt = New-Object System.Windows.Forms.NumericUpDown
$numInt.Location = New-Object System.Drawing.Point(90, 54)
$numInt.Minimum = 2
$numInt.Maximum = 120
$numInt.Value = 5
$numInt.Width = 50
$gbOps.Controls.Add($numInt)

$btnWatch = New-Object System.Windows.Forms.Button
$btnWatch.Text = '开始监控 .sta'
$btnWatch.Location = New-Object System.Drawing.Point(160, 52)
$btnWatch.Width = 110
$gbOps.Controls.Add($btnWatch)

$btnStopWatch = New-Object System.Windows.Forms.Button
$btnStopWatch.Text = '停止监控'
$btnStopWatch.Location = New-Object System.Drawing.Point(280, 52)
$btnStopWatch.Width = 90
$gbOps.Controls.Add($btnStopWatch)

$btnStaNow = New-Object System.Windows.Forms.Button
$btnStaNow.Text = '立即刷新 .sta'
$btnStaNow.Location = New-Object System.Drawing.Point(380, 52)
$btnStaNow.Width = 110
$gbOps.Controls.Add($btnStaNow)

$lblWatch = New-Object System.Windows.Forms.Label
$lblWatch.Text = '监控: 关闭'
$lblWatch.Location = New-Object System.Drawing.Point(510, 58)
$lblWatch.AutoSize = $true
$gbOps.Controls.Add($lblWatch)

# --- resizable output / .sta (drag the splitter) ---
$splitMain = New-Object System.Windows.Forms.SplitContainer
$splitMain.Dock = 'Fill'
$splitMain.Orientation = 'Horizontal'
$splitMain.SplitterWidth = 8
$splitMain.Panel1MinSize = 60
$splitMain.Panel2MinSize = 80
$splitMain.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
# Dock order: Fill first, then Top (Top consumes top edge; Fill gets the rest).
$form.Controls.Add($splitMain)
$form.Controls.Add($pnlTop)

$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Multiline = $true
$txtOut.ScrollBars = 'Both'
$txtOut.WordWrap = $false
$txtOut.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtOut.Dock = 'Fill'
$txtOut.ReadOnly = $true

$lblOutTitle = New-Object System.Windows.Forms.Label
$lblOutTitle.Text = '命令输出（拖动中间灰色分隔条可调整上下区域高度）'
$lblOutTitle.Dock = 'Top'
$lblOutTitle.Height = 22
$lblOutTitle.TextAlign = 'MiddleLeft'
$lblOutTitle.Padding = New-Object System.Windows.Forms.Padding(8, 2, 0, 0)

# Fill first, then Top
$splitMain.Panel1.Controls.Add($txtOut)
$splitMain.Panel1.Controls.Add($lblOutTitle)

$txtSta = New-Object System.Windows.Forms.TextBox
$txtSta.Multiline = $true
$txtSta.ScrollBars = 'Both'
$txtSta.WordWrap = $false
$txtSta.AcceptsReturn = $true
$txtSta.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtSta.Dock = 'Fill'
$txtSta.ReadOnly = $true

$lblStaTitle = New-Object System.Windows.Forms.Label
$lblStaTitle.Text = '.sta 实时内容'
$lblStaTitle.Dock = 'Top'
$lblStaTitle.Height = 22
$lblStaTitle.TextAlign = 'MiddleLeft'
$lblStaTitle.Padding = New-Object System.Windows.Forms.Padding(8, 2, 0, 0)

$splitMain.Panel2.Controls.Add($txtSta)
$splitMain.Panel2.Controls.Add($lblStaTitle)

$form.Add_Shown({
    try {
        # ~35% for command output, rest for .sta
        $h = $splitMain.ClientSize.Height
        if ($h -gt 200) { $splitMain.SplitterDistance = [Math]::Max(80, [int]($h * 0.35)) }
    } catch {}
})

function ConvertTo-WinLines([string]$Text) {
    if ($null -eq $Text) { return '' }
    return (($Text -replace "`r`n", "`n" -replace "`r", "`n") -replace "`n", "`r`n")
}

$busy = $false
$staBusy = $false
$timer = New-Object System.Windows.Forms.Timer
$sessTimer = New-Object System.Windows.Forms.Timer
$sessTimer.Interval = 3000

function Write-Out([string]$msg) {
    if ($form.IsDisposed) { return }
    if ($form.InvokeRequired) {
        $form.BeginInvoke([Action[string]]{ param($m) Write-Out $m }, @($msg)) | Out-Null
        return
    }
    $txtOut.AppendText((ConvertTo-WinLines $msg).TrimEnd() + "`r`n")
}

function Update-SessionLabel {
    if ($form.IsDisposed) { return }
    try {
        if (-not (Test-Path $StateFile)) {
            $lblSess.Text = '会话: 未连接'
            return
        }
        $st = Get-Content -Raw -Path $StateFile | ConvertFrom-Json
        if (-not $st.ready -or -not $st.pid) {
            $lblSess.Text = '会话: 未连接'
            return
        }
        $alive = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
        if (-not $alive) {
            $lblSess.Text = '会话: 已断开（请重新连接）'
            return
        }
        $hostName = if ($st.remoteHost) { [string]$st.remoteHost } else { '?' }
        $lblSess.Text = "会话: 已连接  host=$hostName  pid=$($st.pid)"
    }
    catch {
        $lblSess.Text = '会话: 未知'
    }
}

function Set-Busy([bool]$v, [string]$tip = '') {
    $script:busy = $v
    $form.Cursor = if ($v) { 'AppStarting' } else { 'Default' }
    if ($tip) { $lblSess.Text = $tip }
    elseif (-not $v) { Update-SessionLabel }
}

function Format-Bytes([long]$n) {
    if ($n -ge 1GB) { return ('{0:N2} GB' -f ($n / 1GB)) }
    if ($n -ge 1MB) { return ('{0:N2} MB' -f ($n / 1MB)) }
    if ($n -ge 1KB) { return ('{0:N1} KB' -f ($n / 1KB)) }
    return ("$n B")
}

function Format-Rate([double]$bps) {
    if ($bps -le 0) { return '' }
    if ($bps -ge 1GB) { return ('{0:N2} GB/s' -f ($bps / 1GB)) }
    if ($bps -ge 1MB) { return ('{0:N2} MB/s' -f ($bps / 1MB)) }
    if ($bps -ge 1KB) { return ('{0:N1} KB/s' -f ($bps / 1KB)) }
    return ('{0:N0} B/s' -f $bps)
}

function Format-Eta([double]$sec) {
    if ($sec -le 0) { return '' }
    if ($sec -ge 3600) {
        return ('ETA {0}h{1:D2}m' -f [int]($sec / 3600), [int](($sec % 3600) / 60))
    }
    if ($sec -ge 60) {
        return ('ETA {0}m{1:D2}s' -f [int]($sec / 60), [int]($sec % 60))
    }
    return ('ETA {0:N0}s' -f $sec)
}

function Reset-XferProgressUi {
    try {
        $progXfer.Style = 'Continuous'
        $progXfer.MarqueeAnimationSpeed = 0
        $progXfer.Value = 0
    } catch {}
    $lblXferProg.Text = '进度: 空闲'
}

function Read-XferProgressJson {
    if (-not (Test-Path -LiteralPath $XferProgressFile)) { return $null }
    try {
        $fs = [IO.File]::Open($XferProgressFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)
            try { return $sr.ReadToEnd() }
            finally { $sr.Close() }
        }
        finally { $fs.Close() }
    }
    catch { return $null }
}

function Update-XferProgressUi {
    $raw = Read-XferProgressJson
    if ([string]::IsNullOrWhiteSpace($raw)) {
        if ($script:xferWatching) {
            $elapsed = [int]((Get-Date) - $script:xferWatchStarted).TotalSeconds
            if ($elapsed -ge 1) {
                $lblXferProg.Text = ("等待进度… {0}s" -f $elapsed)
            }
        }
        return
    }
    try {
        $p = $raw | ConvertFrom-Json
        $msg = if ($p.message) { [string]$p.message } else { [string]$p.phase }
        switch -Regex ($msg) {
            '^(uploading|开始上传)$' { $msg = '上传中' }
            '^(downloading|开始下载)$' { $msg = '下载中' }
            '^pack$' { $msg = '远端打包中…' }
            '^extract$' { $msg = '解压中…' }
            '^wait$' { $msg = '准备传输…' }
            '^done$' { $msg = '完成' }
        }
        $pct = 0.0
        try { $pct = [double]$p.pct } catch { $pct = 0 }
        $xfer = 0L; $total = 0L
        try { $xfer = [long]$p.transferred } catch {}
        try { $total = [long]$p.total } catch {}
        $phase = [string]$p.phase
        if ($phase -eq 'pack' -or $phase -eq 'wait' -or $phase -eq 'extract' -or ($total -le 0 -and $phase -ne 'done')) {
            if ($progXfer.Style -ne 'Marquee') {
                $progXfer.Style = 'Marquee'
                $progXfer.MarqueeAnimationSpeed = 30
            }
            $lblXferProg.Text = $msg
        }
        else {
            if ($progXfer.Style -ne 'Continuous') {
                $progXfer.Style = 'Continuous'
                $progXfer.MarqueeAnimationSpeed = 0
            }
            $v = [int][math]::Max(0, [math]::Min(1000, [math]::Round($pct * 10)))
            if ($progXfer.Value -ne $v) { $progXfer.Value = $v }
            $speed = 0.0
            $eta = 0.0
            try { $speed = [double]$p.speed_bps } catch {}
            try { $eta = [double]$p.eta_sec } catch {}
            $rateTxt = Format-Rate $speed
            $etaTxt = Format-Eta $eta
            $parts = @()
            if ($total -gt 0) {
                $parts += ("{0:N1}%" -f $pct)
                $parts += ("{0}/{1}" -f (Format-Bytes $xfer), (Format-Bytes $total))
            }
            else {
                $parts += $msg
                $parts += (Format-Bytes $xfer)
            }
            if ($rateTxt) { $parts += $rateTxt }
            if ($etaTxt) { $parts += $etaTxt }
            $lblXferProg.Text = ($parts -join '  |  ')
        }
    }
    catch {
        $lblXferProg.Text = '进度解析中…'
    }
}

$xferTimer = New-Object System.Windows.Forms.Timer
$xferTimer.Interval = 100
$script:xferWatching = $false
$script:xferWatchStarted = Get-Date
$xferTimer.Add_Tick({ Update-XferProgressUi })

function Start-XferProgressWatch {
    $script:xferWatching = $true
    $script:xferWatchStarted = Get-Date
    try {
        $dir = Split-Path -Parent $XferProgressFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        # Seed a local progress file so UI is not stuck before host writes.
        (@{
            op          = 'pending'
            phase       = 'wait'
            remote      = ''
            local       = ''
            transferred = 0
            total       = 0
            pct         = 0
            message     = '准备传输…'
            ts          = (Get-Date).ToString('o')
        } | ConvertTo-Json -Compress) | Set-Content -Encoding UTF8 -Path $XferProgressFile
    }
    catch {}
    Reset-XferProgressUi
    $progXfer.Style = 'Marquee'
    $progXfer.MarqueeAnimationSpeed = 30
    $lblXferProg.Text = '准备传输…'
    if (-not $xferTimer.Enabled) { $xferTimer.Start() }
}

function Stop-XferProgressWatch {
    $script:xferWatching = $false
    Update-XferProgressUi
    $xferTimer.Stop()
    Start-Sleep -Milliseconds 80
    Update-XferProgressUi
    if ($lblXferProg.Text -match '完成') {
        try {
            $progXfer.Style = 'Continuous'
            $progXfer.Value = 1000
        } catch {}
    }
    elseif ($lblXferProg.Text -match '失败|空闲') {
        # keep
    }
    elseif ($progXfer.Value -gt 0) {
        try {
            $progXfer.Style = 'Continuous'
            $progXfer.Value = 1000
            $lblXferProg.Text = '进度: 完成'
        } catch {}
    }
}

# Pending async jobs polled by $jobTimer (avoids UI-thread SSH waits).
$pendingJobs = New-Object System.Collections.ArrayList
$jobTimer = New-Object System.Windows.Forms.Timer
$jobTimer.Interval = 200

function Invoke-AbqCtlAsync {
    param(
        [Parameter(Mandatory)][string[]]$CliArgs,
        [scriptblock]$OnOk,
        [scriptblock]$OnErr,
        [scriptblock]$OnFinally
    )
    $job = Start-Job -ScriptBlock {
        param($cliPath, $argList)
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cliPath @argList 2>&1
        $code = $LASTEXITCODE
        $text = ($(if ($null -eq $output) { '' } else { ($output | ForEach-Object { "$_" }) -join "`n" })).Trim()
        if ($text -match '(?m)^abqctl\.ps1 — Windows') {
            throw "内部错误：命令未生效，落到了 help。参数=[ $($argList -join ' | ') ]"
        }
        if (($code -ne 0 -and $null -ne $code) -and -not $text) {
            throw "失败 exit=$code 参数=$($argList -join ' ')"
        }
        return $text
    } -ArgumentList $Cli, (, $CliArgs)

    [void]$pendingJobs.Add([pscustomobject]@{
            Job        = $job
            OnOk       = $OnOk
            OnErr      = $OnErr
            OnFinally  = $OnFinally
        })
    if (-not $jobTimer.Enabled) { $jobTimer.Start() }
}

$jobTimer.Add_Tick({
    if ($pendingJobs.Count -eq 0) {
        $jobTimer.Stop()
        return
    }
    $done = @()
    foreach ($item in @($pendingJobs)) {
        if ($item.Job.State -eq 'Running') { continue }
        $done += $item
        $text = $null
        $err = $null
        try {
            if ($item.Job.State -eq 'Failed') {
                $err = ($item.Job.ChildJobs | ForEach-Object { $_.JobStateInfo.Reason.Message }) -join "; "
                if (-not $err) { $err = '后台任务失败' }
            }
            else {
                $recv = Receive-Job $item.Job -ErrorAction SilentlyContinue -ErrorVariable jobErr
                if ($jobErr) { $err = ($jobErr | ForEach-Object { "$_" }) -join "`n" }
                if ($recv -is [System.Array]) { $text = ($recv | ForEach-Object { "$_" }) -join "`n" }
                else { $text = [string]$recv }
                if (-not $err -and $item.Job.ChildJobs) {
                    $errs = @($item.Job.ChildJobs | ForEach-Object { $_.Error } | Where-Object { $_ } | ForEach-Object { "$_" })
                    if ($errs -and -not $text) { $err = ($errs -join "`n") }
                }
            }
        }
        catch {
            $err = $_.Exception.Message
        }
        finally {
            Remove-Job $item.Job -Force -ErrorAction SilentlyContinue
        }

        try {
            if ($err) {
                if ($item.OnErr) { & $item.OnErr $err } else { Write-Out $err }
            }
            else {
                if ($item.OnOk) { & $item.OnOk $text } else { Write-Out $text }
            }
        }
        catch {
            Write-Out $_.Exception.Message
        }
        finally {
            if ($item.OnFinally) { & $item.OnFinally }
        }
    }
    foreach ($d in $done) { [void]$pendingJobs.Remove($d) }
    if ($pendingJobs.Count -eq 0) { $jobTimer.Stop() }
})

function Start-Cmd([string[]]$a, [string]$tip = '执行中…') {
    if ($script:busy) { Write-Out '请等待当前操作完成…'; return }
    Set-Busy $true $tip
    Invoke-AbqCtlAsync -CliArgs $a -OnOk {
        param($text)
        if ($text) { Write-Out $text }
    } -OnErr {
        param($err)
        Write-Out $err
    } -OnFinally {
        Set-Busy $false
    }
}

function Start-StaRefresh([switch]$ForceTip) {
    if ($script:staBusy) { return }
    $j = $txtJob.Text.Trim()
    if (-not $j) {
        $txtSta.Text = '请先填写作业名，再刷新 .sta'
        return
    }
    $script:staBusy = $true
    if ($ForceTip) { $lblWatch.Text = ("刷新中… {0}" -f $j) }
    Invoke-AbqCtlAsync -CliArgs @('sta', $j) -OnOk {
        param($text)
        if (-not $text) {
            $txtSta.Text = "(无输出) job=$j"
        }
        elseif ($text -match 'abqctl\.ps1 — Windows') {
            $txtSta.Text = "错误：未拿到 .sta，命令变成了 help。`r`n请重新打开面板后再试。`r`njob=$j"
        }
        else {
            $txtSta.Text = ConvertTo-WinLines $text
            $txtSta.SelectionStart = $txtSta.Text.Length
            $txtSta.ScrollToCaret()
        }
    } -OnErr {
        param($err)
        $txtSta.Text = ConvertTo-WinLines $err
    } -OnFinally {
        $script:staBusy = $false
        if ($timer.Enabled) {
            $lblWatch.Text = ("监控: {0} / {1}s" -f $txtJob.Text.Trim(), $numInt.Value)
        }
    }
}

function Select-LocalFolder([string]$Desc) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Desc
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog($form) -ne 'OK') { return $null }
    return $dlg.SelectedPath
}

function Get-RemoteXferPath {
    $p = $txtRemotePath.Text.Trim()
    if (-not $p) { return $DefaultRemoteRoot }
    return ($p -replace '\\', '/')
}

$btnConnect.Add_Click({
    if (-not $txtOtp.Text.Trim()) { Write-Out '请输入动态码'; return }
    Start-Cmd @('connect', $txtOtp.Text.Trim()) '正在连接…'
})

$btnBrowse.Add_Click({
    $remote = Get-RemoteXferPath
    Write-Out "预览远端: $remote"
    Start-Cmd @('browse', $remote) '预览远端…'
})

$btnUpload.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'Abaqus INP (*.inp)|*.inp|所有文件 (*.*)|*.*'
    $ofd.Title = '选择要上传的 inp'
    if ($ofd.ShowDialog($form) -ne 'OK') { return }
    $local = $ofd.FileName
    $dest = Get-RemoteXferPath
    # 若填的是某个 .inp 路径，则取其目录作为上传目录
    if ($dest -match '\.inp$') { $dest = ($dest -replace '/[^/]+$', '') }
    if (-not $dest) { $dest = $DefaultRemoteRoot }
    Write-Out "上传: $local -> $dest/"
    if ($script:busy) { Write-Out '请等待当前操作完成…'; return }
    Set-Busy $true '上传中…'
    Start-XferProgressWatch
    Invoke-AbqCtlAsync -CliArgs @('upload', $local, $dest) -OnOk {
        param($text)
        if ($text) { Write-Out $text }
        $remoteFile = $null
        if ($text -match 'remote_path=(\S+)') { $remoteFile = $Matches[1] }
        elseif ($text -match 'remote=(\S+)') { $remoteFile = $Matches[1] }
        if ($remoteFile) {
            $txtInp.Text = $remoteFile
            $txtRemotePath.Text = $remoteFile
            $btnFill.PerformClick()
        }
        $lblXferProg.Text = '进度: 上传完成'
        $progXfer.Style = 'Continuous'
        $progXfer.Value = 1000
    } -OnErr {
        param($err)
        Write-Out $err
        $lblXferProg.Text = '进度: 失败'
    } -OnFinally {
        Stop-XferProgressWatch
        Set-Busy $false
    }
})

$btnDownload.Add_Click({
    $remote = Get-RemoteXferPath
    if (-not $remote -or $remote -eq $DefaultRemoteRoot) {
        Write-Out '请在「远端路径」填写要下载的文件完整路径'
        return
    }
    $localDir = Select-LocalFolder '选择保存下载文件的本地文件夹'
    if (-not $localDir) { return }
    Write-Out "下载文件: $remote -> $localDir"
    if ($script:busy) { Write-Out '请等待当前操作完成…'; return }
    Set-Busy $true '下载文件中…'
    Start-XferProgressWatch
    Invoke-AbqCtlAsync -CliArgs @('download', $remote, $localDir) -OnOk {
        param($text)
        if ($text) { Write-Out $text }
        $lblXferProg.Text = '进度: 下载完成'
        $progXfer.Style = 'Continuous'
        $progXfer.Value = 1000
    } -OnErr {
        param($err)
        Write-Out $err
        $lblXferProg.Text = '进度: 失败'
    } -OnFinally {
        Stop-XferProgressWatch
        Set-Busy $false
    }
})

$btnDownloadDir.Add_Click({
    $remote = Get-RemoteXferPath
    if (-not $remote) {
        Write-Out '请在「远端路径」填写要下载的文件夹路径'
        return
    }
    $localDir = Select-LocalFolder '选择保存下载文件夹的本地目录'
    if (-not $localDir) { return }
    Write-Out "下载文件夹: $remote -> $localDir"
    if ($script:busy) { Write-Out '请等待当前操作完成…'; return }
    Set-Busy $true '下载文件夹中…'
    Start-XferProgressWatch
    Invoke-AbqCtlAsync -CliArgs @('download-dir', $remote, $localDir) -OnOk {
        param($text)
        if ($text) { Write-Out $text }
        $lblXferProg.Text = '进度: 目录下载完成'
        $progXfer.Style = 'Continuous'
        $progXfer.Value = 1000
    } -OnErr {
        param($err)
        Write-Out $err
        $lblXferProg.Text = '进度: 失败'
    } -OnFinally {
        Stop-XferProgressWatch
        Set-Busy $false
    }
})

$btnFill.Add_Click({
    $p = $txtInp.Text.Trim()
    if (-not $p) { return }
    $name = [IO.Path]::GetFileName($p)
    if ($name.ToLower().EndsWith('.inp')) { $name = $name.Substring(0, $name.Length - 4) }
    $txtJob.Text = $name
})

$btnRun.Add_Click({
    $inp = $txtInp.Text.Trim()
    if (-not $inp) { Write-Out '请填写远程 inp'; return }
    $btnFill.PerformClick()
    $cpus = [int]$numCpus.Value
    $dbl = [string]$cmbDouble.SelectedItem
    Write-Out "提交参数: inp=$inp cpus=$cpus double=$dbl"
    if ($script:busy) { Write-Out '请等待当前操作完成…'; return }
    Set-Busy $true '提交中…'
    Invoke-AbqCtlAsync -CliArgs @('run', $inp, '-Cpus', "$cpus", '-Double', $dbl) -OnOk {
        param($text)
        if ($text) { Write-Out $text }
        if (-not $timer.Enabled) {
            $timer.Interval = [int]($numInt.Value * 1000)
            $timer.Start()
            $lblWatch.Text = ("监控: {0} / {1}s" -f $txtJob.Text.Trim(), $numInt.Value)
            Start-StaRefresh
        }
    } -OnErr {
        param($err)
        Write-Out $err
    } -OnFinally {
        Set-Busy $false
    }
})

$btnList.Add_Click({
    $inp = $txtInp.Text.Trim()
    $d = if ($inp -match '\.inp$') { ($inp -replace '/[^/]+$','') } elseif ($inp) { $inp } else { '/public/home/tsyg/wh-data/hq' }
    Start-Cmd @('list-inputs', $d) '列出 inp…'
})

$btnStatus.Add_Click({
    $j = $txtJob.Text.Trim()
    if ($j) { Start-Cmd @('status', $j) '查状态…' } else { Start-Cmd @('status', 'all') '查状态…' }
})
$btnAll.Add_Click({ Start-Cmd @('status', 'all') '查状态…' })
$btnLog.Add_Click({
    $j = $txtJob.Text.Trim()
    if (-not $j) { Write-Out '请填写作业名'; return }
    Start-Cmd @('log', $j) '读日志…'
})
$btnCancel.Add_Click({
    $j = $txtJob.Text.Trim()
    if (-not $j) { Write-Out '请填写作业名'; return }
    if ([System.Windows.Forms.MessageBox]::Show("确定取消 $j ?", '确认', 'YesNo') -ne 'Yes') { return }
    $timer.Stop(); $lblWatch.Text = '监控: 关闭'
    Start-Cmd @('cancel', $j) '取消中…'
})

$btnStaNow.Add_Click({ Start-StaRefresh -ForceTip })
$btnWatch.Add_Click({
    if (-not $txtJob.Text.Trim()) { $btnFill.PerformClick() }
    if (-not $txtJob.Text.Trim()) { Write-Out '请填写作业名'; return }
    $timer.Interval = [int]($numInt.Value * 1000)
    $timer.Stop()
    $timer.Start()
    $lblWatch.Text = ("监控: {0} / {1}s" -f $txtJob.Text.Trim(), $numInt.Value)
    Write-Out $lblWatch.Text
    Start-StaRefresh -ForceTip
})
$btnStopWatch.Add_Click({
    $timer.Stop()
    $lblWatch.Text = '监控: 关闭'
})
$timer.Add_Tick({ Start-StaRefresh })
$sessTimer.Add_Tick({ if (-not $script:busy) { Update-SessionLabel } })
$sessTimer.Start()
Update-SessionLabel

$form.Add_FormClosed({
    $timer.Stop(); $timer.Dispose()
    $sessTimer.Stop(); $sessTimer.Dispose()
    $jobTimer.Stop(); $jobTimer.Dispose()
    $xferTimer.Stop(); $xferTimer.Dispose()
    foreach ($item in @($pendingJobs)) {
        try { Stop-Job $item.Job -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job $item.Job -Force -ErrorAction SilentlyContinue } catch {}
    }
    $pendingJobs.Clear()
})

[void]$form.ShowDialog()
