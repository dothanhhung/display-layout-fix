# Display Layout Fix

A PowerShell script for Windows that puts your monitors back in the right positions after sleep, and gives touch screens their touch back, without unplugging anything or opening Tablet PC Settings.

USB display adapters (DisplayLink, MacroSilicon and similar) often come back from sleep in a different order. Windows then swaps their positions, and the usual fix is to unplug them and plug them back in the right order. This script remembers where each monitor belongs and moves it back automatically.

## What it does
- `save` remembers the current layout, keyed by each monitor's own hardware ID, not by Windows' `DISPLAYn` number (which USB adapters change on every wake).
- `restore` waits up to 60 s for every saved monitor to come back, puts each one at its saved position, then keeps checking for another 20 s in case Windows moves them again.
- `install` runs `restore` hidden whenever the PC wakes (including Modern Standby), you unlock it, or you log on.
- Nothing happens if the layout is already right, or if a different set of monitors is plugged in (e.g. at another desk).

### Touch screens
Windows maps each touch digitizer to a monitor in `HKLM\SOFTWARE\Microsoft\Wisp\Pen\Digimon`, keyed by the monitor's device path. When a USB display driver renames the monitors on wake, the mapping points at a monitor that no longer exists and that screen stops taking touch. Normally you'd fix it in *Tablet PC Settings → Setup*.

`save` learns which touch device belongs to which screen, as USB port → USB port (`touch.json`). `restore` (and `touch`) re-points each digitizer at the monitor now on its paired port, then restarts the digitizer with `pnputil /restart-device` so Windows re-reads the mapping. Writing HKLM needs admin, which is why `install` must be run from an elevated PowerShell (the task runs with highest privileges).

Set touch up once in Tablet PC Settings so the mapping is right, then run `save`.

## How it works
It calls the Windows CCD API (`QueryDisplayConfig` / `SetDisplayConfig`) through a small embedded C# class. Each active display is matched to the saved layout by the **physical location of its parent device** (the USB port, e.g. `USBROOT(0)#USB(3)#USB(1)`), then by monitor device path, then by EDID manufacturer + product code.

The port comes first because some USB display drivers (seen with MacroSilicon `VID_345F`) hand out the monitors' EDID ids and UIDs in wake-up order. After a wake, "monitor F9D0" can be on the other adapter, and Windows, which remembers positions by EDID, puts it in the other screen's place. The USB port never moves. The new positions are applied with `SDC_SAVE_TO_DATABASE`, so Windows keeps them.

## Install
1. Download `DisplayFix.ps1` into a folder of its own (it writes `layout.json` and `displayfix.log` next to itself).
2. Arrange your screens correctly in Settings → System → Display.
3. Run:
   ```
   powershell -ExecutionPolicy Bypass -File DisplayFix.ps1 save
   powershell -ExecutionPolicy Bypass -File DisplayFix.ps1 install
   ```
Run `install` from an **admin** PowerShell (needed for the touch fix). To remove the automatic task: `DisplayFix.ps1 uninstall`.

## Commands
| Command | What it does |
|---|---|
| `list` | Show current monitors, IDs and positions |
| `save` | Remember the current layout as the correct one |
| `restore` | Fix positions now (`-Force` re-applies even if nothing changed) |
| `swap` | Swap the positions of the two USB screens and save that as the layout |
| `touch` | Re-point touch screens at their monitors now (admin) |
| `install` / `uninstall` | Add / remove the scheduled task `DisplayFix-Restore` |

`swap` finds the USB screens by a device-path pattern, `-UsbMatch` (default `RTKF9D`). Run `list` to see yours and pass your own, e.g. `-UsbMatch DisplayLink`.

Every fix writes the positions before and after to `displayfix.log`.

## Limits
- Moving a USB screen to a different port changes its identity: arrange the screens and run `save` again.
- Two screens on the same port (one adapter with two outputs) can't be told apart by port; they fall back to device path / EDID.
- Manual fallback: `swap` swaps the two USB screens **and saves the result**. Tip: put a shortcut to `conhost.exe --headless powershell.exe -ExecutionPolicy Bypass -File DisplayFix.ps1 swap` on the desktop and give it a hotkey.
- Only positions are restored, not resolution, scaling or rotation.

## License
MIT
