<#
.SYNOPSIS
    UHDC Web-Ready Tool: RemoteAccessProvisioning.ps1
.DESCRIPTION
    Remotely provisions RDP access on the target machine by modifying the registry (fDenyTSConnections),
    opening the Windows Firewall for the Remote Desktop profile, and ensuring the TermService is running.
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
        StepName = "REMOTE ACCESS PROVISIONING"
        Description = "We execute a 3-step pipeline to fully provision RDP: 1. Modifying the 'fDenyTSConnections' registry key to allow connections. 2. Opening the local Windows Defender Firewall for the 'Remote Desktop' rule group. 3. Configuring the 'TermService' to start automatically and forcing it to run. If the local firewall blocks WinRM, we automatically fall back to PsExec, passing a Base64-encoded PowerShell payload to safely execute the provisioning as the SYSTEM account."
        Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock { Set-ItemProperty ...; Enable-NetFirewallRule ...; Start-Service TermService } } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Opening System Properties to allow remote connections, opening Windows Firewall to allow the app through, and opening services.msc to start the Remote Desktop Services service."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] REMOTE ACCESS PROVISIONING"
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

$ActionLog = "Remote Access Provisioned (Registry/Firewall/Service)"

# Define the core remediation payload
$Payload = {
    # 1. Registry Modification
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0 -ErrorAction SilentlyContinue

    # 2. Firewall Configuration
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null

    # 3. Service Configuration
    Set-Service -Name "TermService" -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name "TermService" -ErrorAction SilentlyContinue
}

# 2. Execute Remote Provisioning
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
            # Safely encode the payload to Base64 for PS 5.1 execution
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($Payload.ToString())
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            # Execute silently as SYSTEM, capturing the process to check the exit code
            $ArgsList = "-accepteula -nobanner -d \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru

            if ($Process.ExitCode -eq 0) {
                Write-Output "`n[UHDC SUCCESS] Remote Access provisioned successfully via PsExec!"
                Write-Output "[i] You can try connecting using MSRA or RDP now."
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