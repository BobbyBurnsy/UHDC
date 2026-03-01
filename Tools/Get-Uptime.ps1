# Get-Uptime.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Queries the remote computer's WMI/CIM repository for Win32_OperatingSystem
# to calculate the exact Last Boot Up Time and current Uptime (Days, Hours, Minutes).
# Alerts the technician if the machine hasn't been rebooted in over 7 days.

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
Write-Host " [UHDC] UPTIME CHECK: $Target"
Write-Host "========================================"

# 1. Fast Ping Check to prevent WMI timeouts
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# 2. Execute WMI/CIM Query
try {
    Write-Host " [UHDC] [i] Querying $Target..."

    # ------------------------------------------------------------------
    # STEP 1: QUERY SYSTEM UPTIME
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 1: QUERY SYSTEM UPTIME`n`nWHEN TO USE THIS:`nUse this when a user complains about general PC slowness, bizarre application glitches, or when they claim they 'just rebooted' but the issue persists. Users frequently confuse turning off the monitor, closing a laptop lid, or logging off with a full system restart.`n`nWHAT IT DOES:`nWe are establishing a remote WMI/CIM session to query the 'Win32_OperatingSystem' class. We retrieve the exact 'LastBootUpTime' property and subtract it from the current time to calculate the precise number of days, hours, and minutes the machine has been running continuously.`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would press Ctrl+Shift+Esc to open Task Manager, click the 'Performance' tab, select 'CPU', and look at the 'Up time' counter at the bottom. Alternatively, you could open an elevated Command Prompt and type 'systeminfo | find `"System Boot Time`"'." `
        -Code "`$os = Get-CimInstance -ComputerName $Target -ClassName Win32_OperatingSystem`n`$boot = `$os.LastBootUpTime`n`$uptime = (Get-Date) - `$boot"

    $os = Get-CimInstance -ComputerName $Target -ClassName Win32_OperatingSystem -ErrorAction Stop
    $boot = $os.LastBootUpTime
    $now = Get-Date
    $uptime = $now - $boot

    Write-Host "  > Last Boot: $($boot.ToString('MM/dd/yyyy HH:mm'))"
    Write-Host "  > Uptime:    $($uptime.Days) Days, $($uptime.Hours) Hours, $($uptime.Minutes) Minutes"

    # Optional logic: Highlight if uptime is over 7 days
    if ($uptime.Days -gt 7) {
        Write-Host " [UHDC] [!] ATTENTION: Machine has not been rebooted in over a week." -ForegroundColor Yellow
    }

    # --- AUDIT LOG INJECTION ---
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Checked Uptime ($($uptime.Days) Days)" -SharedRoot $SharedRoot
        }
    }
    # ---------------------------

} catch {
    Write-Host "`n [UHDC ERROR] Could not query CIM/WMI."
    Write-Host "     $($_.Exception.Message)"
}

Write-Host "========================================`n"