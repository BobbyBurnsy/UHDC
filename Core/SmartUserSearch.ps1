# SmartUserSearch.ps1 - Place this script in the \Core folder
# DESCRIPTION: The core intelligence engine for the AD User Intelligence panel.
# It queries Active Directory for account details, OR accepts a Computer name
# to cross-reference the central UserHistory.json database.

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$TargetUser,

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
# BULLETPROOF CONFIG LOADER
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
            Write-Host " [UHDC] [!] Error: SharedRoot path is missing and config.json not found." -ForegroundColor Red
            return
        }
    } catch { return }
}

if ([string]::IsNullOrWhiteSpace($TargetUser)) {
    Write-Host " [UHDC] [!] Error: No target provided. Please enter a username or PC name."
    return
}

# DYNAMIC PATHING
$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"

# ====================================================================
# PHASE 1: GENERATE THE HISTORY REPORT (Dual-Search)
# ====================================================================
$userHistory = @()
$computerHistory = @()
$dbStatus = "OK"

Wait-TrainingStep `
    -Desc "STEP 1: CORRELATE USER TO COMPUTER`n`nWHEN TO USE THIS:`nThis is the first step in any remote support scenario. A user calls in with an issue, but they don't know their computer name, making it impossible to remote in or push fixes.`n`nWHAT IT DOES:`nWe are parsing the central 'UserHistory.json' database. We check if your input matches a known Username OR a known Computer Name. If it matches a user, we pull the most recent PC they logged into. We then use a special GUI tag '[GUI:UPDATE_TARGET...]' to automatically fill the 'Target PC' boxes on the right side of the console so you are instantly ready to work.`n`nIN-PERSON EQUIVALENT:`nAsking the user, 'Can you read me the asset tag sticker on the bottom of your laptop?' or having them open the Start Menu, type 'cmd', and run the 'hostname' command." `
    -Code "`$raw = Get-Content `$HistoryFile -Raw | ConvertFrom-Json`n`$userHistory = `$raw | Where-Object { `$_.User -eq `$TargetUser }`nWrite-Host `"[GUI:UPDATE_TARGET:`$(`$userHistory[0].Computer)]`""

if (Test-Path $HistoryFile) {
    $fItem = Get-Item $HistoryFile
    if ($fItem.Length -lt 100) {
        $dbStatus = "EMPTY"
    } else {
        try {
            $raw = Get-Content $HistoryFile -Raw | ConvertFrom-Json
            if ($raw -isnot [System.Array]) { $raw = @($raw) }

            $seenPC = @{}
            $seenUser = @{}

            foreach ($entry in $raw) {
                # 1. Check if the input is a User
                if ("$($entry.User)".Trim() -eq "$TargetUser".Trim()) {
                    $pc = "$($entry.Computer)".Trim()
                    if (-not $seenPC.ContainsKey($pc)) {
                        $userHistory += $entry
                        $seenPC[$pc] = $true
                    }
                }

                # 2. Check if the input is a Computer (Using -match for partial names)
                if ("$($entry.Computer)".Trim() -match "$TargetUser".Trim()) {
                    $usr = "$($entry.User)".Trim()
                    if (-not $seenUser.ContainsKey($usr)) {
                        $computerHistory += $entry
                        $seenUser[$usr] = $true
                    }
                }
            }
        } catch { $dbStatus = "ERROR READING DB" }
    }
} else {
    $dbStatus = "NO FILE"
}

# ====================================================================
# PHASE 2: ACTIVE DIRECTORY QUERY
# ====================================================================
$adObj = $null

Wait-TrainingStep `
    -Desc "STEP 2: QUERY AD & CALCULATE PASSWORD EXPIRATION`n`nWHEN TO USE THIS:`nUse this to instantly verify if an account is locked out, disabled, or if their password is about to expire. It also checks if they have the correct security groups (like VPN or Admin access).`n`nWHAT IT DOES:`nWe use 'Get-ADUser' to pull the account details. Then, we do some math: We query the domain's default password policy ('Get-ADDefaultDomainPasswordPolicy') to find the 'MaxPasswordAge' (e.g., 90 days). We add those 90 days to the user's 'PasswordLastSet' date, and subtract today's date to tell you exactly how many days they have left before they are locked out.`n`nIN-PERSON EQUIVALENT:`nOpening Active Directory Users and Computers (ADUC), searching for the user, checking the 'Account' tab to see if the 'Unlock account' box is checked, and clicking the 'Member Of' tab to read through their assigned groups." `
    -Code "`$adObj = Get-ADUser -Identity `$TargetUser -Properties LockedOut, PasswordLastSet, MemberOf`n`$policy = Get-ADDefaultDomainPasswordPolicy`n`$expDate = `$adObj.PasswordLastSet.AddDays(`$policy.MaxPasswordAge.Days)"

try {
    # If this fails, the script assumes the input is a Computer Name
    $adObj = Get-ADUser -Identity $TargetUser -Properties Office, Title, Department, EmailAddress, PasswordLastSet, LastLogonDate, LockedOut, Enabled, MemberOf, PasswordNeverExpires -ErrorAction Stop
} catch {}

# ====================================================================
# PHASE 3: INTELLIGENT OUTPUT GENERATION
# ====================================================================

if ($adObj) {
    # --- OUTPUT A STANDARD AD USER REPORT ---
    $expiryDate = "N/A"; $daysLeftStr = "N/A"

    if ($adObj.PasswordNeverExpires) {
        $expiryDate = "Never (Exempt)"; $daysLeftStr = "Infinite"
    } else {
        try {
            $policy = Get-ADDefaultDomainPasswordPolicy
            $maxAge = $policy.MaxPasswordAge.Days
            if ($adObj.PasswordLastSet) {
                $exp = $adObj.PasswordLastSet.AddDays($maxAge)
                $expiryDate = $exp.ToString("MM/dd/yyyy HH:mm")
                $span = New-TimeSpan -Start (Get-Date) -End $exp
                $daysLeft = $span.Days

                if ($daysLeft -lt 0) {
                    $daysLeftStr = "!!! EXPIRED ($([math]::Abs($daysLeft)) days ago) !!!"
                } elseif ($daysLeft -le 3) {
                    $daysLeftStr = "!!! $daysLeft (EXPIRING SOON) !!!"
                } else {
                    $daysLeftStr = "$daysLeft"
                }
            }
        } catch { $expiryDate = "Unknown" }
    }

    Write-Host "`n========================================================"
    Write-Host " [UHDC] ACCOUNT REPORT: $($adObj.SamAccountName)"
    Write-Host "========================================================"

    Write-Host " Name:       $($adObj.Name)"
    Write-Host " Title:      $($adObj.Title)"
    Write-Host " Dept:       $($adObj.Department)"
    Write-Host " Email:      $($adObj.EmailAddress)"
    Write-Host " Office:     $($adObj.Office)"

    Write-Host " Status:     " -NoNewline
    if ($adObj.Enabled) { Write-Host "Active" } else { Write-Host "DISABLED" }

    Write-Host " Locked:     " -NoNewline
    if ($adObj.LockedOut) { Write-Host "YES (LOCKED)" } else { Write-Host "No" }

    Write-Host "`n--- Key Access Groups ---"
    if ($adObj.MemberOf) {
        $allGroups = $adObj.MemberOf | ForEach-Object { ($_ -split ",")[0].Replace("CN=","") } | Sort-Object
        $keywords = "M365|Airwatch|VPN|Admin|Polaris"
        $shownGroups = $allGroups | Where-Object { $_ -match $keywords }
        $hiddenCount = $allGroups.Count - $shownGroups.Count

        if ($shownGroups) {
            foreach ($g in $shownGroups) { Write-Host " - $g" }
        } else {
            Write-Host " (No Key Groups Found)"
        }
        if ($hiddenCount -gt 0) { Write-Host " ...plus $hiddenCount other standard groups." }
    } else { Write-Host " (No Groups Found)" }

    Write-Host "`n--- Password & Logon ---"
    Write-Host " Password Set:  $($adObj.PasswordLastSet)"
    Write-Host " Last Logon:    $($adObj.LastLogonDate)"
    Write-Host " [UHDC STATUS] Days until expiry: $daysLeftStr"

    Write-Host "`n--- Known Locations ---"

    if ($dbStatus -ne "OK") {
         Write-Host " [UHDC] [!] Database Issue: $dbStatus"
    } elseif ($userHistory.Count -gt 0) {
        $i = 1
        foreach ($loc in $userHistory) {
            Write-Host " [$i] $($loc.Computer) " -NoNewline
            $seenTime = if ($loc.LastSeen) { $loc.LastSeen } else { "Unknown" }
            Write-Host "(Seen: $seenTime)"
            $i++
        }

        # GUI MAGIC: Auto-fill Action panel
        Write-Host "`n[GUI:UPDATE_TARGET:$($userHistory[0].Computer)]"

    } else {
        Write-Host " (No history found)"
    }
    Write-Host "`n========================================================`n"

} elseif ($computerHistory.Count -gt 0) {
    # --- OUTPUT A COMPUTER HISTORY REPORT ---
    Write-Host "`n========================================================"
    Write-Host " [UHDC] DEVICE HISTORY REPORT"
    Write-Host "========================================================"
    Write-Host " Target PC: $($computerHistory[0].Computer)"
    Write-Host " AD Profile: (Is a Device)"

    Write-Host "`n--- Known Users on this Device ---"
    $i = 1
    foreach ($loc in $computerHistory) {
        Write-Host " [$i] $($loc.User) " -NoNewline
        $seenTime = if ($loc.LastSeen) { $loc.LastSeen } else { "Unknown" }
        Write-Host "(Seen: $seenTime)"
        $i++
    }

    # GUI MAGIC: Move the target PC name to the Action panels!
    Write-Host "`n[GUI:UPDATE_TARGET:$($computerHistory[0].Computer)]"
    Write-Host "`n========================================================`n"

} else {
    # --- NO MATCHES FOUND ---
    Write-Host "`n========================================================"
    Write-Host " [UHDC] SEARCH RESULT: $TargetUser"
    Write-Host "========================================================"
    Write-Host " [!] No matching user found in Active Directory."
    Write-Host " [!] No matching computer or user found in UserHistory.json."
    Write-Host "`n========================================================`n"
}