<#
.SYNOPSIS
    UHDC Web-Ready Core: GlobalNetworkMap.ps1 (Agentless Asset Tracker)
.DESCRIPTION
    A powerful, 100% Agentless background scanner that compiles a master map of
    User-to-Computer relationships. It scans Active Directory for all enabled
    Windows 10/11 workstations, pings them to check availability, queries
    the currently logged-on user, and extracts the MAC address for Wake-on-LAN.
    Optimized for PS 5.1 (.NET Ping & JSON Array Protection).
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$DummyTarget, # Absorbs the empty target box from the GUI button

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [hashtable]$SyncHash
)

# --- TRAINING MODE HELPER (WPF Safe) ---
function Wait-TrainingStep {
    param([string]$Desc, [string]$Code)
    if ($null -ne $SyncHash) {
        $SyncHash.StepDesc = $Desc
        $SyncHash.StepCode = $Code
        $SyncHash.StepReady = $true
        $SyncHash.StepAck = $false

        # Pause the script until the GUI user clicks Execute or Abort
        while (-not $SyncHash.StepAck) { 
            Start-Sleep -Milliseconds 200 
            $Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
            if ($Dispatcher) {
                $Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
            }
        }

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
        $ConfigFile = Join-Path -Path $RootFolder -ChildPath "Config\config.json"

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

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "       [UHDC] GLOBAL NETWORK MAPPER      " -ForegroundColor Cyan
Write-Host "=========================================`n" -ForegroundColor Cyan
Write-Host " [UHDC] [!] Architecture: 100% Agentless (Zero-Footprint)" -ForegroundColor DarkGray
Write-Host " [UHDC] [!] Scope limited to: Active Windows 10/11 Workstations" -ForegroundColor DarkGray
Write-Host " [UHDC] [!] Mode: Additive (Preserves History)" -ForegroundColor DarkGray

# ==============================================================================
# 1. LOAD EXISTING DATABASE (With Composite Key Fix)
# ==============================================================================
$masterDB = @{}
$initialCount = 0

if (Test-Path $HistoryFile) {
    Write-Host "`n [UHDC] [1/3] Loading Database..." -ForegroundColor White

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
        Write-Host " [UHDC] [OK] Loaded $initialCount historical entries." -ForegroundColor Green
    } catch {
        Write-Host " [UHDC] [FATAL] Could not read existing history. Aborting to protect data." -ForegroundColor Red
        return
    }
}

# ==============================================================================
# 2. GET COMPUTERS (Universal Workstation Filter)
# ==============================================================================
Write-Host "`n [UHDC] [2/3] Fetching Computer List from AD..." -ForegroundColor White

Wait-TrainingStep `
    -Desc "STEP 2: QUERY ACTIVE DIRECTORY FOR WORKSTATIONS`n`nWHAT IT DOES:`nWe are querying Active Directory for all enabled computer objects running Windows 10 or Windows 11. This LDAP filter ensures we only target active client endpoints, filtering out servers, disabled PCs, and stale objects so we don't waste time scanning them.`n`nIN-PERSON EQUIVALENT:`nOpening Active Directory Users and Computers (ADUC), creating a custom saved query for 'Operating System starts with Windows 10', and exporting the list to a CSV file to know which desks to check." `
    -Code "`$filter = `"Enabled -eq 'true' -and (OperatingSystem -like '*Windows 10*' -or OperatingSystem -like '*Windows 11*')`"`n`$computers = Get-ADComputer -Filter `$filter | Select-Object -ExpandProperty Name"

try {
    # WHITE-LABELED: Targets Win10/Win11 instead of specific Company PC Names
    $filter = "Enabled -eq 'true' -and (OperatingSystem -like '*Windows 10*' -or OperatingSystem -like '*Windows 11*')"
    $computers = Get-ADComputer -Filter $filter -Properties OperatingSystem | Select-Object -ExpandProperty Name
} catch {
    Write-Host " [UHDC] [ERROR] AD Query Failed." -ForegroundColor Red
    return
}

$total = if ($computers) { $computers.Count } else { 0 }

if ($total -eq 0) {
    Write-Host " [UHDC] [!] No computers found matching scope." -ForegroundColor Yellow
    return
}
Write-Host " [UHDC] [OK] Found $total target workstations." -ForegroundColor Green
Start-Sleep 2

# ==============================================================================
# 3. SCAN LOOP (PS 5.1 .NET Ping & MAC Extraction)
# ==============================================================================
$count = 0
$newFinds = 0
$updatedFinds = 0

Wait-TrainingStep `
    -Desc "STEP 3: PING SWEEP & WMI TELEMETRY EXTRACTION`n`nWHAT IT DOES:`nFor every computer found in AD, we send a fast ping. If it responds, we establish a WMI connection to query the 'Win32_ComputerSystem' class to see who is currently logged in. We simultaneously query 'Win32_NetworkAdapterConfiguration' to extract the MAC address, which allows the UHDC to perform Wake-on-LAN (WoL) deployments later.`n`nIN-PERSON EQUIVALENT:`nWalking the floor, going desk to desk, wiggling the mouse on every active computer to write down the username, and running 'ipconfig /all' to write down the physical MAC address." `
    -Code "`$ping = New-Object System.Net.NetworkInformation.Ping`nif (`$ping.Send(`$pc, 500).Status -eq 'Success') {`n    `$user = (Get-CimInstance Win32_ComputerSystem -ComputerName `$pc).UserName`n    `$mac = (Get-CimInstance Win32_NetworkAdapterConfiguration -ComputerName `$pc -Filter `"IPEnabled='True'`").MACAddress`n}"

