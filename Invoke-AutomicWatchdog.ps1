#Requires -Version 5.1
<#
.SYNOPSIS
    Watchdog fuer Automic (UC4) Service-Manager-Prozesse: prueft, ob alle
    erforderlichen Prozesse laufen, und startet fehlende automatisch nach.

.DESCRIPTION
    Das Skript ueberspringt seine Pruef-/Restart-Logik in drei Situationen:
      1. Ein manueller Wartungsmodus ist ueber eine Flag-Datei aktiviert
         (siehe Test-MaintenanceModeActive).
      2. Es ist gerade ein beabsichtigter System-Shutdown/Reboot im Gange
         (erkannt ueber Event-ID 1074 im System-Log).
      3. Der Server ist erst kuerzlich gebootet und der Automic Service Manager
         faehrt die Prozesse voraussichtlich noch geordnet hoch (Grace Period
         basierend auf LastBootUpTime).

.USAGE
    Gedacht zum Einsatz als wiederkehrender Task im Windows Task Scheduler:

      1. Aktion:  "Programm starten"
         Programm/Skript:  powershell.exe
         Argumente:        -NoProfile -ExecutionPolicy Bypass -File "C:\Pfad\zu\Invoke-AutomicWatchdog.ps1"

      2. Trigger: "Bei Anmeldung" bzw. "Taeglich", mit aktivierter Option
         "Aufgabe wiederholen alle: 5 Minuten" fuer eine Dauer von "Unbegrenzt".

      3. Konto: ein Konto verwenden, das Leserechte auf die Wartungsflag-Datei
         und Ausfuehrungsrechte fuer ucybsmcl.exe hat ("Unabhaengig von der
         Benutzeranmeldung ausfuehren" aktivieren, damit der Task auch ohne
         angemeldete Session laeuft).

    WICHTIG - Zusammenhang mit dem Scheduler-Intervall:
      Die Logdatei-Bereinigung (siehe $LogRetentionDays / Invoke-LogFileCleanup)
      laeuft nur innerhalb eines taeglichen Zeitfensters (Default: die volle
      Stunde 00:00-00:59), NICHT bei jedem einzelnen Lauf. Ist das Scheduler-
      Intervall groesser als dieses Fenster (z. B. Trigger alle 90 Minuten),
      kann es vorkommen, dass an einzelnen Tagen KEIN Lauf in dieses Fenster
      faellt und die Bereinigung an diesem Tag ausfaellt - unkritisch, sie
      holt es am naechsten Tag nach. Ist das Intervall dagegen sehr kurz
      (z. B. alle 5 Minuten), wird die Logdatei innerhalb des Fensters
      mehrfach komplett eingelesen (im Beispiel bis zu 12x), aber nur beim
      ERSTEN Treffer tatsaechlich neu geschrieben (siehe $removedCount-Check) -
      das ist bewusst so und unkritisch. Bei sehr grossen Logdateien und sehr
      kurzen Intervallen (< 1 Minute) sollte das Fenster ggf. verkleinert
      werden.
#>

[CmdletBinding()]
param()

# ============================================================
# KONFIGURATION
# ============================================================

# Zeitfenster (Minuten), innerhalb dessen ein Event 1074 als
# "aktuell laufender, beabsichtigter Shutdown" gewertet wird.
$ShutdownLookbackMinutes = 5

# Zeitfenster (Minuten) nach dem Boot, in dem davon ausgegangen wird,
# dass der Automic Service Manager die Prozesse noch geordnet hochfaehrt.
$StartupGraceMinutes = 10

# Windows-Servicename des Automic Service Managers.
$ServiceManagerServiceName = 'UC4.ServiceManager.WS21'

# Pfad zur SMC-Konfigurationsdatei, die die erwarteten Prozesse definiert.
$SmcFilePath = 'C:\uc4\V21.0\ServiceManager\bin\ws21.smc'

# Pfad zu ucybsmcl.exe (ServiceManager CLI).
$UcybsmclPath = 'C:\uc4\V21.0\ServiceManagerDialog\bin\ucybsmcl.exe'

# Computername (inkl. Port) fuer -h Parameter von ucybsmcl.
$ServiceManagerComputerName = $env:COMPUTERNAME + ':18821'

# ServiceManager-Environment ("Phrase") fuer -n Parameter von ucybsmcl.
$ServiceManagerPhrase = 'ws21'

