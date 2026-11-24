#Requires -Version 5.1
# Batch queue GUI — uses AbqQueue.ps1 over the existing abqctl_win SSH session.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cli = Join-Path $ScriptDir 'AbqQueue.ps1'
$StateFile = Join-Path $env:TEMP 'abqctl_ssh\session.json'
$QueueDirDefault = '/public/home/tsyg/tsyg/abqctl_queue'

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Abaqus 批量队列 / 调度器'
$form.Size = New-Object System.Drawing.Size(1080, 780)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(900, 640)
$fontUi = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.Font = $fontUi

$pnlTop = New-Object System.Windows.Forms.Panel
$pnlTop.Dock = 'Top'
$pnlTop.Height = 250
$pnlTop.Padding = New-Object System.Windows.Forms.Padding(8)

# --- session / scheduler ---
$gbSch = New-Object System.Windows.Forms.GroupBox
$gbSch.Text = '会话与调度器（须先用 abqctl_win 连接；调度器跑在超算 nohup）'
$gbSch.Location = New-Object System.Drawing.Point(4, 4)
$gbSch.Size = New-Object System.Drawing.Size(1048, 100)
$gbSch.Anchor = 'Top,Left,Right'
$pnlTop.Controls.Add($gbSch)

$lblSess = New-Object System.Windows.Forms.Label
$lblSess.Text = '会话: 检测中…'
$lblSess.Location = New-Object System.Drawing.Point(12, 28)
$lblSess.Size = New-Object System.Drawing.Size(520, 22)
$gbSch.Controls.Add($lblSess)

$lblSch = New-Object System.Windows.Forms.Label
$lblSch.Text = '调度器: 未查询'
$lblSch.Location = New-Object System.Drawing.Point(12, 56)
$lblSch.Size = New-Object System.Drawing.Size(520, 22)
$gbSch.Controls.Add($lblSch)

$btnSync = New-Object System.Windows.Forms.Button
$btnSync.Text = '同步脚本'
$btnSync.Location = New-Object System.Drawing.Point(550, 24)
$btnSync.Size = New-Object System.Drawing.Size(90, 28)
$gbSch.Controls.Add($btnSync)

$btnSchStatus = New-Object System.Windows.Forms.Button
$btnSchStatus.Text = '调度器状态'
$btnSchStatus.Location = New-Object System.Drawing.Point(650, 24)
$btnSchStatus.Size = New-Object System.Drawing.Size(100, 28)
$gbSch.Controls.Add($btnSchStatus)

$btnSchStart = New-Object System.Windows.Forms.Button
$btnSchStart.Text = '启动调度器'
$btnSchStart.Location = New-Object System.Drawing.Point(760, 24)
$btnSchStart.Size = New-Object System.Drawing.Size(100, 28)
$gbSch.Controls.Add($btnSchStart)

$btnSchStop = New-Object System.Windows.Forms.Button
$btnSchStop.Text = '停止调度器'
$btnSchStop.Location = New-Object System.Drawing.Point(870, 24)
$btnSchStop.Size = New-Object System.Drawing.Size(100, 28)
$gbSch.Controls.Add($btnSchStop)

$btnNodes = New-Object System.Windows.Forms.Button
$btnNodes.Text = '节点/运行中'
$btnNodes.Location = New-Object System.Drawing.Point(550, 58)
$btnNodes.Size = New-Object System.Drawing.Size(100, 28)
$gbSch.Controls.Add($btnNodes)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新队列'
$btnRefresh.Location = New-Object System.Drawing.Point(660, 58)
$btnRefresh.Size = New-Object System.Drawing.Size(90, 28)
$gbSch.Controls.Add($btnRefresh)

# --- enqueue ---
$gbEnq = New-Object System.Windows.Forms.GroupBox
$gbEnq.Text = '批量入队（每行一个远端 .inp 绝对路径；也可粘贴多行）'
$gbEnq.Location = New-Object System.Drawing.Point(4, 110)
$gbEnq.Size = New-Object System.Drawing.Size(1048, 130)
$gbEnq.Anchor = 'Top,Left,Right'
$pnlTop.Controls.Add($gbEnq)

