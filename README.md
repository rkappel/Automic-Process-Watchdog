# Automic Watchdog

A PowerShell watchdog script for [Automic (UC4) Automation Engine](https://docs.automic.com/) on Windows: periodically checks whether all processes defined in the Service Manager's SMC file are running, and automatically restarts any that are missing via the Service Manager CLI (`ucybsmcl`).

## Features

- **Process check against the SMC file** – reads the active `create` entries from the Service Manager configuration file (filtered by a configurable regex) and compares them against `ucybsmcl -c GET_PROCESS_LIST`.
- **Automatic restart** of missing processes via `ucybsmcl -c START_PROCESS`.
- **Three run-level "gates"** that deliberately skip the entire check for this run:
  - **Maintenance mode** via a centrally maintainable, readable flag file (no need to touch the script, see below) – supports an immediate window or one scheduled in advance.
  - **Intentional shutdown/reboot** – detected via Event ID 1074 in the System log.
  - **Startup grace period** – tolerates the Service Manager still bringing processes up in an orderly fashion after a boot.
- **Endless-loop protection**, per process – stops the watchdog from restarting a single persistently crashing process forever; see below.
- **Compact logging** with log levels (`DEBUG`/`INFO`/`WARN`/`ERROR`), an optional file sink, and automatic cleanup of old entries.
- `ucybsmcl` error output is no longer logged in full (the complete help text on failure) but condensed to a single line; the raw output stays available at `DEBUG` level.

## Requirements

- Windows Server 2016 or newer, PowerShell 5.1
- Automic Automation Engine with Service Manager (`ucybsmcl.exe`)
- The executing account needs:
  - Read access to the SMC file, the maintenance flag file, the log file, and the endless-loop protection flag folder
  - Permission to execute `ucybsmcl.exe`
  - Read access to the System event log (Event ID 1074)

## Configuration

All settings live in the configuration block at the top of [`Invoke-AutomicWatchdog.ps1`](./Invoke-AutomicWatchdog.ps1) – no command-line argument parsing, deliberately kept simple for use as a scheduled task:

| Variable | Purpose |
|---|---|
| `$ShutdownLookbackMinutes` | Time window in which an Event 1074 counts as an ongoing shutdown |
| `$StartupGraceMinutes` | Time window after boot during which checks are skipped |
| `$ProcessStartDelaySeconds` | Pause after each individual process start attempt |
| `$SmcFilePath` | Path to the SMC configuration file |
| `$UcybsmclPath` | Path to `ucybsmcl.exe` |
| `$ProcessNameRegex` | Regex that selects which SMC `create` entries are monitored |
| `$ServiceManagerComputerName` | `-h` parameter for `ucybsmcl` (including port if needed) |
| `$ServiceManagerPhrase` | `-n` parameter for `ucybsmcl` (Service Manager environment) |
| `$MaintenanceFlagFilePath` | Path to the maintenance flag file |
| `$EndlessLoopLookbackMinutes` | Time window used to count recent restart attempts per process |
| `$EndlessLoopMaxRestarts` | Restart attempts allowed per process within that window before protection kicks in |
| `$EndlessLoopFlagDirectory` | Folder where `LoopProtection_<ProcessName>.flag` files are created |
| `$MinimumLogLevel` | Minimum level that gets logged |
| `$LogFile` | Path to the log file (required for endless-loop protection to work) |
| `$LogRetentionDays` | Log entries older than this many days are removed automatically |

## Maintenance mode

Checks can be paused centrally, without touching the script, by creating a flag file (path: `$MaintenanceFlagFilePath`):

```
From: 2026-08-29 22:00
Until: 2026-08-30 02:00
Reason: Patchday
By: <name>
```

- `From` (optional): lets a maintenance window be scheduled in advance. Before this point in time the file is ignored entirely and – importantly – **not** deleted, since it's scheduled, not expired. Omit it to make maintenance mode active as soon as the file exists.
- `Until` (optional, recommended): expiry timestamp. Once this point has passed, maintenance mode is considered over – the script additionally attempts to delete the file automatically (best effort, failures are ignored). If omitted, maintenance mode stays active indefinitely.
- `Reason`, `By` (optional): informational only, go into the log.

Activate immediately for 2 hours:

```powershell
"Until: $((Get-Date).AddHours(2).ToString('yyyy-MM-dd HH:mm'))`nReason: Patchday`nBy: $env:USERNAME" |
    Set-Content 'D:\Automic\UC4Q\Watchdog\maintenance.flag'
```

Schedule a window in advance:

```powershell
"From: 2026-08-29 22:00`nUntil: 2026-08-30 02:00`nReason: Patchday`nBy: $env:USERNAME" |
    Set-Content 'D:\Automic\UC4Q\Watchdog\maintenance.flag'
```

Deactivate: delete the file (or let it expire).

## Endless-loop protection

If a process crashes right after every restart – a real bug, not a transient issue – the watchdog would otherwise detect it missing again on the very next run and restart it again, every 5 minutes, forever, without fixing anything.

To prevent that, the watchdog counts how often each process has been restarted (from its own log file) within `$EndlessLoopLookbackMinutes`. Once a process would be restarted more than `$EndlessLoopMaxRestarts` times in that window, the watchdog:

1. Stops attempting to start that one process (other processes are unaffected).
2. Creates `LoopProtection_<ProcessName>.flag` in `$EndlessLoopFlagDirectory`, containing the matching log excerpt as evidence.
3. Logs an `ERROR` entry.

Recovery is **manual only** – there is no automatic expiry. Once the underlying cause has been fixed, delete the `LoopProtection_*.flag` file and the watchdog will try starting that process again on its next run. This is a deliberate design choice (matching how `systemd`'s `StartLimitBurst` behaves, see e.g. `systemctl reset-failed`): a process that keeps crashing right after being restarted is very likely a real bug, and silently retrying it forever – or after a cooldown – would just hide that instead of surfacing it.

This check needs `$LogFile` to be configured; without a persisted log there is no history to evaluate restart frequency against.

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
