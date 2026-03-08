<#
.SYNOPSIS
    UHDC Enterprise Core (20K+): Helper_AuditLog.ps1
.DESCRIPTION
    Writes UHDC execution telemetry directly to the Windows Event Log 
    for real-time SIEM ingestion (Splunk, Sentinel, etc.).
    Formats the event message as a JSON payload for automatic field extraction.
#>

param(
    [string]$Target,
    [string]$Action,
    [string]$Tech = $env:USERNAME,
    [string]$SharedRoot # Kept for backward compatibility with AppLogic calls
)

$LogName = "UHDC-Audit"
$Source  = "UHDC-Orchestrator"

# 1. Ensure the Custom Event Source exists (Requires Admin, which Launch-UHDC enforces)
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
        New-EventLog -LogName $LogName -Source $Source -ErrorAction Stop
    }
} catch {
    # Fallback to the standard Application log if custom log creation fails
    $LogName = "Application"
    if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
        New-EventLog -LogName $LogName -Source $Source -ErrorAction SilentlyContinue
    }
}

# 2. Format the payload as JSON for SIEM auto-parsing
$EventPayload = @{
    Timestamp  = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
    Technician = $Tech
    Target     = if ($Target) { $Target } else { "N/A" }
    Action     = $Action
} | ConvertTo-Json -Compress

# 3. Determine Event Severity
# Standard actions are 'Information'. Mass deployments or destructive actions are 'Warning'.
$EntryType = "Information"
$EventID   = 10001

if ($Action -match "MASS" -or $Action -match "Force" -or $Action -match "Wipe" -or $Action -match "Rebuild") {
    $EntryType = "Warning"
    $EventID   = 10002
}

# 4. Write to the Windows Event Log
try {
    Write-EventLog -LogName $LogName -Source $Source -EventId $EventID -EntryType $EntryType -Message $EventPayload -ErrorAction Stop
} catch {
    Write-Output "[!] Failed to write to Windows Event Log: $($_.Exception.Message)"
}