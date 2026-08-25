#Requires -Version 5.1
<#
.SYNOPSIS
    Watchdog for Automic (UC4) Service Manager processes: checks whether all
    required processes are running and automatically restarts any that are missing.
 
.DESCRIPTION
    The script skips its check/restart logic for the ENTIRE run in three
    situations:
      1. A manual maintenance mode has been activated via a flag file
         (see Test-MaintenanceModeActive).
      2. The server has just booted and the Automic Service Manager is
         presumably still bringing processes up in an orderly fashion
         (grace period based on LastBootUpTime).
      3. An intentional system shutdown/reboot is currently in progress
         (detected via Event ID 1074 in the System log). Checked only once
         the startup grace period above has already passed - see the note
         on Get-IntendedShutdownEvent for why that ordering matters.
 
    In addition, restarting a SINGLE process (not the whole run) is skipped
    once that process has been restarted too often in too short a time -
    see the ENDLESS-LOOP PROTECTION section and Invoke-EndlessLoopCheck.
    This is what actually prevents the watchdog from restarting a
    persistently crashing process forever ("sich im Kreise starten").
 
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
 
      The endless-loop protection (see below) also reads $LogFile and
      therefore requires it to be configured - without a persisted log file
      there is no history to evaluate restart frequency against.
 
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
 
# Name of this Automic system/environment. Defined once here and reused
# below wherever the environment name appears in a path, the phrase, etc. -
# change ONE value here instead of hunting down every occurrence.
# NOTE: must use double quotes ("...") wherever this is interpolated below,
# not single quotes ('...') - single-quoted strings in PowerShell are
# literal and do NOT expand variables.
#
# Derived automatically from the server's computer name, so this ONE script
# file can be deployed unchanged to every server hosting one of your Automic
# systems - each server picks its own system (and, further below, its own
# Service Manager port) without needing a server-specific copy of the file.
# To add a server/system: add one more entry to the switch below, nothing
# else needs to change. Assumes one Automic system per server; a server
# hosting several systems would need one scheduled task per system instead,
# each overriding $SYSTEM_NAME after this block.

switch ($env:COMPUTERNAME) {
    'SRV-AUTOMIC-Q1' { $SYSTEM_NAME = 'UC4Q' }   # TODO: replace with your real server/system names
	'SRV-AUTOMIC-Q2' { $SYSTEM_NAME = 'UC4Q' }
    'SRV-AUTOMIC-P1' { $SYSTEM_NAME = 'UC4P' }
	'SRV-AUTOMIC-P2' { $SYSTEM_NAME = 'UC4P' }
    default {
        Write-Error "No Automic system configured for computer name '$env:COMPUTERNAME'. Add an entry to the `$env:COMPUTERNAME switch in the CONFIGURATION section of this script."
        exit 1
    }
}

# Service Manager port, derived from $SYSTEM_NAME (each system listens on
# its own port). Add an entry here whenever a new system is added above.
switch ($SYSTEM_NAME) {
    'UC4Q' { $ServiceManagerPort = '8745' }
    'UC4P' { $ServiceManagerPort = '8746' }   # TODO: replace with your real ports
    default {
        Write-Error "No Service Manager port configured for system '$SYSTEM_NAME'. Add an entry to the `$SYSTEM_NAME switch in the CONFIGURATION section of this script."
        exit 1
    }
}


# Time window (minutes) within which an Event 1074 is considered an
# "intentional shutdown currently in progress".
$ShutdownLookbackMinutes = 5
 
# Time window (minutes) after boot during which the Automic Service Manager
# is assumed to still be bringing processes up in an orderly fashion.
$StartupGraceMinutes = 10
 
# Time to wait after each process start
$ProcessStartDelaySeconds = 5
 
# Path to the SMC configuration file that defines the expected processes.
$SmcFilePath = "D:\Automic\$SYSTEM_NAME\ServiceManager\bin\$SYSTEM_NAME.smc"
 
# Path to ucybsmcl.exe (Service Manager CLI).
$UcybsmclPath = "D:\Automic\$SYSTEM_NAME\ServiceManagerDialog\bin\ucybsmcl.exe"
 
# Regex-String to match the smc entries which shall be monitored
$ProcessNameRegex = "(?!"+$env:COMPUTERNAME+"_).*"
 
