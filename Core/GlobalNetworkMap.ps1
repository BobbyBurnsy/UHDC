<#
.SYNOPSIS
    UHDC Web-Ready Core: GlobalNetworkMap.ps1
.DESCRIPTION
    A background scanner that compiles a master map of User-to-Computer relationships. 
    It scans Active Directory for enabled Windows 10/11 workstations, pings them, 
    and queries the currently logged-on user. Updates the central database in Additive Mode.
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
        StepName = "GLOBAL ASSET TELEMETRY"
        Description = "While the UHDC UI parses the background telemetry database automatically, a junior technician should know how to manually search the raw data if the graphical interface is unavailable. By using the classic 'find' command, you can instantly search the central JSON database from any command prompt to locate a user's active hardware."
        Code = "type `"\\server\UHDC`$\Core\UserHistory.json`" | find /i `"jsmith`""
        InPerson = "Walking the floor, going desk to desk, wiggling the mouse on every active computer, and writing down the username displayed on the Windows lock screen."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Load Configuration ---
if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    try {
        $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
        $RootFolder = Split-Path -Path $ScriptDir
        $ConfigFile = Join-Path -Path $RootFolder -ChildPath "config.json"

        if (Test-Path $ConfigFile) {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $SharedRoot = $Config.SharedNetworkRoot
        } else {
            Write-Output "[!] FATAL: Could not locate config.json."
            return
        }
    } catch { return }
}

$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"
$BackupFile  = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.bak"
$TempFile    = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.tmp"

Write-Output "========================================="
Write-Output "      [UHDC] GLOBAL NETWORK MAPPER       "
Write-Output "========================================="
Write-Output "[!] Scope limited to: Active Windows 10/11 Workstations"
Write-Output "[!] Mode: Additive (Preserves History)"

# --- Load Existing Database ---
$masterDB = @{}
$initialCount = 0

if (Test-Path $HistoryFile) {
    Write-Output "`n[1/3] Loading Database..."

    if ((Get-Item $HistoryFile).Length -gt 100) {
        Copy-Item -Path $HistoryFile -Destination $BackupFile -Force
    }

    try {
        $raw = Get-Content $HistoryFile -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($raw -isnot [System.Array]) { $raw = @($raw) }

        foreach ($entry in $raw) {
            if ($entry.User -and $entry.Computer) {
                $uniqueKey = "$($entry.User)-$($entry.Computer)"
                $masterDB[$uniqueKey] = $entry
            }
        }
        $initialCount = $masterDB.Count
        Write-Output " > [OK] Loaded $initialCount historical entries."
    } catch {
        Write-Output "[FATAL] Could not read existing history. Aborting to protect data."
        return
    }
}

# --- Fetch Computer List ---
Write-Output "`n[2/3] Fetching Computer List from AD..."

try {
    $filter = "Enabled -eq 'true' -and (OperatingSystem -like '*Windows 10*' -or OperatingSystem -like '*Windows 11*')"
    $computers = Get-ADComputer -Filter $filter -Properties OperatingSystem | Select-Object -ExpandProperty Name
} catch {
    Write-Output "[!] ERROR: AD Query Failed."
    return
}

$total = if ($computers) { $computers.Count } else { 0 }

if ($total -eq 0) {
    Write-Output "[!] No computers found matching scope."
    return
}
Write-Output " > [OK] Found $total target workstations."
Start-Sleep 2

# --- Scan Loop ---
$count = 0
$newFinds = 0
$updatedFinds = 0

Write-Output "`n[3/3] Executing Ping Sweep & WMI Polling..."

foreach ($pc in $computers) {
    $count++
    $percent = "{0:N0}" -f (($count / $total) * 100)

    if ($count % 100 -eq 0) {
        Write-Output " > Scan in progress... ($percent% complete)"
    }

    if (Test-Connection -ComputerName $pc -Count 1 -Quiet) {
        try {
            $compInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $pc -ErrorAction Stop
            $rawUser = $compInfo.UserName

            if ($rawUser) {
                $cleanUser = ($rawUser -split "\\")[-1].Trim()
                $timeStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm")
                $scanKey = "$cleanUser-$pc"

                if ($masterDB.ContainsKey($scanKey)) {
                    $masterDB[$scanKey].LastSeen = $timeStamp
                    $updatedFinds++
                }
                else {
                    $masterDB[$scanKey] = [PSCustomObject]@{
                        User     = $cleanUser
                        Computer = $pc
                        LastSeen = $timeStamp
                        Source   = "GlobalMap"
                    }
                    $newFinds++
                    Write-Output "[$percent%] NEW: $cleanUser found on $pc"
                }
            }
        } catch {}
    }

    if ($count % 50 -eq 0) {
        if ($masterDB.Count -ge $initialCount -and $masterDB.Count -gt 0) {
            try {
                $finalList = @($masterDB.Values | Sort-Object User)
                $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -ErrorAction Stop

                if (-not [string]::IsNullOrWhiteSpace($jsonOutput)) {
                    Set-Content -Path $TempFile -Value $jsonOutput -Force -ErrorAction Stop
                    Move-Item -Path $TempFile -Destination $HistoryFile -Force -ErrorAction Stop
                }
            } catch {}
        }
    }
}

# --- Final Save ---
Write-Output "`n[!] Finalizing Database..."

if ($masterDB.Count -ge $initialCount -and $masterDB.Count -gt 0) {
    try {
        $finalList = @($masterDB.Values | Sort-Object User)
        $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($jsonOutput)) { throw "Generated JSON string was completely empty." }

        Set-Content -Path $TempFile -Value $jsonOutput -Force -ErrorAction Stop
        Move-Item -Path $TempFile -Destination $HistoryFile -Force -ErrorAction Stop

        Write-Output "`n[UHDC SUCCESS] Map Complete!"
        Write-Output " > Total DB Entries: $($masterDB.Count)"
        Write-Output " > New Connections:  $newFinds"
        Write-Output " > Refreshed:        $updatedFinds"
    } catch {
        Write-Output "[!] ERROR: Could not save file: $($_.Exception.Message)"
        if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Output "[!] PROTECTION TRIGGERED: Scan resulted in data loss ($($masterDB.Count) vs $initialCount)."
    Write-Output "    Save aborted. Restoring backup..."
    Copy-Item $BackupFile $HistoryFile -Force
}
