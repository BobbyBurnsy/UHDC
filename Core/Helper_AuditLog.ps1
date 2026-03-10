<#
.SYNOPSIS
    UHDC Web-Ready Core: Helper_AuditLog.ps1
.DESCRIPTION
    The central logging engine for the UHDC platform. Appends a timestamped record 
    to the central ConsoleAudit.csv file for security and usage tracking.
    Includes a retry loop to prevent data loss during concurrent writes.
#>

param(
    [string]$Target,
    [string]$Action,
    [string]$Tech = $env:USERNAME,
    [string]$SharedRoot
)

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
            return 
        }
    } catch {
        return
    }
}

# --- Write to Audit Log ---
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
        $newEntry | Export-Csv -Path $LogFile -Append -NoTypeInformation -Force -ErrorAction Stop
        $Success = $true
        break
    } catch {
        $RetryCount++
        Start-Sleep -Milliseconds (Get-Random -Minimum 100 -Maximum 500)
    }
}
if (-not $Success) {
    Write-Output "[!] Failed to write to audit log after $MaxRetries attempts. File may be locked."
}

