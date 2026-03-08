<#
.SYNOPSIS
    UHDC Web-Ready Tool: ChromiumProfileRebuild.ps1
.DESCRIPTION
    Completely resets Chrome and Edge browser profiles for a specific user on a remote machine.
    Safely backs up bookmarks to a local temp directory, kills browser processes, 
    deletes corrupted AppData, and restores the bookmarks.
    Attempts WinRM first. If blocked by firewall, falls back to a Base64-encoded
    payload executed via PsExec as SYSTEM.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser,

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
        StepName = "CHROMIUM PROFILE REBUILD"
        Description = "We execute a unified 4-step pipeline directly on the target machine: 1. Copying the user's Bookmarks to a safe temporary directory. 2. Forcefully terminating Chrome/Edge processes to drop file locks. 3. Deleting the corrupted AppData 'User Data' directories. 4. Recreating the folder structure and injecting the saved bookmarks back into place. If the local firewall blocks WinRM, we automatically fall back to PsExec, passing a Base64-encoded PowerShell payload to safely execute the rebuild as the SYSTEM account."
        Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock `$Payload -ArgumentList `$TargetUser } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Opening Task Manager to kill frozen browsers, navigating to %LocalAppData%, copying the Bookmarks file to the Desktop, deleting the 'User Data' folders manually, and pasting the Bookmarks file back into the new profile."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] CHROMIUM PROFILE REBUILD"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target) -or [string]::IsNullOrWhiteSpace($TargetUser)) { 
    Write-Output "[!] ERROR: Both Target PC and Target User are required for a Profile Rebuild."
    return 
}

# 1. Fast Ping Check to prevent WinRM timeouts
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "Chromium Profile Rebuild Executed ($TargetUser)"

# [CRITICAL FIX] Sanitize the TargetUser to prevent Single-Quote Injection
# If the username is "O'Brian", it becomes "O''Brian", which is valid PowerShell syntax inside a string.
$SafeUser = $TargetUser -replace "'", "''"

# Define the core remediation payload as a string so we can inject the TargetUser 
# variable directly into it before Base64 encoding for the PsExec fallback.
$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'
    `$User = '$SafeUser'
    `$cRoot = `"C:\Users\`$User\AppData\Local\Google\Chrome\User Data`"
    `$eRoot = `"C:\Users\`$User\AppData\Local\Microsoft\Edge\User Data`"
    `$backupDir = `"C:\Windows\Temp\UHDC_BM_\`$User`"

    # 1. Secure Bookmarks
    if (!(Test-Path `$backupDir)) { New-Item -ItemType Directory -Path `$backupDir -Force | Out-Null }
    if (Test-Path `"`$cRoot\Default\Bookmarks`") { Copy-Item `"`$cRoot\Default\Bookmarks`" `"`$backupDir\Chrome_BM`" -Force }
    if (Test-Path `"`$eRoot\Default\Bookmarks`") { Copy-Item `"`$eRoot\Default\Bookmarks`" `"`$backupDir\Edge_BM`" -Force }

    # 2. Terminate Processes
    Stop-Process -Name `"chrome`", `"msedge`" -Force
    Start-Sleep -Seconds 2

    # 3. Purge Corrupted Profiles
    if (Test-Path `$cRoot) { Remove-Item `$cRoot -Recurse -Force }
    if (Test-Path `$eRoot) { Remove-Item `$eRoot -Recurse -Force }

    # 4. Restore Bookmarks
    if (Test-Path `"`$backupDir\Chrome_BM`") {
        New-Item -ItemType Directory -Path `"`$cRoot\Default`" -Force | Out-Null
        Copy-Item `"`$backupDir\Chrome_BM`" `"`$cRoot\Default\Bookmarks`" -Force
    }
    if (Test-Path `"`$backupDir\Edge_BM`") {
        New-Item -ItemType Directory -Path `"`$eRoot\Default`" -Force | Out-Null
        Copy-Item `"`$backupDir\Edge_BM`" `"`$eRoot\Default\Bookmarks`" -Force
    }

    # Cleanup
    Remove-Item `$backupDir -Recurse -Force
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)

# 2. Execute Remote Remediation
try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    Write-Output " > Securing bookmarks for $TargetUser..."
    Write-Output " > Terminating browser processes..."
    Write-Output " > Purging AppData and restoring bookmarks..."

    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $PayloadBlock

    Write-Output "`n[UHDC SUCCESS] Chromium profiles rebuilt successfully via WinRM!"

} catch {
    Write-Output "[!] WinRM Failed or Blocked. Initiating PsExec Fallback..."

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"
    if (Test-Path $psExecPath) {
        try {
            # Safely encode the payload to Base64 for PS 5.1 execution
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            # Execute silently as SYSTEM, capturing the process to check the exit code
            $ArgsList = "-accepteula -nobanner -d \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru

            if ($Process.ExitCode -eq 0) {
                Write-Output "`n[UHDC SUCCESS] Chromium profiles rebuilt successfully via PsExec!"
                $ActionLog += " [PsExec Fallback]"
            } else {
                Write-Output "`n[!] ERROR: PsExec executed but returned exit code $($Process.ExitCode)."
                Write-Output "    The command may have failed or the system is unresponsive."
            }
        } catch {
            Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed."
            Write-Output "    Details: $($_.Exception.Message)"
        }
    } else {
        Write-Output "`n[!] FATAL ERROR: WinRM failed and psexec.exe is missing from \Core."
    }
}

# --- AUDIT LOG INJECTION ---
if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
    $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
    if (Test-Path $AuditHelper) {
        & $AuditHelper -Target $Target -Action $ActionLog -SharedRoot $SharedRoot
    }
}