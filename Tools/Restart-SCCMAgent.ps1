# Restart-SCCMAgent.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Remotely restarts the MECM/SCCM Agent service (CcmExec) via WinRM.
# It includes a 4-second delay between stopping and starting to ensure that
# the service fully releases its locks on the local log files before spinning back up.

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
Write-Host " [UHDC] RESTART SCCM AGENT: $Target"
Write-Host "========================================"

# 1. Fast Ping Check to prevent WinRM timeouts
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# 2. Execute Remote Restart
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    # ------------------------------------------------------------------
    # STEP 1: RESTART THE SMS AGENT HOST
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 1: RESTART THE SMS AGENT HOST`n`nWHEN TO USE THIS:`nUse this when a user complains that an application in Software Center is stuck on 'Downloading' or 'Waiting to install', or when a newly deployed application is not showing up in their Software Center at all.`n`nWHAT IT DOES:`nWe are establishing a remote WinRM session to restart the 'CcmExec' (SMS Agent Host) service. We explicitly stop the service, wait 4 seconds to ensure it fully releases its lock on the local SCCM log files (like CAS.log or AppEnforce.log), and then start it again. This forces the agent to wake up and request a fresh machine policy from the management point.`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would open Services (services.msc), locate 'SMS Agent Host', right-click it, and select 'Restart'. Alternatively, you would open the Configuration Manager applet in the Control Panel, go to the Actions tab, select 'Machine Policy Retrieval & Evaluation Cycle', and click 'Run Now'." `
        -Code "Invoke-Command -ComputerName $Target -ScriptBlock {`n    Stop-Service -Name CcmExec -Force`n    Start-Sleep -Seconds 4`n    Start-Service -Name CcmExec`n}"

    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Write-Host "  > [UHDC] Stopping CcmExec service..."
        Stop-Service -Name CcmExec -Force -ErrorAction SilentlyContinue | Out-Null

        # Give the service a moment to fully release its lock on log files
        Start-Sleep -Seconds 4

        Write-Host "  > [UHDC] Starting CcmExec service..."
        Start-Service -Name CcmExec -ErrorAction Stop
    }

    Write-Host "`n [UHDC SUCCESS] SCCM Agent restarted successfully!"
    Write-Host " [UHDC] [i] Note: It may take 2-3 minutes for the PC to check in with the Site Server."

    # --- AUDIT LOG INJECTION ---
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Restarted SCCM Agent (CcmExec)" -SharedRoot $SharedRoot
        }
    }
    # ---------------------------

} catch {
    Write-Host "`n [UHDC ERROR] Could not restart agent."
    Write-Host "     $($_.Exception.Message)"
}

Write-Host "========================================`n"