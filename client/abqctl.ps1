#Requires -Version 5.1
<#
  Windows-native Abaqus helper (no Python).

  Auth uses bundled SSH.NET (Renci.SshNet.dll) — not OpenSSH ASKPASS —
  because Windows OpenSSH password/OTP prompting is unreliable.
  Password = tsyg6100 + 6-digit OTP; OTP is never written to disk.
  `connect` starts one long-lived host process that keeps the SSH session;
  later commands talk to it over localhost TCP.
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

    [string]$RemoteDir = '/public/home/tsyg/wh-data',

    [int]$ListenPort = 0
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HostName = '60.245.128.10'
$Port = 65010
$User = 'tsyg'
$PassPrefix = 'tsyg6100'
$RemoteCtl = '/public/home/tsyg/tsyg/abqctl.sh'
$LocalCtl = Join-Path $ScriptDir 'abqctl.sh'
$LibDir = Join-Path $ScriptDir 'lib'
$SshNetDll = Join-Path $LibDir 'Renci.SshNet.dll'
$StateDir = Join-Path $env:TEMP 'abqctl_ssh'
$StateFile = Join-Path $StateDir 'session.json'
$DefaultRemoteRoot = '/public/home/tsyg/wh-data'
$XferProgressFile = Join-Path $StateDir 'xfer_progress.json'

function Normalize-RemotePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $DefaultRemoteRoot }
    $p = ($Path -replace '\\', '/').Trim()
    if (-not $p.StartsWith('/')) { $p = "$DefaultRemoteRoot/$p" }
    return ($p -replace '/+', '/').TrimEnd('/')
}

function Clear-XferProgress {
    if (Test-Path $XferProgressFile) {
        Remove-Item -Force $XferProgressFile -ErrorAction SilentlyContinue
    }
}

function Write-XferProgress {
    param(
        [string]$Op,
        [string]$Phase = 'transfer',
        [string]$Remote = '',
        [string]$Local = '',
        [long]$Transferred = 0,
        [long]$Total = 0,
        [string]$Message = ''
    )
    Ensure-StateDir
    $pct = 0.0
    if ($Total -gt 0) {
        $pct = [math]::Min(100.0, [math]::Round(100.0 * [double]$Transferred / [double]$Total, 1))
    }
    $obj = @{
        op           = $Op
        phase        = $Phase
        remote       = $Remote
        local        = $Local
        transferred  = $Transferred
        total        = $Total
        pct          = $pct
        message      = $Message
        ts           = (Get-Date).ToString('o')
    }
    $tmp = "$XferProgressFile.tmp"
    ($obj | ConvertTo-Json -Compress) | Set-Content -Encoding UTF8 -Path $tmp
    Move-Item -Force -Path $tmp -Destination $XferProgressFile
}

function Ensure-StateDir {
    if (-not (Test-Path $StateDir)) {
        New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    }
    # legacy cleanup from OpenSSH ASKPASS / ControlMaster experiments
    foreach ($name in @('pass.dat', '.askpass')) {
        $p = Join-Path $StateDir $name
        if (Test-Path $p) { Remove-Item -Force $p -ErrorAction SilentlyContinue }
    }
    Get-ChildItem -Force $StateDir -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'mux_*' } |
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
}

function Read-State {
    if (-not (Test-Path $StateFile)) { return $null }
    try { return (Get-Content -Raw -Path $StateFile | ConvertFrom-Json) } catch { return $null }
}

function Write-State([hashtable]$Data) {
    Ensure-StateDir
    ($Data | ConvertTo-Json -Compress) | Set-Content -Encoding UTF8 -Path $StateFile
}

function ConvertTo-B64([string]$Text) {
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function ConvertFrom-B64([string]$B64) {
    if ([string]::IsNullOrEmpty($B64)) { return '' }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($B64))
}