# Computer name (including port) for the -h parameter of ucybsmcl.
$ServiceManagerComputerName = $env:COMPUTERNAME + ':' + $ServiceManagerPort
 
# Service Manager environment ("Phrase") for the -n parameter of ucybsmcl.
$ServiceManagerPhrase = $SYSTEM_NAME
 
# Path to the maintenance flag file. File exists = maintenance mode active.
# See the doc comment on Test-MaintenanceModeActive for format and behavior.
$MaintenanceFlagFilePath = "D:\Automic\$SYSTEM_NAME\Watchdog\maintenance.flag"
 
# --- Endless-loop protection ---
# Time window (minutes) used to count recent restart attempts per process.
$EndlessLoopLookbackMinutes = 30
 
# Maximum number of restart attempts allowed for the same process within
# $EndlessLoopLookbackMinutes. One more attempt than this creates a
# "LoopProtection_<ProcessName>.flag" file instead of starting the process;
# that process is then skipped on every subsequent run until the file is
# deleted manually. See the ENDLESS-LOOP PROTECTION section below.
$EndlessLoopMaxRestarts = 3
 
# Folder where LoopProtection_<ProcessName>.flag files are created.
$EndlessLoopFlagDirectory = "D:\Automic\$SYSTEM_NAME\Watchdog"
 
# Performance safeguard: instead of reading the entire log file, only the
# last this-many lines are scanned per run for the endless-loop check. Must
# comfortably cover $EndlessLoopLookbackMinutes worth of log entries even on
# a busy run (several missing processes, WARN/ERROR lines, ...) - the
# default is deliberately generous. Without this cap, a log file that has
# grown large over a long retention period combined with a short scheduler
# interval would make Get-Content read the whole file on every single run.
$EndlessLoopLogTailLines = 5000
 
# Minimum level that gets logged: DEBUG < INFO < WARN < ERROR.
# Leave at INFO for normal operation; set to DEBUG for troubleshooting - this
# additionally shows the full raw ucybsmcl output on failures.
$MinimumLogLevel = 'INFO'
 
# Optional log file path. $null = console output only (e.g. for interactive
# testing, or when the scheduled task already captures the output itself).
# NOTE: the endless-loop protection (see below) needs this to be set - it
# reads recent restart attempts back out of this file.
#$LogFile = $null   # e.g. 'C:\Logs\Check-AutomicProcesses.log'
$LogFile = "D:\Automic\$SYSTEM_NAME\Watchdog\AutomicProcessesWatchdog.log"
 
