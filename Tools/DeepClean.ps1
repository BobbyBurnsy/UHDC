# DeepClean.ps1 - Place this script in the \Tools folder
# DESCRIPTION: A heavy-duty cleanup tool. Silently clears and recreates the
# MECM (SCCM) cache using PsExec as SYSTEM. It then uses WinRM to force-empty
# Windows Temp, all User Temp folders, the Recycle Bin, and finally triggers
# a background Windows Disk Cleanup (cleanmgr /sagerun:1).

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
# BULLETPROOF CONFIG LOADER
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
Write-Host " [UHDC] REMOTE DEEP CLEANUP UTILITY"
Write-Host "========================================`n"

# 1. Fast Ping Check
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# ------------------------------------------------------------------
# 2. MECM / SCCM CACHE CLEANUP
# ------------------------------------------------------------------
Wait-TrainingStep `
    -Desc "STEP 1: PURGE MECM (SCCM) CACHE`n`nWHEN TO USE THIS:`nUse this when Software Center deployments are stuck at 0%, failing with 'hash mismatch' errors, or when the C: drive is critically low on space due to large cached application installers.`n`nWHAT IT DOES:`nWe are using PsExec (running as the SYSTEM account) to forcefully delete and recreate the 'ccmcache' directory, bypassing standard permission blocks.`n`nIN-PERSON EQUIVALENT:`nOpen Control Panel > Configuration Manager > Cache tab > Configure Settings > Delete Files." `
    -Code "psexec.exe \\$Target -s cmd /c `"rd /s /q C:\Windows\ccmcache & mkdir C:\Windows\ccmcache`""

Write-Host " [UHDC] [1/3] Clearing & Rebuilding MECM (SCCM) Cache..."

$psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

if (Test-Path $psExecPath) {
    try {
        $cmdChain = 'cmd /c "rd /s /q C:\Windows\ccmcache & mkdir C:\Windows\ccmcache"'
        Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s $cmdChain" -Wait -NoNewWindow

        Write-Host "  > [OK] CCMCache purged and rebuilt."
    } catch {
        Write-Host "  > [!] ERROR: Failed to execute PsExec."
    }
} else {
    Write-Host "  > [!] ERROR: psexec.exe not found in $psExecPath"
    Write-Host "        Please ensure the UHDC console has downloaded it to the \Core folder."
}

# ------------------------------------------------------------------
# 3. TEMP FOLDERS & RECYCLE BIN
# ------------------------------------------------------------------
Wait-TrainingStep `
    -Desc "STEP 2: CLEAR TEMP FOLDERS & RECYCLE BIN`n`nWHEN TO USE THIS:`nUse this when a user is experiencing bizarre application glitches (like Office apps crashing), cannot open certain files, or needs immediate disk space recovery.`n`nWHAT IT DOES:`nWe are establishing a WinRM session to recursively delete files in 'C:\Windows\Temp', iterate through every user profile to clear their 'AppData\Local\Temp' folders, and forcefully empty the Recycle Bin.`n`nIN-PERSON EQUIVALENT:`nPress Win+R, type '%temp%', select all files, and delete. Repeat for 'C:\Windows\Temp'. Finally, right-click the Recycle Bin on the desktop and select 'Empty Recycle Bin'." `
    -Code "Invoke-Command -ComputerName $Target -ScriptBlock {`n    Remove-Item -Path 'C:\Windows\Temp\*' -Recurse -Force`n    Remove-Item -Path 'C:\Users\*\AppData\Local\Temp\*' -Recurse -Force`n    Clear-RecycleBin -Force`n}"

Write-Host "`n [UHDC] [2/3] Emptying Temp Folders & Recycle Bin..."
try {
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        # Clear Windows Temp
        Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

        # Iteratively clear every User's AppData Temp folder
        $userProfiles = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue
        foreach ($profile in $userProfiles) {
            $tempPath = "$($profile.FullName)\AppData\Local\Temp\*"
            Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Clear the Recycle Bin across all drives
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  > [OK] System Temp, User Temp, and Recycle Bin zeroed out."
} catch {
    Write-Host "  > [!] ERROR: Failed to clear Temp/Recycle Bin."
    Write-Host "     $($_.Exception.Message)"
}

# ------------------------------------------------------------------
# 4. DISK CLEANUP (SAGERUN)
# ------------------------------------------------------------------
Wait-TrainingStep `
    -Desc "STEP 3: TRIGGER BACKGROUND DISK CLEANUP`n`nWHEN TO USE THIS:`nUse this for general PC maintenance, post-Windows Update cleanup, or to safely remove old Windows installation files (Windows.old) without interrupting the user.`n`nWHAT IT DOES:`nWe are remotely triggering the native Windows Disk Cleanup utility ('cleanmgr.exe') using the '/sagerun:1' flag, which runs a pre-configured, silent deep clean in the background.`n`nIN-PERSON EQUIVALENT:`nOpen the Start Menu, search for 'Disk Cleanup', select the C: drive, click 'Clean up system files', check all the boxes, and click OK." `
    -Code "Invoke-Command -ComputerName $Target -ScriptBlock { Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:1' -WindowStyle Hidden }"

Write-Host "`n [UHDC] [3/3] Triggering Disk Cleanup (Sagerun)..."
try {
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/sagerun:1" -WindowStyle Hidden
    }
    Write-Host "  > [OK] Disk Cleanup job dispatched to background."
} catch {
    Write-Host "  > [!] ERROR: Failed to dispatch cleanmgr."
    Write-Host "     $($_.Exception.Message)"
}

Write-Host "`n [UHDC SUCCESS] Deep Clean complete on $Target."

# --- AUDIT LOG INJECTION ---
if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
    $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
    if (Test-Path $AuditHelper) {
        & $AuditHelper -Target $Target -Action "Deep Clean (CCM/Temp/Recycle/Sagerun) executed" -SharedRoot $SharedRoot
    }
}
# ---------------------------

Write-Host "========================================`n"