function Ensure-SshNet {
    if (-not (Test-Path $SshNetDll)) {
        throw "缺少 SSH.NET 库: $SshNetDll。请确认 abqctl_win\lib\Renci.SshNet.dll 存在。"
    }
    Unblock-File -Path $SshNetDll -ErrorAction SilentlyContinue
    if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Renci.SshNet' })) {
        Add-Type -Path $SshNetDll
    }
    if (('AbqCtl.SshAuthHelper' -as [type]) -and -not ('AbqCtl.ResumeDownload' -as [type])) {
        throw '当前进程加载了旧版 SSH 组件。请关闭面板后重新打开，再连接，以启用断点续传下载。'
    }
    if (-not ('AbqCtl.SshAuthHelper' -as [type])) {
        $ref = [Renci.SshNet.SshClient].Assembly.Location
        Add-Type -ReferencedAssemblies @($ref, 'System.Core') -TypeDefinition @'
using System;
using System.Globalization;
using System.IO;
using System.Text;
using Renci.SshNet;
using Renci.SshNet.Common;

namespace AbqCtl {
  public static class SshAuthHelper {
    public static SshClient Connect(string host, int port, string user, string password, int timeoutSec) {
      var pauth = new PasswordAuthenticationMethod(user, password);
      var kauth = new KeyboardInteractiveAuthenticationMethod(user);
      kauth.AuthenticationPrompt += (sender, e) => {
        foreach (var prompt in e.Prompts) {
          prompt.Response = password;
        }
      };
      var conn = new ConnectionInfo(host, port, user, pauth, kauth);
      conn.Timeout = TimeSpan.FromSeconds(timeoutSec);
      var client = new SshClient(conn);
      client.HostKeyReceived += (sender, e) => { e.CanTrust = true; };
      client.KeepAliveInterval = TimeSpan.FromSeconds(30);
      client.Connect();
      return client;
    }

    // Must trust host key in C# — PowerShell scriptblocks have no Runspace on SSH.NET threads.
    public static SftpClient ConnectSftp(SshClient ssh) {
      var sftp = new SftpClient(ssh.ConnectionInfo);
      sftp.HostKeyReceived += (sender, e) => { e.CanTrust = true; };
      sftp.OperationTimeout = TimeSpan.FromMinutes(30);
      sftp.Connect();
      return sftp;
    }
  }

  // Counts bytes as SSH.NET reads/writes the stream — reliable even if UploadFile callback is sparse.
  // baseOffset: already-transferred bytes (resume); callback reports base+new.
  public sealed class ProgressStream : Stream {
    readonly Stream _inner;
    readonly Action<ulong> _cb;
    long _count;
    readonly long _base;
    readonly bool _ownInner;
    public ProgressStream(Stream inner, Action<ulong> cb, bool ownInner) : this(inner, cb, ownInner, 0) {}
    public ProgressStream(Stream inner, Action<ulong> cb, bool ownInner, long baseOffset) {
      _inner = inner; _cb = cb; _ownInner = ownInner; _base = baseOffset < 0 ? 0 : baseOffset;
    }
    public override bool CanRead { get { return _inner.CanRead; } }
    public override bool CanSeek { get { return _inner.CanSeek; } }
    public override bool CanWrite { get { return _inner.CanWrite; } }
    public override long Length { get { return _inner.Length; } }
    public override long Position {
      get { return _inner.Position; }
      set { _inner.Position = value; }
    }
    public override void Flush() { _inner.Flush(); }
    public override long Seek(long offset, SeekOrigin origin) { return _inner.Seek(offset, origin); }
    public override void SetLength(long value) { _inner.SetLength(value); }
    public override int Read(byte[] buffer, int offset, int count) {
      int n = _inner.Read(buffer, offset, count);
      if (n > 0) {
        _count += n;
        if (_cb != null) _cb((ulong)(_base + _count));
      }
      return n;
    }
    public override void Write(byte[] buffer, int offset, int count) {
      _inner.Write(buffer, offset, count);
      if (count > 0) {
        _count += count;
        if (_cb != null) _cb((ulong)(_base + _count));
      }
    }
    protected override void Dispose(bool disposing) {
      if (disposing && _ownInner) _inner.Dispose();
      base.Dispose(disposing);
    }
  }

  public static class ResumeDownload {
    const int BufSize = 256 * 1024;

    public static long DownloadFile(SftpClient sftp, string remote, string local, Action<ulong> onBytes) {
      if (!sftp.Exists(remote)) throw new Exception("remote file missing: " + remote);
      long total = (long)sftp.GetAttributes(remote).Size;
      long offset = 0;
      if (File.Exists(local)) {
        offset = new FileInfo(local).Length;
        if (offset == total && total > 0) {
          if (onBytes != null) onBytes((ulong)total);
          return total;
        }
        if (offset > total) {
          File.Delete(local);
          offset = 0;
        }
      }
      string dir = Path.GetDirectoryName(local);
      if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);

      using (var remoteStream = sftp.OpenRead(remote)) {
        if (offset > 0) remoteStream.Seek(offset, SeekOrigin.Begin);
        var mode = offset > 0 ? FileMode.OpenOrCreate : FileMode.Create;
        using (var fs = new FileStream(local, mode, FileAccess.Write, FileShare.Read)) {
          if (offset > 0) fs.Seek(offset, SeekOrigin.Begin);
          var buf = new byte[BufSize];
          long done = offset;
          if (onBytes != null) onBytes((ulong)done);
          int n;
          while ((n = remoteStream.Read(buf, 0, buf.Length)) > 0) {
            fs.Write(buf, 0, n);
            done += n;
            if (onBytes != null) onBytes((ulong)done);
          }
          fs.Flush();
        }
      }
      long finalLen = new FileInfo(local).Length;
      if (total > 0 && finalLen != total) {
        throw new Exception(string.Format("size mismatch local={0} remote={1}", finalLen, total));
      }
      return finalLen;
    }

    static void CollectFiles(SftpClient sftp, string remoteDir, string prefix, System.Collections.Generic.List<object[]> sink) {
      foreach (var e in sftp.ListDirectory(remoteDir)) {
        if (e.Name == "." || e.Name == "..") continue;
        string rel = string.IsNullOrEmpty(prefix) ? e.Name : (prefix + "/" + e.Name);
        if (e.IsDirectory) CollectFiles(sftp, e.FullName.Replace("\\", "/"), rel, sink);
        else if (e.IsRegularFile) sink.Add(new object[] { e.FullName.Replace("\\", "/"), rel, (long)e.Length });
      }
    }

    public static long MeasureDirectory(SftpClient sftp, string remoteDir) {
      remoteDir = remoteDir.TrimEnd('/');
      var files = new System.Collections.Generic.List<object[]>();
      CollectFiles(sftp, remoteDir, "", files);
      long grand = 0;
      for (int i = 0; i < files.Count; i++) grand += (long)files[i][2];
      return grand;
    }

    // Returns "files=N bytes=B skipped=S local=..."
    public static string DownloadDirectory(SftpClient sftp, string remoteDir, string localRoot, Action<ulong> onBytes) {
      remoteDir = remoteDir.TrimEnd('/');
      var files = new System.Collections.Generic.List<object[]>();
      CollectFiles(sftp, remoteDir, "", files);
      long grand = 0;
      for (int i = 0; i < files.Count; i++) grand += (long)files[i][2];
      long transferred = 0;
      int skipped = 0;
      string leaf = Path.GetFileName(remoteDir);
      string destRoot = Path.Combine(localRoot, leaf);
      for (int i = 0; i < files.Count; i++) {
        string rem = (string)files[i][0];
        string rel = (string)files[i][1];
        long sz = (long)files[i][2];
        string local = Path.Combine(destRoot, rel.Replace('/', Path.DirectorySeparatorChar));
        if (File.Exists(local)) {
          long already = new FileInfo(local).Length;
          if (already == sz && sz >= 0) {
            skipped++;
            transferred += sz;
            if (onBytes != null) onBytes((ulong)transferred);
            continue;
          }
        }
        long baseDone = transferred;
        DownloadFile(sftp, rem, local, delegate(ulong fileDone) {
          if (onBytes != null) onBytes((ulong)(baseDone + (long)fileDone));
        });
        transferred = baseDone + sz;
        if (onBytes != null) onBytes((ulong)transferred);
      }
      return string.Format("files={0} bytes={1} skipped={2} local={3}", files.Count, grand, skipped, destRoot);
    }
  }

  // Progress callback runs on SSH.NET worker threads — write JSON with pure .NET only.
  public static class XferProgress {
    public static string FilePath;
    public static string Op;
    public static string Phase;
    public static string Remote;
    public static string Local;
    public static string Message;
    public static long Total;
    static readonly object Gate = new object();
    static DateTime _lastWrite = DateTime.MinValue;
    static DateTime _rateStamp = DateTime.MinValue;
    static long _rateBytes = 0;
    static double _speedBps = 0;

    public static void Begin(string filePath, string op, string phase, string remote, string local, long total, string message) {
      FilePath = filePath;
      Op = op; Phase = phase; Remote = remote; Local = local; Total = total; Message = message;
      _lastWrite = DateTime.MinValue;
      _rateStamp = DateTime.MinValue;
      _rateBytes = 0;
      _speedBps = 0;
      Write(0, total, message, phase, true);
    }

    public static void SetPhase(string phase, string message, long transferred, long total) {
      Phase = phase; Message = message; Total = total;
      Write(transferred, total, message, phase, true);
    }

    public static void Clear() {
      try {
        if (!string.IsNullOrEmpty(FilePath) && File.Exists(FilePath)) File.Delete(FilePath);
      } catch { }
    }

    public static void OnBytes(ulong done) {
      var now = DateTime.UtcNow;
      long d = (long)done;
      bool force = (Total > 0 && d >= Total);
      if (!force && (now - _lastWrite).TotalMilliseconds < 100) return;
      _lastWrite = now;
      Write(d, Total, Message, Phase, false);
    }

    public static Action<ulong> Callback {
      get { return OnBytes; }
    }

    static void Write(long transferred, long total, string message, string phase, bool force) {
      if (string.IsNullOrEmpty(FilePath)) return;
      // ASCII only inside Add-Type source (Chinese literals can corrupt under csc).
      if (phase == "upload" && transferred > 0) message = "uploading";
      if (phase == "download" && transferred > 0) message = "downloading";
      double pct = 0;
      if (total > 0) pct = Math.Min(100.0, Math.Round(100.0 * (double)transferred / (double)total, 1));

      var now = DateTime.UtcNow;
      if (_rateStamp == DateTime.MinValue) {
        _rateStamp = now;
        _rateBytes = transferred;
      } else {
        double dt = (now - _rateStamp).TotalSeconds;
        if (dt >= 0.2) {
          long db = transferred - _rateBytes;
          if (db < 0) db = 0;
          double inst = db / dt;
          _speedBps = (_speedBps <= 1) ? inst : (_speedBps * 0.65 + inst * 0.35);
          _rateStamp = now;
          _rateBytes = transferred;
        }
      }
      double speed = Math.Max(0, _speedBps);
      double eta = 0;
      if (speed > 1 && total > transferred) eta = (total - transferred) / speed;

      var sb = new StringBuilder(320);
      sb.Append("{\"op\":\"").Append(Esc(Op)).Append("\",");
      sb.Append("\"phase\":\"").Append(Esc(phase)).Append("\",");
      sb.Append("\"remote\":\"").Append(Esc(Remote)).Append("\",");
      sb.Append("\"local\":\"").Append(Esc(Local)).Append("\",");
      sb.Append("\"transferred\":").Append(transferred.ToString(CultureInfo.InvariantCulture)).Append(",");
      sb.Append("\"total\":").Append(total.ToString(CultureInfo.InvariantCulture)).Append(",");
      sb.Append("\"pct\":").Append(pct.ToString(CultureInfo.InvariantCulture)).Append(",");
      sb.Append("\"speed_bps\":").Append(speed.ToString("0.###", CultureInfo.InvariantCulture)).Append(",");
      sb.Append("\"eta_sec\":").Append(eta.ToString("0.###", CultureInfo.InvariantCulture)).Append(",");
      sb.Append("\"message\":\"").Append(Esc(message)).Append("\",");
      sb.Append("\"ts\":\"").Append(DateTime.Now.ToString("o")).Append("\"}");
      var json = sb.ToString();
      lock (Gate) {
        // FileShare.ReadWrite: GUI can poll while host keeps updating (Delete+Move was locking).
        for (int i = 0; i < 5; i++) {
          try {
            using (var fs = new FileStream(FilePath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite))
            using (var sw = new StreamWriter(fs, new UTF8Encoding(false))) {
              sw.Write(json);
            }
            return;
          } catch {
            System.Threading.Thread.Sleep(20);
          }
        }
      }
    }

    static string Esc(string s) {
      if (string.IsNullOrEmpty(s)) return "";
      return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", " ");
    }
  }
}
'@
    }
}