# Log entries older than this many days are automatically removed
# (roughly 6 months). Cleanup runs only once a day (see Invoke-LogFileCleanup),
# not on every 5-minute run.
$LogRetentionDays = 100


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

            From: 2026-08-25 22:00
            Until: 2026-08-26 02:00
            Reason: Patchday
            By: <name>

        - From   : Optional. Format 'yyyy-MM-dd HH:mm' (or any format
                   recognized by [DateTime]::TryParse). Lets a maintenance
                   window be scheduled in advance: before this point in time
                   the flag file is ignored entirely (maintenance mode is NOT
                   active yet). Unlike an expired Until, a not-yet-started
                   From is deliberately NOT deleted - it is scheduled, not
                   expired. If omitted, maintenance mode is active as soon as
                   the file exists.
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

          Immediate, for the next 2 hours:
            "Until: $((Get-Date).AddHours(2).ToString('yyyy-MM-dd HH:mm'))`nReason: Patchday`nBy: $env:USERNAME" |
                Set-Content 'D:\Automic\UC4Q\Watchdog\maintenance.flag'

          Scheduled in advance, e.g. next Saturday 22:00-02:00:
            "From: 2026-08-29 22:00`nUntil: 2026-08-30 02:00`nReason: Patchday`nBy: $env:USERNAME" |
                Set-Content 'D:\Automic\UC4Q\Watchdog\maintenance.flag'
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
    $now    = Get-Date

    # --- From: has the maintenance window started yet? ---
    if ($fields.ContainsKey('From')) {
        $fromRaw    = $fields['From']
        $parsedFrom = [DateTime]::MinValue

        if ([DateTime]::TryParse($fromRaw, [ref]$parsedFrom)) {
            if ($now -lt $parsedFrom) {
                # Scheduled for the future - not active yet, and deliberately
                # NOT deleted: this is a planned window, not an expired one.
                Write-Log "Maintenance flag found, but 'From' ($fromRaw) is still in the future - not active yet." -Level 'DEBUG'
                return $false
            }
        } else {
            Write-Log "Maintenance flag: could not parse 'From' value '$fromRaw' - ignoring it." -Level 'WARN'
        }
    }

    # --- Until: has the maintenance window already ended? ---
    if ($fields.ContainsKey('Until')) {
        $untilRaw    = $fields['Until']
        $parsedUntil = [DateTime]::MinValue

        if ([DateTime]::TryParse($untilRaw, [ref]$parsedUntil)) {
            Write-Log "Maintenance flag: comparing Now ($($now.ToString('yyyy-MM-dd HH:mm:ss'))) with Until ($($parsedUntil.ToString('yyyy-MM-dd HH:mm:ss')))." -Level 'DEBUG'

            if ($now -gt $parsedUntil) {
                Write-Log "Maintenance flag found, but 'Until' ($untilRaw) is in the past - ignoring it." -Level 'WARN'

                # Best effort: automatically clean up the expired flag file.
                # Only reached once Until has actually passed - a flag that
                # is merely scheduled for the future (From still ahead) is
                # never touched here, see the From check above.
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
# GATE 2: Server still within the startup grace period?
#
# Checked BEFORE the shutdown gate below: right after a reboot, the Event
# 1074 that caused it is still fresh enough to fall within the shutdown
# lookback window too. Checking the (usually larger) grace-period window
# first means this common case is resolved here without even having to
# query the event log, and without relying on the boot-time comparison
# inside Get-IntendedShutdownEvent to catch it.
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
# GATE 3: Intentional shutdown in progress?
# ============================================================
 
function Get-IntendedShutdownEvent {
    <#
        Looks for an Event 1074 (System log) within the last $LookbackMinutes
        that indicates an intentional shutdown/reboot is currently in
        progress.
 
        IMPORTANT: Event 1074 is written BEFORE the shutdown actually
        happens, so it stays in the System log across the reboot it caused.
        If that reboot has already completed - i.e. the event is older than
        the current boot time - the shutdown it announced is over, the
        system is already back up. Without checking that, this gate could
        fire again right after a reboot for a shutdown that is actually
        already done.
 
        In practice this is already avoided in the common case by checking
        the startup grace period FIRST in MAIN (see GATE 2 above): a fresh
        reboot is normally caught there, before this function ever runs.
        The boot-time comparison below remains as a safeguard for the case
        where $ShutdownLookbackMinutes is configured larger than
        $StartupGraceMinutes - then a stale Event 1074 could still be within
        the shutdown lookback window even after the grace period has
        already elapsed.
 
        Returns the matching event (its .TimeCreated is used for logging) if
        a genuinely pending shutdown was found, otherwise $null.
    #>
    param(
        [int]$LookbackMinutes = $ShutdownLookbackMinutes
    )
 
    $since = (Get-Date).AddMinutes(-$LookbackMinutes)
 
    $shutdownEvent = Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        Id        = 1074
        StartTime = $since
    } -MaxEvents 1 -ErrorAction SilentlyContinue
 
    if (-not $shutdownEvent) {
        return $null
    }
 
    $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
 
    if ($shutdownEvent.TimeCreated -lt $bootTime) {
        Write-Log "Found Event 1074 at $($shutdownEvent.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')), but it predates the current boot ($($bootTime.ToString('yyyy-MM-dd HH:mm:ss'))) - that shutdown has already completed, ignoring it." -Level 'DEBUG'
        return $null
    }
 
    return $shutdownEvent
}
 
 
# ============================================================
# Read the required processes from the SMC file
# ============================================================
 
function Get-RequiredAutomicProcesses {
    <#
        Reads the SMC file line by line and returns the names of the active
        'create' entries whose name matches $ProcessNameRegex. Disabled lines
        (e.g. "!reate ...") deliberately do not match, since they don't start
        with 'create'.
 
        $ProcessNameRegex is fully configurable (see CONFIGURATION section
        above); the shipped default excludes entries prefixed with the local
        computer name (e.g. host-specific remote-agent entries), keeping
        only the centrally managed processes.
    #>
    param(
        [string]$Path = $SmcFilePath
    )
 
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "SMC file not found: $Path" -Level 'ERROR'
        return @()
    }
 
    $required = foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match "^\s*create\s+("+$ProcessNameRegex+")") {
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
# ENDLESS-LOOP PROTECTION (per process, not a global gate)
#
# Purpose: if a process crashes right after every restart (a real bug, not
# a transient issue), the watchdog would otherwise detect it missing again
# on the very next run and restart it again - forever, every 5 minutes,
# without ever fixing anything and without anyone necessarily noticing.
# This protection interrupts that cycle by counting restart attempts per
# process (from the log file) and, once too many happened in too short a
# time, refusing to start that one process any further until a human has
# looked at it and removed the protection file. Deliberately manual-only
# recovery, no automatic expiry - see Invoke-EndlessLoopCheck below.
# ============================================================
 
function Get-EndlessLoopProtectionFlagPath {
    <#
        Builds the path of the endless-loop protection flag file for a given
        process name. Characters that are not allowed in Windows file names
        (\ / : * ? " < > |) are replaced with '_', since Automic process
        names can contain them (e.g. an AWI entry like
        "AWI - http://uc4:8021/awi/").
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ProcessName
    )
 
    $safeName = $ProcessName -replace '[\\/:*?"<>|]', '_'
    return Join-Path -Path $EndlessLoopFlagDirectory -ChildPath "LoopProtection_$safeName.flag"
}
 
function Test-EndlessLoopProtectionActive {
    <#
        Returns $true if an endless-loop protection flag file already exists
        for this process, i.e. automatic restarts for it are currently
        suspended. The file must be removed manually before the watchdog
        will attempt to start this process again - there is no automatic
        expiry, unlike the maintenance flag.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ProcessName
    )
 
    return (Test-Path -LiteralPath (Get-EndlessLoopProtectionFlagPath -ProcessName $ProcessName))
}
 
function Invoke-EndlessLoopCheck {
    <#
        Looks at the log file to see how often a restart of $ProcessName has
        already been attempted within the last $LookbackMinutes minutes. If
        that count has already reached $MaxRestarts, one more attempt would
        exceed the limit - this process is very likely stuck in a restart
        loop, and this next attempt is skipped instead of being made.
 
        In that case, a "LoopProtection_<ProcessName>.flag" file is created
        containing the matching log excerpt as evidence, and this function
        returns $true - the caller must then skip starting the process this
        round. Requires $LogFile to be configured; without a persisted log
        there is no history to evaluate, so the check is effectively
        disabled in that case (logged once as WARN).
 
        Recovery is intentionally manual only: the flag file must be deleted
        by an administrator once the underlying cause has been fixed. There
        is no automatic expiry - a process that keeps crashing right after
        being restarted is very likely a real bug, and silently retrying it
        forever (or after a cooldown) would just hide that instead of
        surfacing it.
 
        PERFORMANCE: reading the log file is the expensive part here, not the
        regex matching - large log files (long retention, short scheduler
        interval) can run into the tens or hundreds of MB. Two things keep
        this cheap:
          - Only the last $EndlessLoopLogTailLines lines are read (via
            Get-Content -Tail), never the whole file - see the comment on
            that setting in the CONFIGURATION section for why that's safe.
          - When called from Start-AutomicProcesses for several missing
            processes in the same run, pass the same pre-loaded $LogLines in
            to avoid reading (even just the tail of) the log file again for
            every single process.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ProcessName,
 
        [int]$LookbackMinutes = $EndlessLoopLookbackMinutes,
        [int]$MaxRestarts     = $EndlessLoopMaxRestarts,
 
        # Optional: pre-loaded log tail, so a caller checking several
        # processes in the same run only has to read the log file once.
        # Falls back to reading $LogFile's tail itself if not supplied.
        [string[]]$LogLines
    )
 
    if (-not $LogFile) {
        Write-Log "Endless-loop protection needs `$LogFile to be configured - skipping the check for '$ProcessName'." -Level 'WARN'
        return $false
    }
 
    if (-not $PSBoundParameters.ContainsKey('LogLines')) {
        if (-not (Test-Path -LiteralPath $LogFile)) {
            Write-Log "Endless-loop protection: log file not found ($LogFile) - skipping the check for '$ProcessName'." -Level 'WARN'
            return $false
        }
        $LogLines = @(Get-Content -LiteralPath $LogFile -Tail $EndlessLoopLogTailLines)
    }
 
    $since         = (Get-Date).AddMinutes(-$LookbackMinutes)
    $escapedName   = [regex]::Escape($ProcessName)
    $pattern       = "^(?<ts>\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s+\[\w+\]\s+Starting process '$escapedName' \.\.\.$"
 
    $recentAttempts = foreach ($line in $LogLines) {
        if ($line -match $pattern) {
            $ts = [DateTime]::ParseExact($Matches.ts, 'yyyy-MM-dd HH:mm:ss', $null)
            if ($ts -ge $since) { $line }
        }
    }
    $recentAttempts = @($recentAttempts)
 
    if ($recentAttempts.Count -lt $MaxRestarts) {
        return $false
    }
 
    Write-Log "Process '$ProcessName' has been restarted $($recentAttempts.Count) times within the last $LookbackMinutes minutes (limit: $MaxRestarts). Automatic restarts for this process are now stopped - remove the protection file manually once the cause has been fixed." -Level 'ERROR'
 
    $flagPath = Get-EndlessLoopProtectionFlagPath -ProcessName $ProcessName
    try {
        $header = @(
            "Endless-loop protection activated for process '$ProcessName' at $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')).",
            "Restarted $($recentAttempts.Count) times within the last $LookbackMinutes minutes (limit: $MaxRestarts).",
            "Delete this file to let the watchdog try starting this process again.",
            "",
            "Matching log excerpt:"
        ) -join [Environment]::NewLine
 
        ($header, ($recentAttempts -join [Environment]::NewLine)) -join [Environment]::NewLine |
            Set-Content -LiteralPath $flagPath -Encoding UTF8
    } catch {
        Write-Log "Could not create the endless-loop protection file for '$ProcessName' ($flagPath): $($_.Exception.Message)" -Level 'ERROR'
    }
 
    return $true
}
 
 
# ============================================================
# Restart missing processes
# ============================================================
 
