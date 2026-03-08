<#
.SYNOPSIS
    UHDC Web-Ready Tool: MECMAgentSynchronization.ps1
.DESCRIPTION
    Remotely restarts the MECM (formerly SCCM) Agent service (CcmExec).
    Attempts WinRM first. If blocked by firewall, falls back to a Base64-encoded
    payload executed via PsExec as SYSTEM. Includes a 4-second delay to ensure
    log file locks are released gracefully.
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
        StepName = "MECM AGENT SYNCHRONIZATION"
        Description = "We establish a remote WinRM session to restart the 'CcmExec' (SMS Agent Host) service. We explicitly stop the service, wait 4 seconds to ensure it fully releases its lock on the local MECM log files (like CAS.log or AppEnforce.log), and then start it again. If the local firewall blocks WinRM, we automatically fall back to PsExec, passing a Base64-encoded PowerShell payload to safely execute the restart as the SYSTEM account."
        Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock { Stop-Service CcmExec -Force; Start-Sleep 4; Start-Service CcmExec } } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Opening Services (services.msc), locating 'SMS Agent Host', right-clicking it, and selecting 'Restart'. Alternatively, opening the Configuration Manager applet in the Control Panel, going to the Actions tab, and running 'Machine Policy Retrieval & Evaluation Cycle'."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] MECM AGENT SYNCHRONIZATION"
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

$ActionLog = "MECM Agent Synchronization Executed (CcmExec)"

# Define the core remediation payload
$Payload = {
    Stop-Service -Name CcmExec -Force -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 4
    Start-Service -Name CcmExec -ErrorAction Stop
}

# 2. Execute Remote Restart
try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."

    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $Payload

    Write-Output "`n[UHDC SUCCESS] MECM Agent synchronized successfully via WinRM!"
    Write-Output "[i] Note: It may take 2-3 minutes for the endpoint to check in with the Management Point."

} catch {
    Write-Output "[!] WinRM Failed or Blocked. Initiating PsExec Fallback..."

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"
    if (Test-Path $psExecPath) {
        try {
            # Safely encode the payload to Base64 for PS 5.1 execution
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($Payload.ToString())
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            # Execute silently as SYSTEM, capturing the process to check the exit code
            $ArgsList = "-accepteula -nobanner -d \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru

            if ($Process.ExitCode -eq 0) {
                Write-Output "`n[UHDC SUCCESS] MECM Agent synchronized successfully via PsExec!"
                Write-Output "[i] Note: It may take 2-3 minutes for the endpoint to check in with the Management Point."
                $ActionLog += " [PsExec Fallback]"
            } else {
                Write-Output "`n[!] ERROR: PsExec executed but returned exit code $($Process.ExitCode)."
                Write-Output "    The service may not exist or the system is unresponsive."
            }
        } catch {
            Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed."
            Write-Output "    Details: $($_.Exception.Message)"
        }
    } else {
        Write-Output "`n[!] FATAL ERROR: WinRM failed and psexec.exe is missing from \Core."
    }
}

# --- AUDIT LOG INJECTION ---
if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
    $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
    if (Test-Path $AuditHelper) {
        & $AuditHelper -Target $Target -Action $ActionLog -SharedRoot $SharedRoot
    }
}