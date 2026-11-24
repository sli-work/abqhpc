#Requires -Version 5.1
# Unified WinForms GUI: session + 单作业 + 批量队列 (one window).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Hide console if launched from powershell.exe (VBS launcher also uses Hidden).
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AbqUiNative {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@ -ErrorAction SilentlyContinue
try {
    $cw = [AbqUiNative]::GetConsoleWindow()
    if ($cw -ne [IntPtr]::Zero) { [void][AbqUiNative]::ShowWindow($cw, 0) }
} catch {}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cli = Join-Path $ScriptDir 'abqctl.ps1'
$QueueCli = Join-Path $ScriptDir 'AbqQueue.ps1'
$StateFile = Join-Path $env:TEMP 'abqctl_ssh\session.json'
$XferProgressFile = Join-Path $env:TEMP 'abqctl_ssh\xfer_progress.json'
$DefaultRemoteRoot = '/public/home/tsyg/wh-data'
$StartTab = 'job'
if ($args -contains '-Queue' -or $args -contains 'queue') { $StartTab = 'queue' }

$fontUi = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$form = New-Object System.Windows.Forms.Form
$form.Text = '超算 Abaqus（队列提交 + 监控下载）'
$form.Size = New-Object System.Drawing.Size(1380, 1000)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(1200, 860)
$form.BackColor = [System.Drawing.SystemColors]::Control
$form.ForeColor = [System.Drawing.SystemColors]::ControlText
$form.Font = $fontUi

# ========== session (always visible) ==========
$gbSess = New-Object System.Windows.Forms.GroupBox
$gbSess.Text = '连接会话（密码 = tsyg6100 + 6位动态码，动态码不保存）'
$gbSess.Dock = 'Top'
$gbSess.Height = 86
$gbSess.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)

$lblOtp = New-Object System.Windows.Forms.Label
$lblOtp.Text = '动态码'
$lblOtp.Location = New-Object System.Drawing.Point(16, 32)
$lblOtp.Size = New-Object System.Drawing.Size(56, 22)
$gbSess.Controls.Add($lblOtp)

$txtOtp = New-Object System.Windows.Forms.TextBox
$txtOtp.Location = New-Object System.Drawing.Point(76, 30)
$txtOtp.Size = New-Object System.Drawing.Size(120, 26)
$txtOtp.MaxLength = 14
$txtOtp.Font = New-Object System.Drawing.Font('Consolas', 12)
$gbSess.Controls.Add($txtOtp)

$lblOtpHint = New-Object System.Windows.Forms.Label
$lblOtpHint.Text = '只填 6 位数字，勿加 tsyg6100'
$lblOtpHint.Location = New-Object System.Drawing.Point(76, 58)
$lblOtpHint.Size = New-Object System.Drawing.Size(240, 18)
$lblOtpHint.ForeColor = [System.Drawing.Color]::DimGray
$gbSess.Controls.Add($lblOtpHint)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = '连接 / 保持会话'
$btnConnect.Location = New-Object System.Drawing.Point(214, 28)
$btnConnect.Size = New-Object System.Drawing.Size(150, 30)
$gbSess.Controls.Add($btnConnect)

$lblSess = New-Object System.Windows.Forms.Label
$lblSess.Text = '会话: 未连接'
$lblSess.Location = New-Object System.Drawing.Point(380, 32)
$lblSess.Size = New-Object System.Drawing.Size(900, 24)
$gbSess.Controls.Add($lblSess)

# ========== tabs ==========
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Font = $fontUi
$tabJob = New-Object System.Windows.Forms.TabPage
$tabJob.Text = '监控 / 下载'
$tabQueue = New-Object System.Windows.Forms.TabPage
$tabQueue.Text = '批量队列（上传+入队）'
[void]$tabs.TabPages.Add($tabJob)
[void]$tabs.TabPages.Add($tabQueue)

$pnlXferBar = New-Object System.Windows.Forms.Panel
$pnlXferBar.Dock = 'Top'
$pnlXferBar.Height = 54
$pnlXferBar.Padding = New-Object System.Windows.Forms.Padding(12, 6, 12, 6)
$pnlXferBar.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)

$form.Controls.Add($tabs)
$form.Controls.Add($pnlXferBar)
$form.Controls.Add($gbSess)

# ----- Tab: Job -----
$pnlJobTop = New-Object System.Windows.Forms.Panel
$pnlJobTop.Dock = 'Top'
$pnlJobTop.Height = 280
$pnlJobTop.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 4)

$gbXfer = New-Object System.Windows.Forms.GroupBox
$gbXfer.Text = '下载结果资料（支持断点续传；中断后再次下载会接着传）'
$gbXfer.Location = New-Object System.Drawing.Point(8, 4)
$gbXfer.Size = New-Object System.Drawing.Size(1320, 140)
$gbXfer.Anchor = 'Top,Left,Right'
$pnlJobTop.Controls.Add($gbXfer)

$lblRemoteDir = New-Object System.Windows.Forms.Label
$lblRemoteDir.Text = '远端路径'
$lblRemoteDir.Location = New-Object System.Drawing.Point(16, 32)
$lblRemoteDir.Size = New-Object System.Drawing.Size(70, 24)
$gbXfer.Controls.Add($lblRemoteDir)

$txtRemotePath = New-Object System.Windows.Forms.TextBox
$txtRemotePath.Location = New-Object System.Drawing.Point(90, 30)
$txtRemotePath.Size = New-Object System.Drawing.Size(1200, 26)
$txtRemotePath.Text = $DefaultRemoteRoot
$txtRemotePath.Anchor = 'Top,Left,Right'
$gbXfer.Controls.Add($txtRemotePath)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = '预览远端'
$btnBrowse.Location = New-Object System.Drawing.Point(90, 66)
$btnBrowse.Size = New-Object System.Drawing.Size(120, 32)
$gbXfer.Controls.Add($btnBrowse)

$btnDownload = New-Object System.Windows.Forms.Button
$btnDownload.Text = '下载文件'
$btnDownload.Location = New-Object System.Drawing.Point(222, 66)
$btnDownload.Size = New-Object System.Drawing.Size(120, 32)
$gbXfer.Controls.Add($btnDownload)

$btnDownloadDir = New-Object System.Windows.Forms.Button
$btnDownloadDir.Text = '下载文件夹'
$btnDownloadDir.Location = New-Object System.Drawing.Point(354, 66)
$btnDownloadDir.Size = New-Object System.Drawing.Size(130, 32)
$gbXfer.Controls.Add($btnDownloadDir)

$lblDlHint = New-Object System.Windows.Forms.Label
$lblDlHint.Text = '先填远端路径，再点下载；大文件/目录支持断点续传'
$lblDlHint.Location = New-Object System.Drawing.Point(500, 72)
$lblDlHint.Size = New-Object System.Drawing.Size(500, 22)
$lblDlHint.ForeColor = [System.Drawing.Color]::DimGray
$gbXfer.Controls.Add($lblDlHint)

$progXfer = New-Object System.Windows.Forms.ProgressBar
$progXfer.Location = New-Object System.Drawing.Point(90, 108)
$progXfer.Size = New-Object System.Drawing.Size(1200, 18)
$progXfer.Anchor = 'Top,Left,Right'
$progXfer.Minimum = 0
$progXfer.Maximum = 1000
$gbXfer.Controls.Add($progXfer)

