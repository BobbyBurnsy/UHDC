<#
.SYNOPSIS
    UHDC Web-Ready Tool: RemotePowerControls.ps1
.DESCRIPTION
    Provides comprehensive power management for remote endpoints.
    Attempts to execute native Windows power commands (shutdown, rwinsta) via WinRM.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [ValidateSet("Restart", "ForceRestart", "Logoff", "Shutdown", "Abort")]
    [string]$PowerAction = "Restart",

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# --- Export Training Data ---
if ($GetTrainingData) {
    $data = @{
        StepName = "REMOTE POWER CONTROLS: $PowerAction"
        Description = "We establish a remote WinRM session to execute native Windows power commands. If the machine's WMI repository is frozen or the firewall blocks RPC traffic, we automatically fall back to PsExec."
        Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock { shutdown.exe /r /t 60 } } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Clicking the Start Menu, selecting the Power icon, and clicking 'Restart'."
    }

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

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[UHDC] REMOTE POWER CONTROLS"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "Remote Power Control Executed: $PowerAction"

$cmdString = switch ($PowerAction) {
    "Restart"      { "shutdown.exe /r /t 60" }
    "ForceRestart" { "shutdown.exe /r /f /t 0" }
    "Logoff"       { "rwinsta.exe console" }
    "Shutdown"     { "shutdown.exe /s /f /t 0" }
    "Abort"        { "shutdown.exe /a" }
}

$Payload = [scriptblock]::Create($cmdString)

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
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($Payload.ToString())
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            $ArgsList = "-accepteula -nobanner -d \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru

            if ($Process.ExitCode -eq 0) {
                Write-Output "`n[UHDC SUCCESS] Power action '$PowerAction' dispatched successfully via PsExec!"
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
