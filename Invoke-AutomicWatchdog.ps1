#Requires -Version 5.1
<#
.SYNOPSIS
    Watchdog for Automic (UC4) Service Manager processes: checks whether all
    required processes are running and automatically restarts any that are missing.

.DESCRIPTION
    The script skips its check/restart logic in three situations:
      1. A manual maintenance mode has been activated via a flag file
         (see Test-MaintenanceModeActive).
      2. An intentional system shutdown/reboot is currently in progress
         (detected via Event ID 1074 in the System log).
      3. The server has just booted and the Automic Service Manager is
         presumably still bringing processes up in an orderly fashion
         (grace period based on LastBootUpTime).

.USAGE
    Intended to run as a recurring task in Windows Task Scheduler:

      1. Action: "Start a program"
         Program/script:  powershell.exe
         Arguments:       -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\Invoke-AutomicWatchdog.ps1"

      2. Trigger: "At log on" or "Daily", with "Repeat task every: 5 minutes"
         enabled, for a duration of "Indefinitely".

      3. Account: use an account that has read access to the maintenance flag
         file and permission to run ucybsmcl.exe (enable "Run whether user is
         logged on or not" so the task also runs without an active session).

    IMPORTANT - relationship with the scheduler interval:
      Log file cleanup (see $LogRetentionDays / Invoke-LogFileCleanup) only
      runs within a daily time window (default: the full hour 00:00-00:59),
      NOT on every single run. If the scheduler interval is larger than this
      window (e.g. a trigger every 90 minutes), it's possible that on some
      days NO run falls within this window and cleanup is skipped that day -
      harmless, it catches up the next day. If the interval is very short
      instead (e.g. every 5 minutes), the log file gets read in full multiple
      times within the window (up to 12x in that example), but is only
      actually rewritten on the FIRST match (see the $removedCount check) -
      this is intentional and harmless. With very large log files and very
      short intervals (< 1 minute), the window may need to be narrowed.

.NOTES
    Author:     René Kappel
    Repository: https://github.com/rkappel/Automic-Process-Watchdog
    License:    MIT
    Version:    1.0.0
    Created:    2026-08-21
#>

[CmdletBinding()]
param()

# ============================================================
# CONFIGURATION
# ============================================================

# Time window (minutes) within which an Event 1074 is considered an
# "intentional shutdown currently in progress".
$ShutdownLookbackMinutes = 5

# Time window (minutes) after boot during which the Automic Service Manager
# is assumed to still be bringing processes up in an orderly fashion.
$StartupGraceMinutes = 10

# Windows service name of the Automic Service Manager.
$ServiceManagerServiceName = 'UC4.ServiceManager.WS21'

# Path to the SMC configuration file that defines the expected processes.
$SmcFilePath = 'C:\uc4\V21.0\ServiceManager\bin\ws21.smc'

# Path to ucybsmcl.exe (Service Manager CLI).
$UcybsmclPath = 'C:\uc4\V21.0\ServiceManagerDialog\bin\ucybsmcl.exe'

# Computer name (including port) for the -h parameter of ucybsmcl.
$ServiceManagerComputerName = $env:COMPUTERNAME + ':18821'

# Service Manager environment ("Phrase") for the -n parameter of ucybsmcl.
$ServiceManagerPhrase = 'ws21'

# Path to the maintenance flag file. File exists = maintenance mode active.
# See the doc comment on Test-MaintenanceModeActive for format and behavior.
$MaintenanceFlagFilePath = 'C:\ProgramData\AutomicMonitoring\maintenance.flag'

# Minimum level that gets logged: DEBUG < INFO < WARN < ERROR.
# Leave at INFO for normal operation; set to DEBUG for troubleshooting - this
# additionally shows the full raw ucybsmcl output on failures.
$MinimumLogLevel = 'INFO'

# Optional log file path. $null = console output only (e.g. for interactive
# testing, or when the scheduled task already captures the output itself).
$LogFile = $null   # e.g. 'C:\Logs\Check-AutomicProcesses.log'

# Log entries older than this many days are automatically removed
# (roughly 6 months). Cleanup runs only once a day (see Invoke-LogFileCleanup),
# not on every 5-minute run.
$LogRetentionDays = 180


# ============================================================
# HELPER FUNCTIONS: LOGGING
# ============================================================

$script:LogLevelOrder = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3 }

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    if ($script:LogLevelOrder[$Level] -lt $script:LogLevelOrder[$MinimumLogLevel]) {
        return
    }

    $line = "{0:yyyy-MM-dd HH:mm:ss}  [{1}]  {2}" -f (Get-Date), $Level, $Message

    # IMPORTANT: Write-Host, not Write-Output! Write-Log is called from many
    # functions (gates, Invoke-Ucybsmcl, ...). Write-Output would inject the
    # log line into that function's success pipeline and corrupt its actual
    # return value (e.g. "return $false" would turn into a non-empty array
    # [logLine, $false] - and that is truthy in PowerShell). Write-Host writes
    # directly to the console without affecting the pipeline.
    Write-Host $line

    if ($LogFile) {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    }
}


