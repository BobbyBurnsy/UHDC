# Get-BatteryReport.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Remotely generates a 14-day Windows battery health report via WinRM,
# copies the resulting HTML file to the local machine, opens it in the default browser,
# and safely cleans up the remote file to leave no trace.

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
Write-Host " [UHDC] BATTERY HEALTH DIAGNOSTICS"
Write-Host "========================================"

# 1. Fast Ping Check to prevent WinRM/SMB timeouts
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# 2. Generate and Pull Report
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    # ------------------------------------------------------------------
    # STEP 1: GENERATE THE REPORT
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 1: GENERATE REMOTE BATTERY REPORT`n`nWHEN TO USE THIS:`nUse this when a user complains that their laptop battery is draining too fast, not holding a charge, or shutting down unexpectedly.`n`nWHAT IT DOES:`nWe are using WinRM to execute the native Windows 'powercfg' utility on the remote machine. This generates a detailed HTML report containing the last 14 days of battery usage, cycle counts, and degradation metrics, saving it to a temporary folder.`n`nIN-PERSON EQUIVALENT:`nOpen an elevated Command Prompt on the user's PC and type 'powercfg /batteryreport /duration 14'." `
        -Code "Invoke-Command -ComputerName $Target -ScriptBlock { cmd.exe /c `"powercfg /batteryreport /output C:\Temp\battery-report.html /duration 14`" }"

    # Ensure remote directory exists and generate report
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        $tempDir = "C:\Temp"
        if (-not (Test-Path $tempDir)) {
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        }

        # Remove old report if it exists to avoid locked file issues
        if (Test-Path "$tempDir\battery-report.html") {
            Remove-Item "$tempDir\battery-report.html" -Force -ErrorAction SilentlyContinue
        }

        Write-Host "  > [1/2] Running powercfg /batteryreport (14-day history)..."
        # Executing via cmd.exe ensures powercfg arguments parse perfectly
        cmd.exe /c "powercfg /batteryreport /output $tempDir\battery-report.html /duration 14" | Out-Null
    }

    $remotePath = "\\$Target\C$\Temp\battery-report.html"
    $localPath  = "$env:TEMP\$Target-battery.html"

    if (Test-Path $remotePath) {

        # ------------------------------------------------------------------
        # STEP 2: RETRIEVE AND CLEANUP
        # ------------------------------------------------------------------
        Wait-TrainingStep `
            -Desc "STEP 2: RETRIEVE AND DISPLAY REPORT`n`nWHEN TO USE THIS:`nThis step brings the generated report back to your workstation so you can analyze the 'Design Capacity' versus the 'Full Charge Capacity' to determine if the battery needs physical replacement.`n`nWHAT IT DOES:`nWe are copying the HTML file over the network (via the C$ administrative share) to your local Temp folder, opening it in your default web browser, and then deleting the remote copy to leave no trace.`n`nIN-PERSON EQUIVALENT:`nNavigate to the folder where the report was saved, double-click the HTML file to open it in Edge/Chrome, and review the battery health statistics." `
            -Code "Copy-Item '\\$Target\C$\Temp\battery-report.html' -Destination '$localPath'`nStart-Process '$localPath'`nRemove-Item '\\$Target\C$\Temp\battery-report.html'"

        Write-Host "  > [2/2] Copying report to local machine..."
        Copy-Item -Path $remotePath -Destination $localPath -Force

        Write-Host "`n [UHDC SUCCESS] Opening battery report locally..."
        # Opens using default web browser
        Start-Process $localPath

        # Clean up the remote machine
        Remove-Item -Path $remotePath -Force -ErrorAction SilentlyContinue

        # --- AUDIT LOG INJECTION ---
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                & $AuditHelper -Target $Target -Action "Generated Remote Battery Report" -SharedRoot $SharedRoot
            }
        }
        # ---------------------------
    } else {
        Write-Host "`n [UHDC] [!] ERROR: Report generation succeeded, but file was not found at $remotePath."
        Write-Host "      (Note: If $Target is a desktop PC, powercfg cannot generate a battery report.)"
    }

} catch {
    Write-Host "`n [UHDC ERROR] Failed to generate battery report."
    Write-Host "     $($_.Exception.Message)"
}

Write-Host "========================================`n"