$lblXferProg = New-Object System.Windows.Forms.Label
$lblXferProg.Text = '传输进度: 空闲（上传/下载共用此进度条）'
$lblXferProg.Location = New-Object System.Drawing.Point(12, 10)
$lblXferProg.Size = New-Object System.Drawing.Size(1300, 28)
$lblXferProg.Dock = 'Fill'
$lblXferProg.TextAlign = 'MiddleLeft'
$lblXferProg.Font = New-Object System.Drawing.Font('Consolas', 10)
$pnlXferBar.Controls.Add($lblXferProg)

# Keep hidden placeholders so old handler refs that may remain do not break
$btnUpload = New-Object System.Windows.Forms.Button
$btnUpload.Visible = $false
$gbSub = New-Object System.Windows.Forms.GroupBox
$gbSub.Visible = $false
$txtInp = New-Object System.Windows.Forms.TextBox
$txtInp.Visible = $false
$txtInp.Text = '/public/home/tsyg/wh-data/hq/DYSTQF_CX_1123.inp'
$numCpus = New-Object System.Windows.Forms.NumericUpDown
$numCpus.Visible = $false
$numCpus.Minimum = 1; $numCpus.Maximum = 64; $numCpus.Value = 8
$cmbDouble = New-Object System.Windows.Forms.ComboBox
$cmbDouble.Visible = $false
[void]$cmbDouble.Items.AddRange(@('both', 'explicit', 'off'))
$cmbDouble.SelectedItem = 'both'
$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Visible = $false
$btnList = New-Object System.Windows.Forms.Button
$btnList.Visible = $false
$btnEnqueueOne = New-Object System.Windows.Forms.Button
$btnEnqueueOne.Visible = $false

$gbOps = New-Object System.Windows.Forms.GroupBox
$gbOps.Text = '任务详情 / .sta 监控（计算请到「批量队列」入队）'
$gbOps.Location = New-Object System.Drawing.Point(8, 152)
$gbOps.Size = New-Object System.Drawing.Size(1320, 118)
$gbOps.Anchor = 'Top,Left,Right'
$pnlJobTop.Controls.Add($gbOps)

$lblJob = New-Object System.Windows.Forms.Label
$lblJob.Text = '作业名'
$lblJob.Location = New-Object System.Drawing.Point(16, 32)
$lblJob.Size = New-Object System.Drawing.Size(56, 24)
$gbOps.Controls.Add($lblJob)

$txtJob = New-Object System.Windows.Forms.TextBox
$txtJob.Location = New-Object System.Drawing.Point(76, 30)
$txtJob.Size = New-Object System.Drawing.Size(220, 26)
$txtJob.Text = 'DYSTQF_CX_1123'
$gbOps.Controls.Add($txtJob)

$btnFill = New-Object System.Windows.Forms.Button
$btnFill.Text = '从远端路径填入'
$btnFill.Location = New-Object System.Drawing.Point(310, 28)
$btnFill.Size = New-Object System.Drawing.Size(130, 30)
$gbOps.Controls.Add($btnFill)

$btnStatus = New-Object System.Windows.Forms.Button
$btnStatus.Text = '查看状态'
$btnStatus.Location = New-Object System.Drawing.Point(452, 28)
$btnStatus.Size = New-Object System.Drawing.Size(100, 30)
$gbOps.Controls.Add($btnStatus)

$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Text = '查看日志'
$btnLog.Location = New-Object System.Drawing.Point(564, 28)
$btnLog.Size = New-Object System.Drawing.Size(100, 30)
$gbOps.Controls.Add($btnLog)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = '取消任务'
$btnCancel.Location = New-Object System.Drawing.Point(676, 28)
$btnCancel.Size = New-Object System.Drawing.Size(100, 30)
$gbOps.Controls.Add($btnCancel)

$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Text = '全部状态'
$btnAll.Location = New-Object System.Drawing.Point(788, 28)
$btnAll.Size = New-Object System.Drawing.Size(100, 30)
$gbOps.Controls.Add($btnAll)

$lblInt = New-Object System.Windows.Forms.Label
$lblInt.Text = 'STA刷新秒'
$lblInt.Location = New-Object System.Drawing.Point(16, 72)
$lblInt.Size = New-Object System.Drawing.Size(80, 24)
$gbOps.Controls.Add($lblInt)

$numInt = New-Object System.Windows.Forms.NumericUpDown
$numInt.Location = New-Object System.Drawing.Point(100, 70)
$numInt.Minimum = 2
$numInt.Maximum = 120
$numInt.Value = 5
$numInt.Width = 56
$gbOps.Controls.Add($numInt)

$btnWatch = New-Object System.Windows.Forms.Button
$btnWatch.Text = '开始监控 .sta'
$btnWatch.Location = New-Object System.Drawing.Point(170, 68)
$btnWatch.Size = New-Object System.Drawing.Size(130, 30)
$gbOps.Controls.Add($btnWatch)

$btnStopWatch = New-Object System.Windows.Forms.Button
$btnStopWatch.Text = '停止监控'
$btnStopWatch.Location = New-Object System.Drawing.Point(312, 68)
$btnStopWatch.Size = New-Object System.Drawing.Size(100, 30)
$gbOps.Controls.Add($btnStopWatch)

$btnStaNow = New-Object System.Windows.Forms.Button
$btnStaNow.Text = '立即刷新 .sta'
$btnStaNow.Location = New-Object System.Drawing.Point(424, 68)
$btnStaNow.Size = New-Object System.Drawing.Size(130, 30)
$gbOps.Controls.Add($btnStaNow)

$lblWatch = New-Object System.Windows.Forms.Label
$lblWatch.Text = '监控: 关闭'
$lblWatch.Location = New-Object System.Drawing.Point(570, 74)
$lblWatch.Size = New-Object System.Drawing.Size(280, 24)
$gbOps.Controls.Add($lblWatch)

$splitJob = New-Object System.Windows.Forms.SplitContainer
$splitJob.Dock = 'Fill'
$splitJob.Orientation = 'Horizontal'
$splitJob.SplitterWidth = 8
$splitJob.Panel1MinSize = 60
$splitJob.Panel2MinSize = 80
$splitJob.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)

$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Multiline = $true
$txtOut.ScrollBars = 'Both'
$txtOut.WordWrap = $false
$txtOut.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtOut.Dock = 'Fill'
$txtOut.ReadOnly = $true
$lblOutTitle = New-Object System.Windows.Forms.Label
$lblOutTitle.Text = '命令输出（两 Tab 共用；可拖分隔条）'
$lblOutTitle.Dock = 'Top'
$lblOutTitle.Height = 22
$lblOutTitle.Padding = New-Object System.Windows.Forms.Padding(8, 2, 0, 0)
$splitJob.Panel1.Controls.Add($txtOut)
$splitJob.Panel1.Controls.Add($lblOutTitle)

$txtSta = New-Object System.Windows.Forms.TextBox
$txtSta.Multiline = $true
$txtSta.ScrollBars = 'Both'
$txtSta.WordWrap = $false
$txtSta.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtSta.Dock = 'Fill'
$txtSta.ReadOnly = $true
$lblStaTitle = New-Object System.Windows.Forms.Label
$lblStaTitle.Text = '.sta 实时内容'
$lblStaTitle.Dock = 'Top'
$lblStaTitle.Height = 22
$lblStaTitle.Padding = New-Object System.Windows.Forms.Padding(8, 2, 0, 0)
$splitJob.Panel2.Controls.Add($txtSta)
$splitJob.Panel2.Controls.Add($lblStaTitle)