function Stop-HostProcess {
    $st = Read-State
    if ($st -and $st.pid) {
        Stop-Process -Id ([int]$st.pid) -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $StateFile) { Remove-Item -Force $StateFile -ErrorAction SilentlyContinue }
}

function Send-HostRequest([hashtable]$Req, [int]$TimeoutSec = 180) {
    $st = Read-State
    if (-not $st -or -not $st.port -or -not $st.token) {
        throw '会话未连接。请先输入动态码并连接。'
    }
    $alive = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
    if (-not $alive) {
        throw '会话进程已退出（动态码不会被保存）。请重新连接。'
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
    # Windows PowerShell here-strings are CRLF; bash rejects `\r` (e.g. `case ... in\r`).
    $cmd = $RemoteCommand -replace "`r", ''
    return (Send-HostRequest @{ op = 'run'; cmd = $cmd } $TimeoutSec)
}

function Sync-RemoteCtl([switch]$Force) {
    if (-not (Test-Path $LocalCtl)) { return }
    $marker = Join-Path $StateDir 'ctl.sha256'
    $hash = (Get-FileHash -Algorithm SHA256 -Path $LocalCtl).Hash
    if (-not $Force -and (Test-Path $marker)) {
        $old = (Get-Content -Raw -Path $marker).Trim()
        if ($old -eq $hash) { return }
    }
    $raw = [IO.File]::ReadAllText($LocalCtl)
    $raw = $raw -replace "`r", ''
    $b64 = ConvertTo-B64 $raw
    $cmd = "mkdir -p /public/home/tsyg/tsyg; printf '%s' '$b64' | base64 -d > $RemoteCtl; chmod +x $RemoteCtl; echo SYNC_OK"
    $out = Invoke-Remote $cmd 60
    if ($out -notmatch 'SYNC_OK') { throw "同步远端脚本失败: $out" }
    Ensure-StateDir
    Set-Content -Encoding ASCII -Path $marker -Value $hash
}

function Get-LoginPassword([string]$InputCode) {
    # 密码 = 静态前缀 tsyg6100 + 动态码。
    # 若输入已以 tsyg6100 开头，则视为完整密码，不再拼接。
    $code = ($InputCode -replace '\s', '')
    if ([string]::IsNullOrWhiteSpace($code)) {
        throw '请填写动态码（只填 6 位动态码，不要带 tsyg6100）。'
    }
    if ($code.StartsWith($PassPrefix)) {
        if ($code.Length -ne ($PassPrefix.Length + 6)) {
            throw ("完整密码应为 {0} 位（tsyg6100 + 6 位动态码），当前 {1} 位。" -f ($PassPrefix.Length + 6), $code.Length)
        }
        return $code
    }
    if ($code -notmatch '^\d{6}$') {
        throw ("动态码应为 6 位数字，当前长度 {0}。不要填写 tsyg6100 前缀。" -f $code.Length)
    }
    return ($PassPrefix + $code)
}

function Connect-Session([string]$Otp) {
    Ensure-StateDir
    Ensure-SshNet
    Stop-HostProcess

    $loginPassword = Get-LoginPassword $Otp
    $rawCode = ($Otp -replace '\s', '')
    if ($rawCode.StartsWith($PassPrefix)) {
        Write-Host ("输入已含前缀 tsyg6100，按完整密码登录，长度 {0}。" -f $loginPassword.Length)
    }
    else {
        Write-Host ("登录密码 = tsyg6100 + 动态码。动态码 {0} 位，密码共 {1} 位。" -f $rawCode.Length, $loginPassword.Length)
    }

    $pipeName = 'abqctl' + [guid]::NewGuid().ToString('N')
    $self = $MyInvocation.MyCommand.Path
    if (-not $self) { $self = Join-Path $ScriptDir 'abqctl.ps1' }
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self,
        '-Command', '_host', '-Arg1', $pipeName
    )
    $hostProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru

    $pipe = $null
    try {
        $connected = $false
        foreach ($i in 1..50) {
            try {
                $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, 'Out')
                $pipe.Connect(250)
                $connected = $true
                break
            }
            catch {
                if ($hostProc.HasExited) { break }
                Start-Sleep -Milliseconds 150
            }
        }
        if (-not $connected) {
            $log = Join-Path $StateDir 'host.log'
            $tail = if (Test-Path $log) { (Get-Content $log -Tail 8) -join ' | ' } else { '' }
            throw ("会话进程没有起来。$tail")
        }
        $sw = New-Object System.IO.StreamWriter($pipe, (New-Object System.Text.UTF8Encoding $false))
        $sw.AutoFlush = $true
        $sw.WriteLine($loginPassword)
        $sw.Dispose()
        $pipe.Dispose()
        $pipe = $null
        $loginPassword = $null

        $deadline = (Get-Date).AddSeconds(45)
        do {
            Start-Sleep -Milliseconds 250
            $st = Read-State
            if ($st -and $st.error) { throw ([string]$st.error) }
            if ($st -and $st.ready -and [int]$st.pid -eq $hostProc.Id) {
                Write-Host '连接成功，SSH 会话已保持（未保存动态码）。'
                Write-Host ("host={0} pid={1}" -f $st.remoteHost, $st.pid)
                Sync-RemoteCtl -Force
                return
            }
            if ($hostProc.HasExited) { break }
        } while ((Get-Date) -lt $deadline)

        $st = Read-State
        $log = Join-Path $StateDir 'host.log'
        $detail = if ($st -and $st.error) { [string]$st.error } else { '连接超时或登录失败。请换一个新的动态码再试。' }
        if (Test-Path $log) {
            $tail = (Get-Content $log -Tail 6) -join "`n"
            if ($tail) { $detail = "$detail`n--- host.log ---`n$tail" }
        }
        throw $detail
    }
    finally {
        if ($pipe) { $pipe.Dispose() }
    }
}

