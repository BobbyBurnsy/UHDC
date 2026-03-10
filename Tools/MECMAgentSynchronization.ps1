<#
.SYNOPSIS
    UHDC Web-Ready Tool: MECMAgentSynchronization.ps1
.DESCRIPTION
    Remotely restarts the MECM (formerly SCCM) Agent service (CcmExec).
    Includes a 4-second delay to ensure log file locks are released gracefully.
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
        StepName = "MECM AGENT SYNCHRONIZATION"
        Description = "We establish a remote WinRM session to restart the 'CcmExec' (SMS Agent Host) service. We explicitly stop the service, wait 4 seconds to ensure it fully releases its lock on the local MECM log files, and then start it again."
        Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock { Stop-Service CcmExec -Force; Start-Sleep 4; Start-Service CcmExec } } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Opening Services (services.msc), locating 'SMS Agent Host', right-clicking it, and selecting 'Restart'."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[UHDC] MECM AGENT SYNCHRONIZATION"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "MECM Agent Synchronization Executed (CcmExec)"

$Payload = {
    Stop-Service -Name CcmExec -Force -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 4
    Start-Service -Name CcmExec -ErrorAction Stop
}

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
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($Payload.ToString())
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            $ArgsList = "-accepteula -nobanner -d \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru

            if ($Process.ExitCode -eq 0) {
                Write-Output "`n[UHDC SUCCESS] MECM Agent synchronized successfully via PsExec!"
                Write-Output "[i] Note: It may take 2-3 minutes for the endpoint to check in with the Management Point."
                $ActionLog += " [PsExec Fallback]"
            } else {
                Write-Output "`n[!] ERROR: PsExec executed but returned exit code $($Process.ExitCode)."
            }
        } catch {
            Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed."
        }
    } else {
        Write-Output "`n[!] FATAL ERROR: WinRM failed and psexec.exe is missing from \Core."
    }
}

if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
    $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
    if (Test-Path $AuditHelper) {
        & $AuditHelper -Target $Target -Action $ActionLog -SharedRoot $SharedRoot
    }
}
