# Automic Watchdog

Ein PowerShell-Watchdog-Skript für [Automic (UC4) Automation Engine](https://docs.automic.com/) auf Windows: prüft in regelmäßigen Abständen, ob alle über die `ServiceManager`-SMC-Datei definierten Prozesse laufen, und startet fehlende automatisch über die `ServiceManager`-CLI (`ucybsmcl`) nach.

## Features

- **Prozessprüfung gegen die SMC-Datei** – liest die aktiven `create`-Einträge aus der `ServiceManager`-Konfigurationsdatei und gleicht sie mit `ucybsmcl -c GET_PROCESS_LIST` ab.
- **Automatischer Nachstart** fehlender Prozesse über `ucybsmcl -c START_PROCESS`.
- **Drei "Gates"**, die eine Prüfung/Aktion bewusst überspringen:
  - **Wartungsmodus** über eine zentral wart- und lesbare Flag-Datei (kein Skript-Zugriff nötig, siehe unten).
  - **Beabsichtigter Shutdown/Reboot** – erkannt über Event-ID 1074 im System-Log.
  - **Startup-Grace-Period** – toleriert, dass der Service Manager nach einem Boot noch geordnet hochfährt.
- **Kompaktes Logging** mit Log-Level (`DEBUG`/`INFO`/`WARN`/`ERROR`), optionalem File-Sink und automatischer Alt-Eintrag-Bereinigung.
- Fehlerausgaben von `ucybsmcl` werden nicht mehr vollständig geloggt (der komplette Hilfetext bei Fehlern), sondern kompakt auf eine Zeile zusammengefasst; die Rohausgabe bleibt auf `DEBUG`-Level abrufbar.

## Voraussetzungen

- Windows Server 2016 oder neuer, PowerShell 5.1
- Automic Automation Engine mit ServiceManager (`ucybsmcl.exe`)
- Ausführendes Konto benötigt:
  - Leserechte auf die SMC-Datei und die Wartungsflag-Datei
  - Ausführungsrechte für `ucybsmcl.exe`
  - Leserechte auf das System-Event-Log (Event-ID 1074)

## Konfiguration

Alle Einstellungen befinden sich im Konfigurationsblock am Anfang von [`Invoke-AutomicWatchdog.ps1`](./Invoke-AutomicWatchdog.ps1) – kein Parsen von Kommandozeilenargumenten, bewusst einfach gehalten für den Einsatz als Scheduled Task:

| Variable | Bedeutung |
|---|---|
| `$ShutdownLookbackMinutes` | Zeitfenster, in dem ein Event 1074 als aktueller Shutdown gilt |
| `$StartupGraceMinutes` | Zeitfenster nach dem Boot, in dem Prüfungen übersprungen werden |
| `$ServiceManagerServiceName` | Windows-Servicename des Automic Service Managers |
| `$SmcFilePath` | Pfad zur SMC-Konfigurationsdatei |
| `$UcybsmclPath` | Pfad zu `ucybsmcl.exe` |
| `$ServiceManagerComputerName` | `-h`-Parameter für `ucybsmcl` (inkl. Port, falls nötig) |
| `$ServiceManagerPhrase` | `-n`-Parameter für `ucybsmcl` (ServiceManager-Environment) |
| `$MaintenanceFlagFilePath` | Pfad zur Wartungsflag-Datei |
| `$MinimumLogLevel` | Ab welchem Level geloggt wird |
| `$LogFile` | Optionaler Pfad zur Logdatei (`$null` = nur Konsole) |
| `$LogRetentionDays` | Logeinträge älter als diese Anzahl Tage werden automatisch entfernt |

## Wartungsmodus

Prüfungen lassen sich ohne Eingriff ins Skript zentral pausieren, indem eine Flag-Datei angelegt wird (Pfad siehe `$MaintenanceFlagFilePath`):

```
Until: 2026-08-21 14:00
Reason: Patchday
By: <Name>
```

- `Until` (optional, empfohlen): Ablaufzeitpunkt (`yyyy-MM-dd HH:mm`). Ist der Zeitpunkt überschritten, gilt der Wartungsmodus als beendet – das Skript versucht die Datei zusätzlich automatisch zu löschen (best effort, Fehler werden ignoriert). Fehlt `Until`, bleibt der Modus unbegrenzt aktiv.
- `Reason`, `By` (optional): rein informativ, landen im Log.

Aktivieren:

```powershell
"Until: $((Get-Date).AddHours(2).ToString('yyyy-MM-dd HH:mm'))`nReason: Patchday`nBy: $env:USERNAME" |
    Set-Content 'C:\ProgramData\AutomicMonitoring\maintenance.flag'
```

Beenden: Datei löschen (oder Ablaufzeit abwarten).

## Einrichtung als Scheduled Task

Siehe ausführliche `.USAGE`-Sektion im Skriptkopf. Kurzfassung:

```
Aktion:    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Pfad\zu\Invoke-AutomicWatchdog.ps1"
Trigger:   täglich, "Aufgabe wiederholen alle: 5 Minuten", Dauer: unbegrenzt
Konto:     Dienstkonto mit den oben genannten Rechten, unabhängig von der Anmeldung ausführen
```

> **Hinweis:** Die tägliche Log-Bereinigung ist an ein festes Stundenfenster (00:00–00:59 Serverzeit) gekoppelt. Bei sehr großen Scheduler-Intervallen (> 1 Stunde) kann die Bereinigung an einzelnen Tagen ausfallen – unkritisch, sie holt es am Folgetag nach. Details im Skriptkopf.

## Lizenz

[MIT](./LICENSE)
