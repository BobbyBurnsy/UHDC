<#
.SYNOPSIS
    UHDC Web-Ready Core: GlobalAssetTelemetry.ps1
.DESCRIPTION
    The server-side aggregator for the Zero-Trust Telemetry system.
    Runs in a continuous background loop, watching the TelemetryDrop folder.
    Ingests incoming JSON payloads (including MAC Addresses for WoL), 
    updates the master UserHistory.json database using atomic saves, 
    and deletes the processed drop files.
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# ====================================================================
# TRAINING DATA EXPORT (For Web UI Modal)
# ====================================================================
if ($GetTrainingData) {
    $data = @{
        StepName = "GLOBAL ASSET TELEMETRY AGGREGATOR"
        Description = "This engine runs continuously in the background. It monitors a secure, 'Write-Only' network drop share. When an endpoint connects to the network, the local agent drops a tiny JSON file into this share. This aggregator reads the file, sanitizes the input, updates the master UserHistory.json database, and deletes the drop file. This Zero-Trust architecture ensures endpoints can report their location instantly without having read/modify access to the master database."
        Code = "while (`$true) {`n    `$files = Get-ChildItem `$DropShare -Filter '*.json'`n    foreach (`$f in `$files) { Update-Database `$f; Remove-Item `$f }`n    Start-Sleep -Seconds 10`n}"
        InPerson = "Having every user call the help desk the exact moment they plug their laptop into a docking station so you can write down their IP address on a whiteboard."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# BULLETPROOF CONFIG LOADER
# ====================================================================
if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
    $SharedRoot = Split-Path -Path $ScriptDir
}

# Define Paths
$DropFolder  = Join-Path -Path $SharedRoot -ChildPath "TelemetryDrop"
$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"
$TempFile    = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.tmp"

if (-not (Test-Path $DropFolder)) { New-Item -ItemType Directory -Path $DropFolder -Force | Out-Null }

Write-Output "========================================"
Write-Output "[UHDC] GLOBAL TELEMETRY AGGREGATOR"
Write-Output "========================================"
Write-Output "[i] Background engine started. Watching Drop Folder..."

# ====================================================================
# CONTINUOUS AGGREGATION LOOP
# ====================================================================
while ($true) {
    $DropFiles = Get-ChildItem -Path $DropFolder -Filter "*.json" -ErrorAction SilentlyContinue

    if ($DropFiles.Count -gt 0) {

        # 1. Load Existing Database into Memory
        $db = @{}
        if (Test-Path $HistoryFile) {
            try {
                $raw = Get-Content $HistoryFile -Raw | ConvertFrom-Json
                if ($raw -isnot [System.Array]) { $raw = @($raw) }
                foreach ($entry in $raw) {
                    if ($entry.User -and $entry.Computer) {
                        $key = "$($entry.User)-$($entry.Computer)"
                        $db[$key] = $entry
                    }
                }
            } catch { Write-Output "[!] DB Read Error. Skipping cycle." ; Start-Sleep -Seconds 10; continue }
        }

        $UpdatesMade = $false

        # 2. Process Incoming Drop Files
        foreach ($file in $DropFiles) {
            try {
                $payload = Get-Content $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop

                # Strict Input Validation (Prevent Injection)
                $cleanUser = $payload.User -replace '[^a-zA-Z0-9_.-]', ''
                $cleanComp = $payload.Computer -replace '[^a-zA-Z0-9_-]', ''

                if (-not [string]::IsNullOrWhiteSpace($cleanUser) -and -not [string]::IsNullOrWhiteSpace($cleanComp)) {
                    $scanKey = "$cleanUser-$cleanComp"

                    # Update or Add Record (NOW INCLUDES MAC ADDRESS)
                    if ($db.ContainsKey($scanKey)) {
                        $db[$scanKey].LastSeen   = $payload.LastSeen
                        $db[$scanKey].Source     = "Event-Agent"
                        $db[$scanKey].MACAddress = $payload.MACAddress
                    } else {
                        $db[$scanKey] = [PSCustomObject]@{
                            User       = $cleanUser
                            Computer   = $cleanComp
                            LastSeen   = $payload.LastSeen
                            Source     = "Event-Agent"
                            MACAddress = $payload.MACAddress
                        }
                    }
                    $UpdatesMade = $true
                }

                # Delete the drop file after successful processing
                Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            } catch {
                # If file is locked or malformed, delete it to prevent loop jamming
                Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            }
        }

        # 3. Atomic Save Back to Disk
        if ($UpdatesMade -and $db.Count -gt 0) {
            try {
                $finalList = @($db.Values | Sort-Object User)
                $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -Compress

                Set-Content -Path $TempFile -Value $jsonOutput -Force
                Move-Item -Path $TempFile -Destination $HistoryFile -Force

                Write-Output "[$(Get-Date -Format 'HH:mm:ss')] Processed $($DropFiles.Count) telemetry updates."
            } catch { Write-Output "[!] Error saving database." }
        }
    }

    # Sleep for 15 seconds before checking the drop folder again
    Start-Sleep -Seconds 15
}