function Start-SessionHost([string]$PipeName) {
    $ErrorActionPreference = 'Continue'
    Ensure-StateDir
    $log = Join-Path $StateDir 'host.log'
    function Log([string]$m) {
        try { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) } catch {}
    }

    try {
        Ensure-SshNet
    }
    catch {
        Write-State @{ ready = $false; error = $_.Exception.Message; pid = $PID }
        Log $_.Exception.Message
        return
    }

    $pipe = New-Object System.IO.Pipes.NamedPipeServerStream($PipeName, 'In')
    $pipe.WaitForConnection()
    $sr = New-Object System.IO.StreamReader($pipe, [Text.Encoding]::UTF8)
    $password = $sr.ReadLine()
    $sr.Dispose()
    $pipe.Dispose()
    if ([string]::IsNullOrWhiteSpace($password)) {
        Write-State @{ ready = $false; error = '未收到动态码'; pid = $PID }
        Log 'empty password'
        return
    }
    Log ("auth start len={0}" -f $password.Length)

    $ssh = $null
    try {
        $ssh = [AbqCtl.SshAuthHelper]::Connect($HostName, [int]$Port, $User, $password, 30)
        $password = $null
        if (-not $ssh.IsConnected) {
            throw 'SSH.NET 连接后 IsConnected=false'
        }
        Log 'ssh connected'
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = "$msg | $($_.Exception.InnerException.Message)" }
        try { if ($ssh) { $ssh.Dispose() } } catch {}
        Write-State @{ ready = $false; error = "SSH 登录失败: $msg。请换新的动态码。"; pid = $PID }
        Log "login failed: $msg"
        return
    }

    $remoteHost = ''
    try {
        $cmd = $ssh.CreateCommand('hostname; echo PROBE_OK')
        $cmd.CommandTimeout = [TimeSpan]::FromSeconds(20)
        $null = $cmd.Execute()
        $probeOut = [string]$cmd.Result
        if ($probeOut -match '(\S+)') { $remoteHost = $Matches[1] }
        Log "probe host=$remoteHost"
    }
    catch {
        Log ("probe failed: " + $_.Exception.Message)
    }

    $sftp = $null
    try {
        $sftp = [AbqCtl.SshAuthHelper]::ConnectSftp($ssh)
        Log 'sftp connected'
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = "$msg | $($_.Exception.InnerException.Message)" }
        try { if ($sftp) { $sftp.Dispose() } } catch {}
        try { if ($ssh) { $ssh.Dispose() } } catch {}
        Write-State @{ ready = $false; error = "SFTP 打开失败: $msg"; pid = $PID }
        Log "sftp failed: $msg"
        return
    }

    function Invoke-SshExec([string]$RemoteCommand, [int]$TimeoutSec = 170) {
        if (-not $ssh.IsConnected) { throw 'SSH 连接已断开，请重新连接。' }
        $cmdObj = $ssh.CreateCommand($RemoteCommand)
        $cmdObj.CommandTimeout = [TimeSpan]::FromSeconds($TimeoutSec)
        $null = $cmdObj.Execute()
        $stdout = [string]$cmdObj.Result
        $stderr = [string]$cmdObj.Error
        $code = [int]$cmdObj.ExitStatus
        $stderr = (($stderr -split "`n") | Where-Object {
                $_ -and ($_ -notmatch 'tput:') -and ($_ -notmatch 'seq: invalid') -and ($_ -notmatch "Try 'seq --help'")
            }) -join "`n"
        $text = $stdout.TrimEnd()
        if ($stderr) { $text = (($text + "`n" + $stderr).Trim()) }
        return @{ code = $code; text = $text }
    }

    function Write-HostOk([string]$Text) {
        $wr.WriteLine((@{ ok = $true; out_b64 = (ConvertTo-B64 $Text) } | ConvertTo-Json -Compress))
    }
    function Write-HostErr([string]$Text) {
        $wr.WriteLine((@{ ok = $false; error_b64 = (ConvertTo-B64 $Text); error = 'failed' } | ConvertTo-Json -Compress))
    }

    $token = [guid]::NewGuid().ToString('N')
    $listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $listenPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    Write-State @{
        ready      = $true
        pid        = $PID
        port       = $listenPort
        token      = $token
        remoteHost = $remoteHost
        engine     = 'sshnet'
    }
    Log "ready port=$listenPort host=$remoteHost"

    $gate = New-Object System.Object
    try {
        while ($true) {
            if (-not $ssh.IsConnected) {
                Log 'ssh dropped'
                break
            }
            if (-not $listener.Pending()) {
                Start-Sleep -Milliseconds 80
                continue
            }
            $tcp = $listener.AcceptTcpClient()
            try {
                $tcp.ReceiveTimeout = 600000
                $tcp.SendTimeout = 600000
                $ns = $tcp.GetStream()
                $rd = New-Object System.IO.StreamReader($ns, [Text.Encoding]::UTF8)
                $wr = New-Object System.IO.StreamWriter($ns, (New-Object System.Text.UTF8Encoding $false))
                $wr.NewLine = "`n"
                $wr.AutoFlush = $true
                $reqLine = $rd.ReadLine()
                if ([string]::IsNullOrWhiteSpace($reqLine)) { continue }
                $req = $reqLine | ConvertFrom-Json
                if ([string]$req.token -ne $token) {
                    Write-HostErr 'bad token'
                    continue
                }
                if ($req.op -eq 'stop') {
                    Write-HostOk 'stopped'
                    break
                }

                [System.Threading.Monitor]::Enter($gate)
                try {
                    switch ([string]$req.op) {
                        'run' {
                            $r = Invoke-SshExec ([string]$req.cmd) 170
                            if ($r.code -ne 0) { Write-HostErr ("远程命令失败 (exit {0}): {1}" -f $r.code, $r.text) }
                            else { Write-HostOk $r.text }
                        }
                        'put' {
                            $local = [string]$req.local
                            $remote = ([string]$req.remote) -replace '\\', '/'
                            if (-not (Test-Path -LiteralPath $local -PathType Leaf)) {
                                throw "本地文件不存在: $local"
                            }
                            $parent = $remote.Substring(0, $remote.LastIndexOf('/'))
                            if ($parent) {
                                $mk = Invoke-SshExec ("mkdir -p '{0}'" -f ($parent -replace "'", "'\''")) 60
                                if ($mk.code -ne 0) { throw "创建远端目录失败: $($mk.text)" }
                            }
                            if (-not $sftp.IsConnected) { throw 'SFTP 已断开' }
                            $total = [long](Get-Item -LiteralPath $local).Length
                            [AbqCtl.XferProgress]::Begin($XferProgressFile, 'put', 'upload', $remote, $local, $total, '开始上传')
                            $ufs = [IO.File]::OpenRead($local)
                            $pfs = New-Object AbqCtl.ProgressStream($ufs, [AbqCtl.XferProgress]::Callback, $true)
                            try { $sftp.UploadFile($pfs, $remote, $true, $null) }
                            finally { $pfs.Dispose() }
                            $st = $sftp.GetAttributes($remote)
                            [AbqCtl.XferProgress]::SetPhase('done', '上传完成', [long]$st.Size, [long]$st.Size)
                            Write-HostOk ("上传完成 remote={0} size={1}" -f $remote, $st.Size)
                            [AbqCtl.XferProgress]::Clear()
                        }
                        'get' {
                            $remote = ([string]$req.remote) -replace '\\', '/'
                            $local = [string]$req.local
                            if (-not $sftp.IsConnected) { throw 'SFTP 已断开' }
                            if (-not $sftp.Exists($remote)) { throw "远端文件不存在: $remote" }
                            $total = [long]$sftp.GetAttributes($remote).Size
                            $resumeHint = if ((Test-Path -LiteralPath $local) -and ((Get-Item -LiteralPath $local).Length -gt 0) -and ((Get-Item -LiteralPath $local).Length -lt $total)) { 'resume' } else { 'download' }
                            [AbqCtl.XferProgress]::Begin($XferProgressFile, 'get', $resumeHint, $remote, $local, $total, $(if ($resumeHint -eq 'resume') { '断点续传' } else { '开始下载' }))
                            $len = [AbqCtl.ResumeDownload]::DownloadFile($sftp, $remote, $local, [AbqCtl.XferProgress]::Callback)
                            [AbqCtl.XferProgress]::SetPhase('done', '下载完成', $len, $total)
                            Write-HostOk ("下载完成 local={0} size={1} resume={2}" -f $local, $len, ($resumeHint -eq 'resume'))
                            [AbqCtl.XferProgress]::Clear()
                        }
                        'getdir' {
                            $remote = ([string]$req.remote) -replace '\\', '/'
                            $localDir = [string]$req.local
                            if (-not (Test-Path -LiteralPath $localDir)) {
                                New-Item -ItemType Directory -Force -Path $localDir | Out-Null
                            }
                            if (-not $sftp.IsConnected) { throw 'SFTP 已断开' }
                            if (-not $sftp.Exists($remote)) { throw "远端目录不存在: $remote" }
                            [AbqCtl.XferProgress]::Begin($XferProgressFile, 'getdir', 'wait', $remote, $localDir, 0, '扫描远端文件…')
                            $grand = [AbqCtl.ResumeDownload]::MeasureDirectory($sftp, $remote)
                            [AbqCtl.XferProgress]::Begin($XferProgressFile, 'getdir', 'download', $remote, $localDir, $grand, '目录断点续传下载…')
                            $summary = [AbqCtl.ResumeDownload]::DownloadDirectory($sftp, $remote, $localDir, [AbqCtl.XferProgress]::Callback)
                            [AbqCtl.XferProgress]::SetPhase('done', '目录下载完成', $grand, $grand)
                            Write-HostOk ("目录下载完成 remote={0} -> {1} ({2})" -f $remote, $localDir, $summary)
                            [AbqCtl.XferProgress]::Clear()
                        }
                        default {
                            Write-HostErr ("unknown op: {0}" -f $req.op)
                        }
                    }
                }
                catch {
                    try { [AbqCtl.XferProgress]::Clear() } catch { Clear-XferProgress }
                    Write-HostErr $_.Exception.Message
                }
                finally {
                    [System.Threading.Monitor]::Exit($gate)
                }
            }
            finally {
                $tcp.Close()
            }
        }
    }
    finally {
        try { $listener.Stop() } catch {}
        try { if ($sftp) { $sftp.Disconnect(); $sftp.Dispose() } } catch {}
        try { if ($ssh) { $ssh.Disconnect(); $ssh.Dispose() } } catch {}
        if (Test-Path $StateFile) { Remove-Item -Force $StateFile -ErrorAction SilentlyContinue }
        Log 'host exit'
    }
}

