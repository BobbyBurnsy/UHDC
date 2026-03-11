<#
.SYNOPSIS
    UHDC Web-Ready Tool: BackgroundPolicyEnforcement.ps1
.DESCRIPTION
    Remotely triggers a forced Group Policy update (Computer policy only)
    on the target machine. Uses /wait:0 to ensure the command returns instantly.
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
        StepName = "BACKGROUND POLICY ENFORCEMENT"
        Description = "While the UHDC uses WinRM and PowerShell runspaces in the background, a junior technician should know how to trigger a remote policy update manually. By utilizing Sysinternals PsExec, you can remotely execute the native 'gpupdate.exe' utility as the SYSTEM account. We use '/force' to reapply all policies, '/target:computer' to limit the scope, and the critical '/wait:0' flag to ensure the command returns instantly without hanging your console if a policy requires a reboot."
        Code = "psexec \\`$Target -s gpupdate.exe /force /target:computer /wait:0"
        InPerson = "Opening an elevated Command Prompt, typing 'gpupdate /force', and waiting for the 'Computer Policy update has completed successfully' message."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[UHDC] BACKGROUND POLICY ENFORCEMENT"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "Background Policy Enforcement Executed (gpupdate /force)"

$Payload = {
    gpupdate /force /target:computer /wait:0 | Out-Null
}

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
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($Payload.ToString())
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            $ArgsList = "-accepteula -nobanner -d \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru

            if ($Process.ExitCode -eq 0) {
                Write-Output "`n[UHDC SUCCESS] Policy enforcement triggered successfully via PsExec!"
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
