<#
.SYNOPSIS
    UHDC Web-Ready Tool: BitLockerStatusVerification.ps1
.DESCRIPTION
    Remotely queries the target computer to retrieve the BitLocker encryption 
    status for all connected volumes.
    Attempts WinRM first. If blocked by firewall, falls back to a Base64-encoded
    payload executed via PsExec as SYSTEM.
    Outputs a styled HTML payload for the web dashboard.
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
        StepName = "BITLOCKER STATUS VERIFICATION"
        Description = "We establish a remote WinRM session to query the target's BitLocker management interface. This retrieves the encryption status, protection state, and active key protectors (like TPM or Numerical Passwords) for all mounted volumes. If the local firewall blocks WinRM, we automatically fall back to PsExec, passing a Base64-encoded PowerShell payload to safely extract the encryption telemetry as the SYSTEM account."
        Code = "try { `$json = Invoke-Command -ComputerName `$Target -ScriptBlock `$Payload } catch { `$json = psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Open an elevated Command Prompt and type 'manage-bde -status', or navigate to 'Control Panel > System and Security > BitLocker Drive Encryption' to view the drive status."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] BITLOCKER STATUS VERIFICATION"
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

$ActionLog = "BitLocker Status Verification Executed"

# 2. Define the core payload to extract BitLocker data as a JSON string
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

    # Compress to a single line and wrap in delimiters for safe extraction
    `$json = @(`$results) | ConvertTo-Json -Compress
    Write-Output `"---JSON_START---`$json---JSON_END---`"
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)
$RawOutputString = $null
$MethodUsed = "WinRM"

# 3. Execute Remote Query
try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    $RawOutputString = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $PayloadBlock | Out-String
} catch {
    Write-Output "[!] WinRM Failed or Blocked. Initiating PsExec Fallback..."
    $MethodUsed = "PsExec"

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"
    if (Test-Path $psExecPath) {
        try {
            # Safely encode the payload to Base64 for PS 5.1 execution
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            $ArgsList = "/accepteula \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"

            # Capture output and filter out PsExec banner noise
            $RawOutputString = & $psExecPath $ArgsList 2>&1 | Out-String
            $ActionLog += " [PsExec Fallback]"
        } catch {
            Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed."
            Write-Output "    Details: $($_.Exception.Message)"
            return
        }
    } else {
        Write-Output "`n[!] FATAL ERROR: WinRM failed and psexec.exe is missing from \Core."
        return
    }
}

# 4. Process Data and Generate HTML
if ($RawOutputString -match '---JSON_START---(.*?)---JSON_END---') {
    try {
        $bdeData = $matches[1] | ConvertFrom-Json

        # Ensure it's an array even if only one volume was found
        if ($bdeData -isnot [System.Array]) { $bdeData = @($bdeData) }

        if ($bdeData.Count -gt 0) {
            Write-Output "`n[UHDC SUCCESS] BitLocker telemetry retrieved via $MethodUsed!`n"

            # Build the HTML Payload
            $html = "<div style='display: flex; flex-direction: column; gap: 12px; margin-top: 10px; margin-bottom: 10px;'>"

            foreach ($vol in $bdeData) {
                # Determine Icon and Color based on Protection Status
                $icon = "fa-lock-open"
                $statusColor = "#e74c3c" # Red (Unprotected)

                if ($vol.Protection -eq "On") { 
                    $icon = "fa-lock"
                    $statusColor = "#2ecc71" # Green (Protected)
                } elseif ($vol.Status -match "Progress") {
                    $icon = "fa-spinner fa-spin"
                    $statusColor = "#f1c40f" # Yellow (Encrypting/Decrypting)
                }

                $html += "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid $statusColor; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"

                $html += "<div style='display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px;'>"
                $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem;'><i class='fa-solid fa-hard-drive'></i> Drive $($vol.MountPoint)</div>"
                $html += "<div style='color: $statusColor; font-weight: bold; font-size: 0.95rem; text-transform: uppercase;'><i class='fa-solid $icon'></i> $($vol.Protection)</div>"
                $html += "</div>"

                $html += "<div style='display: grid; grid-template-columns: 120px 1fr; gap: 8px; font-size: 0.9rem;'>"

                $html += "<span style='color: #94a3b8;'>Volume Status:</span>"
                $html += "<span style='color: #cbd5e1;'>$($vol.Status)</span>"

                $html += "<span style='color: #94a3b8;'>Encryption:</span>"
                $html += "<span style='color: #cbd5e1;'>$($vol.Method)</span>"

                $html += "<span style='color: #94a3b8;'>Key Protectors:</span>"
                $html += "<span style='color: #cbd5e1;'>$($vol.Protectors)</span>"

                $html += "</div></div>"
            }

            $html += "</div>"

            # Output the raw HTML directly into the telemetry stream
            Write-Output $html

            # --- AUDIT LOG INJECTION ---
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
        Write-Output "    Details: $($_.Exception.Message)"
    }
} else {
    Write-Output "`n[!] ERROR: No valid BitLocker data returned from target."
}