function Upload-LocalFile([string]$LocalPath, [string]$DestDir) {
    if (-not $LocalPath) { throw '用法: .\abqctl.ps1 upload <本地文件> [远端目录]' }
    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
        throw "本地文件不存在: $LocalPath"
    }
    $localFull = (Resolve-Path -LiteralPath $LocalPath).Path
    $dir = Normalize-RemotePath $(if ($DestDir) { $DestDir } else { $RemoteDir })
    $name = [IO.Path]::GetFileName($localFull)
    $remote = "$dir/$name"
    $out = Send-HostRequest @{ op = 'put'; local = $localFull; remote = $remote } 600
    Write-Host $out
    Write-Host "remote_path=$remote"
}

function Upload-LocalInpFolder([string]$LocalDir, [string]$DestDir) {
    if (-not $LocalDir) { throw '用法: .\abqctl.ps1 upload-inps <本地文件夹> [远端目录]' }
    if (-not (Test-Path -LiteralPath $LocalDir -PathType Container)) {
        throw "本地文件夹不存在: $LocalDir"
    }
    $dirFull = (Resolve-Path -LiteralPath $LocalDir).Path
    $dest = Normalize-RemotePath $(if ($DestDir) { $DestDir } else { $RemoteDir })
    $files = @(Get-ChildItem -LiteralPath $dirFull -Filter '*.inp' -File)
    if ($files.Count -eq 0) { throw "文件夹内没有 .inp: $dirFull" }
    Write-Host ("将上传 {0} 个 .inp -> {1}" -f $files.Count, $dest)
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        $remote = "$dest/$($f.Name)"
        Write-Host ("上传: {0}" -f $f.Name)
        $out = Send-HostRequest @{ op = 'put'; local = $f.FullName; remote = $remote } 600
        Write-Host $out
        Write-Host "remote_path=$remote"
        [void]$paths.Add($remote)
    }
    Write-Host ("UPLOAD_INPS_OK count={0}" -f $paths.Count)
    Write-Host ('remote_paths=' + ($paths -join ';'))
}