$tabJob.Controls.Add($splitJob)
$tabJob.Controls.Add($pnlJobTop)

# ----- Tab: Queue -----
$pnlQTop = New-Object System.Windows.Forms.Panel
$pnlQTop.Dock = 'Top'
$pnlQTop.Height = 420
$pnlQTop.Padding = New-Object System.Windows.Forms.Padding(8)

$gbUpload = New-Object System.Windows.Forms.GroupBox
$gbUpload.Text = '准备 .inp：从远端填入，或本地上传（上传进度见下方进度条与顶部状态）'
$gbUpload.Location = New-Object System.Drawing.Point(8, 4)
$gbUpload.Size = New-Object System.Drawing.Size(1320, 130)
$gbUpload.Anchor = 'Top,Left,Right'
$pnlQTop.Controls.Add($gbUpload)

$lblUpDest = New-Object System.Windows.Forms.Label
$lblUpDest.Text = '远端目录'
$lblUpDest.Location = New-Object System.Drawing.Point(16, 32)
$lblUpDest.Size = New-Object System.Drawing.Size(70, 24)
$gbUpload.Controls.Add($lblUpDest)

$txtUploadDir = New-Object System.Windows.Forms.TextBox
$txtUploadDir.Location = New-Object System.Drawing.Point(90, 30)
$txtUploadDir.Size = New-Object System.Drawing.Size(1200, 26)
$txtUploadDir.Text = '/public/home/tsyg/wh-data/hq'
$txtUploadDir.Anchor = 'Top,Left,Right'
$gbUpload.Controls.Add($txtUploadDir)

$btnFillRemoteInps = New-Object System.Windows.Forms.Button
$btnFillRemoteInps.Text = '从远端填入 .inp'
$btnFillRemoteInps.Location = New-Object System.Drawing.Point(90, 66)
$btnFillRemoteInps.Size = New-Object System.Drawing.Size(150, 32)
$gbUpload.Controls.Add($btnFillRemoteInps)

$btnUploadOne = New-Object System.Windows.Forms.Button
$btnUploadOne.Text = '上传单个 .inp'
$btnUploadOne.Location = New-Object System.Drawing.Point(252, 66)
$btnUploadOne.Size = New-Object System.Drawing.Size(130, 32)
$gbUpload.Controls.Add($btnUploadOne)

$btnUploadFolder = New-Object System.Windows.Forms.Button
$btnUploadFolder.Text = '本地文件夹批量上传'
$btnUploadFolder.Location = New-Object System.Drawing.Point(394, 66)
$btnUploadFolder.Size = New-Object System.Drawing.Size(170, 32)
$gbUpload.Controls.Add($btnUploadFolder)

$lblUpHint = New-Object System.Windows.Forms.Label
$lblUpHint.Text = '上传完成后路径会自动写入下方入队列表'
$lblUpHint.Location = New-Object System.Drawing.Point(580, 72)
$lblUpHint.Size = New-Object System.Drawing.Size(420, 22)
$lblUpHint.ForeColor = [System.Drawing.Color]::DimGray
$gbUpload.Controls.Add($lblUpHint)

$progUpload = New-Object System.Windows.Forms.ProgressBar
$progUpload.Location = New-Object System.Drawing.Point(90, 106)
$progUpload.Size = New-Object System.Drawing.Size(1200, 16)
$progUpload.Anchor = 'Top,Left,Right'
$progUpload.Minimum = 0
$progUpload.Maximum = 1000
$gbUpload.Controls.Add($progUpload)

$gbSch = New-Object System.Windows.Forms.GroupBox
$gbSch.Text = '调度器（跑在超算 nohup；多客户端共享，全局仅一个）'
$gbSch.Location = New-Object System.Drawing.Point(8, 142)
$gbSch.Size = New-Object System.Drawing.Size(1320, 72)
$gbSch.Anchor = 'Top,Left,Right'
$pnlQTop.Controls.Add($gbSch)

$lblSch = New-Object System.Windows.Forms.Label
$lblSch.Text = '调度器: 未查询'
$lblSch.Location = New-Object System.Drawing.Point(16, 32)
$lblSch.Size = New-Object System.Drawing.Size(300, 24)
$gbSch.Controls.Add($lblSch)

$btnSync = New-Object System.Windows.Forms.Button
$btnSync.Text = '同步脚本'
$btnSync.Location = New-Object System.Drawing.Point(330, 28)
$btnSync.Size = New-Object System.Drawing.Size(100, 30)
$gbSch.Controls.Add($btnSync)

$btnSchStatus = New-Object System.Windows.Forms.Button
$btnSchStatus.Text = '状态'
$btnSchStatus.Location = New-Object System.Drawing.Point(442, 28)
$btnSchStatus.Size = New-Object System.Drawing.Size(80, 30)
$gbSch.Controls.Add($btnSchStatus)

$btnSchStart = New-Object System.Windows.Forms.Button
$btnSchStart.Text = '启动调度器'
$btnSchStart.Location = New-Object System.Drawing.Point(534, 28)
$btnSchStart.Size = New-Object System.Drawing.Size(110, 30)
$gbSch.Controls.Add($btnSchStart)

$btnSchStop = New-Object System.Windows.Forms.Button
$btnSchStop.Text = '停止调度器'
$btnSchStop.Location = New-Object System.Drawing.Point(656, 28)
$btnSchStop.Size = New-Object System.Drawing.Size(110, 30)
$gbSch.Controls.Add($btnSchStop)

$btnNodes = New-Object System.Windows.Forms.Button
$btnNodes.Text = '节点/运行中'
$btnNodes.Location = New-Object System.Drawing.Point(778, 28)
$btnNodes.Size = New-Object System.Drawing.Size(110, 30)
$gbSch.Controls.Add($btnNodes)

$btnRefreshQ = New-Object System.Windows.Forms.Button
$btnRefreshQ.Text = '刷新队列'
$btnRefreshQ.Location = New-Object System.Drawing.Point(900, 28)
$btnRefreshQ.Size = New-Object System.Drawing.Size(100, 30)
$gbSch.Controls.Add($btnRefreshQ)

$gbEnq = New-Object System.Windows.Forms.GroupBox
$gbEnq.Text = '批量入队 / 选中任务操作（每行一个远端 .inp；远端填入或上传后会自动写入）'
$gbEnq.Location = New-Object System.Drawing.Point(8, 222)
$gbEnq.Size = New-Object System.Drawing.Size(1320, 186)
$gbEnq.Anchor = 'Top,Left,Right'
$pnlQTop.Controls.Add($gbEnq)

$txtBatch = New-Object System.Windows.Forms.TextBox
$txtBatch.Multiline = $true
$txtBatch.ScrollBars = 'Vertical'
$txtBatch.Location = New-Object System.Drawing.Point(16, 26)
$txtBatch.Size = New-Object System.Drawing.Size(1280, 58)
$txtBatch.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtBatch.Anchor = 'Top,Left,Right'
$txtBatch.Text = '/public/home/tsyg/wh-data/hq/DYSTQF_CX_1123.inp'
$gbEnq.Controls.Add($txtBatch)

$lblQCpus = New-Object System.Windows.Forms.Label
$lblQCpus.Text = 'CPUs'
$lblQCpus.Location = New-Object System.Drawing.Point(16, 98)
$lblQCpus.Size = New-Object System.Drawing.Size(42, 22)
$gbEnq.Controls.Add($lblQCpus)

