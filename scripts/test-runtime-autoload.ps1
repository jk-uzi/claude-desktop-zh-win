param(
  [Parameter(Mandatory=$true)][string]$Manifest,
  [switch]$ApplyOnce,
  [switch]$Watch,
  [switch]$ActivateClaude,
  [ValidateRange(10,604800)][int]$WatchSeconds=300,
  [string]$BuildDirectory,
  [int]$ParentProcessId,
  [string]$ParentExecutable,
  [datetime]$ParentStartedBefore,
  [string]$RegistryFile,
  [string]$RegistrySha256,
  [string]$StopFile,
  [string]$SetupProfileDirectory,
  [string]$SetupStateDirectory,
  [string]$SetupNodeExecutable,
  [string]$SetupCliPath
)
$ErrorActionPreference='Stop'
function Get-DesktopClaude {
  @(Get-Process -Name Claude -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -notlike '*\claude-code\*' } catch { $true } })
}
# Secondary Claude windows (for example the third-party inference settings)
# have their own renderer and therefore need their own injection. Keep the
# marker strings ASCII-safe so Windows PowerShell 5.1 reads this file correctly.
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
if (-not ('ClaudeZhWindows' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class ClaudeZhWindows {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  public static IntPtr[] Find(uint[] pids) {
    var set=new HashSet<uint>(pids); var list=new List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if(!set.Contains(pid) || !IsWindowVisible(h)) return true;
      var cls=new StringBuilder(256); GetClassName(h,cls,256);
      if(cls.ToString()!="Chrome_WidgetWin_1") return true;
      var title=new StringBuilder(512); GetWindowText(h,title,512);
      if(title.ToString().StartsWith("DevTools",StringComparison.OrdinalIgnoreCase)) return true;
      list.Add(h); return true;
    }, IntPtr.Zero);
    return list.ToArray();
  }
}
'@
}
function Find-ClaudeWindowText([IntPtr]$Handle,[string]$Name) {
  try {
    $element=[Windows.Automation.AutomationElement]::FromHandle($Handle)
    if (!$element) { return $null }
    $condition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty,$Name)
    return $element.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
  } catch { return $null }
}
function Get-ClaudeWindowHandles {
  $pids=@(Get-DesktopClaude | ForEach-Object { [uint32]$_.Id })
  if ($pids.Count -eq 0) { return @() }
  return @([ClaudeZhWindows]::Find($pids))
}
# A settings renderer is identified by its search field, not by any visible
# text: chat transcripts may quote the English headings below.
function Test-SettingsWindow([IntPtr]$Handle) {
  try {
    $element=[Windows.Automation.AutomationElement]::FromHandle($Handle)
    if (!$element) { return $false }
    $condition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Edit)
    foreach ($edit in $element.FindAll([Windows.Automation.TreeScope]::Descendants,$condition)) {
      if ($edit.Current.Name -eq 'Search settings') { return $true }
    }
  } catch { return $false }
  return $false
}
function Focus-ClaudeWindow([IntPtr]$Handle) {
  if ([ClaudeZhWindows]::GetForegroundWindow() -eq $Handle) { return $true }
  [void][ClaudeZhWindows]::SetForegroundWindow($Handle)
  $deadline=(Get-Date).AddSeconds(1)
  while ([ClaudeZhWindows]::GetForegroundWindow() -ne $Handle -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
  return [ClaudeZhWindows]::GetForegroundWindow() -eq $Handle
}
if ($ApplyOnce -and $Watch) { throw 'Choose ApplyOnce or Watch.' }
if ($ActivateClaude -and !($ApplyOnce -or $Watch)) { throw 'ActivateClaude requires ApplyOnce or Watch.' }
if (($SetupProfileDirectory -or $SetupStateDirectory -or $SetupNodeExecutable -or $SetupCliPath) -and (!$Watch -or !$SetupProfileDirectory -or !$SetupStateDirectory -or !$SetupNodeExecutable -or !$SetupCliPath)) { throw 'First-launch setup requires a complete CLI/profile binding and Watch.' }
if (($ParentProcessId -or $ParentExecutable -or $RegistryFile -or $RegistrySha256) -and (!$Watch -or !$ParentProcessId -or !$ParentExecutable -or !$RegistryFile -or $RegistrySha256 -notmatch '^[a-f0-9]{64}$' -or $ParentStartedBefore -eq [datetime]::MinValue)) { throw 'Parent-bound watch requires a complete owner and registry identity.' }
$repo=Split-Path -Parent $PSScriptRoot
$manifestPath=(Resolve-Path -LiteralPath $Manifest).Path
$bundle=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($bundle.version -notin @(1,2) -or $bundle.locale -notin @('zh-Hans','zh-Hant') -or $bundle.payloadSha256 -notmatch '^[a-f0-9]{64}$' -or $bundle.successMarker -notmatch '^CLAUDE_ZH_APPLIED_[a-f0-9]{32}$') { throw 'Unsupported runtime bundle.' }
function Get-RuntimeHash([string]$File) {
  $stream=[IO.File]::OpenRead($File); $hasher=[Security.Cryptography.SHA256]::Create()
  try { return [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
  finally { $stream.Dispose(); $hasher.Dispose() }
}
if ((Get-RuntimeHash $bundle.payload) -ne $bundle.payloadSha256) { throw 'Runtime payload hash mismatch.' }
if ($bundle.version -eq 2 -and ($bundle.catalogSha256 -notmatch '^[a-f0-9]{64}$' -or (Get-RuntimeHash $bundle.catalogFile) -ne $bundle.catalogSha256)) { throw 'Runtime catalog hash mismatch.' }
$parentStartedTicks=0
if ($ParentProcessId) {
  $parent=Get-Process -Id $ParentProcessId -ErrorAction Stop
  if (![string]::Equals([IO.Path]::GetFullPath($parent.Path),[IO.Path]::GetFullPath($ParentExecutable),[StringComparison]::OrdinalIgnoreCase) -or $parent.StartTime.ToUniversalTime() -gt $ParentStartedBefore.ToUniversalTime()) { throw 'Plugin host identity changed before watcher startup.' }
  $parentStartedTicks=$parent.StartTime.ToUniversalTime().Ticks
  if ((Get-Item -LiteralPath $RegistryFile).LastWriteTimeUtc -gt $parent.StartTime.ToUniversalTime()) { throw 'A retired plugin host cannot start a watcher for newer options.' }
}
function Test-Owner {
  if (!$ParentProcessId) { return $true }
  try {
    $parent=Get-Process -Id $ParentProcessId -ErrorAction Stop
    return $parent.StartTime.ToUniversalTime().Ticks -eq $parentStartedTicks -and [string]::Equals([IO.Path]::GetFullPath($parent.Path),[IO.Path]::GetFullPath($ParentExecutable),[StringComparison]::OrdinalIgnoreCase) -and (Get-RuntimeHash $RegistryFile) -eq $RegistrySha256
  } catch { return $false }
}
if (!(Test-Owner)) { throw 'Plugin options changed before watcher startup.' }
if (!$BuildDirectory) { $BuildDirectory=Join-Path $repo '.handoff/runtime-console-bridge' }
[void][IO.Directory]::CreateDirectory($BuildDirectory)
$buildRun=Join-Path $BuildDirectory ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($buildRun)
$source=Join-Path $buildRun 'RuntimeConsoleBridge.cs'
[IO.File]::WriteAllBytes($source,[IO.File]::ReadAllBytes((Join-Path $repo 'integrations/windows-runtime/RuntimeConsoleBridge.cs')))
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$gac=Join-Path $env:WINDIR 'Microsoft.NET/assembly/GAC_MSIL'
$references=@('UIAutomationClient','UIAutomationTypes','WindowsBase') | ForEach-Object {
  $found=@([IO.Directory]::GetFiles((Join-Path $gac $_),($_.ToString()+'.dll'),[IO.SearchOption]::AllDirectories))
  if ($found.Count -ne 1) { throw 'Windows UI Automation reference is missing or ambiguous.' }
  '/reference:'+$found[0]
}
$native=Join-Path $buildRun 'RuntimeConsoleBridge.exe'
& $compiler /nologo /target:exe /platform:x64 /codepage:65001 ('/out:'+$native) @references $source
if ($LASTEXITCODE -ne 0) { throw 'Runtime console adapter compilation failed.' }
$selfTest=(& $native --self-test $PID | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or $selfTest.state -ne 'SelfTestPassed') { throw 'Runtime adapter self-test failed.' }
$report=@{ startedAt=(Get-Date).ToString('o'); compiled=$true; adapterSourceSha256=(Get-RuntimeHash $source); selfTest=$selfTest; mode='BuildOnly'; events=@(); stopFile=$(if ($StopFile) {[IO.Path]::GetFullPath($StopFile)} else {Join-Path $buildRun 'stop'}); parentBound=[bool]$ParentProcessId }
$reportFile=Join-Path $buildRun 'result.json'
function Save-Report { $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportFile -Encoding UTF8 }
function Clear-SetupNotice {
  if ($script:setupIcon -and (Get-Date) -ge $script:setupNoticeUntil) { $script:setupIcon.Dispose(); $script:setupIcon=$null }
}
function Show-SetupNotice([bool]$Ready) {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if ($script:setupIcon) { $script:setupIcon.Dispose() }
    $script:setupIcon=New-Object System.Windows.Forms.NotifyIcon
    $script:setupIcon.Icon=[System.Drawing.SystemIcons]::Information
    $script:setupIcon.BalloonTipTitle=('"Claude \u4e2d\u6587"' | ConvertFrom-Json)
    $script:setupIcon.Text=$script:setupIcon.BalloonTipTitle
    $script:setupIcon.BalloonTipText=if ($Ready) { ('"\u4e2d\u6587\u5df2\u51c6\u5907\u597d\uff0c\u4ece\u539f\u6765\u7684\u5165\u53e3\u6253\u5f00 Claude \u5373\u53ef\u3002"' | ConvertFrom-Json) } else { ('"\u8bf7\u901a\u8fc7 Claude \u7684\u201c\u6587\u4ef6 \u2192 \u9000\u51fa\u201d\u6b63\u5e38\u9000\u51fa\uff0c\u7b49\u5f85\u4e2d\u6587\u51c6\u5907\u5b8c\u6210\u3002"' | ConvertFrom-Json) }
    $script:setupIcon.Visible=$true
    $script:setupIcon.ShowBalloonTip(6000)
    $script:setupNoticeUntil=(Get-Date).AddSeconds(8)
  } catch { # Notifications are optional; never change Windows notification settings.
    if ($script:setupIcon) { $script:setupIcon.Dispose(); $script:setupIcon=$null }
  }
}
function Invoke-Adapter {
  $adapterArgs=@($bundle.sourceExecutable,$bundle.payload,$bundle.payloadSha256,$bundle.successMarker,'25000')
  if ($bundle.version -eq 2) { $adapterArgs+=@($bundle.catalogFile,$bundle.catalogSha256) }
  if ($ParentProcessId) { $adapterArgs+=@('--parent',$ParentProcessId.ToString(),$parentStartedTicks.ToString(),$ParentExecutable,'--registry',$RegistryFile,$RegistrySha256) }
  if ($script:windowContext) { $adapterArgs+=@('--window-handle',$script:windowContext.windowHandle.ToString()) }
  if ($ActivateClaude -and !$script:windowContext) { $adapterArgs+=@('--activate-claude') }
  $raw=& $native @adapterArgs
  $result=$raw | ConvertFrom-Json
  $event=@{ time=(Get-Date).ToString('o'); state=$result.state; applicationPid=$result.applicationPid; applicationStartTicks=$result.applicationStartTicks }
  foreach ($count in @('uiNodes','tabItems','editInputs','consoleLabels','promptValueLength','writtenValueLength','filenameCandidates','openCandidates','observedForegroundPid','promptProcessId','focusedProcessId','pickerForegroundPid','pickerOwnerPid','pickerZeroForegroundSamples','pickerIdentityBits')) {
    if ($null -ne $result.$count) { $event[$count]=[int]$result.$count }
  }
  foreach ($field in @('promptReadOnly','promptValueShape','resumedOwnPayload','catalogDialogState','focusStage','foregroundIsDevTools','promptHasFocus','activationRequested','foregroundKind','focusedNameIsPrompt','pickerWindowClass','pickerForegroundKind','scriptSubmitted','errorKind','devToolsOpenMethod')) {
    if ($null -ne $result.$field) { $event[$field]=$result.$field }
  }
  if ($script:windowContext) { foreach ($key in $script:windowContext.Keys) { $event[$key]=$script:windowContext[$key] } }
  $report.events+=@($event)
  Save-Report
  return $result
}
if ($ApplyOnce) {
  $report.mode='ApplyOnce'
  $result=Invoke-Adapter
  Write-Output ($result | ConvertTo-Json -Compress)
} elseif ($Watch) {
  $report.mode='Watch'
  # One explicit bounded experiment; no startup registration or background persistence.
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $sha=[Security.Cryptography.SHA256]::Create()
  try { $name=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity+'|'+$bundle.sourceExecutable.ToLowerInvariant()))).Replace('-','') }
  finally { $sha.Dispose() }
  $mutex=[Threading.Mutex]::new($false,('Local\Claude3pZhRuntime-'+$name))
  $owned=$false
  try {
    $lockDeadline=(Get-Date).AddSeconds(6)
    do {
      try { $owned=$mutex.WaitOne(100) } catch [Threading.AbandonedMutexException] { $owned=$true }
    } while (!$owned -and $ParentProcessId -and (Test-Owner) -and (Get-Date) -lt $lockDeadline)
    if (!$owned) { throw 'A runtime localization watcher already owns this application.' }
    $setupReady=$true
    if ($SetupProfileDirectory) {
      $setupDeadline=if ($ParentProcessId) {[datetime]::MaxValue} else {(Get-Date).AddSeconds($WatchSeconds)}
      $ownerFile=Join-Path $buildRun 'setup-owner.json'
      if ($ParentProcessId) {
        @{pid=$ParentProcessId;startedTicks=$parentStartedTicks.ToString();executable=$ParentExecutable;registryFile=$RegistryFile;registrySha256=$RegistrySha256;stopFile=$report.stopFile} | ConvertTo-Json | Set-Content -LiteralPath $ownerFile -Encoding UTF8
      }
      $setupStatus=& $SetupNodeExecutable $SetupCliPath runtime-setup-status --profile-dir $SetupProfileDirectory
      if ($LASTEXITCODE -ne 0) { throw 'Cannot read original runtime setup status.' }
      $setup=$setupStatus | ConvertFrom-Json
      $announced=$false
      while ($setup.state -ne 'RuntimeSetupReady' -and (Get-Date) -lt $setupDeadline) {
        Clear-SetupNotice
        if (!(Test-Owner) -or (Test-Path -LiteralPath $report.stopFile)) { break }
        if ((Get-DesktopClaude).Count -ne 0) {
          if (!$announced) {
            $report.setup=@{state='WaitingForNormalExit';changed=$false}; Save-Report
            Write-Output ($report.setup | ConvertTo-Json -Compress); $announced=$true
            Show-SetupNotice $false
          }
          Start-Sleep -Seconds 1; continue
        }
        # Require two stopped observations; never close a window or alter data
        # while the original process or any Claude helper is still alive.
        Start-Sleep -Seconds 1
        if ((Get-DesktopClaude).Count -ne 0) { continue }
        if (!(Test-Owner) -or (Test-Path -LiteralPath $report.stopFile)) { break }
        $setupArgs=@($SetupCliPath,'runtime-setup','--profile-dir',$SetupProfileDirectory,'--state-dir',$SetupStateDirectory)
        if ($ParentProcessId) { $setupArgs+=@('--runtime-owner',$ownerFile) }
        $setupOutput=& $SetupNodeExecutable @setupArgs
        if ($LASTEXITCODE -ne 0) { throw 'First-launch setup failed; original application was not launched.' }
        $setup=$setupOutput | ConvertFrom-Json
      }
      if ($setup.state -eq 'RuntimeSetupReady') {
        if ($setup.changed -eq $true) { Show-SetupNotice $true }
        $report.setup=$setup; Save-Report
        Write-Output ($setup | ConvertTo-Json -Compress)
      }
      $setupReady=$setup.state -eq 'RuntimeSetupReady'
    }
    $seen=[Collections.Generic.HashSet[string]]::new()
    $mainLocalizedMarker=-join ([char[]](0x663E,0x793A,0x4FA7,0x8FB9,0x680F))
    $windowCooldown=@{}
    # A restarted watcher must not inject an already localized main window.
    foreach ($existing in Get-DesktopClaude) {
      if ($existing.MainWindowHandle -eq 0) { continue }
      if (Find-ClaudeWindowText ([IntPtr]$existing.MainWindowHandle) $mainLocalizedMarker) {
        try { [void]$seen.Add(($existing.Id.ToString()+':'+$existing.StartTime.ToUniversalTime().Ticks)) } catch {}
      }
    }
    if ($ParentProcessId) {
      $before=(Get-Item -LiteralPath $RegistryFile).LastWriteTimeUtc
      foreach ($existing in @(Get-Process -Name Claude -ErrorAction SilentlyContinue)) {
        try { if ($existing.Path -eq $bundle.sourceExecutable -and $existing.StartTime.ToUniversalTime() -lt $before) { [void]$seen.Add(($existing.Id.ToString()+':'+$existing.StartTime.ToUniversalTime().Ticks)) } } catch {}
      }
    }
    $deadline=if ($ParentProcessId) {[datetime]::MaxValue} else {(Get-Date).AddSeconds($WatchSeconds)}
    Save-Report
    if ($setupReady -and (Test-Owner) -and !(Test-Path -LiteralPath $report.stopFile)) { Write-Output ('Watching original Claude'+$(if ($ParentProcessId) {' while plugin host and options are current.'} else {' for '+$WatchSeconds+' seconds.'})+' Stop file: '+$report.stopFile) }
    while ($setupReady -and (Get-Date) -lt $deadline -and !(Test-Path -LiteralPath $report.stopFile) -and (Test-Owner)) {
      Clear-SetupNotice
      $candidates=@(Get-Process -Name Claude -ErrorAction SilentlyContinue | Where-Object {
        try { $_.MainWindowHandle -ne 0 -and $_.Path -eq $bundle.sourceExecutable -and !$seen.Contains(($_.Id.ToString()+':'+$_.StartTime.ToUniversalTime().Ticks)) } catch { $false }
      })
      if ($candidates.Count -gt 0) {
        $result=Invoke-Adapter
        if ($result.applicationPid -and ($result.scriptSubmitted -or $result.state -notin @('DeferredNoForegroundClaude','FocusChanged','ApplicationExited'))) {
          [void]$seen.Add(($result.applicationPid.ToString()+':'+$result.applicationStartTicks))
          Write-Output ($result | ConvertTo-Json -Compress)
        }
        elseif ($result.state -eq 'AdapterError') {
          foreach ($candidate in $candidates) { [void]$seen.Add(($candidate.Id.ToString()+':'+$candidate.StartTime.ToUniversalTime().Ticks)) }
          Write-Output ($result | ConvertTo-Json -Compress)
        }
      }
      # Settings and other secondary windows use their own renderer, so they
      # are localized as soon as their untranslated marker is visible.
      $handles=@(Get-ClaudeWindowHandles)
      $openKeys=@{}
      foreach ($handle in $handles) { $openKeys[[string][int64]$handle]=$true }
      foreach ($key in @($windowCooldown.Keys)) { if (!$openKeys.ContainsKey($key)) { $windowCooldown.Remove($key) } }
      foreach ($handle in $handles) {
        $key=[string][int64]$handle
        if ($windowCooldown.ContainsKey($key) -and (Get-Date) -lt $windowCooldown[$key]) { continue }
        if (!(Test-SettingsWindow $handle)) { continue }
        $marker=$null
        if (Find-ClaudeWindowText $handle 'Configure third-party inference') { $marker='Configure third-party inference' }
        elseif (Find-ClaudeWindowText $handle 'Search settings') { $marker='Search settings' }
        if (!$marker) { continue }
        if (!(Focus-ClaudeWindow $handle)) { $windowCooldown[$key]=(Get-Date).AddSeconds(10); continue }
        # A failed or superseded attempt must not lock the window out for minutes.
        $windowCooldown[$key]=(Get-Date).AddSeconds(15)
        $script:windowContext=@{ windowHandle=[int64]$handle; windowMarker=$marker }
        try {
          $result=Invoke-Adapter
          if ($result.scriptSubmitted) { $windowCooldown[$key]=(Get-Date).AddSeconds(60) }
          else { $windowCooldown[$key]=(Get-Date).AddSeconds(10) }
          if ($result.scriptSubmitted -or $result.state -eq 'AdapterError') { Write-Output ($result | ConvertTo-Json -Compress) }
        } finally { $script:windowContext=$null }
      }
      Start-Sleep -Seconds 2
    }
  } finally {
    if ($script:setupIcon) { $script:setupIcon.Dispose() }
    if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose()
  }
}
$report.finishedAt=(Get-Date).ToString('o')
Save-Report
@{report=$reportFile;native=$native;mode=$report.mode;selfTestPassed=$true;uiAttempted=($ApplyOnce -or $Watch)} | ConvertTo-Json -Compress
