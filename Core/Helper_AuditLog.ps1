<#
.SYNOPSIS
    UHDC Web-Ready Core: Helper_AuditLog.ps1
.DESCRIPTION
    The central logging engine for the UHDC platform. It accepts 
    parameters for the Target PC and the Action performed, grabs the executing 
    technician's username ($env:USERNAME), and appends a timestamped record 
    to the central ConsoleAudit.csv file for security and usage tracking.
    Includes a retry loop to prevent data loss during concurrent writes.
#>

param(
    [string]$Target,
    [string]$Action,
    [string]$Tech = $env:USERNAME,
    [string]$SharedRoot
)

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
            return 
        }
    } catch {
        return
    }
}

# ------------------------------------------------------------------
# WRITE TO UNIFIED CSV LOG (WITH CONCURRENCY PROTECTION)
# ------------------------------------------------------------------
$LogFolder = Join-Path -Path $SharedRoot -ChildPath "Logs"
if (-not (Test-Path $LogFolder)) { New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null }

$LogFile = Join-Path -Path $LogFolder -ChildPath "ConsoleAudit.csv"

$newEntry = [PSCustomObject]@{ 
    Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Tech      = $Tech
    Target    = if ($Target) { $Target } else { "N/A" }
    Action    = $Action 
}

$RetryCount = 0
$MaxRetries = 5
$Success = $false

while ($RetryCount -lt $MaxRetries) {
    try {
        # -ErrorAction Stop is required here so the catch block triggers on a file lock
        $newEntry | Export-Csv -Path $LogFile -Append -NoTypeInformation -Force -ErrorAction Stop
        $Success = $true
        break # Success, exit the retry loop
    } catch {
        $RetryCount++
        # Random backoff prevents two colliding threads from retrying at the exact same time
        Start-Sleep -Milliseconds (Get-Random -Minimum 100 -Maximum 500)
    }
}

if (-not $Success) {
    # Changed to Write-Output so the Web UI catches the error if the CSV is permanently locked
    Write-Output "[!] Failed to write to audit log after $MaxRetries attempts. File may be locked by another process."
}