$numQCpus = New-Object System.Windows.Forms.NumericUpDown
$numQCpus.Location = New-Object System.Drawing.Point(60, 94)
$numQCpus.Minimum = 1
$numQCpus.Maximum = 64
$numQCpus.Value = 8
$numQCpus.Width = 56
$gbEnq.Controls.Add($numQCpus)

$lblQDbl = New-Object System.Windows.Forms.Label
$lblQDbl.Text = 'double'
$lblQDbl.Location = New-Object System.Drawing.Point(130, 98)
$lblQDbl.Size = New-Object System.Drawing.Size(50, 22)
$gbEnq.Controls.Add($lblQDbl)

$cmbQDouble = New-Object System.Windows.Forms.ComboBox
$cmbQDouble.Location = New-Object System.Drawing.Point(186, 94)
$cmbQDouble.Width = 100
$cmbQDouble.DropDownStyle = 'DropDownList'
[void]$cmbQDouble.Items.AddRange(@('both', 'explicit', 'off'))
$cmbQDouble.SelectedItem = 'both'
$gbEnq.Controls.Add($cmbQDouble)

$lblPri = New-Object System.Windows.Forms.Label
$lblPri.Text = 'priority'
$lblPri.Location = New-Object System.Drawing.Point(300, 98)
$lblPri.Size = New-Object System.Drawing.Size(55, 22)
$gbEnq.Controls.Add($lblPri)

$numPri = New-Object System.Windows.Forms.NumericUpDown
$numPri.Location = New-Object System.Drawing.Point(360, 94)
$numPri.Minimum = -100
$numPri.Maximum = 100
$numPri.Value = 0
$numPri.Width = 56
$gbEnq.Controls.Add($numPri)

$lblPrefer = New-Object System.Windows.Forms.Label
$lblPrefer.Text = 'prefer节点'
$lblPrefer.Location = New-Object System.Drawing.Point(434, 98)
$lblPrefer.Size = New-Object System.Drawing.Size(80, 22)
$gbEnq.Controls.Add($lblPrefer)

$txtPrefer = New-Object System.Windows.Forms.TextBox
$txtPrefer.Location = New-Object System.Drawing.Point(518, 94)
$txtPrefer.Width = 120
$gbEnq.Controls.Add($txtPrefer)

$btnEnqueue = New-Object System.Windows.Forms.Button
$btnEnqueue.Text = '入队全部'
$btnEnqueue.Location = New-Object System.Drawing.Point(656, 92)
$btnEnqueue.Size = New-Object System.Drawing.Size(120, 30)
$gbEnq.Controls.Add($btnEnqueue)

$btnStopSel = New-Object System.Windows.Forms.Button
$btnStopSel.Text = '停止选中'
$btnStopSel.Location = New-Object System.Drawing.Point(16, 140)
$btnStopSel.Size = New-Object System.Drawing.Size(120, 32)
$gbEnq.Controls.Add($btnStopSel)

$btnDeleteSel = New-Object System.Windows.Forms.Button
$btnDeleteSel.Text = '删除选中'
$btnDeleteSel.Location = New-Object System.Drawing.Point(148, 140)
$btnDeleteSel.Size = New-Object System.Drawing.Size(120, 32)
$gbEnq.Controls.Add($btnDeleteSel)

$btnCancelSel = New-Object System.Windows.Forms.Button
$btnCancelSel.Text = '取消排队(waiting)'
$btnCancelSel.Location = New-Object System.Drawing.Point(280, 140)
$btnCancelSel.Size = New-Object System.Drawing.Size(150, 32)
$gbEnq.Controls.Add($btnCancelSel)

$lblSelHint = New-Object System.Windows.Forms.Label
$lblSelHint.Text = '先在下方列表多选：停止=排队取消/杀运行中进程；删除=从队列移除（运行中会先停止）'
$lblSelHint.Location = New-Object System.Drawing.Point(450, 146)
$lblSelHint.Size = New-Object System.Drawing.Size(820, 22)
$lblSelHint.ForeColor = [System.Drawing.Color]::DimGray
$gbEnq.Controls.Add($lblSelHint)

$splitQ = New-Object System.Windows.Forms.SplitContainer
$splitQ.Dock = 'Fill'
$splitQ.Orientation = 'Horizontal'
$splitQ.SplitterWidth = 6
$splitQ.Panel1MinSize = 120
$splitQ.Panel2MinSize = 60

# Panel1: nodes (top) + queue jobs (fill)
$lblNodes = New-Object System.Windows.Forms.Label
$lblNodes.Text = '登录节点资源（双击填入 prefer；点「刷新队列」或「刷新节点」更新）'
$lblNodes.Dock = 'Top'
$lblNodes.Height = 22
$lblNodes.Padding = New-Object System.Windows.Forms.Padding(8, 2, 0, 0)

$lvNodes = New-Object System.Windows.Forms.ListView
$lvNodes.Dock = 'Top'
$lvNodes.Height = 110
$lvNodes.View = 'Details'
$lvNodes.FullRowSelect = $true
$lvNodes.GridLines = $true
$lvNodes.MultiSelect = $false
[void]$lvNodes.Columns.Add('节点', 110)
[void]$lvNodes.Columns.Add('总核', 55)
[void]$lvNodes.Columns.Add('已用估', 60)
[void]$lvNodes.Columns.Add('可用估', 60)
[void]$lvNodes.Columns.Add('作业数', 55)
[void]$lvNodes.Columns.Add('load', 60)
[void]$lvNodes.Columns.Add('运行中作业', 280)
[void]$lvNodes.Columns.Add('状态', 160)

$lvQueue = New-Object System.Windows.Forms.ListView
$lvQueue.Dock = 'Fill'
$lvQueue.View = 'Details'
$lvQueue.FullRowSelect = $true
$lvQueue.GridLines = $true
$lvQueue.MultiSelect = $true
[void]$lvQueue.Columns.Add('id', 50)
[void]$lvQueue.Columns.Add('status', 80)
[void]$lvQueue.Columns.Add('cpus', 50)
[void]$lvQueue.Columns.Add('node', 90)
[void]$lvQueue.Columns.Add('job', 140)
[void]$lvQueue.Columns.Add('inp', 420)
[void]$lvQueue.Columns.Add('updated', 160)

$lblQueueTitle = New-Object System.Windows.Forms.Label
$lblQueueTitle.Text = '队列任务'
$lblQueueTitle.Dock = 'Top'
$lblQueueTitle.Height = 20
$lblQueueTitle.Padding = New-Object System.Windows.Forms.Padding(8, 2, 0, 0)

# Dock order: Fill first, then Top controls (Top stack from bottom of Tops? Actually last Top is closest to top)
$splitQ.Panel1.Controls.Add($lvQueue)
$splitQ.Panel1.Controls.Add($lblQueueTitle)
$splitQ.Panel1.Controls.Add($lvNodes)
$splitQ.Panel1.Controls.Add($lblNodes)