# Pfad zur Wartungsflag-Datei. Existenz der Datei = Wartungsmodus aktiv.
# Format und Verhalten siehe Doku-Kommentar bei Test-MaintenanceModeActive.
$MaintenanceFlagFilePath = 'C:\ProgramData\AutomicMonitoring\maintenance.flag'

# Ab welchem Level wird geloggt: DEBUG < INFO < WARN < ERROR.
# DEBUG zeigt zusaetzlich die vollstaendige Rohausgabe von ucybsmcl bei Fehlern -
# im Normalbetrieb auf INFO lassen, fuer Troubleshooting auf DEBUG stellen.
$MinimumLogLevel = 'INFO'

# Optionaler Logpfad. $null = nur Konsolenausgabe (z. B. bei interaktivem Test
# oder wenn der Scheduled Task die Ausgabe ohnehin protokolliert).
$LogFile = $null   # z. B. 'C:\Logs\Check-AutomicProcesses.log'

# Logeintraege, die aelter als diese Anzahl Tage sind, werden automatisch
# entfernt (ca. 6 Monate). Die Bereinigung laeuft nur einmal taeglich
# (siehe Invoke-LogFileCleanup), nicht bei jedem 5-Minuten-Lauf.
$LogRetentionDays = 180


# ============================================================
# HILFSFUNKTIONEN: LOGGING
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

    # WICHTIG: Write-Host statt Write-Output! Write-Log wird aus vielen Funktionen
    # heraus aufgerufen (Gates, Invoke-Ucybsmcl, ...). Write-Output wuerde die
    # Logzeile in die Erfolgs-Pipeline dieser Funktionen einschleusen und damit
    # deren eigentlichen Rueckgabewert verfaelschen (z. B. wird aus "return $false"
    # ein nicht-leeres Array [Logzeile, $false] - und das ist in PowerShell
    # truthy). Write-Host schreibt direkt auf die Konsole, ohne die Pipeline
    # zu beeinflussen.
    Write-Host $line

    if ($LogFile) {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    }
}


# ============================================================
# Log-Datei bereinigen (Eintraege > $LogRetentionDays entfernen)
# ============================================================

function Invoke-LogFileCleanup {
    <#
        Entfernt Zeilen aus der Logdatei, deren Zeitstempel aelter als
        $LogRetentionDays ist. Zeilen ohne erkennbaren Zeitstempel am
        Zeilenanfang (z. B. mehrzeilige DEBUG-Ausgaben von ucybsmcl) werden
        sicherheitshalber behalten statt geraten geloescht zu werden.

        Laeuft bewusst nur einmal taeglich (innerhalb der Stunde 00:00-00:59),
        nicht bei jedem 5-Minuten-Lauf - sonst wird bei grossen Logdateien
        unnoetig oft die komplette Datei neu eingelesen und geschrieben.
        Das volle Stundenfenster (statt z. B. nur der ersten 5 Minuten) ist
        bewusst grosszuegig gewaehlt: es toleriert unterschiedliche Scheduler-
        Intervalle (siehe Hinweis im Datei-Header), ohne dass die Bereinigung
        an einzelnen Tagen komplett ausfaellt. Mehrfaches Lesen innerhalb der
        Stunde ist billig, geschrieben wird ohnehin nur beim ersten Treffer
        (siehe $removedCount-Check unten).
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
        Write-Log "Logbereinigung: $removedCount Eintraege aelter als $RetentionDays Tage entfernt."
    }
}


# ============================================================
# HILFSFUNKTION: ucybsmcl kapseln, Fehlerausgabe kompakt halten
# ============================================================

# Bekannte Exitcodes von ucybsmcl (siehe -help / Automic-Doku).
$script:UcybsmclExitCodeDescriptions = @{
    0 = 'OK'
    1 = 'Invalid parameters'
    2 = 'Kein aktiver ServiceManager auf dem angegebenen Host'
    3 = 'ServiceManager verhaelt sich unerwartet'
    4 = 'Pipe-Fehler'
    5 = 'Kein ServiceManager mit dem angegebenen Instanznamen'
}

