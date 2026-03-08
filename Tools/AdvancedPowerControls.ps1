<#
.SYNOPSIS
    UHDC Web-Ready Tool: AdvancedPowerControls.ps1
.DESCRIPTION
    Provides comprehensive power management for remote endpoints.
    Attempts to execute native Windows power commands (shutdown, rwinsta) via WinRM.
    If blocked by firewall or WMI is frozen, falls back to a Base64-encoded
    payload executed via PsExec under the SYSTEM context.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser, # Passed by AppLogic, but unused in this specific script

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [ValidateSet("Restart", "ForceRestart", "Logoff", "Shutdown", "Abort")]
    [string]$PowerAction = "Restart",

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# ====================================================================
# TRAINING DATA EXPORT (For Web UI Modal)
# ====================================================================
if ($GetTrainingData) {
    $data = @{
        StepName = "ADVANCED POWER CONTROLS: $PowerAction"
        Description = "We establish a remote WinRM session to execute native Windows power commands. If the machine's WMI repository is frozen or the firewall blocks RPC traffic, we automatically fall back to PsExec, passing a Base64-encoded PowerShell payload to safely force the action as the SYSTEM account."
        Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock { shutdown.exe /r /t 60 } } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Clicking the Start Menu, selecting the Power icon, and clicking 'Restart'."
    }

    # Adjust training data dynamically based on the action selected!
    if ($PowerAction -eq "ForceRestart") {
        $data.Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock { shutdown.exe /r /f /t 0 } } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        $data.InPerson = "Holding down the physical power button on the laptop for 5 seconds."
    } elseif ($PowerAction -eq "Logoff") {
        $data.Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock { rwinsta.exe console } } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        $data.InPerson = "Pressing Ctrl+Alt+Del and selecting 'Sign out'."
    } elseif ($PowerAction -eq "Shutdown") {
        $data.Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock { shutdown.exe /s /f /t 0 } } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        $data.InPerson = "Clicking the Start Menu, selecting the Power icon, and clicking 'Shut down'."
    } elseif ($PowerAction -eq "Abort") {
        $data.Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock { shutdown.exe /a } } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        $data.InPerson = "Quickly opening a command prompt and typing 'shutdown /a' before the timer runs out."
    }

    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] ADVANCED POWER CONTROLS"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

# 1. Fast Ping Check
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "Power Control Executed: $PowerAction"

# 2. Dynamically construct the payload based on the requested action
$cmdString = switch ($PowerAction) {
    "Restart"      { "shutdown.exe /r /t 60" }
    "ForceRestart" { "shutdown.exe /r /f /t 0" }
    "Logoff"       { "rwinsta.exe console" }
    "Shutdown"     { "shutdown.exe /s /f /t 0" }
    "Abort"        { "shutdown.exe /a" }
}

$Payload = [scriptblock]::Create($cmdString)

# 3. Execute Remote Power Action
try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    Write-Output " > Dispatching command: $cmdString"

    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $Payload

    Write-Output "`n[UHDC SUCCESS] Power action '$PowerAction' dispatched successfully via WinRM!"

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
                Write-Output "`n[UHDC SUCCESS] Power action '$PowerAction' dispatched successfully via PsExec!"
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