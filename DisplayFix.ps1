# DisplayFix - keep monitor positions after sleep (USB display adapters reshuffle).
#   list       show current monitors + positions
#   save       remember the current (correct) layout -> layout.json
#   restore    put saved positions back (waits for all monitors, re-checks a few times)
#   swap       emergency: swap the two USB screens' positions
#   touch      re-point touch screens at their monitors (by USB port; needs admin)
#   recover    after a USB display driver crash: restart each adapter left without a picture
#   install    auto-run restore on wake / unlock / plug-in / logon, recover on driver crash
#   uninstall  remove the scheduled tasks
param(
  [ValidateSet('list','save','restore','swap','touch','recover','install','uninstall')][string]$Action = 'list',
  [int]$WaitSec = 60,
  [switch]$Force,
  [string]$UsbMatch = 'RTKF9D',
  [string]$AdapterMatch = 'VID_345F&PID_9133&MI_03'
)
$ErrorActionPreference = 'Stop'
$Dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cfg  = Join-Path $Dir 'layout.json'
$Log  = Join-Path $Dir 'displayfix.log'
$Task = 'DisplayFix-Restore'
$RecoverTask = 'DisplayFix-Recover'

Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public class DispFix {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
  [StructLayout(LayoutKind.Sequential)] public struct RATIONAL { public uint N; public uint D; }
  [StructLayout(LayoutKind.Sequential)] public struct SRC { public LUID adapterId; public uint id; public uint modeIdx; public uint status; }
  [StructLayout(LayoutKind.Sequential)] public struct TGT { public LUID adapterId; public uint id; public uint modeIdx; public uint tech; public uint rot; public uint scale; public RATIONAL refresh; public uint scan; public int avail; public uint status; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH { public SRC src; public TGT tgt; public uint flags; }
  [StructLayout(LayoutKind.Explicit, Size=64)] public struct MODE {
    [FieldOffset(0)] public uint type; [FieldOffset(4)] public uint id; [FieldOffset(8)] public LUID adapterId;
    [FieldOffset(16)] public ulong r0; [FieldOffset(24)] public ulong r1; [FieldOffset(32)] public ulong r2;
    [FieldOffset(40)] public ulong r3; [FieldOffset(48)] public ulong r4; [FieldOffset(56)] public ulong r5;
    [FieldOffset(16)] public uint w; [FieldOffset(20)] public uint h; [FieldOffset(24)] public uint fmt;
    [FieldOffset(28)] public int x; [FieldOffset(32)] public int y; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct TNAME {
    public uint type; public uint size; public LUID adapterId; public uint id;
    public uint flags; public uint tech; public ushort mfg; public ushort prod; public uint conn;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string friendly;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string path; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SNAME {
    public uint type; public uint size; public LUID adapterId; public uint id;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string gdi; }

  [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint f, out uint np, out uint nm);
  [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint f, ref uint np, [In,Out] PATH[] p, ref uint nm, [In,Out] MODE[] m, IntPtr topo);
  [DllImport("user32.dll")] static extern int SetDisplayConfig(uint np, [In] PATH[] p, uint nm, [In] MODE[] m, uint f);
  [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TNAME r);
  [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref SNAME r);

  public class Mon { public int Idx; public string Gdi, Name, Edid, Path; public int X, Y, W, H; }
  static PATH[] P; static MODE[] M;

  public static List<Mon> Get() {
    uint np, nm;
    int r = GetDisplayConfigBufferSizes(2, out np, out nm);
    if (r != 0) throw new Exception("GetDisplayConfigBufferSizes error " + r);
    P = new PATH[np]; M = new MODE[nm];
    r = QueryDisplayConfig(2, ref np, P, ref nm, M, IntPtr.Zero);   // QDC_ONLY_ACTIVE_PATHS
    if (r != 0) throw new Exception("QueryDisplayConfig error " + r);
    Array.Resize(ref P, (int)np); Array.Resize(ref M, (int)nm);
    var list = new List<Mon>();
    for (int i = 0; i < P.Length; i++) {
      var t = new TNAME(); t.type = 2; t.size = (uint)Marshal.SizeOf(typeof(TNAME)); t.adapterId = P[i].tgt.adapterId; t.id = P[i].tgt.id;
      DisplayConfigGetDeviceInfo(ref t);
      var s = new SNAME(); s.type = 1; s.size = (uint)Marshal.SizeOf(typeof(SNAME)); s.adapterId = P[i].src.adapterId; s.id = P[i].src.id;
      DisplayConfigGetDeviceInfo(ref s);
      var m = new Mon(); m.Idx = i; m.Gdi = s.gdi; m.Name = t.friendly; m.Path = t.path;
      m.Edid = t.mfg.ToString("X4") + ":" + t.prod.ToString("X4");
      uint mi = P[i].src.modeIdx;
      if (mi < M.Length && M[mi].type == 1) { m.X = M[mi].x; m.Y = M[mi].y; m.W = (int)M[mi].w; m.H = (int)M[mi].h; }
      list.Add(m);
    }
    return list;
  }

  // idx = Mon.Idx from the last Get()
  public static int Apply(int[] idx, int[] xs, int[] ys) {
    for (int k = 0; k < idx.Length; k++) { uint mi = P[idx[k]].src.modeIdx; M[mi].x = xs[k]; M[mi].y = ys[k]; }
    // SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_SAVE_TO_DATABASE | SDC_ALLOW_CHANGES
    return SetDisplayConfig((uint)P.Length, P, (uint)M.Length, M, 0x80 | 0x20 | 0x200 | 0x400);
  }
}
'@

function Write-Log($msg) {
  $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Action, $msg
  Add-Content -Path $Log -Value $line
  Write-Host $msg
  if ((Get-Item $Log).Length -gt 200KB) { Get-Content $Log -Tail 500 | Set-Content $Log }
}
# Physical location of the monitor's parent device (USB port for USB adapters).
# USB display drivers (MacroSilicon) hand out EDID ids and UIDs in wake-up order,
# so after a wake "F9D0" can sit on the other adapter - only the port is stable.
$PortCache = @{}
function Get-Port($path) {
  if ($PortCache.ContainsKey($path)) { return $PortCache[$path] }
  $port = ''
  if ($path -match '^\\\\\?\\DISPLAY#([^#]+)#([^#]+)#') {
    $inst = "DISPLAY\$($Matches[1])\$($Matches[2])"
    try {
      $parent = (Get-PnpDeviceProperty -InstanceId $inst -KeyName DEVPKEY_Device_Parent -ErrorAction Stop).Data
      $loc = (Get-PnpDeviceProperty -InstanceId $parent -KeyName DEVPKEY_Device_LocationPaths -ErrorAction Stop).Data
      if ($loc) { $port = $loc[0] }
    } catch {}
  }
  $PortCache[$path] = $port
  return $port
}
function Get-Mons {
  [DispFix]::Get() | Where-Object { $_.W -gt 0 } |
    ForEach-Object { $_ | Add-Member -NotePropertyName Port -NotePropertyValue (Get-Port $_.Path) -PassThru }
}
function Save-Layout {
  $mons = @(Get-Mons)
  $mons | Select-Object Name, Edid, Port, Path, X, Y | ConvertTo-Json | Set-Content -Path $Cfg -Encoding UTF8
  Write-Log ('saved: ' + (Fmt $mons))
}

# ---- touch screens ----------------------------------------------------------
# Windows maps each touch digitizer to a monitor in HKLM ...\Wisp\Pen\Digimon
# ("20-<digitizer interface path>" = <monitor device path>). When the USB driver
# renames the monitors on wake, the mapping points at a monitor that no longer
# exists and that screen stops taking touch. touch.json pairs them by USB port.
$TouchCfg = Join-Path $Dir 'touch.json'
$DigiKey  = 'HKLM:\SOFTWARE\Microsoft\Wisp\Pen\Digimon'
$HidIface = '{4d1e55b2-f16f-11cf-88cb-001111000030}'

function Get-ParentLoc($inst) {
  try {
    $parent = (Get-PnpDeviceProperty -InstanceId $inst -KeyName DEVPKEY_Device_Parent -ErrorAction Stop).Data
    $loc = (Get-PnpDeviceProperty -InstanceId $parent -KeyName DEVPKEY_Device_LocationPaths -ErrorAction Stop).Data
    if ($loc) { return $loc[0] }
  } catch {}
  return ''
}
function Get-Touchscreens {
  $vals = Get-ItemProperty $DigiKey -ErrorAction SilentlyContinue
  $names = if ($vals) { @($vals.PSObject.Properties | Where-Object { $_.Name -like '*-\\?\HID#*' } | ForEach-Object { $_.Name }) } else { @() }
  Get-PnpDevice -PresentOnly -Class HIDClass | Where-Object { $_.HardwareID -contains 'HID_DEVICE_UP:000D_U:0004' } | ForEach-Object {
    $iface = '\\?\' + ($_.InstanceId -replace '\\', '#') + '#' + $HidIface
    $name = $names | Where-Object { $_.Substring($_.IndexOf('-') + 1) -eq $iface } | Select-Object -First 1
    $cur = if ($name) { $vals.$name } else { $null }
    [pscustomobject]@{ Inst = $_.InstanceId; Port = (Get-ParentLoc $_.InstanceId); Name = $name; Iface = $iface; Monitor = $cur }
  }
}
function Is-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

# Learn touch port -> monitor port from the current Digimon entries. A stale entry
# still names the right adapter (the "7&b079922" part survives the rename).
function Save-Touch {
  $mons = @(Get-Mons); $pairs = @{}
  if (Test-Path $TouchCfg) { (Get-Content $TouchCfg -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $pairs[$_.Name] = $_.Value } }
  foreach ($t in @(Get-Touchscreens)) {
    if (-not $t.Monitor -or -not $t.Port) { continue }
    $m = @($mons | Where-Object { $_.Path -eq $t.Monitor })
    if ($m.Count -ne 1 -and $t.Monitor -match '^\\\\\?\\DISPLAY#[^#]+#(\d+&[0-9a-fA-F]+)&') {
      $adapter = $Matches[1]
      $m = @($mons | Where-Object { $_.Path -match ('#' + [regex]::Escape($adapter) + '&') })
    }
    if ($m.Count -eq 1 -and $m[0].Port) { $pairs[$t.Port] = $m[0].Port }
  }
  if ($pairs.Count) { [pscustomobject]$pairs | ConvertTo-Json | Set-Content -Path $TouchCfg -Encoding UTF8 }
  Write-Log ("touch pairs: " + (($pairs.GetEnumerator() | ForEach-Object { "$($_.Key) -> $($_.Value)" }) -join ' | '))
}

function Repair-Touch {
  if (-not (Test-Path $TouchCfg)) { return }
  $pairs = Get-Content $TouchCfg -Raw | ConvertFrom-Json
  $mons = @(Get-Mons); $fixed = @()
  foreach ($t in @(Get-Touchscreens)) {
    $want = $pairs.($t.Port)
    if (-not $want) { continue }
    $m = @($mons | Where-Object { $_.Port -eq $want })
    if ($m.Count -ne 1 -or $t.Monitor -eq $m[0].Path) { continue }
    if (-not (Is-Admin)) { Write-Log "touch on $($t.Port) points at a missing screen - needs admin to fix (run install as admin)"; continue }
    $name = if ($t.Name) { $t.Name } else { '20-' + $t.Iface }
    Set-ItemProperty -Path $DigiKey -Name $name -Value $m[0].Path
    $fixed += $t
    Write-Log "touch $($t.Inst): $($t.Monitor) -> $($m[0].Path)"
  }
  # the digitizer re-reads its screen mapping when it re-arrives
  foreach ($t in $fixed) { $o = & pnputil.exe /restart-device "$($t.Inst)" 2>&1; Write-Log "restart-device: $(($o | Out-String).Trim() -replace '\s+', ' ')" }
}
function Fmt($mons) {
  ($mons | Sort-Object X, Y | ForEach-Object {
    $usb = if ($_.Port -match 'USBROOT\(0\)#(.+)#USBMI') { ' ' + $Matches[1] } else { '' }
    '{0}({1}{2}) @{3},{4}' -f $_.Gdi, $_.Edid, $usb, $_.X, $_.Y }) -join ' | '
}

# saved entry -> current monitor: unique USB port first, then exact device path,
# then unique EDID id (the port is the only key that survives a driver reshuffle)
function Match-Layout($saved, $cur) {
  $map = @{}
  foreach ($s in $saved) {
    $m = @()
    if ($s.Port -and @($saved | Where-Object { $_.Port -eq $s.Port }).Count -eq 1) {
      $m = @($cur | Where-Object { $_.Port -eq $s.Port })
    }
    if ($m.Count -ne 1) { $m = @($cur | Where-Object { $_.Path -eq $s.Path }) }
    if ($m.Count -ne 1) {
      $sameSaved = @($saved | Where-Object { $_.Edid -eq $s.Edid })
      $m = @($cur | Where-Object { $_.Edid -eq $s.Edid })
      if ($sameSaved.Count -ne 1 -or $m.Count -ne 1) { return $null }
    }
    $map[$s.Path] = $m[0]
  }
  if (@($map.Values | ForEach-Object { $_.Idx } | Sort-Object -Unique).Count -ne $saved.Count) { return $null }
  return $map
}

# returns 'ok' (already right), 'fixed', or 'wait' (monitors not all back yet)
function Try-Restore($saved) {
  $cur = @(Get-Mons)
  if ($cur.Count -ne $saved.Count) { return 'wait' }
  $map = Match-Layout $saved $cur
  if (-not $map) { return 'wait' }
  $idx = @(); $xs = @(); $ys = @(); $diff = $false
  foreach ($s in $saved) {
    $c = $map[$s.Path]
    $idx += [int]$c.Idx; $xs += [int]$s.X; $ys += [int]$s.Y
    if ($c.X -ne $s.X -or $c.Y -ne $s.Y) { $diff = $true }
  }
  if (-not $diff -and -not $Force) { return 'ok' }
  Write-Log ('before: ' + (Fmt $cur))
  $r = [DispFix]::Apply([int[]]$idx, [int[]]$xs, [int[]]$ys)
  if ($r -ne 0) { Write-Log "SetDisplayConfig error $r"; return 'wait' }
  Write-Log ('after:  ' + (Fmt (Get-Mons)))
  $script:Force = $false
  return 'fixed'
}

function Run-Restore {
  if (-not (Test-Path $Cfg)) { Write-Log 'no layout.json - run save first'; return }
  $json = Get-Content $Cfg -Raw | ConvertFrom-Json   # PS 5.1 emits the array as ONE object
  $saved = @($json)
  # USB screens come back late and Windows may reshuffle once more after they do:
  # wait for the full set, then keep checking for ~20 s after the first fix.
  $deadline = (Get-Date).AddSeconds($WaitSec); $settleUntil = $null; $state = 'wait'
  while ((Get-Date) -lt $deadline) {
    $state = Try-Restore $saved
    if ($state -ne 'wait' -and -not $settleUntil) { $settleUntil = (Get-Date).AddSeconds(20); Repair-Touch }
    if ($settleUntil -and (Get-Date) -gt $settleUntil) { break }
    Start-Sleep -Seconds 4
  }
  if (-not $settleUntil) { Write-Log ('gave up: monitor set differs from layout.json -> ' + (Fmt (Get-Mons))) }
  Repair-Touch
}

# ---- driver crash recovery ---------------------------------------------------
# The MacroSilicon driver (msusbdisplaydriver.dll) crashes now and then; all its
# screens share one UMDF host, so every USB screen drops. Windows restarts the host,
# but a screen often stays black while its adapter still reports OK.
# "Dead" = adapter present, but no active monitor on its port.
function Get-DeadAdapters {
  $script:PortCache = @{}
  $live = @(Get-Mons | ForEach-Object { $_.Port })
  @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "*$AdapterMatch*" } | Where-Object {
    $loc = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_LocationPaths -ErrorAction SilentlyContinue).Data
    -not ($loc -and $live -contains $loc[0])
  })
}

