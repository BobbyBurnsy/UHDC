# Check-Bitlocker.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Remotely queries the target computer via WinRM to retrieve
# the BitLocker encryption status for all connected volumes. Displays the
# Mount Point, Volume Status, Protection Status, Encryption Method, and Key Protectors.

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [hashtable]$SyncHash
)

# --- TRAINING MODE HELPER ---
function Wait-TrainingStep {
    param([string]$Desc, [string]$Code)
    if ($null -ne $SyncHash) {
        $SyncHash.StepDesc = $Desc
        $SyncHash.StepCode = $Code
        $SyncHash.StepReady = $true
        $SyncHash.StepAck = $false

        # Pause the script until the GUI user clicks Execute or Abort
        while (-not $SyncHash.StepAck) { Start-Sleep -Milliseconds 200 }

        if (-not $SyncHash.StepResult) {
            throw "Execution aborted by user during Training Mode."
        }
    }
}
# ----------------------------

# ------------------------------------------------------------------
# BULLETPROOF CONFIG LOADER (Fallback if run standalone)
# ------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    try {
        $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
        $RootFolder = Split-Path -Path $ScriptDir
        $ConfigFile = Join-Path -Path $RootFolder -ChildPath "config.json"

        if (Test-Path $ConfigFile) {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $SharedRoot = $Config.SharedNetworkRoot
        }
    } catch { }
}

if ([string]::IsNullOrWhiteSpace($Target)) { return }

Write-Host "========================================"
Write-Host " [UHDC] BITLOCKER STATUS UTILITY"
Write-Host "========================================"

# 1. Fast Ping Check
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# 2. Query BitLocker Volumes
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    Wait-TrainingStep `
        -Desc "STEP 1: QUERY BITLOCKER STATUS`n`nWe are establishing a remote WinRM session to query the target's BitLocker management interface. This will retrieve the encryption status, protection state, and active key protectors (like TPM or Numerical Passwords) for all mounted volumes.`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would open an elevated Command Prompt and type 'manage-bde -status', or navigate to 'Control Panel > System and Security > BitLocker Drive Encryption' to view the drive status." `
        -Code "Invoke-Command -ComputerName $Target -ScriptBlock { Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionMethod, KeyProtector }"

    $bdeVolumes = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, EncryptionMethod, ProtectionStatus,
            @{Name="Protectors";Expression={ ($_.KeyProtector.KeyProtectorType) -join ", " }}
    }

    Write-Host "`n --- BitLocker Volumes ---"

    if ($bdeVolumes) {
        foreach ($vol in $bdeVolumes) {
            Write-Host "  > Drive: $($vol.MountPoint)"
            Write-Host "    Status:     $($vol.VolumeStatus)"
            Write-Host "    Protection: $($vol.ProtectionStatus)"
            Write-Host "    Encryption: $($vol.EncryptionMethod)"
            Write-Host "    Protectors: $($vol.Protectors)`n"
        }

        # --- AUDIT LOG INJECTION ---
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                & $AuditHelper -Target $Target -Action "Queried BitLocker Status" -SharedRoot $SharedRoot
            }
        }
        # ---------------------------

    } else {
        Write-Host "  [UHDC] [i] No BitLocker volumes found or feature is not installed."
    }

} catch {
    Write-Host "`n [UHDC ERROR] Could not retrieve BitLocker status."
    Write-Host "     $($_.Exception.Message)"
}

Write-Host "========================================`n"