# ============================================================
# Clean up the log file (remove entries older than $LogRetentionDays)
# ============================================================

function Invoke-LogFileCleanup {
    <#
        Removes lines from the log file whose timestamp is older than
        $LogRetentionDays. Lines without a recognizable timestamp at the
        start of the line (e.g. multi-line DEBUG output from ucybsmcl) are
        kept as a precaution rather than being guessed at and deleted.

        Deliberately runs only once a day (within the hour 00:00-00:59), not
        on every 5-minute run - otherwise large log files would be needlessly
        re-read and rewritten in full on every single run. The full one-hour
        window (rather than, say, just the first 5 minutes) is intentionally
        generous: it tolerates different scheduler intervals (see the note in
        the file header) without cleanup being skipped entirely on some days.
        Reading multiple times within the hour is cheap; the file is only
        ever rewritten on the first match anyway (see the $removedCount
        check below).
    #>
    param(
        [string]$Path          = $LogFile,
        [int]   $RetentionDays = $LogRetentionDays
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return
    }

    $now = Get-Date
    if ($now.Hour -ne 0) {
        return
    }

    $cutoff  = $now.AddDays(-$RetentionDays)
    $pattern = '^(\d{4}-\d{2}-\d{2})\s+\d{2}:\d{2}:\d{2}\s+\['

    $original = @(Get-Content -LiteralPath $Path)

    $kept = foreach ($line in $original) {
        if ($line -match $pattern) {
            $lineDate = [DateTime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)
            if ($lineDate -ge $cutoff) { $line }
        } else {
            $line
        }
    }
    $kept = @($kept)

    $removedCount = $original.Count - $kept.Count
    if ($removedCount -gt 0) {
        Set-Content -LiteralPath $Path -Value $kept -Encoding UTF8
        Write-Log "Log cleanup: removed $removedCount entries older than $RetentionDays days."
    }
}


# ============================================================
# HELPER FUNCTION: wrap ucybsmcl, keep error output compact
# ============================================================

# Known exit codes of ucybsmcl (see -help / Automic documentation).
$script:UcybsmclExitCodeDescriptions = @{
    0 = 'OK'
    1 = 'Invalid parameters'
    2 = 'No active Service Manager on the specified host'
    3 = 'Service Manager behaves unexpectedly'
    4 = 'Pipe error'
    5 = 'No Service Manager with the specified instance name'
}

function Invoke-Ucybsmcl {
    <#
        Central wrapper for all ucybsmcl calls.

        On error (e.g. wrong parameters), ucybsmcl prints its complete help
        text to STDERR. That's unusable in the log if it gets printed again
        on every single failure. This function therefore logs only a compact
        summary (exit code + meaning + first line of output) at ERROR level
        on failure; the full raw output only goes to DEBUG level (and is
        therefore suppressed by default).
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory)]
        [string]$Context
    )

    $output   = & $UcybsmclPath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE

    $description = if ($script:UcybsmclExitCodeDescriptions.ContainsKey($exitCode)) {
        $script:UcybsmclExitCodeDescriptions[$exitCode]
    } else {
        'Unknown exit code'
    }

    if ($exitCode -ne 0) {
        $firstLine = $output | Where-Object { $_ -and $_.ToString().Trim() -ne '' } | Select-Object -First 1
        Write-Log "$Context failed - exit code $exitCode ($description): $firstLine" -Level 'ERROR'
        Write-Log ("Full ucybsmcl output for '$Context':`n" + ($output -join [Environment]::NewLine)) -Level 'DEBUG'
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $output
        Success  = ($exitCode -eq 0)
    }
}


