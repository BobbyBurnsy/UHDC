<#
.SYNOPSIS
    UHDC Web-Ready Tool: SystemUptimeVerification.ps1
.DESCRIPTION
    Queries the remote computer's WMI/CIM repository for Win32_OperatingSystem
    to calculate the exact Last Boot Up Time and current Uptime.
    Attempts WinRM first. If blocked by firewall, falls back to a Base64-encoded
    payload executed via PsExec as SYSTEM.
    Outputs a styled HTML payload for the web dashboard.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser, # Passed by AppLogic, but unused in this specific script

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# ====================================================================
# TRAINING DATA EXPORT (For Web UI Modal)
# ====================================================================
if ($GetTrainingData) {
    $data = @{
        StepName = "SYSTEM UPTIME VERIFICATION"
        Description = "We establish a remote WinRM session to query the 'Win32_OperatingSystem' class. We retrieve the exact 'LastBootUpTime' property and subtract it from the current time to calculate the precise number of days, hours, and minutes the machine has been running continuously. If the local firewall blocks WinRM, we automatically fall back to PsExec, passing a Base64-encoded PowerShell payload to safely extract the boot time as the SYSTEM account."
        Code = "try { `$boot = Invoke-Command -ComputerName `$Target -ScriptBlock { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } } catch { `$boot = psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Pressing Ctrl+Shift+Esc to open Task Manager, clicking the 'Performance' tab, selecting 'CPU', and looking at the 'Up time' counter at the bottom."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] SYSTEM UPTIME VERIFICATION"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

# 1. Fast Ping Check to prevent WinRM timeouts
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "System Uptime Verified"

# Define the core payload to extract the boot time as a clean ISO 8601 string
$PayloadString = @"
    `$ErrorActionPreference = 'Stop'
    `$os = Get-CimInstance -ClassName Win32_OperatingSystem
    Write-Output `$os.LastBootUpTime.ToString('o')
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)
$RawBootString = $null
$MethodUsed = "WinRM"

# 2. Execute Remote Query
try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    $RawBootString = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $PayloadBlock
} catch {
    Write-Output "[!] WinRM Failed or Blocked. Initiating PsExec Fallback..."
    $MethodUsed = "PsExec"

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"
    if (Test-Path $psExecPath) {
        try {
            # Safely encode the payload to Base64 for PS 5.1 execution
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            $ArgsList = "/accepteula \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"

            # Capture output and filter out PsExec banner noise
            $PsExecOutput = & $psExecPath $ArgsList 2>&1 | Out-String

            # Extract the ISO 8601 date string using Regex
            if ($PsExecOutput -match '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.*)') {
                $RawBootString = $matches[1].Trim()
                $ActionLog += " [PsExec Fallback]"
            } else {
                throw "Could not parse boot time from PsExec output."
            }
        } catch {
            Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed."
            Write-Output "    Details: $($_.Exception.Message)"
            return
        }
    } else {
        Write-Output "`n[!] FATAL ERROR: WinRM failed and psexec.exe is missing from \Core."
        return
    }
}

# 3. Process Data and Generate HTML
if (-not [string]::IsNullOrWhiteSpace($RawBootString)) {
    try {
        $boot = [datetime]::Parse($RawBootString)
        $now = Get-Date
        $uptime = $now - $boot

        Write-Output "`n[UHDC SUCCESS] Uptime retrieved successfully via $MethodUsed!"

        # Determine status color (Green if < 7 days, Yellow if > 7 days)
        $statusColor = "#2ecc71" # Green
        if ($uptime.Days -gt 7) { $statusColor = "#f1c40f" } # Yellow

        # Build the HTML Payload
        $html = "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid $statusColor; margin-top: 10px; margin-bottom: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
        $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 12px;'><i class='fa-solid fa-clock'></i> System Uptime</div>"

        $html += "<div style='display: grid; grid-template-columns: 90px 1fr; gap: 8px; font-size: 0.95rem;'>"

        $html += "<span style='color: #94a3b8;'>Last Boot:</span>"
        $html += "<span style='color: #cbd5e1;'>$($boot.ToString('MM/dd/yyyy HH:mm'))</span>"

        $html += "<span style='color: #94a3b8;'>Uptime:</span>"
        $html += "<span style='color: #f8fafc; font-weight: bold;'>$($uptime.Days) Days, $($uptime.Hours) Hours, $($uptime.Minutes) Minutes</span>"

        $html += "</div>"

        # Inject a warning banner if uptime is high
        if ($uptime.Days -gt 7) {
            $html += "<div style='margin-top: 12px; padding-top: 12px; border-top: 1px solid #334155; color: $statusColor; font-size: 0.9rem; font-weight: bold;'>"
            $html += "<i class='fa-solid fa-triangle-exclamation'></i> ATTENTION: Machine has not been rebooted in over a week."
            $html += "</div>"
        }

        $html += "</div>"

        # Output the raw HTML directly into the telemetry stream
        Write-Output $html

        # --- AUDIT LOG INJECTION ---
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                & $AuditHelper -Target $Target -Action "Verified Uptime ($($uptime.Days) Days)" -SharedRoot $SharedRoot
            }
        }
    } catch {
        Write-Output "`n[!] ERROR: Failed to parse boot time string."
        Write-Output "    Details: $($_.Exception.Message)"
    }
} else {
    Write-Output "`n[!] ERROR: No boot time string returned from target."
}