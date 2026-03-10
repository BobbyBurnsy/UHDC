<#
.SYNOPSIS
    UHDC Web-Ready Core: Helper_CheckSessions.ps1
.DESCRIPTION
    Queries a remote computer to retrieve a list of all currently 
    active and disconnected user sessions. Includes an automated 
    PsExec fallback to bypass Windows Firewall RPC blocks.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# --- Export Training Data ---
if ($GetTrainingData) {
    $data = @{
        StepName = "QUERY ACTIVE USER SESSIONS"
        Description = "We are querying the remote computer to see who is physically logged in at the keyboard (via WMI) and who is connected remotely in the background (via the 'quser' command). If the firewall blocks the standard RPC query, we automatically deploy PsExec to bypass the block."
        Code = "`$comp = Get-CimInstance Win32_ComputerSystem -ComputerName `$Target`n`$quserOutput = quser /server:`$Target 2>&1"
        InPerson = "Walking up to the computer, wiggling the mouse to see who is locked on the screen, and opening Task Manager -> Users tab to see background sessions."
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
        }
    } catch { }
}

if ([string]::IsNullOrWhiteSpace($Target)) {
    Write-Output "[!] Error: No target computer provided."
    return
}

Write-Output "========================================"
Write-Output "[UHDC] SESSION CHECK: $Target"
Write-Output "========================================"

$pingSender = New-Object System.Net.NetworkInformation.Ping
$isOnline = $false

try {
    $reply = $pingSender.Send($Target, 1000)
    if ($reply.Status -eq "Success") { $isOnline = $true }
} catch {}

if (-not $isOnline) {
    Write-Output "[!] $Target is offline or not responding."
    return
}

$UpdateHelper = if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) { Join-Path -Path $SharedRoot -ChildPath "Core\Helper_UpdateHistory.ps1" } else { $null }
$psExecPath = if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) { Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe" } else { $null }

# --- WMI Console Check ---
Write-Output "[i] Querying physical console user..."
try {
    $comp = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $Target -ErrorAction Stop
    $rawUser = $comp.UserName

    if ($rawUser) {
        Write-Output " > Console User: $rawUser" 
        if ($UpdateHelper -and (Test-Path $UpdateHelper)) {
            $cleanUser = ($rawUser -split "\\")[-1].Trim()
            & $UpdateHelper -User $cleanUser -Computer $Target -SharedRoot $SharedRoot
            Write-Output " > History map updated for $cleanUser."
        }
    } else {
        Write-Output " > Console User: [Nobody is physically logged in]"
    }
} catch {
    Write-Output " > [!] WMI Query Failed: RPC unavailable or Access Denied." 
}

# --- Terminal Session Check ---
Write-Output "`n[i] Querying terminal/background sessions..."
try {
    $quserOutput = quser /server:$Target 2>&1

    if ($quserOutput -match "Error" -or $quserOutput -match "RPC") {
        Write-Output " > [i] RPC Blocked by Firewall. Attempting PsExec bypass..."
        if ($psExecPath -and (Test-Path $psExecPath)) {
            $quserOutput = & $psExecPath /accepteula \\$Target -s quser 2>&1
        } else {
            Write-Output " > [!] ERROR: psexec.exe missing from \Core. Cannot bypass firewall."
        }
    }

    if ($quserOutput -match "No User exists") {
        Write-Output " > No background or remote sessions found."
    } 
    elseif ($quserOutput -match "Error" -or $quserOutput -match "RPC" -or $quserOutput -match "could not be found") {
        Write-Output " > [!] Target refused connection. Unable to verify sessions."
    }
    else {
        foreach ($line in $quserOutput) {
            if ($line -match "PsExec v" -or $line -match "Sysinternals" -or $line -match "Copyright" -or $line -match "starting on" -or $line -match "exited with error code") { continue }
            Write-Output " $line"

            if ($line -match "^\s*>?([a-zA-Z0-9_\.-]+)\s+.*Active") {
                $qUser = $matches[1]
                if ($qUser -ne "services" -and $UpdateHelper -and (Test-Path $UpdateHelper)) {
                    & $UpdateHelper -User $qUser -Computer $Target -SharedRoot $SharedRoot
                    Write-Output " > History map updated for $qUser."
                }
            }
        }
    }
} catch {
    Write-Output " > [!] Terminal query failed." 
}
