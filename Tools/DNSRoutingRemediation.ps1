<#
.SYNOPSIS
    UHDC Web-Ready Tool: DNSRoutingRemediation.ps1
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
        StepName = "DNS ROUTING REMEDIATION"
        Description = "Use this when a computer is connected to the network, but you cannot connect to it via hostname. We establish a remote WinRM session to flush the PC's local DNS cache, force it to re-register its current IP, and refresh its NetBIOS names."
        Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock { ipconfig /flushdns; ipconfig /registerdns; nbtstat -RR } } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Opening an elevated Command Prompt and typing 'ipconfig /flushdns', pressing Enter, typing 'ipconfig /registerdns', pressing Enter, and finally typing 'nbtstat -RR'."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[UHDC] DNS ROUTING REMEDIATION"
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

$ActionLog = "DNS Routing Remediation Executed (Flush/Register/NBT)"

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
