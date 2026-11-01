# Display Layout Fix

A PowerShell script for Windows that puts your monitors back in the right positions after sleep, without unplugging anything.

USB display adapters (DisplayLink, MacroSilicon and similar) often come back from sleep in a different order. Windows then swaps their positions, and the usual fix is to unplug them and plug them back in the right order. This script remembers where each monitor belongs and moves it back automatically.

## What it does
- `save` remembers the current layout, keyed by each monitor's own hardware ID, not by Windows' `DISPLAYn` number (which USB adapters change on every wake).
- `restore` waits up to 60 s for every saved monitor to come back, puts each one at its saved position, then keeps checking for another 20 s in case Windows moves them again.
- `install` runs `restore` hidden whenever the PC wakes (including Modern Standby), you unlock it, or you log on.
- Nothing happens if the layout is already right, or if a different set of monitors is plugged in (e.g. at another desk).

## How it works
It calls the Windows CCD API (`QueryDisplayConfig` / `SetDisplayConfig`) through a small embedded C# class. Each active display path is matched to the saved layout by its monitor device path (unique per monitor and port), falling back to the EDID manufacturer + product code when that is unique. The new positions are applied with `SDC_SAVE_TO_DATABASE`, so Windows keeps them.

## Install
1. Download `DisplayFix.ps1` into a folder of its own (it writes `layout.json` and `displayfix.log` next to itself).
2. Arrange your screens correctly in Settings → System → Display.
3. Run:
   ```
   powershell -ExecutionPolicy Bypass -File DisplayFix.ps1 save
   powershell -ExecutionPolicy Bypass -File DisplayFix.ps1 install
   ```
No admin rights needed. To remove the automatic task: `DisplayFix.ps1 uninstall`.

## Commands
| Command | What it does |
|---|---|
| `list` | Show current monitors, IDs and positions |
| `save` | Remember the current layout as the correct one |
| `restore` | Fix positions now (`-Force` re-applies even if nothing changed) |
| `swap` | Swap the positions of the two USB screens and save that as the layout |
| `install` / `uninstall` | Add / remove the scheduled task `DisplayFix-Restore` |

`swap` finds the USB screens by a device-path pattern, `-UsbMatch` (default `RTKF9D`). Run `list` to see yours and pass your own, e.g. `-UsbMatch DisplayLink`.

Every fix writes the positions before and after to `displayfix.log`.

## Limits
- Some USB display drivers (seen with MacroSilicon `VID_345F`) hand out their outputs in wake-up order. Then the monitor IDs swap along with the pictures, and nothing Windows reports can tell which physical screen is which. `restore` sees a correct layout and does nothing. Use `swap`: it swaps the two USB screens **and saves the result**, so the next `restore` keeps it. Tip: put a shortcut to `conhost.exe --headless powershell.exe -ExecutionPolicy Bypass -File DisplayFix.ps1 swap` on the desktop and give it a hotkey.
- Only positions are restored, not resolution, scaling or rotation.

## License
MIT