$txtBatch = New-Object System.Windows.Forms.TextBox
$txtBatch.Multiline = $true
$txtBatch.ScrollBars = 'Vertical'
$txtBatch.Location = New-Object System.Drawing.Point(12, 24)
$txtBatch.Size = New-Object System.Drawing.Size(700, 70)
$txtBatch.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtBatch.Anchor = 'Top,Left,Right'
$txtBatch.Text = "/public/home/tsyg/wh-data/hq/DYSTQF_CX_1123.inp"
$gbEnq.Controls.Add($txtBatch)

$lblCpus = New-Object System.Windows.Forms.Label
$lblCpus.Text = 'CPUs'
$lblCpus.Location = New-Object System.Drawing.Point(730, 24)
$lblCpus.AutoSize = $true
$gbEnq.Controls.Add($lblCpus)

$numCpus = New-Object System.Windows.Forms.NumericUpDown
$numCpus.Location = New-Object System.Drawing.Point(780, 22)
$numCpus.Minimum = 1
$numCpus.Maximum = 64
$numCpus.Value = 8
$numCpus.Width = 60
$gbEnq.Controls.Add($numCpus)

$lblDbl = New-Object System.Windows.Forms.Label
$lblDbl.Text = 'double'
$lblDbl.Location = New-Object System.Drawing.Point(850, 24)
$lblDbl.AutoSize = $true
$gbEnq.Controls.Add($lblDbl)

$cmbDouble = New-Object System.Windows.Forms.ComboBox
$cmbDouble.Location = New-Object System.Drawing.Point(910, 22)
$cmbDouble.Width = 90
$cmbDouble.DropDownStyle = 'DropDownList'
[void]$cmbDouble.Items.AddRange(@('both', 'explicit', 'off'))
$cmbDouble.SelectedItem = 'both'
$gbEnq.Controls.Add($cmbDouble)

$lblPri = New-Object System.Windows.Forms.Label
$lblPri.Text = 'priority'
$lblPri.Location = New-Object System.Drawing.Point(730, 56)
$lblPri.AutoSize = $true
$gbEnq.Controls.Add($lblPri)

$numPri = New-Object System.Windows.Forms.NumericUpDown
$numPri.Location = New-Object System.Drawing.Point(790, 54)
$numPri.Minimum = -100
$numPri.Maximum = 100
$numPri.Value = 0
$numPri.Width = 60
$gbEnq.Controls.Add($numPri)

$lblNode = New-Object System.Windows.Forms.Label
$lblNode.Text = 'prefer'
$lblNode.Location = New-Object System.Drawing.Point(860, 56)
$lblNode.AutoSize = $true
$gbEnq.Controls.Add($lblNode)

$txtPrefer = New-Object System.Windows.Forms.TextBox
$txtPrefer.Location = New-Object System.Drawing.Point(910, 54)
$txtPrefer.Width = 90
$txtPrefer.Text = ''
$gbEnq.Controls.Add($txtPrefer)

$btnEnqueue = New-Object System.Windows.Forms.Button
$btnEnqueue.Text = '入队全部'
$btnEnqueue.Location = New-Object System.Drawing.Point(730, 88)
$btnEnqueue.Size = New-Object System.Drawing.Size(100, 28)
$gbEnq.Controls.Add($btnEnqueue)

$btnCancelSel = New-Object System.Windows.Forms.Button
$btnCancelSel.Text = '取消选中 waiting'
$btnCancelSel.Location = New-Object System.Drawing.Point(840, 88)
$btnCancelSel.Size = New-Object System.Drawing.Size(130, 28)
$gbEnq.Controls.Add($btnCancelSel)

# --- bottom: queue list + log ---
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Orientation = 'Horizontal'
$split.SplitterWidth = 6
$form.Controls.Add($split)
$form.Controls.Add($pnlTop)

$lv = New-Object System.Windows.Forms.ListView
$lv.Dock = 'Fill'
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.GridLines = $true
$lv.MultiSelect = $true
[void]$lv.Columns.Add('id', 50)
[void]$lv.Columns.Add('status', 80)
[void]$lv.Columns.Add('cpus', 50)
[void]$lv.Columns.Add('node', 90)
[void]$lv.Columns.Add('job', 140)
[void]$lv.Columns.Add('inp', 420)
[void]$lv.Columns.Add('updated', 160)
$split.Panel1.Controls.Add($lv)

