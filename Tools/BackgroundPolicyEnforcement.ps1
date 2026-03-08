<#
.SYNOPSIS
    UHDC Web-Ready Tool: BackgroundPolicyEnforcement.ps1
.DESCRIPTION
    Remotely triggers a forced Group Policy update (Computer policy only)
    on the target machine. Uses /wait:0 to ensure the command returns instantly
    without hanging the console on potential reboot prompts.
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
        StepName = "BACKGROUND POLICY ENFORCEMENT"
        Description = "We establish a remote WinRM session to execute the native Windows 'gpupdate' utility. We use the '/force' flag to reapply all policies (not just changed ones), '/target:computer' to limit the scope and speed it up, and '/wait:0' to ensure the command returns instantly without hanging our console if a policy requires a reboot. If the local firewall blocks WinRM, we automatically fall back to PsExec, passing a Base64-encoded PowerShell payload to safely execute the update as the SYSTEM account."
        Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock { gpupdate /force /target:computer /wait:0 } } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Opening an elevated Command Prompt, typing 'gpupdate /force', and waiting for the 'Computer Policy update has completed successfully' message."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] BACKGROUND POLICY ENFORCEMENT"
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

$ActionLog = "Background Policy Enforcement Executed (gpupdate /force)"

# Define the core remediation payload
$Payload = {
    # /wait:0 ensures the command returns instantly without hanging on reboot prompts
    gpupdate /force /target:computer /wait:0 | Out-Null
}

# 2. Execute Remote Update
try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    Write-Output " > Enforcing computer policy update..."

    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $Payload

    Write-Output "`n[UHDC SUCCESS] Policy enforcement triggered successfully via WinRM!"

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
                Write-Output "`n[UHDC SUCCESS] Policy enforcement triggered successfully via PsExec!"
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