# Invoke-GPUpdate.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Remotely triggers a forced Group Policy update (Computer policy only)
# on the target machine. Uses /wait:0 to ensure the command returns instantly
# without hanging the console on potential reboot prompts.

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
Write-Host " [UHDC] FORCE GPUPDATE: $Target"
Write-Host "========================================"

# 1. Fast Ping Check to prevent WinRM timeouts
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# 2. Execute Remote Update
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    # ------------------------------------------------------------------
    # STEP 1: TRIGGER REMOTE GPUPDATE
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 1: FORCE GROUP POLICY UPDATE`n`nWHEN TO USE THIS:`nUse this when a user is missing mapped network drives, hasn't received a newly deployed software package, or when a new security policy (like a firewall rule or LAPS configuration) needs to be applied immediately without waiting for the standard 90-minute background refresh cycle.`n`nWHAT IT DOES:`nWe are establishing a remote WinRM session to execute the native Windows 'gpupdate' utility. We use the '/force' flag to reapply all policies (not just changed ones), '/target:computer' to limit the scope and speed it up, and '/wait:0' to ensure the command returns instantly without hanging our console if a policy requires a reboot.`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would open an elevated Command Prompt, type 'gpupdate /force', and wait for the 'Computer Policy update has completed successfully' message." `
        -Code "Invoke-Command -ComputerName $Target -ScriptBlock { gpupdate /force /target:computer /wait:0 }"

    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Write-Host "  > [UHDC] Running gpupdate /force /target:computer..."
        # /wait:0 ensures the command returns instantly without hanging on reboot prompts
        gpupdate /force /target:computer /wait:0 | Out-Null
    }

    Write-Host "`n [UHDC SUCCESS] Computer policy update triggered successfully!"

    # --- AUDIT LOG INJECTION ---
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Forced Remote GPUpdate" -SharedRoot $SharedRoot
        }
    }
    # ---------------------------

} catch {
    Write-Host "`n [UHDC ERROR] Could not trigger GPUpdate."
    Write-Host "     $($_.Exception.Message)"
}

Write-Host "========================================`n"