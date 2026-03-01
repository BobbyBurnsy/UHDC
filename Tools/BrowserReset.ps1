# BrowserReset.ps1 - Place this script in the \Tools folder
# DESCRIPTION: A professional remediation tool that completely resets Chrome
# and Edge browser profiles for a specific user on a remote machine.
# It backs up their bookmarks, forcefully terminates locked browser processes,
# deletes the corrupted AppData profiles (wiping cookies, history, and cache),
# and then restores the bookmarks to a fresh profile.

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

Write-Host "##########################################################"
Write-Host "#        [UHDC] BROWSER PROFILE RESET UTILITY            #"
Write-Host "##########################################################`n"

# Fast Ping Test
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    return
}

# Ensure we have the user from AD box or prompt if missing
if ([string]::IsNullOrWhiteSpace($TargetUser)) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $TargetUser = [Microsoft.VisualBasic.Interaction]::InputBox("Username was missing from the AD box. Enter TARGET USERNAME:", "User Required", "")
    if ([string]::IsNullOrWhiteSpace($TargetUser)) { return }
}

Write-Host " [UHDC] Target set to $TargetUser. Awaiting technician confirmation..."

# The GUI Safety Gate
Add-Type -AssemblyName Microsoft.VisualBasic
$conf = [Microsoft.VisualBasic.Interaction]::InputBox("WARNING: This will DELETE all Passwords, History, and Cookies for $TargetUser on $Target.`n`nOnly Bookmarks will be preserved.`n`nType 'CONFIRM' to proceed:", "Confirm Browser Reset", "")

if ($conf -ne "CONFIRM") {
    Write-Host " [UHDC] Profile reset aborted by technician."
    return
}

# ------------------------------------------------------------------
# 2. SETUP & BACKUP BOOKMARKS
# ------------------------------------------------------------------
$localBackup = "C:\UHDC\Backups\BrowserReset_$Target"
if (-not (Test-Path $localBackup)) { New-Item -ItemType Directory -Path $localBackup -Force | Out-Null }

$cRoot = "\\$Target\c$\Users\$TargetUser\AppData\Local\Google\Chrome\User Data"
$eRoot = "\\$Target\c$\Users\$TargetUser\AppData\Local\Microsoft\Edge\User Data"

Wait-TrainingStep `
    -Desc "STEP 1: BACKUP BOOKMARKS`n`nWe are copying the user's Bookmarks file from their remote AppData directory to a safe local backup folder.`n`nIN-PERSON EQUIVALENT:`nIf you were at the user's desk, you would open File Explorer, navigate to '%LocalAppData%\Google\Chrome\User Data\Default', copy the 'Bookmarks' file, and paste it to the Desktop for safekeeping." `
    -Code "Copy-Item '\\$Target\c$\Users\$TargetUser\AppData\Local\Google\Chrome\User Data\Default\Bookmarks' -Destination 'C:\UHDC\Backups\BrowserReset_$Target\Chrome_BM' -Force"

Write-Host " [UHDC] [1/4] Securing user bookmarks..."
if (Test-Path "$cRoot\Default\Bookmarks") { Copy-Item "$cRoot\Default\Bookmarks" "$localBackup\Chrome_BM" -Force }
if (Test-Path "$eRoot\Default\Bookmarks") { Copy-Item "$eRoot\Default\Bookmarks" "$localBackup\Edge_BM" -Force }

# ------------------------------------------------------------------
# 3. KILL PROCESSES
# ------------------------------------------------------------------
Wait-TrainingStep `
    -Desc "STEP 2: TERMINATE BROWSER PROCESSES`n`nWe must forcefully terminate any running instances of Chrome or Edge. If the browser is open (or running in the background), Windows will lock the AppData files and prevent us from deleting them.`n`nIN-PERSON EQUIVALENT:`nIf you were at the user's desk, you would press Ctrl+Shift+Esc to open Task Manager, locate all 'Google Chrome' and 'Microsoft Edge' processes, right-click them, and select 'End task'." `
    -Code "psexec.exe \\$Target -s taskkill /F /IM chrome.exe /IM msedge.exe /T"

Write-Host " [UHDC] [2/4] Terminating active browser processes..."

$psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

if (Test-Path $psExecPath) {
    Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s taskkill /F /IM chrome.exe /IM msedge.exe /T" -Wait -NoNewWindow
} else {
    Write-Host " [UHDC] [!] ERROR: psexec.exe not found at $psExecPath"
    Write-Host "        Please ensure the UHDC console has downloaded it to the \Core folder."
}

# ------------------------------------------------------------------
# 4. DELETE APPDATA FOLDERS
# ------------------------------------------------------------------
Wait-TrainingStep `
    -Desc "STEP 3: PURGE CORRUPTED PROFILES`n`nWe are deleting the entire 'User Data' directory for both browsers. This permanently wipes the corrupted cache, cookies, history, and extensions.`n`nIN-PERSON EQUIVALENT:`nIf you were at the user's desk, you would navigate to '%LocalAppData%\Google\Chrome\' and permanently delete the 'User Data' folder. You would then repeat this for '%LocalAppData%\Microsoft\Edge\'." `
    -Code "Remove-Item '\\$Target\c$\Users\$TargetUser\AppData\Local\Google\Chrome\User Data' -Recurse -Force"

Write-Host " [UHDC] [3/4] Purging corrupted AppData profiles..."
if (Test-Path $cRoot) { Remove-Item $cRoot -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $eRoot) { Remove-Item $eRoot -Recurse -Force -ErrorAction SilentlyContinue }

# ------------------------------------------------------------------
# 5. RESTORE BOOKMARKS
# ------------------------------------------------------------------
Wait-TrainingStep `
    -Desc "STEP 4: RESTORE BOOKMARKS`n`nWe are recreating the 'Default' profile directory structure and copying the backed-up Bookmarks file back into place before the user opens the browser again.`n`nIN-PERSON EQUIVALENT:`nIf you were at the user's desk, you would open Chrome once to let it automatically recreate the default folders, close the browser, and then copy the saved 'Bookmarks' file from the Desktop back into the 'Default' folder." `
    -Code "New-Item -ItemType Directory -Path '\\$Target\c$\Users\$TargetUser\AppData\Local\Google\Chrome\User Data\Default' -Force`nCopy-Item 'C:\UHDC\Backups\BrowserReset_$Target\Chrome_BM' '\\$Target\...\Default\Bookmarks' -Force"

Write-Host " [UHDC] [4/4] Restoring bookmarks to fresh profile structure..."
if (Test-Path "$localBackup\Chrome_BM") {
    New-Item -ItemType Directory -Path "$cRoot\Default" -Force | Out-Null
    Copy-Item "$localBackup\Chrome_BM" "$cRoot\Default\Bookmarks" -Force
}
if (Test-Path "$localBackup\Edge_BM") {
    New-Item -ItemType Directory -Path "$eRoot\Default" -Force | Out-Null
    Copy-Item "$localBackup\Edge_BM" "$eRoot\Default\Bookmarks" -Force
}

Write-Host "`n [UHDC SUCCESS] $TargetUser's browsers have been successfully reset on $Target."

# --- AUDIT LOG INJECTION ---
if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
    $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
    if (Test-Path $AuditHelper) {
        & $AuditHelper -Target $Target -Action "Browser Profile Reset executed for user: $TargetUser" -SharedRoot $SharedRoot
    }
} else {
    Write-Host " [UHDC] [i] Audit log skipped (No SharedRoot mapped)." -ForegroundColor Yellow
}
# ---------------------------

Write-Host "========================================================`n"