switch ($Action) {
  'list' {
    Get-Mons | Sort-Object X, Y | Format-Table Gdi, Name, Edid, X, Y, W, H, Port, Path -AutoSize | Out-String -Width 400 | Write-Host
  }
  'save' { Save-Layout; Save-Touch }
  'touch' { Repair-Touch }
  'restore' { Run-Restore }
  'recover' {
    Start-Sleep -Seconds 10   # let Windows' own restart of the driver host finish
    $dead = @(Get-DeadAdapters)
    # our own restarts can crash the driver again: max 3 recoveries per 10 min
    $stateF = Join-Path $Dir 'recover.json'
    $hist = @()
    if (Test-Path $stateF) { $hist = @(@(Get-Content $stateF -Raw | ConvertFrom-Json) | Where-Object { [datetime]$_ -gt (Get-Date).AddMinutes(-10) }) }
    if (-not $dead.Count) {
      Write-Log 'driver crash: all USB screens came back by themselves'
    } elseif ($hist.Count -ge 3) {
      Write-Log 'gave up: 3 recoveries in 10 min - unplug both USB screens, plug them in one at a time'
    } else {
      $hist += (Get-Date).ToString('o')
      ConvertTo-Json -InputObject @($hist) | Set-Content -Path $stateF -Encoding UTF8
      # one adapter at a time, and wait for its picture before the next
      foreach ($d in $dead) {
        $o = & pnputil.exe /restart-device "$($d.InstanceId)" 2>&1
        Write-Log "restart $($d.InstanceId): $(($o | Out-String).Trim() -replace '\s+', ' ')"
        $until = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $until -and @(Get-DeadAdapters | Where-Object { $_.InstanceId -eq $d.InstanceId }).Count) { Start-Sleep -Seconds 2 }
      }
      $left = @(Get-DeadAdapters)
      Write-Log ("after recover: $($left.Count) adapter(s) still without a picture -> " + (Fmt (Get-Mons)))
    }
    Run-Restore
  }
  'swap' {
    $usb = @(Get-Mons | Where-Object { $_.Path -match $UsbMatch })
    if ($usb.Count -ne 2) { Write-Log "swap: found $($usb.Count) USB screens matching '$UsbMatch', need 2"; exit 1 }
    Write-Log ('before: ' + (Fmt (Get-Mons)))
    $r = [DispFix]::Apply([int[]]@($usb[0].Idx, $usb[1].Idx), [int[]]@($usb[1].X, $usb[0].X), [int[]]@($usb[1].Y, $usb[0].Y))
    Write-Log ("SetDisplayConfig=$r  after: " + (Fmt (Get-Mons)))
    # The USB driver can swap which monitor ID drives which physical screen, so a
    # manual swap is the new truth - save it, or the next restore would undo it.
    if ($r -eq 0) { Save-Layout }
  }
  'install' {
    $ps = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" restore"
    $act = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe $ps"
    $ns = 'Root/Microsoft/Windows/TaskScheduler'
    $wake = Get-CimClass -Namespace $ns -ClassName MSFT_TaskEventTrigger | New-CimInstance -ClientOnly
    $wake.Enabled = $true; $wake.Delay = 'PT3S'
    $wake.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">' +
      "*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]] or " +
      "*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=507]]" +
      '</Select></Query></QueryList>'
    $unlock = Get-CimClass -Namespace $ns -ClassName MSFT_TaskSessionStateChangeTrigger | New-CimInstance -ClientOnly
    $unlock.Enabled = $true; $unlock.StateChange = 8; $unlock.UserId = "$env:USERDOMAIN\$env:USERNAME"
    # device started (screen / touch plugged in). Our own pnputil restart also fires
    # it; that rerun finds nothing to fix, so it does not loop.
    $plug = Get-CimClass -Namespace $ns -ClassName MSFT_TaskEventTrigger | New-CimInstance -ClientOnly
    $plug.Enabled = $true; $plug.Delay = 'PT5S'
    $plug.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-Kernel-PnP/Configuration"><Select Path="Microsoft-Windows-Kernel-PnP/Configuration">' +
      '*[System[EventID=410]]</Select></Query></QueryList>'
    $logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    # Highest = elevated, needed to rewrite the touch mapping in HKLM
    if (-not (Is-Admin)) { Write-Log 'install needs admin (touch fix writes HKLM) - run it from an admin PowerShell'; exit 1 }
    $pr = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $Task -Action $act -Trigger @($wake, $unlock, $plug, $logon) -Settings $set -Principal $pr -Force | Out-Null
    # user-mode driver crash (UMDF device offline); recover itself skips non-display devices
    $ract = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument ("--headless powershell.exe " + ($ps -replace ' restore$', ' recover'))
    $crash = Get-CimClass -Namespace $ns -ClassName MSFT_TaskEventTrigger | New-CimInstance -ClientOnly
    $crash.Enabled = $true
    $crash.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">' +
      "*[System[Provider[@Name='Microsoft-Windows-DriverFrameworks-UserMode'] and EventID=10111]]" +
      '</Select></Query></QueryList>'
    $rset = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $RecoverTask -Action $ract -Trigger $crash -Settings $rset -Principal $pr -Force | Out-Null
    Write-Log "tasks installed: '$Task' (wake + unlock + plug-in + logon), '$RecoverTask' (driver crash)"
  }
  'uninstall' {
    foreach ($t in $Task, $RecoverTask) { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
    Write-Log "tasks '$Task', '$RecoverTask' removed"
  }
}