function Invoke-Ucybsmcl {
    <#
        Zentraler Wrapper fuer alle ucybsmcl-Aufrufe.

        ucybsmcl gibt bei einem Fehler (z. B. falsche Parameter) den kompletten
        Hilfetext auf STDERR aus. Das ist im Log unbrauchbar, wenn es bei jedem
        Fehlschlag erneut abgedruckt wird. Diese Funktion loggt deshalb im
        Fehlerfall nur eine knappe Zusammenfassung (Exitcode + Bedeutung + erste
        Zeile der Ausgabe) auf ERROR-Level; die vollstaendige Rohausgabe landet
        nur auf DEBUG-Level (und wird damit standardmaessig unterdrueckt).
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
        'Unbekannter Exitcode'
    }

    if ($exitCode -ne 0) {
        $firstLine = $output | Where-Object { $_ -and $_.ToString().Trim() -ne '' } | Select-Object -First 1
        Write-Log "$Context fehlgeschlagen - Exitcode $exitCode ($description): $firstLine" -Level 'ERROR'
        Write-Log ("Vollstaendige ucybsmcl-Ausgabe fuer '$Context':`n" + ($output -join [Environment]::NewLine)) -Level 'DEBUG'
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $output
        Success  = ($exitCode -eq 0)
    }
}


# ============================================================
# GATE 1: Manueller Wartungsmodus aktiv? (Flag-Datei)
# ============================================================

function Test-MaintenanceModeActive {
    <#
        Prueft, ob die Wartungsflag-Datei existiert und (noch) gueltig ist.

        FORMAT DER FLAG-DATEI (eine "Key: Value"-Zeile pro Eintrag, Keys englisch):

            Until: 2026-08-21 14:00
            Reason: Patchday
            By: René

        - Until  : Optional, aber empfohlen. Format 'yyyy-MM-dd HH:mm' (bzw. jedes
                   von [DateTime]::TryParse erkannte Format). Dient als Sicherheitsnetz:
                   ist der Zeitpunkt ueberschritten, gilt der Wartungsmodus als
                   NICHT mehr aktiv, selbst wenn die Datei noch existiert (z. B. weil
                   das Loeschen nach einem Wartungsfenster vergessen wurde).
                   Fehlt Until, bleibt der Wartungsmodus unbegrenzt aktiv, bis die
                   Datei manuell entfernt wird.
        - Reason : Optional, rein informativ - landet im Log.
        - By     : Optional, rein informativ - landet im Log.

        Existiert die Datei nicht -> kein Wartungsmodus, Rueckgabe $false.

        Zum Aktivieren/Beenden ist ausschliesslich das Anlegen/Loeschen dieser
        Datei noetig - das Skript selbst muss dafuer nicht angefasst werden,
        z. B.:
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

    $reason = if ($fields.ContainsKey('Reason')) { $fields['Reason'] } else { '(nicht angegeben)' }
    $by     = if ($fields.ContainsKey('By'))     { $fields['By'] }     else { '(nicht angegeben)' }

    if ($fields.ContainsKey('Until')) {
        $untilRaw    = $fields['Until']
        $parsedUntil = [DateTime]::MinValue

        if ([DateTime]::TryParse($untilRaw, [ref]$parsedUntil)) {
            $now = Get-Date
            Write-Log "Wartungsflag: Vergleiche Now ($($now.ToString('yyyy-MM-dd HH:mm:ss'))) mit Until ($($parsedUntil.ToString('yyyy-MM-dd HH:mm:ss')))." -Level 'DEBUG'

            if ($now -gt $parsedUntil) {
                Write-Log "Wartungsflag gefunden, aber 'Until' ($untilRaw) liegt in der Vergangenheit - wird ignoriert." -Level 'WARN'

                # Best-effort: abgelaufene Flag-Datei automatisch aufraeumen.
                # Fehlschlag (z. B. fehlende Rechte, Datei gerade gesperrt) wird
                # bewusst nur als WARN geloggt und ignoriert - beim naechsten
                # Lauf wird der Loeschversuch einfach wiederholt.
                try {
                    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
                    Write-Log "Abgelaufene Wartungsflag-Datei automatisch entfernt: $Path"
                } catch {
                    Write-Log "Abgelaufene Wartungsflag-Datei konnte nicht geloescht werden (wird ignoriert, naechster Versuch beim naechsten Lauf): $($_.Exception.Message)" -Level 'WARN'
                }

                return $false
            }
        } else {
            Write-Log "Wartungsflag: 'Until'-Wert '$untilRaw' konnte nicht geparst werden - wird ignoriert (kein Ablaufschutz aktiv fuer diesen Eintrag)." -Level 'WARN'
        }
    } else {
        Write-Log "Wartungsflag ohne 'Until' gesetzt - bleibt unbegrenzt aktiv bis zum manuellen Loeschen der Datei." -Level 'WARN'
    }

    Write-Log "Wartungsmodus aktiv (Reason: $reason, By: $by)."
    return $true
}


