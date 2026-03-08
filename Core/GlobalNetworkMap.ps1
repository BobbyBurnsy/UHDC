<#
.SYNOPSIS
    UHDC Web-Ready Core: GlobalNetworkMap.ps1
.DESCRIPTION
    A powerful background scanner that compiles a master map of
    User-to-Computer relationships. It scans Active Directory for all enabled
    Windows 10/11 workstations, pings them to check availability, and queries
    the currently logged-on user. It updates the central 'UserHistory.json'
    database in "Additive Mode," ensuring that new detections are added without
    overwriting existing history for users who utilize multiple devices.
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
        StepName = "GLOBAL NETWORK MAPPER"
        Description = "This engine sweeps Active Directory for all enabled Windows 10/11 workstations. It pings each machine and uses WMI to identify the currently logged-on user. It then compiles this data into a central JSON database using an 'Additive' composite key (User-Computer) to track users across multiple devices without overwriting their history. It uses an atomic save operation every 50 endpoints to prevent database corruption."
        Code = "`$computers = Get-ADComputer -Filter `$filter`nforeach (`$pc in `$computers) {`n    `$user = (Get-CimInstance Win32_ComputerSystem -ComputerName `$pc).UserName`n    `$masterDB[`"`$user-`$pc`"] = `$entry`n}`n# Atomic Save to .tmp then rename to .json"
        InPerson = "Walking the floor, going desk to desk, wiggling the mouse on every active computer, writing down the username displayed on the lock screen, and updating a master Excel spreadsheet."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# BULLETPROOF CONFIG LOADER
# ====================================================================
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

# ==============================================================================
# 1. LOAD EXISTING DATABASE (With Composite Key)
# ==============================================================================
$masterDB = @{}
$initialCount = 0

if (Test-Path $HistoryFile) {
    Write-Output "`n[1/3] Loading Database..."

    # CRITICAL FIX: Only backup if the file is healthy (>100 bytes).
    if ((Get-Item $HistoryFile).Length -gt 100) {
        Copy-Item -Path $HistoryFile -Destination $BackupFile -Force
    }

    try {
        $raw = Get-Content $HistoryFile -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($raw -isnot [System.Array]) { $raw = @($raw) }

        foreach ($entry in $raw) {
            # The Key is "User-Computer" to prevent overwriting PC1 with PC2
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

# ==============================================================================
# 2. GET COMPUTERS (Universal Workstation Filter)
# ==============================================================================
Write-Output "`n[2/3] Fetching Computer List from AD..."

try {
    # Targets Win10/Win11 instead of specific Company PC Names
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

# ==============================================================================
# 3. SCAN LOOP
# ==============================================================================
$count = 0
$newFinds = 0
$updatedFinds = 0

Write-Output "`n[3/3] Executing Ping Sweep & WMI Polling..."

foreach ($pc in $computers) {
    $count++
    $percent = "{0:N0}" -f (($count / $total) * 100)

    # UI Heartbeat
    if ($count % 100 -eq 0) {
        Write-Output " > Scan in progress... ($percent% complete)"
    }

    # Fast Ping Test
    if (Test-Connection -ComputerName $pc -Count 1 -Quiet) {
        try {
            # Quick WMI Query
            $compInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $pc -ErrorAction Stop
            $rawUser = $compInfo.UserName

            if ($rawUser) {
                $cleanUser = ($rawUser -split "\\")[-1].Trim()
                $timeStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm")

                # Create the Unique Key
                $scanKey = "$cleanUser-$pc"

                if ($masterDB.ContainsKey($scanKey)) {
                    # --- UPDATE EXISTING ENTRY ---
                    $masterDB[$scanKey].LastSeen = $timeStamp
                    $updatedFinds++
                }
                else {
                    # --- ADD NEW ENTRY ---
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

    # --- ATOMIC AUTO-SAVE (Every 50 items) ---
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

# ==============================================================================
# 4. FINAL ATOMIC SAVE
# ==============================================================================
Write-Output "`n[!] Finalizing Database..."

# Final Safety Check: Database should create NEW records, never shrink.
if ($masterDB.Count -ge $initialCount -and $masterDB.Count -gt 0) {
    try {
        $finalList = @($masterDB.Values | Sort-Object User)

        # 1. Convert to JSON in memory first
        $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($jsonOutput)) { throw "Generated JSON string was completely empty." }

        # 2. Write to Temp file
        Set-Content -Path $TempFile -Value $jsonOutput -Force -ErrorAction Stop

        # 3. Swap Temp for Live
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