function Download-RemoteFile([string]$RemotePath, [string]$LocalDir) {
    if (-not $RemotePath -or -not $LocalDir) {
        throw '用法: .\abqctl.ps1 download <远端文件> <本地目录>'
    }
    $remote = Normalize-RemotePath $RemotePath
    if (-not (Test-Path -LiteralPath $LocalDir)) {
        New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
    }
    $localDirFull = (Resolve-Path -LiteralPath $LocalDir).Path
    $name = Split-Path -Leaf $remote
    $local = Join-Path $localDirFull $name
    $out = Send-HostRequest @{ op = 'get'; remote = $remote; local = $local } 600
    Write-Host $out
}

function Download-RemoteDir([string]$RemotePath, [string]$LocalDir) {
    if (-not $RemotePath -or -not $LocalDir) {
        throw '用法: .\abqctl.ps1 download-dir <远端目录> <本地目录>'
    }
    $remote = Normalize-RemotePath $RemotePath
    if (-not (Test-Path -LiteralPath $LocalDir)) {
        New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
    }
    $localDirFull = (Resolve-Path -LiteralPath $LocalDir).Path
    $out = Send-HostRequest @{ op = 'getdir'; remote = $remote; local = $localDirFull } 900
    Write-Host $out
}

function Browse-RemotePath([string]$RemotePath) {
    $remote = Normalize-RemotePath $(if ($RemotePath) { $RemotePath } else { $DefaultRemoteRoot })
    $q = $remote -replace "'", "'\''"
    $script = @"
p='$q'
echo "path=`$p"
if [ ! -e "`$p" ]; then
  echo "不存在: `$p"
  exit 1
fi
if [ -d "`$p" ]; then
  echo "type=directory"
  echo "=== listing (dirs first, max 300) ==="
  ls -lah --group-directories-first "`$p" 2>/dev/null | head -n 300
  echo "=== *.inp ==="
  ls -1 "`$p"/*.inp 2>/dev/null | head -n 80 || echo "(none)"
else
  echo "type=file"
  ls -lah "`$p"
  case "`$p" in
    *.inp|*.sta|*.log|*.dat|*.msg|*.com|*.txt|*.sh|*.py|*.csv)
      echo "=== preview (first 60 lines) ==="
      head -n 60 "`$p"
      ;;
    *)
      echo "(二进制或未知类型，仅显示文件信息)"
      ;;
  esac
fi
"@
    Invoke-Remote ($script -replace "`r", '') 60
}

function List-RemoteInps([string]$RemoteDir) {
    $dir = Normalize-RemotePath $(if ($RemoteDir) { $RemoteDir } else { '/public/home/tsyg/wh-data/hq' })
    if ($dir -match '\.inp$') { $dir = ($dir -replace '/[^/]+$', '') }
    $q = $dir -replace "'", "'\''"
    $script = @"
p='$q'
if [ ! -d "`$p" ]; then
  echo "不存在目录: `$p"
  exit 1
fi
n=0
paths=''
for f in "`$p"/*.inp; do
  [ -f "`$f" ] || continue
  n=`$((n+1))
  if [ -z "`$paths" ]; then paths="`$f"; else paths="`$paths;`$f"; fi
  echo "inp=`$f"
  if [ `$n -ge 200 ]; then break; fi
done
echo "LIST_INPS_OK dir=`$p count=`$n"
echo "remote_paths=`$paths"
"@
    Invoke-Remote ($script -replace "`r", '') 60
}

function Show-Help {
    @"
abqctl.ps1 — Windows 原生（SSH.NET，无 Python）

  .\abqctl.ps1 connect <6位动态码>
  .\abqctl.ps1 upload <本地文件> [远端目录]     # 默认远端 /public/home/tsyg/wh-data
  .\abqctl.ps1 upload-inps <本地文件夹> [远端目录]  # 批量上传文件夹内全部 .inp
  .\abqctl.ps1 list-inps [远端目录]            # 列出远端目录下全部 .inp（入队用）
  .\abqctl.ps1 browse [远端路径]               # 预览目录列表或文件前几行
  .\abqctl.ps1 download <远端文件> <本地目录>   # 支持断点续传
  .\abqctl.ps1 download-dir <远端目录> <本地目录> # 逐文件断点续传
  .\abqctl.ps1 run <远程.inp> [-Cpus 40] [-Double both]  # 保留CLI；GUI 已改为只走队列
  .\abqctl.ps1 status [作业名|all]
  .\abqctl.ps1 sta <作业名>
  .\abqctl.ps1 log <作业名>
  .\abqctl.ps1 cancel <作业名>
  .\abqctl.ps1 disconnect
  .\abqctl.ps1 gui
  .\abqctl.ps1 queue-gui          # 批量队列面板（见 AbqQueue.ps1）

批量队列（需已 connect）：
  .\AbqQueue.ps1 sync | scheduler-start | enqueue <inp> | list | gui

密码 = tsyg6100 + 动态码。动态码只用于建立这一条 SSH，不会写入磁盘。
"@ | Write-Host
}

switch ($Command) {
    '_host' { Start-SessionHost -PipeName $Arg1; exit 0 }
    'help' { Show-Help }
    '' { Show-Help }
    'gui' { & (Join-Path $ScriptDir 'AbqCtlGui.ps1') }
    'queue-gui' { & (Join-Path $ScriptDir 'AbqQueueGui.ps1') }
    'connect' {
        if (-not $Arg1) { throw '用法: .\abqctl.ps1 connect <6位动态码>' }
        Connect-Session -Otp $Arg1
    }
    'disconnect' {
        try { Send-HostRequest @{ op = 'stop' } 15 | Out-Null } catch {}
        Stop-HostProcess
        Write-Host '会话已断开。'
    }
    'run' {
        if (-not $Arg1) { throw '用法: .\abqctl.ps1 run <远程.inp> [-Cpus 40] [-Double both]' }
        Sync-RemoteCtl
        Write-Host "提交参数: inp=$Arg1 cpus=$Cpus double=$Double"
        Invoke-Remote "bash $RemoteCtl run '$Arg1' --cpus $Cpus --double $Double" 90
    }
    'submit' {
        if (-not $Arg1) { throw '用法: .\abqctl.ps1 submit <远程.inp>' }
        Sync-RemoteCtl
        Invoke-Remote "bash $RemoteCtl run '$Arg1' --cpus $Cpus --double $Double" 90
    }
    'status' {
        # no Sync here — keep status/sta snappy so GUI watch does not freeze
        $j = if ($Arg1) { $Arg1 } else { 'all' }
        Invoke-Remote "bash $RemoteCtl status '$j'"
    }
    'sta' {
        if (-not $Arg1) { throw '用法: .\abqctl.ps1 sta <作业名>' }
        Invoke-Remote "bash $RemoteCtl sta '$Arg1' 120"
    }
    'log' {
        if (-not $Arg1) { throw '用法: .\abqctl.ps1 log <作业名>' }
        Invoke-Remote "bash $RemoteCtl log '$Arg1'"
    }
    'cancel' {
        if (-not $Arg1) { throw '用法: .\abqctl.ps1 cancel <作业名>' }
        Sync-RemoteCtl
        $script = @"
bash $RemoteCtl cancel '$Arg1' || true
for h in login05 login08 login10; do
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no `$h "pkill -f 'analysis.pyc -job $Arg1' 2>/dev/null; true" 2>/dev/null || true
done
rm -f /public/home/tsyg/wh-data/hq/${Arg1}.lck 2>/dev/null || true
bash $RemoteCtl status '$Arg1' | head -30
"@
        Invoke-Remote $script 60
    }
    'list-inputs' {
        Sync-RemoteCtl
        $d = if ($Arg1) { $Arg1 } else { '/public/home/tsyg/wh-data/hq' }
        Invoke-Remote "bash $RemoteCtl list-inputs '$d'"
    }
    'upload' { Upload-LocalFile -LocalPath $Arg1 -DestDir $(if ($Arg2) { $Arg2 } else { $RemoteDir }) }
    'upload-inps' { Upload-LocalInpFolder -LocalDir $Arg1 -DestDir $(if ($Arg2) { $Arg2 } else { $RemoteDir }) }
    'list-inps' { List-RemoteInps -RemoteDir $Arg1 }
    'browse' { Browse-RemotePath -RemotePath $Arg1 }
    'ls' { Browse-RemotePath -RemotePath $Arg1 }
    'download' { Download-RemoteFile -RemotePath $Arg1 -LocalDir $Arg2 }
    'download-dir' { Download-RemoteDir -RemotePath $Arg1 -LocalDir $Arg2 }
    default { Show-Help }
}
