<#
.SYNOPSIS
    UHDC Web-Ready Tool: BitLockerStatusVerification.ps1
.DESCRIPTION
    Remotely queries the target computer to retrieve the BitLocker encryption 
    status for all connected volumes.
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
        StepName = "BITLOCKER STATUS VERIFICATION"
        Description = "While the UHDC uses the BitLocker PowerShell module to parse and format volume data into a clean UI, a junior technician should know how to check encryption status manually. By utilizing Sysinternals PsExec, you can remotely execute the native 'manage-bde' command as the SYSTEM account to instantly view the encryption status, protection state, and lock status of all drives on the target machine."
        Code = "psexec \\`$Target -s manage-bde -status"
        InPerson = "Opening an elevated Command Prompt and typing 'manage-bde -status', or navigating to 'Control Panel > System and Security > BitLocker Drive Encryption'."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[UHDC] BITLOCKER STATUS VERIFICATION"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "BitLocker Status Verification Executed"

$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'
    `$volumes = Get-BitLockerVolume

    `$results = @()
    if (`$volumes) {
        foreach (`$vol in `$volumes) {
            `$protectors = (`$vol.KeyProtector | Select-Object -ExpandProperty KeyProtectorType) -join ', '
            `$results += [PSCustomObject]@{
                MountPoint = `$vol.MountPoint
                Status     = `$vol.VolumeStatus.ToString()
                Protection = `$vol.ProtectionStatus.ToString()
                Method     = `$vol.EncryptionMethod.ToString()
                Protectors = if (`$protectors) { `$protectors } else { 'None' }
            }
        }
    }

    `$json = @(`$results) | ConvertTo-Json -Compress
    Write-Output `"---JSON_START---`$json---JSON_END---`"
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)
$RawOutputString = $null
$MethodUsed = "WinRM"

try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    $RawOutputString = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $PayloadBlock | Out-String
} catch {
    Write-Output "[!] WinRM Failed or Blocked. Initiating PsExec Fallback..."
    $MethodUsed = "PsExec"

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"
    if (Test-Path $psExecPath) {
        try {
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            $ArgsList = "/accepteula \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $RawOutputString = & $psExecPath $ArgsList 2>&1 | Out-String
            $ActionLog += " [PsExec Fallback]"
        } catch {
            Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed."
            return
        }
    } else {
        Write-Output "`n[!] FATAL ERROR: WinRM failed and psexec.exe is missing from \Core."
        return
    }
}

if ($RawOutputString -match '---JSON_START---(.*?)---JSON_END---') {
    try {
        $bdeData = $matches[1] | ConvertFrom-Json
        if ($bdeData -isnot [System.Array]) { $bdeData = @($bdeData) }

        if ($bdeData.Count -gt 0) {
            Write-Output "`n[UHDC SUCCESS] BitLocker telemetry retrieved via $MethodUsed!`n"

            $html = "<div style='display: flex; flex-direction: column; gap: 12px; margin-top: 10px; margin-bottom: 10px;'>"

            foreach ($vol in $bdeData) {
                $icon = "fa-lock-open"
                $statusColor = "#e74c3c"

                if ($vol.Protection -eq "On") { 
                    $icon = "fa-lock"
                    $statusColor = "#2ecc71"
                } elseif ($vol.Status -match "Progress") {
                    $icon = "fa-spinner fa-spin"
                    $statusColor = "#f1c40f"
                }

                $html += "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid $statusColor; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
                $html += "<div style='display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px;'>"
                $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem;'><i class='fa-solid fa-hard-drive'></i> Drive $($vol.MountPoint)</div>"
                $html += "<div style='color: $statusColor; font-weight: bold; font-size: 0.95rem; text-transform: uppercase;'><i class='fa-solid $icon'></i> $($vol.Protection)</div>"
                $html += "</div>"
                $html += "<div style='display: grid; grid-template-columns: 120px 1fr; gap: 8px; font-size: 0.9rem;'>"
                $html += "<span style='color: #94a3b8;'>Volume Status:</span><span style='color: #cbd5e1;'>$($vol.Status)</span>"
                $html += "<span style='color: #94a3b8;'>Encryption:</span><span style='color: #cbd5e1;'>$($vol.Method)</span>"
                $html += "<span style='color: #94a3b8;'>Key Protectors:</span><span style='color: #cbd5e1;'>$($vol.Protectors)</span>"
                $html += "</div></div>"
            }

            $html += "</div>"
            Write-Output $html

            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) {
                    & $AuditHelper -Target $Target -Action $ActionLog -SharedRoot $SharedRoot
                }
            }
        } else {
            Write-Output "`n[i] No BitLocker volumes found or feature is not installed."
        }
    } catch {
        Write-Output "`n[!] ERROR: Failed to parse BitLocker data JSON."
    }
} else {
    Write-Output "`n[!] ERROR: No valid BitLocker data returned from target."
}