# ============================================================
# GATE 2: Beabsichtigter Shutdown im Gange?
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
# GATE 3: Server befindet sich noch in der Startup-Grace-Period?
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
# Sollprozesse aus der SMC-Datei einlesen
# ============================================================

function Get-RequiredAutomicProcesses {
    <#
        Liest die SMC-Datei zeilenweise ein und liefert die Namen der aktiven
        'create'-Eintraege. Deaktivierte Zeilen (z. B. "!reate ...") matchen
        bewusst nicht, da sie nicht mit 'create' beginnen.

        Regex auf WP/CP/JWP/JCP/REST-Prozesse eingeschraenkt (an die
        tatsaechliche Umgebung angepasst).
    #>
    param(
        [string]$Path = $SmcFilePath
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "SMC-Datei nicht gefunden: $Path" -Level 'ERROR'
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
# Laufende Services per ucybsmcl abfragen
# ============================================================

function Get-AutomicRunningServices {
    <#
        Ruft "ucybsmcl -c GET_PROCESS_LIST" auf und parst die Ausgabe.

        Ausgabeformat laut Automic-Doku:
            "Service" "Status" ["ProcID" "Start time" "Runtime" "CPU Time"]
        Status: "R" = Running, "S" = Stopped

        Liefert ein Array von PSCustomObjects mit Name/Status fuer ALLE
        bekannten Services (nicht nur die laufenden) - Filterung erfolgt
        beim Aufrufer.
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
# Abgleich: welche Sollprozesse laufen nicht?
# ============================================================

function Get-MissingAutomicProcesses {
    <#
        Vergleicht die Sollliste aus der SMC-Datei mit den tatsaechlich
        laufenden (Status "R") Services.

        Rueckgabe: Array der fehlenden Prozessnamen (leer = alles ok).
    #>

    $required = Get-RequiredAutomicProcesses

    if ($required.Count -eq 0) {
        Write-Log "Keine aktiven 'create'-Eintraege in der SMC-Datei gefunden - Pruefung uebersprungen." -Level 'WARN'
        return @()
    }

    $running = Get-AutomicRunningServices
    $runningNames = @($running | Where-Object { $_.Status -eq 'R' } | Select-Object -ExpandProperty Name)

    $missing = @($required | Where-Object { $_ -notin $runningNames })

    return $missing
}


# ============================================================
# Fehlende Prozesse nachstarten
# ============================================================

function Start-AutomicProcesses {
    <#
        Startet die uebergebenen Prozessnamen nacheinander per
        "ucybsmcl -c START_PROCESS". Ein fehlgeschlagener Start bricht die
        Schleife nicht ab, sondern wird geloggt - die uebrigen Prozesse
        werden trotzdem versucht.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$ProcessNames
    )

    foreach ($name in $ProcessNames) {
        Write-Log "Starte Prozess '$name' ..."

        $result = Invoke-Ucybsmcl -Context "START_PROCESS '$name'" -ArgumentList @(
            '-c', 'START_PROCESS',
            '-h', $ServiceManagerComputerName,
            '-n', $ServiceManagerPhrase,
            '-s', $name
        )

        if ($result.Success) {
            Write-Log "Prozess '$name' erfolgreich gestartet."
        }
        # Fehlerfall wird bereits kompakt von Invoke-Ucybsmcl geloggt.
    }
}


# ============================================================
# HAUPTABLAUF
# ============================================================

Invoke-LogFileCleanup

Write-Log "Pruefung gestartet."

if (Test-MaintenanceModeActive) {
    Write-Log "Wartungsmodus aktiv. Ueberspringe Pruefung."
    return
}

if (Test-IntendedShutdownPending) {
    Write-Log "Beabsichtigter Shutdown/Reboot erkannt (Event 1074 innerhalb der letzten $ShutdownLookbackMinutes Min.). Ueberspringe Pruefung."
    return
}

if (Test-InStartupGracePeriod) {
    $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    Write-Log "System befindet sich noch in der Startup-Grace-Period (Boot: $bootTime, Fenster: $StartupGraceMinutes Min.). Ueberspringe Pruefung."
    return
}

Write-Log "Keine Gates aktiv. Fuehre Prozesspruefung durch."

$missingProcesses = Get-MissingAutomicProcesses

if ($missingProcesses.Count -eq 0) {
    Write-Log "Alle erforderlichen Automic-Prozesse laufen."
} else {
    Write-Log ("Fehlende Prozesse: {0}" -f ($missingProcesses -join ', ')) -Level 'WARN'
    Start-AutomicProcesses -ProcessNames $missingProcesses
}

Write-Log "Pruefung beendet."