$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Multiline = $true
$txtOut.ScrollBars = 'Both'
$txtOut.WordWrap = $false
$txtOut.Dock = 'Fill'
$txtOut.ReadOnly = $true
$txtOut.Font = New-Object System.Drawing.Font('Consolas', 9)
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = '命令输出'
$lblLog.Dock = 'Top'
$lblLog.Height = 22
$split.Panel2.Controls.Add($txtOut)
$split.Panel2.Controls.Add($lblLog)

$form.Add_Shown({
    try {
        $h = $split.ClientSize.Height
        if ($h -gt 200) { $split.SplitterDistance = [Math]::Max(120, [int]($h * 0.55)) }
    } catch {}
})

function ConvertTo-WinLines([string]$Text) {
    if ($null -eq $Text) { return '' }
    return (($Text -replace "`r`n", "`n" -replace "`r", "`n") -replace "`n", "`r`n")
}

function Write-Out([string]$msg) {
    if ($form.IsDisposed) { return }
    if ($form.InvokeRequired) {
        $form.BeginInvoke([Action[string]] { param($m) Write-Out $m }, @($msg)) | Out-Null
        return
    }
    $txtOut.AppendText((ConvertTo-WinLines $msg).TrimEnd() + "`r`n")
}

function Update-SessionLabel {
    try {
        if (-not (Test-Path $StateFile)) {
            $lblSess.Text = '会话: 未连接（请先 abqctl_win connect）'
            return
        }
        $st = Get-Content -Raw -Path $StateFile | ConvertFrom-Json
        $alive = $st.pid -and (Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue)
        if (-not $alive) {
            $lblSess.Text = '会话: 已断开'
            return
        }
        $h = if ($st.remoteHost) { $st.remoteHost } else { '?' }
        $lblSess.Text = "会话: 已连接  host=$h  pid=$($st.pid)  队列=$QueueDirDefault"
    }
    catch {
        $lblSess.Text = '会话: 未知'
    }
}

$script:busy = $false
function Invoke-CliAsync([string[]]$CliArgs, [scriptblock]$OnOk = $null) {
    if ($script:busy) {
        Write-Out '忙：请等当前命令结束'
        return
    }
    $script:busy = $true
    $job = Start-Job -ScriptBlock {
        param($CliPath, $Args)
        $ErrorActionPreference = 'Continue'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CliPath @Args 2>&1 | Out-String
    } -ArgumentList $Cli, $CliArgs

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 400
    $timer.Add_Tick({
        if ($job.State -eq 'Running') { return }
        $timer.Stop()
        $timer.Dispose()
        try {
            $out = Receive-Job $job 2>&1 | Out-String
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            Write-Out $out
            if ($OnOk) { & $OnOk $out }
        }
        catch {
            Write-Out $_.Exception.Message
        }
        finally {
            $script:busy = $false
            Update-SessionLabel
        }
    }.GetNewClosure())
    $timer.Start()
}

function Parse-AndFillQueue([string]$raw) {
    $lv.BeginUpdate()
    try {
        $lv.Items.Clear()
        # extract JSON array from output (may have sync lines before)
        $start = $raw.IndexOf('[')
        $end = $raw.LastIndexOf(']')
        if ($start -lt 0 -or $end -le $start) { return }
        $json = $raw.Substring($start, $end - $start + 1)
        $rows = $json | ConvertFrom-Json
        if (-not $rows) { return }
        if ($rows -isnot [System.Array]) { $rows = @($rows) }
        foreach ($r in $rows) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$r.id)
            [void]$item.SubItems.Add([string]$r.status)
            [void]$item.SubItems.Add([string]$r.cpus)
            [void]$item.SubItems.Add([string]$r.node)
            [void]$item.SubItems.Add([string]$r.job_name)
            [void]$item.SubItems.Add([string]$r.inp)
            [void]$item.SubItems.Add([string]$r.updated_at)
            $item.Tag = $r
            [void]$lv.Items.Add($item)
        }
    }
    catch {
        Write-Out ("解析队列失败: " + $_.Exception.Message)
    }
    finally {
        $lv.EndUpdate()
    }
}

function Refresh-Queue {
    Invoke-CliAsync @('list') {
        param($out)
        Parse-AndFillQueue $out
        if ($out -match 'process=alive|STARTED|ALREADY_RUNNING') {
            $lblSch.Text = '调度器: 可能在运行（见输出）'
        }
    }
}

