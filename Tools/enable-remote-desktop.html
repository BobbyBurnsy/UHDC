<#
.SYNOPSIS
    UHDC Web-Ready Tool: RemoteAccessProvisioning.ps1
.DESCRIPTION
    Remotely provisions RDP access on the target machine by modifying the registry,
    opening the Windows Firewall for the Remote Desktop profile, and ensuring the TermService is running.
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
        StepName = "REMOTE ACCESS PROVISIONING"
        Description = "While the UHDC uses PowerShell to orchestrate the registry, firewall, and service dependencies, a junior technician should know how to provision RDP manually from the command line. By utilizing Sysinternals PsExec, you can remotely execute a chained CMD command as the SYSTEM account to modify the 'fDenyTSConnections' registry key using 'reg add', open the Windows Firewall using 'netsh', and start the Terminal Services service all at once."
        Code = "psexec \\`$Target -s cmd.exe /c `"reg add `"HKLM\System\CurrentControlSet\Control\Terminal Server`" /v fDenyTSConnections /t REG_DWORD /d 0 /f & netsh advfirewall firewall set rule group=`"Remote Desktop`" new enable=Yes & net start TermService`""
        InPerson = "Opening System Properties to allow remote connections, opening Windows Defender Firewall to allow the app through, and opening services.msc to start the Remote Desktop Services service."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[UHDC] REMOTE ACCESS PROVISIONING"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "Remote Access Provisioned (Registry/Firewall/Service)"

$Payload = {
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0 -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null
    Set-Service -Name "TermService" -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name "TermService" -ErrorAction SilentlyContinue
}

try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    Write-Output " > Provisioning registry, firewall, and services..."

    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $Payload

    Write-Output "`n[UHDC SUCCESS] Remote Access provisioned successfully via WinRM!"
    Write-Output "[i] You can try connecting using MSRA or RDP now."

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
                Write-Output "`n[UHDC SUCCESS] Remote Access provisioned successfully via PsExec!"
                Write-Output "[i] You can try connecting using MSRA or RDP now."
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
