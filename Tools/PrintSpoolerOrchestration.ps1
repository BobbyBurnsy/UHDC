<#
.SYNOPSIS
    UHDC Web-Ready Tool: PrintSpoolerOrchestration.ps1
.DESCRIPTION
    Remotely stops the Print Spooler service, forcibly deletes any
    stuck files in the spool\PRINTERS directory, and then restarts the service.
    Attempts WinRM first. If blocked by firewall, falls back to a Base64-encoded
    payload executed via PsExec as SYSTEM.
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
        StepName = "PRINT SPOOLER ORCHESTRATION"
        Description = "We are executing a 3-step pipeline to clear a stuck print queue: 1. Stopping the 'Spooler' service to release file locks. 2. Forcefully deleting all corrupted .SHD and .SPL files in the system's PRINTERS directory. 3. Restarting the service to bring the printing subsystem back online. If the local firewall blocks WinRM, we automatically fall back to PsExec, passing a Base64-encoded PowerShell payload to safely execute the remediation as the SYSTEM account."
        Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock { Stop-Service Spooler -Force; Remove-Item 'C:\Windows\System32\spool\PRINTERS\*' -Force; Start-Service Spooler } } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Opening services.msc to stop the Print Spooler, navigating to C:\Windows\System32\spool\PRINTERS to delete all files, and then starting the service again."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] PRINT SPOOLER ORCHESTRATION"
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

$ActionLog = "Print Spooler Orchestration Executed (Queue Cleared)"

# Define the core remediation payload
$Payload = {
    Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue | Out-Null

    # Give the service a moment to fully release its file locks
    Start-Sleep -Seconds 2

    $spoolFolder = "C:\Windows\System32\spool\PRINTERS"
    if (Test-Path $spoolFolder) {
        Remove-Item -Path "$spoolFolder\*" -File -Force -ErrorAction SilentlyContinue
    }

    Start-Service -Name Spooler -ErrorAction Stop
}

# 2. Execute Remote Remediation
try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    Write-Output " > Stopping service, clearing corrupted spool files, and restarting..."

    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $Payload

    Write-Output "`n[UHDC SUCCESS] Print Spooler restarted and print queue cleared via WinRM!"

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
                Write-Output "`n[UHDC SUCCESS] Print Spooler restarted and print queue cleared via PsExec!"
                $ActionLog += " [PsExec Fallback]"
            } else {
                Write-Output "`n[!] ERROR: PsExec executed but returned exit code $($Process.ExitCode)."
                Write-Output "    The command may have failed or the system is unresponsive."
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