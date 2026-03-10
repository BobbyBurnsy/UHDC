<#
.SYNOPSIS
    UHDC Enterprise Core (20K+): Helper_AuditLog.ps1
.DESCRIPTION
    Writes UHDC execution telemetry directly to the Windows Event Log 
    for real-time SIEM ingestion. Formats the event message as a JSON 
    payload for automatic field extraction.
#>

param(
    [string]$Target,
    [string]$Action,
    [string]$Tech = $env:USERNAME,
    [string]$SharedRoot
)

$LogName = "UHDC-Audit"
$Source  = "UHDC-Orchestrator"

# --- Ensure Custom Event Source Exists ---
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
        New-EventLog -LogName $LogName -Source $Source -ErrorAction Stop
    }
} catch {
    $LogName = "Application"
    if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
        New-EventLog -LogName $LogName -Source $Source -ErrorAction SilentlyContinue
    }
}

# --- Format JSON Payload ---
$EventPayload = @{
    Timestamp  = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
    Technician = $Tech
    Target     = if ($Target) { $Target } else { "N/A" }
    Action     = $Action
} | ConvertTo-Json -Compress

# --- Determine Event Severity ---
$EntryType = "Information"
$EventID   = 10001

if ($Action -match "MASS" -or $Action -match "Force" -or $Action -match "Wipe" -or $Action -match "Rebuild") {
    $EntryType = "Warning"
    $EventID   = 10002
}

# --- Write to Windows Event Log ---
try {
    Write-EventLog -LogName $LogName -Source $Source -EventId $EventID -EntryType $EntryType -Message $EventPayload -ErrorAction Stop
} catch {
    Write-Output "[!] Failed to write to Windows Event Log: $($_.Exception.Message)"
}