# Mirror of command output on queue tab (same buffer via sync writes)
$txtOutQ = New-Object System.Windows.Forms.TextBox
$txtOutQ.Multiline = $true
$txtOutQ.ScrollBars = 'Both'
$txtOutQ.WordWrap = $false
$txtOutQ.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtOutQ.Dock = 'Fill'
$txtOutQ.ReadOnly = $true
$lblOutQ = New-Object System.Windows.Forms.Label
$lblOutQ.Text = '命令输出（与「单作业」页同步）'
$lblOutQ.Dock = 'Top'
$lblOutQ.Height = 22
$lblOutQ.Padding = New-Object System.Windows.Forms.Padding(8, 2, 0, 0)
$splitQ.Panel2.Controls.Add($txtOutQ)
$splitQ.Panel2.Controls.Add($lblOutQ)

$tabQueue.Controls.Add($splitQ)
$tabQueue.Controls.Add($pnlQTop)

# rename nodes button for clarity
$btnNodes.Text = '刷新节点'

# ========== helpers / async ==========
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
    $line = (ConvertTo-WinLines $msg).TrimEnd() + "`r`n"
    $txtOut.AppendText($line)
    $txtOutQ.AppendText($line)
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
    if ($sec -ge 3600) { return ('ETA {0}h{1:D2}m' -f [int]($sec / 3600), [int](($sec % 3600) / 60)) }
    if ($sec -ge 60) { return ('ETA {0}m{1:D2}s' -f [int]($sec / 60), [int]($sec % 60)) }
    return ('ETA {0:N0}s' -f $sec)
}

function Sync-UploadProgressBar {
    # Mirror shared transfer progress onto the queue-tab upload bar.
    try {
        if ($progUpload.Style -ne $progXfer.Style) {
            $progUpload.Style = $progXfer.Style
            if ($progXfer.Style -eq 'Marquee') {
                $progUpload.MarqueeAnimationSpeed = 30
            } else {
                $progUpload.MarqueeAnimationSpeed = 0
            }
        }
        if ($progXfer.Style -eq 'Continuous' -and $progUpload.Value -ne $progXfer.Value) {
            $progUpload.Value = $progXfer.Value
        }
    } catch {}
}

function Reset-XferProgressUi {
    try {
        $progXfer.Style = 'Continuous'
        $progXfer.MarqueeAnimationSpeed = 0
        $progXfer.Value = 0
        $progUpload.Style = 'Continuous'
        $progUpload.MarqueeAnimationSpeed = 0
        $progUpload.Value = 0
    } catch {}
    $lblXferProg.Text = '传输进度: 空闲'
}

function Read-XferProgressJson {
    if (-not (Test-Path -LiteralPath $XferProgressFile)) { return $null }
    try {
        $fs = [IO.File]::Open($XferProgressFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)
            try { return $sr.ReadToEnd() } finally { $sr.Close() }
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
            if ($elapsed -ge 1) { $lblXferProg.Text = ("等待进度… {0}s" -f $elapsed) }
        }
        return
    }
    try {
        $p = $raw | ConvertFrom-Json
        $msg = if ($p.message) { [string]$p.message } else { [string]$p.phase }
        switch -Regex ($msg) {
            '^(uploading|开始上传)$' { $msg = '上传中' }
            '^(downloading|开始下载|目录断点续传下载…)$' { $msg = '下载中' }
            '^resume$' { $msg = '断点续传中' }
            '^pack$' { $msg = '远端打包中…' }
            '^extract$' { $msg = '解压中…' }
            '^wait$' { $msg = '准备传输…' }
            '^done$' { $msg = '完成' }
        }
        $pct = 0.0
        try { $pct = [double]$p.pct } catch {}
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
            Sync-UploadProgressBar
        }
        else {
            if ($progXfer.Style -ne 'Continuous') {
                $progXfer.Style = 'Continuous'
                $progXfer.MarqueeAnimationSpeed = 0
            }
            $v = [int][math]::Max(0, [math]::Min(1000, [math]::Round($pct * 10)))
            if ($progXfer.Value -ne $v) { $progXfer.Value = $v }
            $speed = 0.0; $eta = 0.0
            try { $speed = [double]$p.speed_bps } catch {}
            try { $eta = [double]$p.eta_sec } catch {}
            $parts = @()
            if ($total -gt 0) {
                $parts += ("{0:N1}%" -f $pct)
                $parts += ("{0}/{1}" -f (Format-Bytes $xfer), (Format-Bytes $total))
            }
            else {
                $parts += $msg
                $parts += (Format-Bytes $xfer)
            }
            $rateTxt = Format-Rate $speed
            $etaTxt = Format-Eta $eta
            if ($rateTxt) { $parts += $rateTxt }
            if ($etaTxt) { $parts += $etaTxt }
            $lblXferProg.Text = ($parts -join '  |  ')
            Sync-UploadProgressBar
        }
    }
    catch { $lblXferProg.Text = '进度解析中…' }
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
        (@{
            op = 'pending'; phase = 'wait'; remote = ''; local = ''
            transferred = 0; total = 0; pct = 0; message = '准备传输…'
            ts = (Get-Date).ToString('o')
        } | ConvertTo-Json -Compress) | Set-Content -Encoding UTF8 -Path $XferProgressFile
    } catch {}
    Reset-XferProgressUi
    $progXfer.Style = 'Marquee'
    $progXfer.MarqueeAnimationSpeed = 30
    $progUpload.Style = 'Marquee'
    $progUpload.MarqueeAnimationSpeed = 30
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
            $progXfer.Style = 'Continuous'; $progXfer.Value = 1000
            $progUpload.Style = 'Continuous'; $progUpload.Value = 1000
        } catch {}
    }
    elseif ($progXfer.Value -gt 0 -and $lblXferProg.Text -notmatch '失败|空闲') {
        try {
            $progXfer.Style = 'Continuous'; $progXfer.Value = 1000
            $progUpload.Style = 'Continuous'; $progUpload.Value = 1000
            $lblXferProg.Text = '进度: 完成'
        } catch {}
    }
}

$script:busy = $false
$script:staBusy = $false
$timer = New-Object System.Windows.Forms.Timer
$sessTimer = New-Object System.Windows.Forms.Timer
$sessTimer.Interval = 3000
$pendingJobs = New-Object System.Collections.ArrayList
$jobTimer = New-Object System.Windows.Forms.Timer
$jobTimer.Interval = 200

function Invoke-CliAsync {
    param(
        [Parameter(Mandatory)][string]$CliPath,
        [Parameter(Mandatory)][string[]]$CliArgs,
        [scriptblock]$OnOk,
        [scriptblock]$OnErr,
        [scriptblock]$OnFinally
    )
    $job = Start-Job -ScriptBlock {
        param($path, $argList)
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path @argList 2>&1
        $code = $LASTEXITCODE
        $text = ($(if ($null -eq $output) { '' } else { ($output | ForEach-Object { "$_" }) -join "`n" })).Trim()
        if ($text -match '(?m)^abqctl\.ps1 — Windows' -or $text -match '(?m)^AbqQueue\.ps1 —') {
            if ($argList[0] -ne 'help') {
                throw "内部错误：命令未生效。参数=[ $($argList -join ' | ') ]"
            }
        }
        if (($code -ne 0 -and $null -ne $code) -and -not $text) {
            throw "失败 exit=$code 参数=$($argList -join ' ')"
        }
        return $text
    } -ArgumentList $CliPath, (, $CliArgs)

    [void]$pendingJobs.Add([pscustomobject]@{
            Job       = $job
            OnOk      = $OnOk
            OnErr     = $OnErr
            OnFinally = $OnFinally
        })
    if (-not $jobTimer.Enabled) { $jobTimer.Start() }
}