function Start-AutomicProcesses {
    <#
        Starts the given process names one after another via
        "ucybsmcl -c START_PROCESS". A failed start does not abort the loop -
        it's logged and the remaining processes are still attempted.
 
        Before each start, two independent checks can skip a process:
          - Test-EndlessLoopProtectionActive: a protection file from an
            earlier run already exists for this process.
          - Invoke-EndlessLoopCheck: this process has not been protected yet,
            but this attempt would push it over the restart limit - so
            protection is activated now, and this attempt is skipped too.
 
        The log tail used by Invoke-EndlessLoopCheck is read once here (not
        once per process) and passed into every call - see the PERFORMANCE
        note on Invoke-EndlessLoopCheck.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$ProcessNames
    )
 
    $logTail = if ($LogFile -and (Test-Path -LiteralPath $LogFile)) {
        @(Get-Content -LiteralPath $LogFile -Tail $EndlessLoopLogTailLines)
    } else {
        @()
    }
 
    foreach ($name in $ProcessNames) {
 
        if (Test-EndlessLoopProtectionActive -ProcessName $name) {
            Write-Log "Endless-loop protection is active for process '$name' - skipping automatic restart. Remove '$(Get-EndlessLoopProtectionFlagPath -ProcessName $name)' manually once the cause has been fixed." -Level 'WARN'
            continue
        }
 
        if (Invoke-EndlessLoopCheck -ProcessName $name -LogLines $logTail) {
            continue
        }
 
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
 
        Start-Sleep $ProcessStartDelaySeconds
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
 
if (Test-InStartupGracePeriod) {
    $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    Write-Log "System is still within the startup grace period (boot: $bootTime, window: $StartupGraceMinutes min.). Skipping check."
    return
}
 
$pendingShutdownEvent = Get-IntendedShutdownEvent
if ($pendingShutdownEvent) {
    Write-Log "Intentional shutdown/reboot detected (Event 1074 at $($pendingShutdownEvent.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')), within the last $ShutdownLookbackMinutes min.). Skipping check."
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
