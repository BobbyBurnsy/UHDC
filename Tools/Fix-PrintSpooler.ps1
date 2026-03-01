# Fix-PrintSpooler.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Remotely stops the Print Spooler service, forcibly deletes any
# stuck files in the spool\PRINTERS directory, and then restarts the service.

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
Write-Host " [UHDC] PRINT SPOOLER REMEDIATION"
Write-Host "========================================"

# 1. Fast Ping Check to prevent WinRM timeouts
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# 2. Execute Spooler Reset
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    # ------------------------------------------------------------------
    # STEP 1: STOP THE SERVICE
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 1: STOP THE PRINT SPOOLER SERVICE`n`nWHEN TO USE THIS:`nUse this when a user complains that a document is 'stuck' in the print queue, preventing all other documents from printing, and right-clicking 'Cancel' does nothing.`n`nWHAT IT DOES:`nWe are remotely stopping the Windows Print Spooler service. This is required because the service places a 'lock' on the corrupted print files, preventing us from deleting them while it is running.`n`nIN-PERSON EQUIVALENT:`nOpen Services (services.msc), locate 'Print Spooler', right-click, and select 'Stop'." `
        -Code "Invoke-Command -ComputerName $Target -ScriptBlock { Stop-Service -Name Spooler -Force }"

    Write-Host "  > [1/3] Stopping Print Spooler service..."
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
    }

    # Give the service a moment to fully release its file locks
    Start-Sleep -Seconds 2

    # ------------------------------------------------------------------
    # STEP 2: CLEAR THE QUEUE
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 2: CLEAR THE PRINT QUEUE DIRECTORY`n`nWHEN TO USE THIS:`nThis is the core remediation step. Once the service is stopped, the corrupted data must be purged.`n`nWHAT IT DOES:`nWe are forcefully deleting all files (usually .SHD and .SPL files) inside the system's PRINTERS directory. We use the '-File' flag to ensure we only delete the stuck jobs and don't accidentally delete the folder itself.`n`nIN-PERSON EQUIVALENT:`nOpen File Explorer, navigate to 'C:\Windows\System32\spool\PRINTERS', select all files inside the folder, and delete them." `
        -Code "Invoke-Command -ComputerName $Target -ScriptBlock { Remove-Item -Path 'C:\Windows\System32\spool\PRINTERS\*' -File -Force }"

    Write-Host "  > [2/3] Clearing stuck print jobs..."
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        $spoolFolder = "C:\Windows\System32\spool\PRINTERS"
        if (Test-Path $spoolFolder) {
            Remove-Item -Path "$spoolFolder\*" -File -Force -ErrorAction SilentlyContinue
        }
    }

    # ------------------------------------------------------------------
    # STEP 3: START THE SERVICE
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 3: RESTART THE PRINT SPOOLER SERVICE`n`nWHEN TO USE THIS:`nThis is the final step to bring the printing subsystem back online.`n`nWHAT IT DOES:`nWe are starting the Print Spooler service back up. The user's print queue will now be completely empty, and they can attempt to print their document again.`n`nIN-PERSON EQUIVALENT:`nOpen Services (services.msc), locate 'Print Spooler', right-click, and select 'Start'." `
        -Code "Invoke-Command -ComputerName $Target -ScriptBlock { Start-Service -Name Spooler }"

    Write-Host "  > [3/3] Starting Print Spooler service..."
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Start-Service -Name Spooler -ErrorAction Stop
    }

    Write-Host "`n [UHDC SUCCESS] Print Spooler restarted and print queue cleared!"

    # --- AUDIT LOG INJECTION ---
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Print Spooler Reset and Queue Cleared" -SharedRoot $SharedRoot
        }
    }
    # ---------------------------

} catch {
    Write-Host "`n [UHDC ERROR] Could not fix print spooler."
    Write-Host "     $($_.Exception.Message)"
}

Write-Host "========================================`n"