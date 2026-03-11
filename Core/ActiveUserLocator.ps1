<#
.SYNOPSIS
    UHDC Web-Ready Core: ActiveUserLocator.ps1
.DESCRIPTION
    A multi-vector intelligence engine designed to locate a specific user on the network.
    It utilizes a cascading fallback logic:
    1. Local Database (UserHistory.json)
    2. Cloud Pivot (Microsoft Intune / Graph API)
    3. Context-Aware Subnet Sweep (AD Office/OU attribute)
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$TargetUser,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [hashtable]$SyncHash,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# --- Export Training Data ---
if ($GetTrainingData) {
    $data = @{
        StepName = "ACTIVE USER LOCATOR"
        Description = "The UHDC automates a complex 3-stage hunt (Local DB -> Intune -> AD Subnet Sweep) to find a user. However, a junior technician must know how to manually check who is logged into a specific computer without relying on complex PowerShell scripts. Using the classic Windows Management Instrumentation Command-line (WMIC) utility, you can instantly query a remote PC from a standard command prompt to see exactly who is physically sitting at the keyboard."
        Code = "wmic /node:`"TargetPC`" computersystem get username"
        InPerson = "Checking your personal notes, checking the cloud asset management portal, and finally walking the floor of their department to check the lock screen of every active computer."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
if ([string]::IsNullOrWhiteSpace($TargetUser)) {
    Write-Output "[!] ERROR: No username provided. Please search a user first."
    return
}

if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
    $SharedRoot = Split-Path -Path $ScriptDir
}

$HistoryFile  = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"
$UpdateHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_UpdateHistory.ps1"

Write-Output "========================================"
Write-Output "[UHDC] ACTIVE USER LOCATOR"
Write-Output "========================================"

# --- Identity Resolution ---
$ResolvedUser = $null
$UPN = $null
$office = $null
$dn = $null

try {
    $exact = Get-ADUser -Identity $TargetUser -Properties Office, DistinguishedName, UserPrincipalName -ErrorAction SilentlyContinue
    if ($exact) {
        $ResolvedUser = $exact.SamAccountName
        $UPN = $exact.UserPrincipalName
        $office = $exact.Office
        $dn = $exact.DistinguishedName
        Write-Output "[i] Target Locked: $($exact.Name)"
    }
} catch {}

if (-not $ResolvedUser) {
    Write-Output "[!] Ambiguous or invalid username: '$TargetUser'"
    return
}

$foundPC = $null
$foundVector = $null

# --- Vector 1: Local History ---
if (-not $foundPC -and (Test-Path $HistoryFile)) {
    Write-Output " > Vector 1: Checking Local History DB..."
    try {
        $raw = Get-Content $HistoryFile -Raw | ConvertFrom-Json
        if ($raw -isnot [System.Array]) { $raw = @($raw) }

        $match = $raw | Where-Object { $_.User -eq $ResolvedUser } | Sort-Object LastSeen -Descending | Select-Object -First 1

        if ($match) {
            $hPC = $match.Computer
            if (Test-Connection -ComputerName $hPC -Count 1 -Quiet) {
                $check = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $hPC -ErrorAction SilentlyContinue
                if ($check.UserName -match $ResolvedUser) {
                    $foundPC = $hPC
                    $foundVector = "Local Database Cache"
                }
            }
        }
    } catch {}
}

# --- Vector 2: Cloud Pivot (Intune) ---
if (-not $foundPC -and $UPN) {
    Write-Output " > Vector 2: Pivoting to Microsoft Intune..."
    if (Get-MgContext -ErrorAction SilentlyContinue) {
        try {
            $cloudDevices = Get-MgDeviceManagementManagedDevice -Filter "userPrincipalName eq '$UPN'" -ErrorAction SilentlyContinue
            if ($cloudDevices) {
                foreach ($dev in $cloudDevices) {
                    $cPC = $dev.DeviceName
                    if (Test-Connection -ComputerName $cPC -Count 1 -Quiet) {
                        $check = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $cPC -ErrorAction SilentlyContinue
                        if ($check.UserName -match $ResolvedUser) {
                            $foundPC = $cPC
                            $foundVector = "Intune Cloud Pivot"
                            break
                        }
                    }
                }
            }
        } catch {}
    } else {
        Write-Output "   (Skipped: Graph API not connected)"
    }
}

# --- Vector 3: Subnet Sweep ---
if (-not $foundPC) {
    Write-Output " > Vector 3: Context-Aware Subnet Sweep..."
    $searchBase = $null
    $filter = $null

    if (-not [string]::IsNullOrWhiteSpace($office)) {
        $filter = "$office*"
    } elseif ($dn -match "OU=Users,(.+)$") {
        $rootDN = $matches[1]
        $searchBase = "OU=Computers,$rootDN"
    }

    if ($searchBase -or $filter) {
        try {
            if ($searchBase) {
                $computers = Get-ADComputer -Filter * -SearchBase $searchBase -ErrorAction Stop | Select-Object -ExpandProperty Name
            } else {
                $computers = Get-ADComputer -Filter "Name -like '$filter'" -ErrorAction Stop | Select-Object -ExpandProperty Name
            }

            if ($computers) {
                if ($computers.Count -gt 100) { $computers = $computers | Select-Object -First 100 }

                Write-Output "   Scanning $($computers.Count) local machines via WMI..."

                $pingSender = New-Object System.Net.NetworkInformation.Ping
                foreach ($pc in $computers) {
                    if ($pingSender.Send($pc, 300).Status -eq "Success") {
                        $check = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $pc -ErrorAction SilentlyContinue
                        if ($check.UserName -match $ResolvedUser) {
                            $foundPC = $pc
                            $foundVector = "Active Directory Subnet Sweep"
                            break
                        }
                    }
                }
            }
        } catch {}
    } else {
        Write-Output "   (Skipped: No Office/OU context found in AD profile)"
    }
}

# --- Output & GUI Handoff ---
if ($foundPC) {
    try {
        if (Test-Path $UpdateHelper) {
            & $UpdateHelper -User $ResolvedUser -Computer $foundPC -SharedRoot $SharedRoot | Out-Null
        }
    } catch {}

    $html = "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid #9b59b6; margin-top: 15px; margin-bottom: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
    $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 8px;'><i class='fa-solid fa-magnifying-glass-location'></i> Active User Locator Result</div>"
    $html += "<div style='color: #2ecc71; font-size: 1.3rem; font-weight: bold; margin-bottom: 4px;'>$foundPC</div>"
    $html += "<div style='color: #94a3b8; font-size: 0.9rem;'><i class='fa-solid fa-crosshairs'></i> Found via: <span style='color: #cbd5e1;'>$foundVector</span></div>"
    $html += "</div>"

    Write-Output $html
    Write-Output "[GUI:UPDATE_TARGET:$foundPC]"

} else {
    Write-Output "`n[!] Scan exhausted. User is either offline or on an unreachable subnet."
}
