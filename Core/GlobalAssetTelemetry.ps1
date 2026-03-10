<#
.SYNOPSIS
    UHDC Web-Ready Core: GlobalAssetTelemetry.ps1
.DESCRIPTION
    The server-side aggregator for the Telemetry system.
    Runs in a continuous background loop, watching the TelemetryDrop folder.
    Ingests incoming JSON payloads, updates the master UserHistory.json database 
    using atomic saves, and deletes the processed drop files.
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# --- Export Training Data ---
if ($GetTrainingData) {
    $data = @{
        StepName = "GLOBAL ASSET TELEMETRY AGGREGATOR"
        Description = "This engine runs continuously in the background. It monitors a secure network drop share. When an endpoint connects to the network, the local agent drops a JSON file into this share. This aggregator reads the file, sanitizes the input, updates the master database, and deletes the drop file."
        Code = "while (`$true) {`n    `$files = Get-ChildItem `$DropShare -Filter '*.json'`n    foreach (`$f in `$files) { Update-Database `$f; Remove-Item `$f }`n    Start-Sleep -Seconds 15`n}"
        InPerson = "Having every user call the help desk the exact moment they plug their laptop into a docking station so you can write down their IP address."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Load Configuration ---
if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
    $SharedRoot = Split-Path -Path $ScriptDir
}

$DropFolder  = Join-Path -Path $SharedRoot -ChildPath "TelemetryDrop"
$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"
$TempFile    = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.tmp"

if (-not (Test-Path $DropFolder)) { New-Item -ItemType Directory -Path $DropFolder -Force | Out-Null }

Write-Output "========================================"
Write-Output "[UHDC] GLOBAL TELEMETRY AGGREGATOR"
Write-Output "========================================"
Write-Output "[i] Background engine started. Watching Drop Folder..."

# --- Main Polling Loop ---
while ($true) {
    $DropFiles = Get-ChildItem -Path $DropFolder -Filter "*.json" -ErrorAction SilentlyContinue

    if ($DropFiles.Count -gt 0) {

        # 1. Load Existing Database
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

        # 2. Process Incoming Files
        foreach ($file in $DropFiles) {
            try {
                $payload = Get-Content $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop

                # Sanitize input
                $cleanUser = $payload.User -replace '[^a-zA-Z0-9_.-]', ''
                $cleanComp = $payload.Computer -replace '[^a-zA-Z0-9_-]', ''

                if (-not [string]::IsNullOrWhiteSpace($cleanUser) -and -not [string]::IsNullOrWhiteSpace($cleanComp)) {
                    $scanKey = "$cleanUser-$cleanComp"

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

                Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            } catch {
                Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            }
        }

        # 3. Atomic Save
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

    Start-Sleep -Seconds 15
}
