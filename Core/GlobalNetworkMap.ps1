# GlobalNetworkMap.ps1 - Place this script in the \Core folder
# DESCRIPTION: A powerful background scanner that compiles a master map of
# User-to-Computer relationships. It scans Active Directory for all enabled
# Windows 10/11 workstations, pings them to check availability, and queries
# the currently logged-on user. It updates the central 'UserHistory.json'
# database in "Additive Mode," ensuring that new detections are added without
# overwriting existing history for users who utilize multiple devices.

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$DummyTarget, # Absorbs the empty target box from the GUI button

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [hashtable]$SyncHash
)

# --- TRAINING MODE HELPER ---
function Wait-TrainingStep {
    param([string]$Desc, [string]$Code)
    if ($null -ne $SyncHash) {
        $SyncHash.StepDesc = $Desc
        $SyncHash.StepCode = $Code
        $SyncHash.StepReady = $true
        $SyncHash.StepAck = $false

        # Pause the script until the GUI user clicks Execute or Abort
        while (-not $SyncHash.StepAck) { Start-Sleep -Milliseconds 200 }

        if (-not $SyncHash.StepResult) {
            throw "Execution aborted by user during Training Mode."
        }
    }
}
# ----------------------------

# ------------------------------------------------------------------
# BULLETPROOF CONFIG LOADER (Fallback if run standalone)
# ------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    try {
        $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
        $RootFolder = Split-Path -Path $ScriptDir
        $ConfigFile = Join-Path -Path $RootFolder -ChildPath "config.json"

        if (Test-Path $ConfigFile) {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $SharedRoot = $Config.SharedNetworkRoot
        } else {
            Write-Host " [!] FATAL: Could not locate config.json."
            return
        }
    } catch { return }
}

$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"
$BackupFile  = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.bak"
$TempFile    = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.tmp"

Write-Host "========================================="
Write-Host "       [UHDC] GLOBAL NETWORK MAPPER      "
Write-Host "=========================================`n"
Write-Host " [UHDC] [!] Scope limited to: Active Windows 10/11 Workstations"
Write-Host " [UHDC] [!] Mode: Additive (Preserves History)"

# ==============================================================================
# 1. LOAD EXISTING DATABASE (With Composite Key Fix)
# ==============================================================================
$masterDB = @{}
$initialCount = 0

if (Test-Path $HistoryFile) {
    Write-Host "`n [UHDC] [1/3] Loading Database..."

    # CRITICAL FIX: Only backup if the file is healthy (>100 bytes).
    if ((Get-Item $HistoryFile).Length -gt 100) {
        Copy-Item -Path $HistoryFile -Destination $BackupFile -Force
    }

    Wait-TrainingStep `
        -Desc "STEP 1: LOAD EXISTING DATABASE`n`nWHEN TO USE THIS:`nThis tool is restricted to Master Admins and is typically run twice a week (e.g., Mondays and Thursdays at 10 AM) to build and maintain the global asset map used by the Smart User Search.`n`nWHAT IT DOES:`nWe are loading the central 'UserHistory.json' database into memory. We use a composite key ('User-Computer') to ensure that if a user logs into a second laptop, it adds a new record rather than overwriting their primary desktop.`n`nIN-PERSON EQUIVALENT:`nOpening a master Excel spreadsheet on a shared network drive that tracks which employee is assigned to which physical desk or computer." `
        -Code "`$raw = Get-Content `$HistoryFile -Raw | ConvertFrom-Json`nforeach (`$entry in `$raw) { `$masterDB[`"`$(`$entry.User)-`$(`$entry.Computer)`"] = `$entry }"

    try {
        $raw = Get-Content $HistoryFile -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($raw -isnot [System.Array]) { $raw = @($raw) }

        foreach ($entry in $raw) {
            # The Key is now "User-Computer" to prevent overwriting PC1 with PC2
            if ($entry.User -and $entry.Computer) {
                $uniqueKey = "$($entry.User)-$($entry.Computer)"
                $masterDB[$uniqueKey] = $entry
            }
        }
        $initialCount = $masterDB.Count
        Write-Host " [UHDC] [OK] Loaded $initialCount historical entries."
    } catch {
        Write-Host " [UHDC] [FATAL] Could not read existing history. Aborting to protect data."
        return
    }
}

