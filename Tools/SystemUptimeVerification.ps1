<#
.SYNOPSIS
    UHDC Web-Ready Tool: SystemUptimeVerification.ps1
.DESCRIPTION
    Queries the remote computer's WMI/CIM repository for Win32_OperatingSystem
    to calculate the exact Last Boot Up Time and current Uptime.
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
        StepName = "SYSTEM UPTIME VERIFICATION"
        Description = "We establish a remote WinRM session to query the 'Win32_OperatingSystem' class. We retrieve the exact 'LastBootUpTime' property and subtract it from the current time to calculate the precise number of days, hours, and minutes the machine has been running continuously."
        Code = "try { `$boot = Invoke-Command -ComputerName `$Target -ScriptBlock { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } } catch { `$boot = psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Pressing Ctrl+Shift+Esc to open Task Manager, clicking the 'Performance' tab, selecting 'CPU', and looking at the 'Up time' counter at the bottom."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[UHDC] SYSTEM UPTIME VERIFICATION"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "System Uptime Verified"

$PayloadString = @"
    `$ErrorActionPreference = 'Stop'
    `$os = Get-CimInstance -ClassName Win32_OperatingSystem
    Write-Output `$os.LastBootUpTime.ToString('o')
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)
$RawBootString = $null
$MethodUsed = "WinRM"

try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    $RawBootString = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $PayloadBlock
} catch {
    Write-Output "[!] WinRM Failed or Blocked. Initiating PsExec Fallback..."
    $MethodUsed = "PsExec"

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"
    if (Test-Path $psExecPath) {
        try {
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            $ArgsList = "/accepteula \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $PsExecOutput = & $psExecPath $ArgsList 2>&1 | Out-String

            if ($PsExecOutput -match '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.*)') {
                $RawBootString = $matches[1].Trim()
                $ActionLog += " [PsExec Fallback]"
            } else {
                throw "Could not parse boot time from PsExec output."
            }
        } catch {
            Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed."
            return
        }
    } else {
        Write-Output "`n[!] FATAL ERROR: WinRM failed and psexec.exe is missing from \Core."
        return
    }
}

if (-not [string]::IsNullOrWhiteSpace($RawBootString)) {
    try {
        $boot = [datetime]::Parse($RawBootString)
        $now = Get-Date
        $uptime = $now - $boot

        Write-Output "`n[UHDC SUCCESS] Uptime retrieved successfully via $MethodUsed!"

        $statusColor = "#2ecc71"
        if ($uptime.Days -gt 7) { $statusColor = "#f1c40f" }

        $html = "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid $statusColor; margin-top: 10px; margin-bottom: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
        $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 12px;'><i class='fa-solid fa-clock'></i> System Uptime</div>"
        $html += "<div style='display: grid; grid-template-columns: 90px 1fr; gap: 8px; font-size: 0.95rem;'>"
        $html += "<span style='color: #94a3b8;'>Last Boot:</span><span style='color: #cbd5e1;'>$($boot.ToString('MM/dd/yyyy HH:mm'))</span>"
        $html += "<span style='color: #94a3b8;'>Uptime:</span><span style='color: #f8fafc; font-weight: bold;'>$($uptime.Days) Days, $($uptime.Hours) Hours, $($uptime.Minutes) Minutes</span>"
        $html += "</div>"

        if ($uptime.Days -gt 7) {
            $html += "<div style='margin-top: 12px; padding-top: 12px; border-top: 1px solid #334155; color: $statusColor; font-size: 0.9rem; font-weight: bold;'>"
            $html += "<i class='fa-solid fa-triangle-exclamation'></i> ATTENTION: Machine has not been rebooted in over a week."
            $html += "</div>"
        }

        $html += "</div>"
        Write-Output $html

        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                & $AuditHelper -Target $Target -Action "Verified Uptime ($($uptime.Days) Days)" -SharedRoot $SharedRoot
            }
        }
    } catch {
        Write-Output "`n[!] ERROR: Failed to parse boot time string."
    }
} else {
    Write-Output "`n[!] ERROR: No boot time string returned from target."
}
