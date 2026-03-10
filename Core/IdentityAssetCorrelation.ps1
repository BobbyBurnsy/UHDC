<#
.SYNOPSIS
    UHDC Web-Ready Core: IdentityAssetCorrelation.ps1
.DESCRIPTION
    The core intelligence engine for the AD User Intelligence panel.
    Queries Active Directory for account details, parses AD groups,
    and cross-references the central UserHistory.json database.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$TargetUser,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [switch]$AsJson,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# --- Export Training Data ---
if ($GetTrainingData) {
    $data = @{
        StepName = "IDENTITY & ASSET CORRELATION"
        Description = "We execute a dual-pronged intelligence query. First, we parse the central UserHistory database to map the user to their hardware. Second, we query Active Directory for their profile, check their lockout status, calculate their password expiration date, and filter their AD groups."
        Code = "`$history = `$raw | Where-Object { `$_.User -eq `$TargetUser }`n`$adObj = Get-ADUser -Identity `$TargetUser -Properties LockedOut, PasswordLastSet, MemberOf`n`$policy = Get-ADDefaultDomainPasswordPolicy`n`$expDate = `$adObj.PasswordLastSet.AddDays(`$policy.MaxPasswordAge.Days)"
        InPerson = "Asking the user for their computer name, opening ADUC to check if their account is locked, checking their 'Member Of' tab, and manually calculating 90 days from their last password reset."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Load Configuration ---
$ImportantGroups = @("VPN", "Admin", "M365", "License", "Remote")

if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    try {
        $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
        $RootFolder = Split-Path -Path $ScriptDir
        $ConfigFile = Join-Path -Path $RootFolder -ChildPath "Config\config.json"
        if (Test-Path $ConfigFile) {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $SharedRoot = $Config.SharedNetworkRoot
            if ($Config.ActiveDirectory.ImportantGroups) {
                $ImportantGroups = $Config.ActiveDirectory.ImportantGroups
            }
        } else { return }
    } catch { return }
} else {
    $ConfigFile = Join-Path -Path $SharedRoot -ChildPath "Config\config.json"
    if (Test-Path $ConfigFile) {
        $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($Config.ActiveDirectory.ImportantGroups) {
            $ImportantGroups = $Config.ActiveDirectory.ImportantGroups
        }
    }
}

if ([string]::IsNullOrWhiteSpace($TargetUser)) { return }

$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"

# --- Query Telemetry History ---
$userHistory = @()
$computerHistory = @()
$dbStatus = "OK"

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
                if ("$($entry.User)".Trim() -eq "$TargetUser".Trim()) {
                    $pc = "$($entry.Computer)".Trim()
                    if (-not $seenPC.ContainsKey($pc)) {
                        $userHistory += $entry
                        $seenPC[$pc] = $true
                    }
                }
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
} else { $dbStatus = "NO FILE" }

# --- Query Active Directory ---
$adObj = $null
try {
    $adObj = Get-ADUser -Identity $TargetUser -Properties Office, Title, Department, EmailAddress, PasswordLastSet, LastLogonDate, LockedOut, Enabled, MemberOf, PasswordNeverExpires -ErrorAction Stop
} catch {}

# --- Process Data ---
$expiryDate = "N/A"; $daysLeftStr = "N/A"
$matchedGroups = @()
$standardGroupCount = 0

if ($adObj) {
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

                if ($daysLeft -lt 0) { $daysLeftStr = "!!! EXPIRED ($([math]::Abs($daysLeft)) days ago) !!!" } 
                elseif ($daysLeft -le 3) { $daysLeftStr = "!!! $daysLeft (EXPIRING SOON) !!!" } 
                else { $daysLeftStr = "$daysLeft" }
            }
        } catch { $expiryDate = "Unknown" }
    }

    if ($adObj.MemberOf) {
        foreach ($dn in $adObj.MemberOf) {
            $cn = if ($dn -match "^CN=([^,]+)") { $matches[1] } else { $dn }

            $isImportant = $false
            foreach ($keyword in $ImportantGroups) {
                if ($cn -match $keyword) {
                    $isImportant = $true
                    break
                }
            }

            if ($isImportant) { $matchedGroups += $cn } else { $standardGroupCount++ }
        }
    }
}

# --- JSON Output (Web UI) ---
if ($AsJson) {
    $res = @{ Status = "error"; Message = "No matching user or computer found."; Type = "none" }

    if ($adObj) {
        $res.Status = "success"
        $res.Type = "user"
        $res.Name = $adObj.Name
        $res.Title = $adObj.Title
        $res.Department = $adObj.Department
        $res.IsEnabled = [bool]$adObj.Enabled
        $res.IsLocked = [bool]$adObj.LockedOut
        $res.DaysUntilExpiry = $daysLeftStr
        $res.TargetPC = if ($userHistory.Count -gt 0) { $userHistory[0].Computer } else { "" }
        $res.KnownPCs = @($userHistory.Computer)
        $res.Email = $adObj.EmailAddress
        $res.ImportantGroups = $matchedGroups

    } elseif ($computerHistory.Count -gt 0) {
        $res.Status = "success"
        $res.Type = "computer"
        $res.TargetPC = $computerHistory[0].Computer
    }

    $res | ConvertTo-Json -Depth 3 | Write-Output
    return
}

