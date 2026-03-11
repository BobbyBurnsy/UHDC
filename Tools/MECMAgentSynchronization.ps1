<#
.SYNOPSIS
    UHDC Web-Ready Tool: SCCMAgentRestart.ps1
.DESCRIPTION
    Remotely restarts the SCCM Agent service (CcmExec).
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
        StepName = "SCCM AGENT RESTART"
        Description = "While the UHDC uses PowerShell to safely restart the service with a built-in delay, a junior technician should know how to bounce a service manually using classic command-line tools. By utilizing Sysinternals PsExec, you can remotely execute a chained CMD command as the SYSTEM account to stop the 'CcmExec' service, use a classic loopback ping to create a 4-second delay (allowing log file locks to release), and then start the service back up."
        Code = "psexec \\`$Target -s cmd.exe /c `"net stop CcmExec & ping 127.0.0.1 -n 5 > nul & net start CcmExec`""
        InPerson = "Opening Services (services.msc), locating 'SMS Agent Host', right-clicking it, and selecting 'Restart'. Alternatively, opening an elevated command prompt and typing the 'net stop' and 'net start' commands."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[UHDC] SCCM AGENT RESTART"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "SCCM Agent Restart Executed (CcmExec)"

$Payload = {
    Stop-Service -Name CcmExec -Force -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 4
    Start-Service -Name CcmExec -ErrorAction Stop
}

try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $Payload

    Write-Output "`n[UHDC SUCCESS] SCCM Agent restarted successfully via WinRM!"
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
                Write-Output "`n[UHDC SUCCESS] SCCM Agent restarted successfully via PsExec!"
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