$jobTimer.Add_Tick({
    if ($pendingJobs.Count -eq 0) { $jobTimer.Stop(); return }
    $done = @()
    foreach ($item in @($pendingJobs)) {
        if ($item.Job.State -eq 'Running') { continue }
        $done += $item
        $text = $null; $err = $null
        try {
            if ($item.Job.State -eq 'Failed') {
                $err = ($item.Job.ChildJobs | ForEach-Object { $_.JobStateInfo.Reason.Message }) -join '; '
                if (-not $err) { $err = '后台任务失败' }
            }
            else {
                $recv = Receive-Job $item.Job -ErrorAction SilentlyContinue -ErrorVariable jobErr
                if ($jobErr) { $err = ($jobErr | ForEach-Object { "$_" }) -join "`n" }
                if ($recv -is [System.Array]) { $text = ($recv | ForEach-Object { "$_" }) -join "`n" }
                else { $text = [string]$recv }
            }
        }
        catch { $err = $_.Exception.Message }
        finally { Remove-Job $item.Job -Force -ErrorAction SilentlyContinue }

        try {
            if ($err) { if ($item.OnErr) { & $item.OnErr $err } else { Write-Out $err } }
            else { if ($item.OnOk) { & $item.OnOk $text } else { Write-Out $text } }
        }
        catch { Write-Out $_.Exception.Message }
        finally { if ($item.OnFinally) { & $item.OnFinally } }
    }
    foreach ($d in $done) { [void]$pendingJobs.Remove($d) }
    if ($pendingJobs.Count -eq 0) { $jobTimer.Stop() }
})

function Start-Cmd([string[]]$a, [string]$tip = '执行中…') {
    if ($script:busy) { Write-Out '请等待当前操作完成…'; return }
    Set-Busy $true $tip
    Invoke-CliAsync -CliPath $Cli -CliArgs $a -OnOk {
        param($text)
        if ($text) { Write-Out $text }
    } -OnErr {
        param($err)
        Write-Out $err
    } -OnFinally {
        Set-Busy $false
    }
}

function Start-QueueCmd([string[]]$a, [string]$tip = '队列操作…', [scriptblock]$OnOk = $null) {
    if ($script:busy) { Write-Out '请等待当前操作完成…'; return }
    Set-Busy $true $tip
    Invoke-CliAsync -CliPath $QueueCli -CliArgs $a -OnOk {
        param($text)
        if ($text) { Write-Out $text }
        if ($OnOk) { & $OnOk $text }
    } -OnErr {
        param($err)
        Write-Out $err
    } -OnFinally {
        Set-Busy $false
    }
}