$pingSender = New-Object System.Net.NetworkInformation.Ping

foreach ($pc in $computers) {
    $count++
    $percent = "{0:N0}" -f (($count / $total) * 100)

    # Fast Ping Test (.NET class prevents PS 5.1 WMI terminating errors)
    $isOnline = $false
    try {
        if ($pingSender.Send($pc, 500).Status -eq "Success") { $isOnline = $true }
    } catch {}

    if ($isOnline) {
        try {
            # Quick WMI Query for Logged-in User
            $compInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $pc -ErrorAction Stop
            $rawUser = $compInfo.UserName

            if ($rawUser) {
                $cleanUser = ($rawUser -split "\\")[-1].Trim()
                $timeStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm")

                # Extract MAC Address for Wake-on-LAN (Agentless)
                $macAddress = $null
                try {
                    $netAdapter = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -ComputerName $pc -Filter "IPEnabled = 'True'" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($netAdapter) { $macAddress = $netAdapter.MACAddress }
                } catch {}

                # Create the Unique Key
                $scanKey = "$cleanUser-$pc"

                if ($masterDB.ContainsKey($scanKey)) {
                    # --- UPDATE EXISTING ENTRY ---
                    $masterDB[$scanKey].LastSeen = $timeStamp
                    if ($macAddress) { $masterDB[$scanKey].MACAddress = $macAddress }
                    $updatedFinds++
                }
                else {
                    # --- ADD NEW ENTRY ---
                    $masterDB[$scanKey] = [PSCustomObject]@{
                        User       = $cleanUser
                        Computer   = $pc
                        LastSeen   = $timeStamp
                        Source     = "Agentless-Map"
                        MACAddress = $macAddress
                    }
                    $newFinds++

                    Write-Host " [UHDC] [$percent%] NEW: $cleanUser found on $pc" -ForegroundColor Cyan
                }
            }
        } catch {}
    }

    # --- ATOMIC AUTO-SAVE (Every 50 items) ---
    if ($count % 50 -eq 0) {
        if ($masterDB.Count -ge $initialCount -and $masterDB.Count -gt 0) {
            try {
                $finalList = @($masterDB.Values | Sort-Object User)
                $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -Compress -ErrorAction Stop

                # PS 5.1 Single-Item Array Protection
                if ($finalList.Count -eq 1 -and $jsonOutput -notmatch "^\s*\[") {
                    $jsonOutput = "[$jsonOutput]"
                }

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
Write-Host "`n [UHDC] [3/3] Finalizing Database..." -ForegroundColor White

Wait-TrainingStep `
    -Desc "STEP 4: ATOMIC DATABASE SAVE`n`nWHAT IT DOES:`nWe are converting our updated memory dictionary back into JSON format. To prevent database corruption if the script crashes or the network drops mid-save, we write the data to a '.tmp' file first, and then instantly swap it with the live 'UserHistory.json' file.`n`nIN-PERSON EQUIVALENT:`nSaving your updated Excel tracker as 'Tracker_New.xlsx', deleting the old 'Tracker.xlsx', and renaming the new file to replace it." `
    -Code "Set-Content -Path `$TempFile -Value `$jsonOutput -Force`nMove-Item -Path `$TempFile -Destination `$HistoryFile -Force"

# Final Safety Check: Database should create NEW records, never shrink.
if ($masterDB.Count -ge $initialCount -and $masterDB.Count -gt 0) {
    try {
        $finalList = @($masterDB.Values | Sort-Object User)

        # 1. Convert to JSON in memory first
        $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -Compress -ErrorAction Stop

        # PS 5.1 Single-Item Array Protection
        if ($finalList.Count -eq 1 -and $jsonOutput -notmatch "^\s*\[") {
            $jsonOutput = "[$jsonOutput]"
        }

        if ([string]::IsNullOrWhiteSpace($jsonOutput)) { throw "Generated JSON string was completely empty." }

        # 2. Write to Temp file
        Set-Content -Path $TempFile -Value $jsonOutput -Force -ErrorAction Stop

        # 3. Swap Temp for Live
        Move-Item -Path $TempFile -Destination $HistoryFile -Force -ErrorAction Stop

        Write-Host " [UHDC SUCCESS] Map Complete!" -ForegroundColor Green
        Write-Host "             Total DB Entries: $($masterDB.Count)" -ForegroundColor Green
        Write-Host "             New Connections:  $newFinds" -ForegroundColor Green
        Write-Host "             Refreshed:        $updatedFinds" -ForegroundColor Green
    } catch {
        Write-Host " [UHDC] [ERROR] Could not save file: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Host " [UHDC] [PROTECTION] Scan resulted in data loss ($($masterDB.Count) vs $initialCount)." -ForegroundColor Yellow
    Write-Host "               Save aborted. Restoring backup..." -ForegroundColor Yellow
    Copy-Item $BackupFile $HistoryFile -Force
}
