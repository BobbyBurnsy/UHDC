<#
.SYNOPSIS
    UHDC Web-Ready Tool: DeepStorageRemediation.ps1
.DESCRIPTION
    A heavy-duty storage remediation tool. Silently clears the MECM (SCCM) cache,
    force-empties Windows Temp, all User Temp folders, the Recycle Bin, and finally 
    triggers a background Windows Disk Cleanup (cleanmgr /sagerun:1).
    Attempts WinRM first. If blocked by firewall, falls back to a Base64-encoded
    payload executed via PsExec as SYSTEM.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser, # Passed by AppLogic, but unused in this specific script

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
        StepName = "DEEP STORAGE REMEDIATION"
        Description = "We execute a unified 4-step deep clean pipeline: 1. Purging the MECM (SCCM) cache directory. 2. Recursively deleting Windows Temp and all User Temp directories. 3. Emptying the system-wide Recycle Bin. 4. Triggering a silent Windows Disk Cleanup (cleanmgr /sagerun:1) in the background. If the local firewall blocks WinRM, we automatically fall back to PsExec, passing a Base64-encoded PowerShell payload to safely execute the remediation as the SYSTEM account."
        Code = "try { Invoke-Command -ComputerName `$Target -ScriptBlock { Remove-Item 'C:\Windows\ccmcache\*' -Force; Remove-Item 'C:\Windows\Temp\*' -Force; Clear-RecycleBin -Force; Start-Process 'cleanmgr.exe' -ArgumentList '/sagerun:1' } } catch { psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Opening Control Panel to clear the Configuration Manager cache, pressing Win+R to delete %temp% files, emptying the Recycle Bin, and running the Disk Cleanup utility."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] DEEP STORAGE REMEDIATION"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

# 1. Fast Ping Check to prevent WinRM timeouts
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "Deep Storage Remediation Executed (MECM/Temp/Recycle/Sagerun)"

# Define the unified core remediation payload
$Payload = {
    # 1. MECM / SCCM Cache Cleanup
    if (Test-Path "C:\Windows\ccmcache") {
        Remove-Item -Path "C:\Windows\ccmcache\*" -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        New-Item -ItemType Directory -Path "C:\Windows\ccmcache" -Force -ErrorAction SilentlyContinue | Out-Null
    }

    # 2. Windows Temp Cleanup
    Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

    # 3. User Temp Cleanup (Iterate through all profiles)
    $userProfiles = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue
    foreach ($profile in $userProfiles) {
        $tempPath = "$($profile.FullName)\AppData\Local\Temp\*"
        Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 4. Recycle Bin Cleanup
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue

    # 5. Trigger Background Disk Cleanup
    Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/sagerun:1" -WindowStyle Hidden -ErrorAction SilentlyContinue
}

# 2. Execute Remote Remediation
try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    Write-Output " > Purging MECM cache, Temp directories, and Recycle Bin..."
    Write-Output " > Dispatching background Disk Cleanup (cleanmgr)..."

    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $Payload

    Write-Output "`n[UHDC SUCCESS] Deep Storage Remediation completed successfully via WinRM!"

} catch {
    Write-Output "[!] WinRM Failed or Blocked. Initiating PsExec Fallback..."

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"
    if (Test-Path $psExecPath) {
        try {
            # Safely encode the payload to Base64 for PS 5.1 execution
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($Payload.ToString())
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            # Execute silently as SYSTEM, capturing the process to check the exit code
            $ArgsList = "-accepteula -nobanner -d \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru

            if ($Process.ExitCode -eq 0) {
                Write-Output "`n[UHDC SUCCESS] Deep Storage Remediation completed successfully via PsExec!"
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