function Extract-JsonPayload([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $start = $raw.IndexOf('[')
    $startObj = $raw.IndexOf('{')
    if ($start -ge 0 -and ($startObj -lt 0 -or $start -le $startObj)) {
        $end = $raw.LastIndexOf(']')
        if ($end -gt $start) { return $raw.Substring($start, $end - $start + 1) }
    }
    if ($startObj -ge 0) {
        $end = $raw.LastIndexOf('}')
        if ($end -gt $startObj) { return $raw.Substring($startObj, $end - $startObj + 1) }
    }
    return $null
}

function Parse-AndFillQueue([string]$raw) {
    $lvQueue.BeginUpdate()
    try {
        $lvQueue.Items.Clear()
        $json = Extract-JsonPayload $raw
        if (-not $json) { return }
        $rows = $json | ConvertFrom-Json
        if (-not $rows) { return }
        if ($rows -isnot [System.Array]) { $rows = @($rows) }
        # skip if looks like node snapshots (have ncpu)
        if ($rows.Count -gt 0 -and ($null -ne $rows[0].ncpu -or $null -ne $rows[0].used_cpus)) {
            return
        }
        foreach ($r in $rows) {
            if ($null -eq $r.id -and $null -eq $r.inp) { continue }
            $item = New-Object System.Windows.Forms.ListViewItem([string]$r.id)
            [void]$item.SubItems.Add([string]$r.status)
            [void]$item.SubItems.Add([string]$r.cpus)
            [void]$item.SubItems.Add([string]$r.node)
            [void]$item.SubItems.Add([string]$r.job_name)
            [void]$item.SubItems.Add([string]$r.inp)
            [void]$item.SubItems.Add([string]$r.updated_at)
            $item.Tag = $r
            [void]$lvQueue.Items.Add($item)
        }
    }
    catch {
        Write-Out ("解析队列失败: " + $_.Exception.Message)
    }
    finally {
        $lvQueue.EndUpdate()
    }
}

function Parse-AndFillNodes([string]$raw) {
    $lvNodes.BeginUpdate()
    try {
        $lvNodes.Items.Clear()
        $json = Extract-JsonPayload $raw
        if (-not $json) { return }
        $rows = $json | ConvertFrom-Json
        if (-not $rows) { return }
        if ($rows -isnot [System.Array]) { $rows = @($rows) }
        foreach ($r in $rows) {
            $node = [string]$(if ($r.node) { $r.node } else { '?' })
            $ncpu = 0; $used = 0; $jobs = 0
            try { $ncpu = [int]$r.ncpu } catch {}
            try { $used = [int]$r.used_cpus } catch {}
            try { $jobs = [int]$r.running_jobs } catch {}
            $free = [math]::Max(0, [int]([math]::Floor($ncpu * 0.8)) - $used)
            $jobNames = ''
            try {
                $jj = $r.jobs
                if ($jj) {
                    if ($jj -isnot [System.Array]) { $jj = @($jj) }
                    $jobNames = (($jj | ForEach-Object { $_.job_name }) -join ', ')
                }
            } catch {}
            # DB snapshot may use detail_json
            if (-not $jobNames -and $r.detail_json) {
                try {
                    $dj = $r.detail_json | ConvertFrom-Json
                    if ($dj) {
                        if ($dj -isnot [System.Array]) { $dj = @($dj) }
                        $jobNames = (($dj | ForEach-Object { $_.job_name }) -join ', ')
                        if (-not $jobs) { $jobs = $dj.Count }
                    }
                } catch {}
            }
            $st = if ($r.error) { [string]$r.error } else { 'ok' }
            $upd = if ($r.updated_at) { [string]$r.updated_at } else { '' }
            if ($upd) { $st = "$st  $upd" }
            $item = New-Object System.Windows.Forms.ListViewItem($node)
            [void]$item.SubItems.Add("$ncpu")
            [void]$item.SubItems.Add("$used")
            [void]$item.SubItems.Add("$free")
            [void]$item.SubItems.Add("$jobs")
            [void]$item.SubItems.Add([string]$r.loadavg)
            [void]$item.SubItems.Add($jobNames)
            [void]$item.SubItems.Add($st)
            $item.Tag = $r
            if ($r.error) {
                $item.ForeColor = [System.Drawing.Color]::Firebrick
            }
            elseif ($free -le 0 -or $jobs -ge 2) {
                $item.ForeColor = [System.Drawing.Color]::DarkOrange
            }
            else {
                $item.ForeColor = [System.Drawing.Color]::DarkGreen
            }
            [void]$lvNodes.Items.Add($item)
        }
    }
    catch {
        Write-Out ("解析节点失败: " + $_.Exception.Message)
    }
    finally {
        $lvNodes.EndUpdate()
    }
}

function Refresh-Nodes {
    Start-QueueCmd @('jobs-running') '刷新节点…' {
        param($out)
        Parse-AndFillNodes $out
    }
}

function Refresh-Queue {
    if ($script:busy) { Write-Out '请等待当前操作完成…'; return }
    Set-Busy $true '刷新队列与节点…'
    $job = Start-Job -ScriptBlock {
        param($path)
        $ErrorActionPreference = 'Continue'
        $q = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path list 2>&1 | Out-String
        $n = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path jobs-running 2>&1 | Out-String
        "===QUEUE===`n$q`n===NODES===`n$n"
    } -ArgumentList $QueueCli
    [void]$pendingJobs.Add([pscustomobject]@{
            Job = $job
            OnOk = {
                param($text)
                if ($text) {
                    $qi = $text.IndexOf('===QUEUE===')
                    $ni = $text.IndexOf('===NODES===')
                    if ($qi -ge 0 -and $ni -gt $qi) {
                        Parse-AndFillQueue $text.Substring($qi, $ni - $qi)
                        Parse-AndFillNodes $text.Substring($ni)
                    }
                    else {
                        Parse-AndFillQueue $text
                        Write-Out $text
                    }
                }
            }
            OnErr = { param($err) Write-Out $err }
            OnFinally = { Set-Busy $false }
        })
    if (-not $jobTimer.Enabled) { $jobTimer.Start() }
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
    Invoke-CliAsync -CliPath $Cli -CliArgs @('sta', $j) -OnOk {
        param($text)
        if (-not $text) { $txtSta.Text = "(无输出) job=$j" }
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

# ========== events: job ==========
$btnConnect.Add_Click({
    if (-not $txtOtp.Text.Trim()) { Write-Out '请输入动态码'; return }
    Start-Cmd @('connect', $txtOtp.Text.Trim()) '正在连接…'
})

$btnBrowse.Add_Click({
    $remote = Get-RemoteXferPath
    Write-Out "预览远端: $remote"
    Start-Cmd @('browse', $remote) '预览远端…'
})

function Get-UploadDestDir {
    $d = $txtUploadDir.Text.Trim() -replace '\\', '/'
    if (-not $d) { $d = '/public/home/tsyg/wh-data/hq' }
    if ($d -match '\.inp$') { $d = ($d -replace '/[^/]+$', '') }
    return $d
}

function Append-BatchPaths([string[]]$Paths) {
    $cur = @($txtBatch.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($p in $Paths) {
        if ($p -and ($cur -notcontains $p)) { $cur += $p }
    }
    $txtBatch.Text = ($cur -join "`r`n")
}

$btnFillRemoteInps.Add_Click({
    $dest = Get-UploadDestDir
    Write-Out "从远端目录列出 .inp: $dest"
    if ($script:busy) { Write-Out '请等待当前操作完成…'; return }
    Set-Busy $true '列出远端 .inp…'
    Invoke-CliAsync -CliPath $Cli -CliArgs @('list-inps', $dest) -OnOk {
        param($text)
        if ($text) { Write-Out $text }
        $paths = @()
        if ($text -match 'remote_paths=(\S*)') {
            $paths = @($Matches[1] -split ';' | Where-Object { $_ })
        }
        if ($paths.Count -eq 0) {
            $paths = @([regex]::Matches($text, '(?m)^inp=(\S+\.inp)\s*$') | ForEach-Object { $_.Groups[1].Value })
        }
        if ($paths.Count -eq 0) {
            Write-Out "该目录下没有 .inp: $dest"
            return
        }
        Append-BatchPaths $paths
        Write-Out ("已从远端填入 {0} 条 .inp，可点「入队全部」" -f $paths.Count)
    } -OnErr {
        param($err)
        Write-Out $err
    } -OnFinally {
        Set-Busy $false
    }
})

$btnUploadOne.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'Abaqus INP (*.inp)|*.inp|所有文件 (*.*)|*.*'
    $ofd.Title = '选择要上传的 inp'
    if ($ofd.ShowDialog($form) -ne 'OK') { return }
    $local = $ofd.FileName
    $dest = Get-UploadDestDir
    Write-Out "上传: $local -> $dest/"
    if ($script:busy) { Write-Out '请等待当前操作完成…'; return }
    Set-Busy $true '上传中…'
    Start-XferProgressWatch
    Invoke-CliAsync -CliPath $Cli -CliArgs @('upload', $local, $dest) -OnOk {
        param($text)
        if ($text) { Write-Out $text }
        $remoteFile = $null
        if ($text -match 'remote_path=(\S+)') { $remoteFile = $Matches[1] }
        if ($remoteFile) {
            Append-BatchPaths @($remoteFile)
            $txtRemotePath.Text = $remoteFile
            Write-Out "已加入入队列表: $remoteFile"
        }
        $lblXferProg.Text = '传输进度: 上传完成'
        $progXfer.Style = 'Continuous'; $progXfer.Value = 1000
        $progUpload.Style = 'Continuous'; $progUpload.Value = 1000
    } -OnErr {
        param($err)
        Write-Out $err
        $lblXferProg.Text = '传输进度: 失败'
    } -OnFinally {
        Stop-XferProgressWatch
        Set-Busy $false
    }
})

$btnUploadFolder.Add_Click({
    $folder = Select-LocalFolder '选择包含 .inp 的本地文件夹（将上传其中全部 .inp）'
    if (-not $folder) { return }
    $dest = Get-UploadDestDir
    $count = @(Get-ChildItem -LiteralPath $folder -Filter '*.inp' -File).Count
    if ($count -eq 0) { Write-Out "文件夹内没有 .inp: $folder"; return }
    Write-Out "批量上传 $count 个 .inp: $folder -> $dest/"
    if ($script:busy) { Write-Out '请等待当前操作完成…'; return }
    Set-Busy $true ("批量上传 {0} 个 inp…" -f $count)
    Start-XferProgressWatch
    Invoke-CliAsync -CliPath $Cli -CliArgs @('upload-inps', $folder, $dest) -OnOk {
        param($text)
        if ($text) { Write-Out $text }
        if ($text -match 'remote_paths=(\S+)') {
            $paths = @($Matches[1] -split ';' | Where-Object { $_ })
            Append-BatchPaths $paths
            Write-Out ("已将 {0} 条路径加入入队列表，可点「入队全部」" -f $paths.Count)
        }
        $lblXferProg.Text = '传输进度: 批量上传完成'
        $progXfer.Style = 'Continuous'
        $progXfer.Value = 1000
        $progUpload.Style = 'Continuous'
        $progUpload.Value = 1000
    } -OnErr {
        param($err)
        Write-Out $err
        $lblXferProg.Text = '传输进度: 失败'
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
    Invoke-CliAsync -CliPath $Cli -CliArgs @('download', $remote, $localDir) -OnOk {
        param($text)
        if ($text) { Write-Out $text }
        $lblXferProg.Text = '进度: 下载完成'
        $progXfer.Style = 'Continuous'; $progXfer.Value = 1000
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
    if (-not $remote) { Write-Out '请填写远端文件夹路径'; return }
    $localDir = Select-LocalFolder '选择保存下载文件夹的本地目录'
    if (-not $localDir) { return }
    Write-Out "下载文件夹: $remote -> $localDir"
    if ($script:busy) { Write-Out '请等待当前操作完成…'; return }
    Set-Busy $true '下载文件夹中…'
    Start-XferProgressWatch
    Invoke-CliAsync -CliPath $Cli -CliArgs @('download-dir', $remote, $localDir) -OnOk {
        param($text)
        if ($text) { Write-Out $text }
        $lblXferProg.Text = '进度: 目录下载完成'
        $progXfer.Style = 'Continuous'; $progXfer.Value = 1000
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
    $p = $txtRemotePath.Text.Trim()
    if (-not $p) { return }
    $name = [IO.Path]::GetFileName($p)
    if ($name.ToLower().EndsWith('.inp')) { $name = $name.Substring(0, $name.Length - 4) }
    elseif ($name.ToLower() -match '\.(odb|sta|log|dat|msg)$') {
        $name = [IO.Path]::GetFileNameWithoutExtension($name)
    }
    $txtJob.Text = $name
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
    $timer.Stop(); $timer.Start()
    $lblWatch.Text = ("监控: {0} / {1}s" -f $txtJob.Text.Trim(), $numInt.Value)
    Write-Out $lblWatch.Text
    Start-StaRefresh -ForceTip
})
$btnStopWatch.Add_Click({ $timer.Stop(); $lblWatch.Text = '监控: 关闭' })
$timer.Add_Tick({ Start-StaRefresh })

# ========== events: queue ==========
$btnSync.Add_Click({ Start-QueueCmd @('sync') '同步远端脚本…' })
$btnSchStatus.Add_Click({
    Start-QueueCmd @('scheduler-status') '查调度器…' {
        param($out)
        if ($out -match 'process=alive') { $lblSch.Text = '调度器: 运行中' }
        elseif ($out -match 'process=dead|scheduler.pid=\(missing\)') { $lblSch.Text = '调度器: 未运行' }
        else { $lblSch.Text = '调度器: 见输出' }
    }
})
$btnSchStart.Add_Click({
    Start-QueueCmd @('scheduler-start') '启动调度器…' {
        param($out)
        if ($out -match 'STARTED|ALREADY_RUNNING') { $lblSch.Text = '调度器: 运行中' }
        else { $lblSch.Text = '调度器: 启动结果见输出' }
    }
})
$btnSchStop.Add_Click({
    Start-QueueCmd @('scheduler-stop') '停止调度器…' {
        param($out)
        $lblSch.Text = '调度器: 已请求停止'
    }
})
$btnNodes.Add_Click({ Refresh-Nodes })
$btnRefreshQ.Add_Click({ Refresh-Queue })
$lvNodes.Add_DoubleClick({
    if ($lvNodes.SelectedItems.Count -lt 1) { return }
    $n = $lvNodes.SelectedItems[0].Text
    if ($n) {
        $txtPrefer.Text = $n
        Write-Out "prefer 节点已设为: $n"
    }
})

$btnEnqueue.Add_Click({
    $lines = @($txtBatch.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($lines.Count -eq 0) { Write-Out '没有可入队的路径'; return }
    $cpus = [int]$numQCpus.Value
    $dbl = [string]$cmbQDouble.SelectedItem
    $pri = [int]$numPri.Value
    $pref = $txtPrefer.Text.Trim()
    $packed = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $a = @('enqueue', $line, '-Cpus', "$cpus", '-Double', $dbl, '-Priority', "$pri")
        if ($pref) { $a += @('-Node', $pref) }
        [void]$packed.Add(($a -join "`t"))
    }
    if ($script:busy) { Write-Out '请等待当前操作完成…'; return }
    Set-Busy $true '批量入队…'
    $job = Start-Job -ScriptBlock {
        param($path, $packs)
        $ErrorActionPreference = 'Continue'
        $sb = New-Object System.Text.StringBuilder
        foreach ($pack in $packs) {
            $parts = $pack -split "`t"
            $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path @parts 2>&1 | Out-String
            [void]$sb.AppendLine($o)
        }
        $sb.ToString()
    } -ArgumentList $QueueCli, @($packed.ToArray())
    [void]$pendingJobs.Add([pscustomobject]@{
            Job = $job
            OnOk = {
                param($text)
                if ($text) { Write-Out $text }
                Refresh-Queue
            }
            OnErr = { param($err) Write-Out $err }
            OnFinally = { Set-Busy $false }
        })
    if (-not $jobTimer.Enabled) { $jobTimer.Start() }
})

function Invoke-QueueIdsAsync([string]$Verb, [string[]]$Ids, [string]$Tip) {
    if (-not $Ids -or $Ids.Count -eq 0) { Write-Out '未选中行'; return }
    if ($script:busy) { Write-Out '请等待当前操作完成…'; return }
    Set-Busy $true $Tip
    $job = Start-Job -ScriptBlock {
        param($path, $verb, $idList)
        $ErrorActionPreference = 'Continue'
        $sb = New-Object System.Text.StringBuilder
        foreach ($id in $idList) {
            $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path $verb $id 2>&1 | Out-String
            [void]$sb.AppendLine($o)
        }
        $sb.ToString()
    } -ArgumentList $QueueCli, $Verb, $Ids
    [void]$pendingJobs.Add([pscustomobject]@{
            Job = $job
            OnOk = {
                param($text)
                if ($text) { Write-Out $text }
                Refresh-Queue
            }
            OnErr = { param($err) Write-Out $err }
            OnFinally = { Set-Busy $false }
        })
    if (-not $jobTimer.Enabled) { $jobTimer.Start() }
}

$btnCancelSel.Add_Click({
    $ids = @($lvQueue.SelectedItems | ForEach-Object { $_.Text })
    Invoke-QueueIdsAsync 'cancel' $ids '取消排队…'
})
$btnStopSel.Add_Click({
    $ids = @($lvQueue.SelectedItems | ForEach-Object { $_.Text })
    if ($ids.Count -eq 0) { Write-Out '未选中行'; return }
    $msg = "停止选中的 $($ids.Count) 条？`n排队中将取消；运行中会杀远端 Abaqus 进程。"
    if ([System.Windows.Forms.MessageBox]::Show($msg, '确认停止', 'YesNo') -ne 'Yes') { return }
    Invoke-QueueIdsAsync 'stop' $ids '停止选中…'
})
$btnDeleteSel.Add_Click({
    $ids = @($lvQueue.SelectedItems | ForEach-Object { $_.Text })
    if ($ids.Count -eq 0) { Write-Out '未选中行'; return }
    $msg = "删除选中的 $($ids.Count) 条记录？`n运行中/排队中会先停止再删除。"
    if ([System.Windows.Forms.MessageBox]::Show($msg, '确认删除', 'YesNo') -ne 'Yes') { return }
    Invoke-QueueIdsAsync 'delete' $ids '删除选中…'
})

$sessTimer.Add_Tick({ if (-not $script:busy) { Update-SessionLabel } })
$sessTimer.Start()
Update-SessionLabel

$splitJob.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$splitQ.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)

$form.Add_Shown({
    try {
        $hj = $splitJob.ClientSize.Height
        if ($hj -gt 200) { $splitJob.SplitterDistance = [Math]::Max(80, [int]($hj * 0.4)) }
        $hq = $splitQ.ClientSize.Height
        if ($hq -gt 200) { $splitQ.SplitterDistance = [Math]::Max(180, [int]($hq * 0.68)) }
        if ($StartTab -eq 'queue') { $tabs.SelectedTab = $tabQueue }
    } catch {}
    Write-Out '批量队列：可用「从远端填入 .inp」或「本地文件夹批量上传」，再点「入队全部」。监控/下载 Tab 支持断点续传。'
})

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
