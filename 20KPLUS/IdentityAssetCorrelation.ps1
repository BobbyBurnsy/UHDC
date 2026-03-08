<#
.SYNOPSIS
    UHDC Enterprise Core (20K+): IdentityAssetCorrelation.ps1
.DESCRIPTION
    The high-performance SQL intelligence engine for the AD User Intelligence panel.
    Replaces the flat JSON file with direct, parameterized SQL queries against the 
    central telemetry database. Cross-references Active Directory profiles and 
    outputs raw JSON for the Web UI KPI cards, or styled HTML for the telemetry stream.
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

# ====================================================================
# TRAINING DATA EXPORT (For Web UI Modal)
# ====================================================================
if ($GetTrainingData) {
    $data = @{
        StepName = "IDENTITY & ASSET CORRELATION (SQL EDITION)"
        Description = "We execute a dual-pronged intelligence query. First, we execute a parameterized SQL query against the central AssetTelemetry database to instantly map the user to their physical hardware. Second, we query Active Directory for their profile, check their lockout status, dynamically calculate their exact password expiration date, and filter their AD groups to highlight critical access."
        Code = "`$cmd = New-Object System.Data.SqlClient.SqlCommand(`"SELECT TOP 5 ComputerName, LastSeen FROM AssetTelemetry WHERE Username = @User`", `$conn)`n`$adObj = Get-ADUser -Identity `$TargetUser -Properties LockedOut, PasswordLastSet, MemberOf"
        InPerson = "Asking the user for their computer name, opening ADUC to check if their account is locked, checking their 'Member Of' tab, and manually calculating 90 days from their last password reset."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# BULLETPROOF CONFIG LOADER
# ====================================================================
$ImportantGroups = @("VPN", "Admin", "M365", "License", "Remote") # Fallback defaults

# [!] ENTERPRISE SQL CONFIGURATION
# Replace this with your actual SQL Server details. 
# Integrated Security=True ensures the technician's AD account is used for access.
$SqlConnectionString = "Server=tcp:YOUR-SQL-SERVER,1433;Initial Catalog=UHDCTelemetry;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;"

if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    try {
        $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
        $RootFolder = Split-Path -Path $ScriptDir
        $ConfigFile = Join-Path -Path $RootFolder -ChildPath "Config\config.json"
        if (Test-Path $ConfigFile) {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $SharedRoot = $Config.SharedNetworkRoot
            if ($Config.ActiveDirectory.ImportantGroups) { $ImportantGroups = $Config.ActiveDirectory.ImportantGroups }
            if ($Config.Database.ConnectionString) { $SqlConnectionString = $Config.Database.ConnectionString }
        } else { return }
    } catch { return }
} else {
    $ConfigFile = Join-Path -Path $SharedRoot -ChildPath "Config\config.json"
    if (Test-Path $ConfigFile) {
        $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($Config.ActiveDirectory.ImportantGroups) { $ImportantGroups = $Config.ActiveDirectory.ImportantGroups }
        if ($Config.Database.ConnectionString) { $SqlConnectionString = $Config.Database.ConnectionString }
    }
}

if ([string]::IsNullOrWhiteSpace($TargetUser)) { return }

# ====================================================================
# PHASE 1: SQL DATABASE QUERY (High Performance)
# ====================================================================
$userHistory = @()
$computerHistory = @()
$dbStatus = "OK"

try {
    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $SqlConnectionString
    $SqlConnection.Open()

    # Query 1: Search by Username (Get top 5 most recent PCs)
    $SqlCmdUser = $SqlConnection.CreateCommand()
    $SqlCmdUser.CommandText = "SELECT TOP 5 Username, ComputerName, LastSeen FROM AssetTelemetry WHERE Username = @Target ORDER BY LastSeen DESC"
    $SqlCmdUser.Parameters.AddWithValue("@Target", $TargetUser) | Out-Null

    $ReaderUser = $SqlCmdUser.ExecuteReader()
    while ($ReaderUser.Read()) {
        $userHistory += [PSCustomObject]@{
            User     = $ReaderUser["Username"].ToString()
            Computer = $ReaderUser["ComputerName"].ToString()
            LastSeen = $ReaderUser["LastSeen"].ToString()
        }
    }
    $ReaderUser.Close()

    # Query 2: Search by ComputerName (If the tech searched a PC instead of a User)
    if ($userHistory.Count -eq 0) {
        $SqlCmdComp = $SqlConnection.CreateCommand()
        $SqlCmdComp.CommandText = "SELECT TOP 5 Username, ComputerName, LastSeen FROM AssetTelemetry WHERE ComputerName = @Target ORDER BY LastSeen DESC"
        $SqlCmdComp.Parameters.AddWithValue("@Target", $TargetUser) | Out-Null

        $ReaderComp = $SqlCmdComp.ExecuteReader()
        while ($ReaderComp.Read()) {
            $computerHistory += [PSCustomObject]@{
                User     = $ReaderComp["Username"].ToString()
                Computer = $ReaderComp["ComputerName"].ToString()
                LastSeen = $ReaderComp["LastSeen"].ToString()
            }
        }
        $ReaderComp.Close()
    }

    $SqlConnection.Close()
} catch {
    $dbStatus = "SQL ERROR: $($_.Exception.Message)"
}

# ====================================================================
# PHASE 2: ACTIVE DIRECTORY QUERY
# ====================================================================
$adObj = $null

try {
    $adObj = Get-ADUser -Identity $TargetUser -Properties Office, Title, Department, EmailAddress, PasswordLastSet, LastLogonDate, LockedOut, Enabled, MemberOf, PasswordNeverExpires -ErrorAction Stop
} catch {}

# ====================================================================
# PHASE 3: CALCULATIONS & GROUP PARSING
# ====================================================================
$expiryDate = "N/A"; $daysLeftStr = "N/A"
$matchedGroups = @()
$standardGroupCount = 0

if ($adObj) {
    # Password Expiry Calculation
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

    # AD Group Parsing
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

# ====================================================================
# PHASE 4: JSON API RESPONSE (For Web UI KPI Cards)
# ====================================================================
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

# ====================================================================
# PHASE 5: HTML TELEMETRY OUTPUT (Fallback)
# ====================================================================
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

    # --- INJECT AD GROUPS ---
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

    # --- INJECT SQL LOCATIONS ---
    $html += "<div style='border-top: 1px solid #334155; padding-top: 10px;'>"
    $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 0.95rem; margin-bottom: 6px;'><i class='fa-solid fa-location-dot'></i> Known Locations (SQL)</div>"

    if ($userHistory.Count -gt 0) {
        $i = 1
        foreach ($loc in $userHistory) {
            $html += "<div style='color: #cbd5e1; font-size: 0.85rem; margin-bottom: 2px;'>[$i] $($loc.Computer) <span style='color: #64748b;'>(Seen: $($loc.LastSeen))</span></div>"
            $i++
        }
        Write-Output "[GUI:UPDATE_TARGET:$($userHistory[0].Computer)]"
    } else { 
        $html += "<div style='color: #7f8c8d; font-size: 0.85rem;'>No history found in database.</div>" 
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