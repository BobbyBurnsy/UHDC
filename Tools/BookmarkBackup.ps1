# BookmarkBackup.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Remotely backs up Google Chrome and Microsoft Edge bookmarks
# for a specified user via SMB. Saves the files locally to C:\UHDC\Bookmarks
# and automatically opens File Explorer to the new backup folder.

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser,

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

# ------------------------------------------------------------------
# 1. VALIDATION & FALLBACKS
# ------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Target)) { return }

Write-Host "========================================================"
Write-Host " [UHDC] REMOTE BOOKMARK BACKUP UTILITY"
Write-Host "========================================================"

# Fast Ping Test
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    return
}

# If the AD box was blank, pop up a fallback box
if ([string]::IsNullOrWhiteSpace($TargetUser)) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $TargetUser = [Microsoft.VisualBasic.Interaction]::InputBox("Username was missing from the AD box. Enter TARGET USERNAME:", "User Required", "")
    if ([string]::IsNullOrWhiteSpace($TargetUser)) { return }
}

# ------------------------------------------------------------------
# 2. EXECUTE BACKUP
# ------------------------------------------------------------------
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmm")
$destFolder = "C:\UHDC\Bookmarks\$Target-$TargetUser-$timestamp"

# Browser Paths
$chromePath = "\\$Target\c$\Users\$TargetUser\AppData\Local\Google\Chrome\User Data\Default\Bookmarks"
$edgePath   = "\\$Target\c$\Users\$TargetUser\AppData\Local\Microsoft\Edge\User Data\Default\Bookmarks"

if (-not (Test-Path $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }

Write-Host " [UHDC] Connecting to hidden administrative share (\\$Target\c$)..."

$found = $false

# --- CHROME BACKUP ---
Wait-TrainingStep `
    -Desc "STEP 1: SECURE CHROME BOOKMARKS`n`nWe are accessing the remote computer's hidden C$ administrative share to copy the user's Google Chrome Bookmarks file directly over the network to our local machine.`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would open File Explorer, type '%LocalAppData%\Google\Chrome\User Data\Default' into the address bar, copy the file named 'Bookmarks', and save it to a flash drive or network share." `
    -Code "Copy-Item '\\$Target\c$\Users\$TargetUser\AppData\Local\Google\Chrome\User Data\Default\Bookmarks' -Destination '$destFolder\Chrome_Bookmarks' -Force"

if (Test-Path $chromePath) {
    Copy-Item $chromePath -Destination "$destFolder\Chrome_Bookmarks" -Force
    Write-Host " [UHDC] [OK] Chrome Bookmarks successfully secured."
    $found = $true
} else {
    Write-Host " [UHDC] [i] No Chrome bookmarks found for this user."
}

# --- EDGE BACKUP ---
Wait-TrainingStep `
    -Desc "STEP 2: SECURE EDGE BOOKMARKS`n`nWe are repeating the process for Microsoft Edge, which stores its user data in a similar Chromium-based directory structure.`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would navigate to '%LocalAppData%\Microsoft\Edge\User Data\Default', copy the 'Bookmarks' file, and save it alongside the Chrome backup." `
    -Code "Copy-Item '\\$Target\c$\Users\$TargetUser\AppData\Local\Microsoft\Edge\User Data\Default\Bookmarks' -Destination '$destFolder\Edge_Bookmarks' -Force"

if (Test-Path $edgePath) {
    Copy-Item $edgePath -Destination "$destFolder\Edge_Bookmarks" -Force
    Write-Host " [UHDC] [OK] Edge Bookmarks successfully secured."
    $found = $true
} else {
    Write-Host " [UHDC] [i] No Edge bookmarks found for this user."
}

# ------------------------------------------------------------------
# 3. FINISH & OPEN FOLDER
# ------------------------------------------------------------------
if ($found) {
    Write-Host "`n [UHDC SUCCESS] Backup complete! Opening local destination folder..."

    Wait-TrainingStep `
        -Desc "STEP 3: VERIFY BACKUP`n`nWe are launching File Explorer on your local machine and using the '/select' argument to automatically highlight the newly created backup folder.`n`nIN-PERSON EQUIVALENT:`nIf you were at the user's desk, you would open the flash drive or network share to visually confirm the files were successfully copied before proceeding with any destructive actions (like a profile reset or PC swap)." `
        -Code "Start-Process explorer.exe -ArgumentList `"/select,\`"$destFolder\`"`""

    # Uses the /select trick to safely bypass runspace parsing and highlight the new folder!
    Start-Process explorer.exe -ArgumentList "/select,`"$destFolder`""

    # --- AUDIT LOG INJECTION ---
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Backed up Chrome/Edge Bookmarks ($TargetUser)" -SharedRoot $SharedRoot
        }
    }
    # ---------------------------

} else {
    Write-Host "`n [UHDC] [!] No bookmarks found for user $TargetUser on $Target."
    Remove-Item $destFolder -Force -ErrorAction SilentlyContinue
}

Write-Host "========================================================`n"