# --- HTML Output (Fallback) ---
if ($adObj) {
    $statusColor = if ($adObj.Enabled) { "#2ecc71" } else { "#7f8c8d" }
    $statusText  = if ($adObj.Enabled) { "Active" } else { "DISABLED" }

    $lockColor = if ($adObj.LockedOut) { "#e74c3c" } else { "#2ecc71" }
    $lockText  = if ($adObj.LockedOut) { "YES (LOCKED)" } else { "No" }

    $expColor = "#3498db"
    if ($daysLeftStr -match "EXPIRED") { $expColor = "#e74c3c" }
    elseif ($daysLeftStr -match "SOON") { $expColor = "#f1c40f" }

    $html = "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid #3498db; margin-top: 10px; margin-bottom: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
    $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 12px;'><i class='fa-solid fa-address-card'></i> AD Profile: $($adObj.SamAccountName)</div>"

    $html += "<div style='display: grid; grid-template-columns: 100px 1fr; gap: 6px; font-size: 0.9rem; margin-bottom: 12px;'>"
    $html += "<span style='color: #94a3b8;'>Name:</span><span style='color: #cbd5e1;'>$($adObj.Name)</span>"
    $html += "<span style='color: #94a3b8;'>Title:</span><span style='color: #cbd5e1;'>$($adObj.Title)</span>"
    $html += "<span style='color: #94a3b8;'>Status:</span><span style='color: $statusColor; font-weight: bold;'>$statusText</span>"
    $html += "<span style='color: #94a3b8;'>Locked:</span><span style='color: $lockColor; font-weight: bold;'>$lockText</span>"
    $html += "</div>"

    $html += "<div style='border-top: 1px solid #334155; padding-top: 10px; margin-bottom: 12px;'>"
    $html += "<div style='color: #94a3b8; font-size: 0.85rem; margin-bottom: 4px;'>Password Set: $($adObj.PasswordLastSet)</div>"
    $html += "<div style='color: $expColor; font-weight: bold; font-size: 0.95rem;'>Expiry: $daysLeftStr</div>"
    $html += "</div>"

    $html += "<div style='border-top: 1px solid #334155; padding-top: 10px; margin-bottom: 12px;'>"
    $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 0.95rem; margin-bottom: 6px;'><i class='fa-solid fa-users'></i> Key Access Groups</div>"

    if ($matchedGroups.Count -gt 0) {
        foreach ($grp in ($matchedGroups | Sort-Object)) {
            $html += "<div style='color: #cbd5e1; font-size: 0.85rem; margin-bottom: 2px;'>- $grp</div>"
        }
    } else {
        $html += "<div style='color: #7f8c8d; font-size: 0.85rem; margin-bottom: 2px;'>No high-priority groups detected.</div>"
    }

    if ($standardGroupCount -gt 0) {
        $html += "<div style='color: #7f8c8d; font-size: 0.8rem; margin-top: 4px; font-style: italic;'>...plus $standardGroupCount standard domain groups.</div>"
    }
    $html += "</div>"

    $html += "<div style='border-top: 1px solid #334155; padding-top: 10px;'>"
    $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 0.95rem; margin-bottom: 6px;'><i class='fa-solid fa-location-dot'></i> Known Locations</div>"

    if ($userHistory.Count -gt 0) {
        $i = 1
        foreach ($loc in $userHistory) {
            $html += "<div style='color: #cbd5e1; font-size: 0.85rem; margin-bottom: 2px;'>[$i] $($loc.Computer) <span style='color: #64748b;'>(Seen: $($loc.LastSeen))</span></div>"
            $i++
        }
        Write-Output "[GUI:UPDATE_TARGET:$($userHistory[0].Computer)]"
    } else { 
        $html += "<div style='color: #7f8c8d; font-size: 0.85rem;'>No history found.</div>" 
    }

    $html += "</div></div>"
    Write-Output $html

} elseif ($computerHistory.Count -gt 0) {
    $html = "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid #9b59b6; margin-top: 10px; margin-bottom: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
    $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 12px;'><i class='fa-solid fa-desktop'></i> Device History: $($computerHistory[0].Computer)</div>"

    $i = 1
    foreach ($loc in $computerHistory) {
        $html += "<div style='color: #cbd5e1; font-size: 0.85rem; margin-bottom: 4px;'>[$i] $($loc.User) <span style='color: #64748b;'>(Seen: $($loc.LastSeen))</span></div>"
        $i++
    }
    $html += "</div>"
    Write-Output $html
    Write-Output "[GUI:UPDATE_TARGET:$($computerHistory[0].Computer)]"
}
