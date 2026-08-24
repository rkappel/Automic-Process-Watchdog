# Automic Watchdog

A PowerShell watchdog script for [Automic (UC4) Automation Engine](https://docs.automic.com/) on Windows: periodically checks whether all processes defined in the Service Manager's SMC file are running, and automatically restarts any that are missing via the Service Manager CLI (`ucybsmcl`).

## Features

- **Process check against the SMC file** – reads the active `create` entries from the Service Manager configuration file and compares them against `ucybsmcl -c GET_PROCESS_LIST`.
- **Automatic restart** of missing processes via `ucybsmcl -c START_PROCESS`.
- **Three "gates"** that deliberately skip a check/action:
  - **Maintenance mode** via a centrally maintainable, readable flag file (no need to touch the script, see below).
  - **Intentional shutdown/reboot** – detected via Event ID 1074 in the System log.
  - **Startup grace period** – tolerates the Service Manager still bringing processes up in an orderly fashion after a boot.
- **Compact logging** with log levels (`DEBUG`/`INFO`/`WARN`/`ERROR`), an optional file sink, and automatic cleanup of old entries.
- `ucybsmcl` error output is no longer logged in full (the complete help text on failure) but condensed to a single line; the raw output stays available at `DEBUG` level.

## Requirements

- Windows Server 2016 or newer, PowerShell 5.1
- Automic Automation Engine with Service Manager (`ucybsmcl.exe`)
- The executing account needs:
  - Read access to the SMC file and the maintenance flag file
  - Permission to execute `ucybsmcl.exe`
  - Read access to the System event log (Event ID 1074)

## Configuration

All settings live in the configuration block at the top of [`Invoke-AutomicWatchdog.ps1`](./Invoke-AutomicWatchdog.ps1) – no command-line argument parsing, deliberately kept simple for use as a scheduled task:

| Variable | Purpose |
|---|---|
| `$ShutdownLookbackMinutes` | Time window in which an Event 1074 counts as an ongoing shutdown |
| `$StartupGraceMinutes` | Time window after boot during which checks are skipped |
| `$ServiceManagerServiceName` | Windows service name of the Automic Service Manager |
| `$SmcFilePath` | Path to the SMC configuration file |
| `$UcybsmclPath` | Path to `ucybsmcl.exe` |
| `$ServiceManagerComputerName` | `-h` parameter for `ucybsmcl` (including port if needed) |
| `$ServiceManagerPhrase` | `-n` parameter for `ucybsmcl` (Service Manager environment) |
| `$MaintenanceFlagFilePath` | Path to the maintenance flag file |
| `$MinimumLogLevel` | Minimum level that gets logged |
| `$LogFile` | Optional path to the log file (`$null` = console only) |
| `$LogRetentionDays` | Log entries older than this many days are removed automatically |

## Maintenance mode

Checks can be paused centrally, without touching the script, by creating a flag file (path: `$MaintenanceFlagFilePath`):

```
Until: 2026-08-21 14:00
Reason: Patchday
By: <name>
```

- `Until` (optional, recommended): expiry timestamp (`yyyy-MM-dd HH:mm`). Once this point has passed, maintenance mode is considered over – the script additionally attempts to delete the file automatically (best effort, failures are ignored). If `Until` is omitted, maintenance mode stays active indefinitely.
- `Reason`, `By` (optional): informational only, go into the log.

Activate:

```powershell
"Until: $((Get-Date).AddHours(2).ToString('yyyy-MM-dd HH:mm'))`nReason: Patchday`nBy: $env:USERNAME" |
    Set-Content 'C:\ProgramData\AutomicMonitoring\maintenance.flag'
```

Deactivate: delete the file (or let it expire).

## Setting up as a scheduled task

See the full `.USAGE` section in the script header. Short version:

```
Action:   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\Invoke-AutomicWatchdog.ps1"
Trigger:  daily, "Repeat task every: 5 minutes", duration: indefinitely
Account:  service account with the permissions listed above, run whether user is logged on or not
```

> **Note:** Daily log cleanup is tied to a fixed one-hour window (00:00–00:59 server time). With very large scheduler intervals (> 1 hour), cleanup may be skipped on some days – harmless, it catches up the next day. Details in the script header.

## License

[MIT](./LICENSE)
