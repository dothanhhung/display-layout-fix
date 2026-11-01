# DisplayFix - keep monitor positions after sleep (USB display adapters reshuffle).
#   list       show current monitors + positions
#   save       remember the current (correct) layout -> layout.json
#   restore    put saved positions back (waits for all monitors, re-checks a few times)
#   swap       emergency: swap the two USB screens' positions
#   install    auto-run restore on wake / unlock / logon (scheduled task)
#   uninstall  remove the scheduled task
param(
  [ValidateSet('list','save','restore','swap','install','uninstall')][string]$Action = 'list',
  [int]$WaitSec = 60,
  [switch]$Force,
  [string]$UsbMatch = 'RTKF9D'
)
$ErrorActionPreference = 'Stop'
$Dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cfg  = Join-Path $Dir 'layout.json'
$Log  = Join-Path $Dir 'displayfix.log'
$Task = 'DisplayFix-Restore'

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

switch ($Action) {
  'list' {
    Get-Mons | Sort-Object X, Y | Format-Table Gdi, Name, Edid, X, Y, W, H, Port, Path -AutoSize | Out-String -Width 400 | Write-Host
  }
  'save' { Save-Layout }
  'restore' {
    if (-not (Test-Path $Cfg)) { Write-Log 'no layout.json - run save first'; exit 1 }
    $json = Get-Content $Cfg -Raw | ConvertFrom-Json   # PS 5.1 emits the array as ONE object
    $saved = @($json)
    # USB screens come back late and Windows may reshuffle once more after they do:
    # wait for the full set, then keep checking for ~20 s after the first fix.
    $deadline = (Get-Date).AddSeconds($WaitSec); $settleUntil = $null; $state = 'wait'
    while ((Get-Date) -lt $deadline) {
      $state = Try-Restore $saved
      if ($state -ne 'wait' -and -not $settleUntil) { $settleUntil = (Get-Date).AddSeconds(20) }
      if ($settleUntil -and (Get-Date) -gt $settleUntil) { break }
      Start-Sleep -Seconds 4
    }
    if (-not $settleUntil) { Write-Log ('gave up: monitor set differs from layout.json -> ' + (Fmt (Get-Mons))) }
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
    $logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    $pr = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $Task -Action $act -Trigger @($wake, $unlock, $logon) -Settings $set -Principal $pr -Force | Out-Null
    Write-Log "task '$Task' installed (wake + unlock + logon)"
  }
  'uninstall' {
    Unregister-ScheduledTask -TaskName $Task -Confirm:$false
    Write-Log "task '$Task' removed"
  }
}