# ==============================================================================
# 2. GET COMPUTERS (Universal Workstation Filter)
# ==============================================================================
Write-Host "`n [UHDC] [2/3] Fetching Computer List from AD..."

Wait-TrainingStep `
    -Desc "STEP 2: QUERY ACTIVE DIRECTORY FOR WORKSTATIONS`n`nWHAT IT DOES:`nWe are querying Active Directory for all enabled computer objects running Windows 10 or Windows 11. This LDAP filter ensures we only target active client endpoints, filtering out servers, disabled PCs, and stale objects so we don't waste time scanning them.`n`nIN-PERSON EQUIVALENT:`nOpening Active Directory Users and Computers (ADUC), creating a custom saved query for 'Operating System starts with Windows 10', and exporting the list to a CSV file to know which desks to check." `
    -Code "`$filter = `"Enabled -eq 'true' -and (OperatingSystem -like '*Windows 10*' -or OperatingSystem -like '*Windows 11*')`"`n`$computers = Get-ADComputer -Filter `$filter | Select-Object -ExpandProperty Name"

try {
    # WHITE-LABELED: Targets Win10/Win11 instead of specific Company PC Names
    $filter = "Enabled -eq 'true' -and (OperatingSystem -like '*Windows 10*' -or OperatingSystem -like '*Windows 11*')"
    $computers = Get-ADComputer -Filter $filter -Properties OperatingSystem | Select-Object -ExpandProperty Name
} catch {
    Write-Host " [UHDC] [ERROR] AD Query Failed."
    return
}

$total = if ($computers) { $computers.Count } else { 0 }

if ($total -eq 0) {
    Write-Host " [UHDC] [!] No computers found matching scope."
    return
}
Write-Host " [UHDC] [OK] Found $total target workstations."
Start-Sleep 2

# ==============================================================================
# 3. SCAN LOOP
# ==============================================================================
$count = 0
$newFinds = 0
$updatedFinds = 0

Wait-TrainingStep `
    -Desc "STEP 3: PING SWEEP & WMI USER QUERY`n`nWHAT IT DOES:`nFor every computer found in AD, we send a fast ping. If it responds, we establish a WMI connection to query the 'Win32_ComputerSystem' class and extract the 'UserName' property to see who is currently logged in. We then update their 'LastSeen' timestamp in our memory dictionary.`n`nIN-PERSON EQUIVALENT:`nWalking the floor, going desk to desk, wiggling the mouse on every active computer, and writing down the username displayed on the lock screen." `
    -Code "if (Test-Connection -ComputerName `$pc -Count 1 -Quiet) {`n    `$compInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName `$pc`n    `$rawUser = `$compInfo.UserName`n}"

foreach ($pc in $computers) {
    $count++
    $percent = "{0:N0}" -f (($count / $total) * 100)

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

                    Write-Host " [UHDC] [$percent%] NEW: $cleanUser found on $pc"
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
Write-Host "`n [UHDC] [3/3] Finalizing Database..."

Wait-TrainingStep `
    -Desc "STEP 4: ATOMIC DATABASE SAVE`n`nWHAT IT DOES:`nWe are converting our updated memory dictionary back into JSON format. To prevent database corruption if the script crashes or the network drops mid-save, we write the data to a '.tmp' file first, and then instantly swap it with the live 'UserHistory.json' file.`n`nIN-PERSON EQUIVALENT:`nSaving your updated Excel tracker as 'Tracker_New.xlsx', deleting the old 'Tracker.xlsx', and renaming the new file to replace it." `
    -Code "Set-Content -Path `$TempFile -Value `$jsonOutput -Force`nMove-Item -Path `$TempFile -Destination `$HistoryFile -Force"

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

        Write-Host " [UHDC SUCCESS] Map Complete!"
        Write-Host "             Total DB Entries: $($masterDB.Count)"
        Write-Host "             New Connections:  $newFinds"
        Write-Host "             Refreshed:        $updatedFinds"
    } catch {
        Write-Host " [UHDC] [ERROR] Could not save file: $($_.Exception.Message)"
        if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Host " [UHDC] [PROTECTION] Scan resulted in data loss ($($masterDB.Count) vs $initialCount)."
    Write-Host "               Save aborted. Restoring backup..."
    Copy-Item $BackupFile $HistoryFile -Force
}