# ============================================================
# GATE 1: Manual maintenance mode active? (flag file)
# ============================================================

function Test-MaintenanceModeActive {
    <#
        Checks whether the maintenance flag file exists and is (still) valid.

        FLAG FILE FORMAT (one "Key: Value" line per entry, English keys):

            Until: 2026-08-21 14:00
            Reason: Patchday
            By: René

        - Until  : Optional, but recommended. Format 'yyyy-MM-dd HH:mm' (or
                   any format recognized by [DateTime]::TryParse). Acts as a
                   safety net: once this point in time has passed, maintenance
                   mode is considered NO LONGER active even if the file still
                   exists (e.g. because deleting it after a maintenance window
                   was forgotten). If Until is omitted, maintenance mode stays
                   active indefinitely until the file is removed manually.
        - Reason : Optional, informational only - goes into the log.
        - By     : Optional, informational only - goes into the log.

        If the file does not exist -> no maintenance mode, returns $false.

        Activating/ending maintenance mode only requires creating/deleting
        this file - the script itself does not need to be touched, e.g.:
            "Until: $((Get-Date).AddHours(2).ToString('yyyy-MM-dd HH:mm'))`nReason: Patchday`nBy: $env:USERNAME" |
                Set-Content 'C:\ProgramData\AutomicMonitoring\maintenance.flag'
    #>
    param(
        [string]$Path = $MaintenanceFlagFilePath
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $fields = @{}
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*(\w+)\s*:\s*(.+?)\s*$') {
            $fields[$Matches[1]] = $Matches[2]
        }
    }

    $reason = if ($fields.ContainsKey('Reason')) { $fields['Reason'] } else { '(not specified)' }
    $by     = if ($fields.ContainsKey('By'))     { $fields['By'] }     else { '(not specified)' }

    if ($fields.ContainsKey('Until')) {
        $untilRaw    = $fields['Until']
        $parsedUntil = [DateTime]::MinValue

        if ([DateTime]::TryParse($untilRaw, [ref]$parsedUntil)) {
            $now = Get-Date
            Write-Log "Maintenance flag: comparing Now ($($now.ToString('yyyy-MM-dd HH:mm:ss'))) with Until ($($parsedUntil.ToString('yyyy-MM-dd HH:mm:ss')))." -Level 'DEBUG'

            if ($now -gt $parsedUntil) {
                Write-Log "Maintenance flag found, but 'Until' ($untilRaw) is in the past - ignoring it." -Level 'WARN'

                # Best effort: automatically clean up the expired flag file.
                # A failure (e.g. missing permissions, file currently locked)
                # is deliberately only logged as WARN and ignored - the next
                # run will simply try to delete it again.
                try {
                    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
                    Write-Log "Expired maintenance flag file removed automatically: $Path"
                } catch {
                    Write-Log "Could not delete the expired maintenance flag file (ignoring, will retry on the next run): $($_.Exception.Message)" -Level 'WARN'
                }

                return $false
            }
        } else {
            Write-Log "Maintenance flag: could not parse 'Until' value '$untilRaw' - ignoring it (no expiry protection active for this entry)." -Level 'WARN'
        }
    } else {
        Write-Log "Maintenance flag set without 'Until' - stays active indefinitely until the file is deleted manually." -Level 'WARN'
    }

    Write-Log "Maintenance mode active (Reason: $reason, By: $by)."
    return $true
}


# ============================================================
# GATE 2: Intentional shutdown in progress?
# ============================================================

function Test-IntendedShutdownPending {
    param(
        [int]$LookbackMinutes = $ShutdownLookbackMinutes
    )

    $since = (Get-Date).AddMinutes(-$LookbackMinutes)

    $shutdownEvent = Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        Id        = 1074
        StartTime = $since
    } -MaxEvents 1 -ErrorAction SilentlyContinue

    return [bool]$shutdownEvent
}


# ============================================================
# GATE 3: Server still within the startup grace period?
# ============================================================

function Test-InStartupGracePeriod {
    param(
        [int]$GraceMinutes = $StartupGraceMinutes
    )

    $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    $elapsed  = (Get-Date) - $bootTime

    return $elapsed.TotalMinutes -lt $GraceMinutes
}


# ============================================================
# Read the required processes from the SMC file
# ============================================================

