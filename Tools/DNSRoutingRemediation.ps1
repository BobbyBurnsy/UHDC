<#
.SYNOPSIS
    UHDC Web-Ready Tool: DNSNetworkRefresh.ps1
.DESCRIPTION
    Forcefully refreshes the target machine's DNS and NetBIOS registration
    on the domain controller. It executes 'ipconfig /flushdns', 'ipconfig /registerdns',
    and 'nbtstat -RR' sequentially.
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
        StepName = "DNS & NETWORK REFRESH"
        Description = "While the UHDC uses PowerShell runspaces in the background, a junior technician should know how to force a DNS and NetBIOS refresh manually using classic command-line tools. By utilizing Sysinternals PsExec, you can remotely execute a chained CMD command as the SYSTEM account to flush the DNS cache, re-register the IP address with the Domain Controller, and refresh the NetBIOS names in one swift motion."
        Code = "psexec \\`$Target -s cmd.exe /c `"ipconfig /flushdns & ipconfig /registerdns & nbtstat -RR`""
        InPerson = "Opening an elevated Command Prompt and typing 'ipconfig /flushdns', pressing Enter, typing 'ipconfig /registerdns', pressing Enter, and finally typing 'nbtstat -RR'."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[UHDC] DNS & NETWORK REFRESH"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[i] Target didn't answer ping (Likely DNS mismatch). Proceeding anyway..."
} else {
    Write-Output "[i] Target is reachable. Proceeding..."
}

$ActionLog = "DNS Network Refresh Executed (Flush/Register/NBT)"

$Payload = {
    ipconfig /flushdns | Out-Null
    ipconfig /registerdns | Out-Null
    nbtstat -RR | Out-Null
}

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
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($Payload.ToString())
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            $ArgsList = "-accepteula -nobanner -d \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru

            if ($Process.ExitCode -eq 0) {
                Write-Output "`n[UHDC SUCCESS] DNS/WINS refresh commands dispatched via PsExec."
                Write-Output "             (Note: It may take 5-10 minutes for the Domain Controller to update)"
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
