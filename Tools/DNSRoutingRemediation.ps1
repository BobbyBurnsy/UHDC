<#
.SYNOPSIS
    UHDC Web-Ready Tool: DNSRoutingRemediation.ps1
.DESCRIPTION
    Forcefully refreshes the target machine's DNS and NetBIOS registration
    on the domain controller. It executes 'ipconfig /flushdns', 'ipconfig /registerdns',
    and 'nbtstat -RR' sequentially.
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
        StepName = "DNS ROUTING REMEDIATION"
        Description = "Use this when a computer is connected to the network, but you cannot connect to it via hostname (e.g., switching from Wi-Fi to a wired dock). We establish a remote WinRM session to flush the PC's local DNS cache, force it to re-register its current IP, and refresh its NetBIOS names. If the local firewall blocks WinRM, we automatically fall back to PsExec, passing a Base64-encoded PowerShell payload to safely execute the remediation as the SYSTEM account."
        Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock { ipconfig /flushdns; ipconfig /registerdns; nbtstat -RR } } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Opening an elevated Command Prompt and typing 'ipconfig /flushdns', pressing Enter, typing 'ipconfig /registerdns', pressing Enter, and finally typing 'nbtstat -RR'."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] DNS ROUTING REMEDIATION"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

# We do a quick ping, but we don't stop the script if it fails,
# because if DNS is broken, the ping will naturally fail!
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[i] Target didn't answer ping (Likely DNS mismatch). Proceeding anyway..."
} else {
    Write-Output "[i] Target is reachable. Proceeding..."
}

$ActionLog = "DNS Routing Remediation Executed (Flush/Register/NBT)"

# Define the core remediation payload
$Payload = {
    ipconfig /flushdns | Out-Null
    ipconfig /registerdns | Out-Null
    nbtstat -RR | Out-Null
}

# 2. Execute Remote Remediation
try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    Write-Output " > Flushing local DNS Cache..."
    Write-Output " > Registering new DNS Records..."
    Write-Output " > Refreshing NetBIOS (nbtstat)..."

    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $Payload

    Write-Output "`n[UHDC SUCCESS] DNS/WINS refresh commands dispatched via WinRM."
    Write-Output "             (Note: It may take 5-10 minutes for the Domain Controller to update)"

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
                Write-Output "`n[UHDC SUCCESS] DNS/WINS refresh commands dispatched via PsExec."
                Write-Output "             (Note: It may take 5-10 minutes for the Domain Controller to update)"
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