function Get-RequiredAutomicProcesses {
    <#
        Reads the SMC file line by line and returns the names of the active
        'create' entries. Disabled lines (e.g. "!reate ...") deliberately do
        not match, since they don't start with 'create'.

        Regex restricted to WP/CP/JWP/JCP/REST processes (tailored to the
        actual environment).
    #>
    param(
        [string]$Path = $SmcFilePath
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "SMC file not found: $Path" -Level 'ERROR'
        return @()
    }

    $required = foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match "^\s*create\s+(.*J?[WC]P.*|[^_]*REST[^_]*)") {
            $Matches[1]
        }
    }

    return @($required)
}


# ============================================================
# Query running services via ucybsmcl
# ============================================================

function Get-AutomicRunningServices {
    <#
        Calls "ucybsmcl -c GET_PROCESS_LIST" and parses the output.

        Output format per Automic documentation:
            "Service" "Status" ["ProcID" "Start time" "Runtime" "CPU Time"]
        Status: "R" = Running, "S" = Stopped

        Returns an array of PSCustomObjects with Name/Status for ALL known
        services (not just the running ones) - filtering happens on the
        caller's side.
    #>

    $result = Invoke-Ucybsmcl -Context 'GET_PROCESS_LIST' -ArgumentList @(
        '-c', 'GET_PROCESS_LIST',
        '-h', $ServiceManagerComputerName,
        '-n', $ServiceManagerPhrase
    )

    if (-not $result.Success) {
        return @()
    }

    $services = foreach ($line in $result.Output) {
        if ($line -match '^"([^"]+)"\s+"([^"]+)"') {
            [PSCustomObject]@{
                Name   = $Matches[1]
                Status = $Matches[2]
            }
        }
    }

    return @($services)
}


# ============================================================
# Diff: which required processes are not running?
# ============================================================

function Get-MissingAutomicProcesses {
    <#
        Compares the required list from the SMC file against the actually
        running (Status "R") services.

        Returns: array of missing process names (empty = all good).
    #>

    $required = Get-RequiredAutomicProcesses

    if ($required.Count -eq 0) {
        Write-Log "No active 'create' entries found in the SMC file - check skipped." -Level 'WARN'
        return @()
    }

    $running = Get-AutomicRunningServices
    $runningNames = @($running | Where-Object { $_.Status -eq 'R' } | Select-Object -ExpandProperty Name)

    $missing = @($required | Where-Object { $_ -notin $runningNames })

    return $missing
}


# ============================================================
# Restart missing processes
# ============================================================

function Start-AutomicProcesses {
    <#
        Starts the given process names one after another via
        "ucybsmcl -c START_PROCESS". A failed start does not abort the loop -
        it's logged and the remaining processes are still attempted.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$ProcessNames
    )

    foreach ($name in $ProcessNames) {
        Write-Log "Starting process '$name' ..."

        $result = Invoke-Ucybsmcl -Context "START_PROCESS '$name'" -ArgumentList @(
            '-c', 'START_PROCESS',
            '-h', $ServiceManagerComputerName,
            '-n', $ServiceManagerPhrase,
            '-s', $name
        )

        if ($result.Success) {
            Write-Log "Process '$name' started successfully."
        }
        # Failure is already logged compactly by Invoke-Ucybsmcl.
    }
}


# ============================================================
# MAIN
# ============================================================

Invoke-LogFileCleanup

Write-Log "Check started."

if (Test-MaintenanceModeActive) {
    Write-Log "Maintenance mode active. Skipping check."
    return
}

if (Test-IntendedShutdownPending) {
    Write-Log "Intentional shutdown/reboot detected (Event 1074 within the last $ShutdownLookbackMinutes min.). Skipping check."
    return
}

if (Test-InStartupGracePeriod) {
    $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    Write-Log "System is still within the startup grace period (boot: $bootTime, window: $StartupGraceMinutes min.). Skipping check."
    return
}

Write-Log "No gates active. Running process check."

$missingProcesses = Get-MissingAutomicProcesses

if ($missingProcesses.Count -eq 0) {
    Write-Log "All required Automic processes are running."
} else {
    Write-Log ("Missing processes: {0}" -f ($missingProcesses -join ', ')) -Level 'WARN'
    Start-AutomicProcesses -ProcessNames $missingProcesses
}

Write-Log "Check finished."