$btnSync.Add_Click({ Invoke-CliAsync @('sync') })
$btnSchStatus.Add_Click({
    Invoke-CliAsync @('scheduler-status') {
        param($out)
        if ($out -match 'process=alive') { $lblSch.Text = '调度器: 运行中' }
        elseif ($out -match 'process=dead|scheduler.pid=\(missing\)') { $lblSch.Text = '调度器: 未运行' }
        else { $lblSch.Text = '调度器: 见输出' }
    }
})
$btnSchStart.Add_Click({
    Invoke-CliAsync @('scheduler-start') {
        param($out)
        if ($out -match 'STARTED|ALREADY_RUNNING') { $lblSch.Text = '调度器: 运行中' }
        else { $lblSch.Text = '调度器: 启动结果见输出' }
    }
})
$btnSchStop.Add_Click({
    Invoke-CliAsync @('scheduler-stop') {
        param($out)
        $lblSch.Text = '调度器: 已请求停止'
    }
})
$btnNodes.Add_Click({ Invoke-CliAsync @('jobs-running') })
$btnRefresh.Add_Click({ Refresh-Queue })

$btnEnqueue.Add_Click({
    $lines = @($txtBatch.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($lines.Count -eq 0) {
        Write-Out '没有可入队的路径'
        return
    }
    $cpus = [int]$numCpus.Value
    $dbl = [string]$cmbDouble.SelectedItem
    $pri = [int]$numPri.Value
    $pref = $txtPrefer.Text.Trim()
    $argList = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $a = @('enqueue', $line, '-Cpus', "$cpus", '-Double', $dbl, '-Priority', "$pri")
        if ($pref) { $a += @('-Node', $pref) }
        # run sequentially in one job
        $argList.Add(($a -join "`t"))
    }
    if ($script:busy) { Write-Out '忙'; return }
    $script:busy = $true
    $job = Start-Job -ScriptBlock {
        param($CliPath, $Packed)
        $ErrorActionPreference = 'Continue'
        $sb = New-Object System.Text.StringBuilder
        foreach ($pack in $Packed) {
            $parts = $pack -split "`t"
            $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CliPath @parts 2>&1 | Out-String
            [void]$sb.AppendLine($o)
        }
        $sb.ToString()
    } -ArgumentList $Cli, @($argList.ToArray())

    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 500
    $t.Add_Tick({
        if ($job.State -eq 'Running') { return }
        $t.Stop(); $t.Dispose()
        try {
            $out = Receive-Job $job 2>&1 | Out-String
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            Write-Out $out
            Refresh-Queue
        }
        catch { Write-Out $_.Exception.Message }
        finally { $script:busy = $false }
    }.GetNewClosure())
    $t.Start()
})

$btnCancelSel.Add_Click({
    $ids = @($lv.SelectedItems | ForEach-Object { $_.Text })
    if ($ids.Count -eq 0) { Write-Out '未选中行'; return }
    if ($script:busy) { Write-Out '忙'; return }
    $script:busy = $true
    $job = Start-Job -ScriptBlock {
        param($CliPath, $Ids)
        $ErrorActionPreference = 'Continue'
        $sb = New-Object System.Text.StringBuilder
        foreach ($id in $Ids) {
            $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CliPath cancel $id 2>&1 | Out-String
            [void]$sb.AppendLine($o)
        }
        $sb.ToString()
    } -ArgumentList $Cli, $ids
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 400
    $t.Add_Tick({
        if ($job.State -eq 'Running') { return }
        $t.Stop(); $t.Dispose()
        try {
            Write-Out (Receive-Job $job 2>&1 | Out-String)
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            Refresh-Queue
        }
        catch { Write-Out $_.Exception.Message }
        finally { $script:busy = $false }
    }.GetNewClosure())
    $t.Start()
})

$sessTimer = New-Object System.Windows.Forms.Timer
$sessTimer.Interval = 3000
$sessTimer.Add_Tick({ Update-SessionLabel })
$sessTimer.Start()
$form.Add_FormClosed({ $sessTimer.Stop(); $sessTimer.Dispose() })

Update-SessionLabel
Write-Out "队列 GUI 已启动。本地 CLI: $Cli"
Write-Out '请确认 abqctl_win 会话已连接，然后点「同步脚本」→「启动调度器」→ 入队。'

[System.Windows.Forms.Application]::Run($form)
