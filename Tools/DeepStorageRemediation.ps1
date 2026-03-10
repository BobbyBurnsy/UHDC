<#
.SYNOPSIS
    UHDC Web-Ready Tool: DeepStorageRemediation.ps1
.DESCRIPTION
    A heavy-duty storage remediation tool. Calculates free space, silently clears 
    the MECM (SCCM) cache, force-empties Windows Temp, all User Temp folders, 
    and the Recycle Bin. Recalculates free space to determine total data purged,
    then triggers a background Windows Disk Cleanup (cleanmgr /sagerun:1).
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

# --- Export Training Data ---
if ($GetTrainingData) {
    $data = @{
        StepName = "DEEP STORAGE REMEDIATION"
        Description = "We execute a unified pipeline: 1. Query Win32_LogicalDisk for current free space. 2. Purge the MECM (SCCM) cache, Windows Temp, User Temp directories, and the Recycle Bin. 3. Re-query the disk to calculate exact bytes freed. 4. Trigger a silent Windows Disk Cleanup (cleanmgr /sagerun:1) in the background."
        Code = "`$before = (Get-CimInstance Win32_LogicalDisk -Filter `"DeviceID='C:'`").FreeSpace`nRemove-Item 'C:\Windows\ccmcache\*' -Recurse -Force`n`$after = (Get-CimInstance Win32_LogicalDisk -Filter `"DeviceID='C:'`").FreeSpace"
        InPerson = "Opening Control Panel to clear the Configuration Manager cache, pressing Win+R to delete %temp% files, emptying the Recycle Bin, and running the Disk Cleanup utility."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[UHDC] DEEP STORAGE REMEDIATION"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "Deep Storage Remediation Executed"

$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'

    # 1. Get Initial Free Space
    `$driveBefore = Get-CimInstance Win32_LogicalDisk -Filter `"DeviceID='C:'`"
    `$spaceBefore = `$driveBefore.FreeSpace

    # 2. MECM / SCCM Cache Cleanup
    if (Test-Path `"C:\Windows\ccmcache`") { Remove-Item -Path `"C:\Windows\ccmcache\*`" -Recurse -Force }

    # 3. Windows Temp Cleanup
    Remove-Item -Path `"C:\Windows\Temp\*`" -Recurse -Force

    # 4. User Temp Cleanup
    `$userProfiles = Get-ChildItem -Path `"C:\Users`" -Directory
    foreach (`$profile in `$userProfiles) {
        Remove-Item -Path `"`$(`$profile.FullName)\AppData\Local\Temp\*`" -Recurse -Force
    }

    # 5. Recycle Bin Cleanup
    Clear-RecycleBin -Force

    # 6. Get Final Free Space
    `$driveAfter = Get-CimInstance Win32_LogicalDisk -Filter `"DeviceID='C:'`"
    `$spaceAfter = `$driveAfter.FreeSpace

    `$freedBytes = `$spaceAfter - `$spaceBefore
    if (`$freedBytes -lt 0) { `$freedBytes = 0 }

    # 7. Trigger Background Disk Cleanup
    Start-Process -FilePath `"cleanmgr.exe`" -ArgumentList `"/sagerun:1`" -WindowStyle Hidden

    `$results = @{ SpaceFreedBytes = `$freedBytes }
    `$json = `$results | ConvertTo-Json -Compress
    Write-Output `"---JSON_START---`$json---JSON_END---`"
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)
$RawOutputString = $null
$MethodUsed = "WinRM"

try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    Write-Output " > Purging MECM cache, Temp directories, and Recycle Bin..."
    Write-Output " > Dispatching background Disk Cleanup (cleanmgr)..."

    $RawOutputString = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $PayloadBlock | Out-String
} catch {
    Write-Output "[!] WinRM Failed or Blocked. Initiating PsExec Fallback..."
    $MethodUsed = "PsExec"

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"
    if (Test-Path $psExecPath) {
        try {
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
            $EncodedCommand = [Convert]::ToBase64String($Bytes)
            $ArgsList = "/accepteula \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $RawOutputString = & $psExecPath $ArgsList 2>&1 | Out-String
            $ActionLog += " [PsExec Fallback]"
        } catch {
            Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed."
            return
        }
    } else {
        Write-Output "`n[!] FATAL ERROR: WinRM failed and psexec.exe is missing from \Core."
        return
    }
}

if ($RawOutputString -match '---JSON_START---(.*?)---JSON_END---') {
    try {
        $data = $matches[1] | ConvertFrom-Json
        $bytes = [math]::Round($data.SpaceFreedBytes, 0)

        $displaySpace = "0 MB"
        if ($bytes -gt 1GB) {
            $displaySpace = "$([math]::Round($bytes / 1GB, 2)) GB"
        } elseif ($bytes -gt 0) {
            $displaySpace = "$([math]::Round($bytes / 1MB, 2)) MB"
        }

        Write-Output "`n[UHDC SUCCESS] Deep Storage Remediation completed via $MethodUsed!"

        $html = "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid #f1c40f; margin-top: 10px; margin-bottom: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
        $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 12px;'><i class='fa-solid fa-broom'></i> Storage Recovery Report</div>"
        $html += "<div style='display: grid; grid-template-columns: 100px 1fr; gap: 8px; font-size: 0.95rem; margin-bottom: 12px;'>"
        $html += "<span style='color: #94a3b8;'>Target:</span><span style='color: #cbd5e1;'>$Target</span>"
        $html += "<span style='color: #94a3b8;'>Space Freed:</span><span style='color: #f1c40f; font-weight: bold; font-size: 1.4rem;'>$displaySpace</span>"
        $html += "</div>"
        $html += "<div style='border-top: 1px solid #334155; padding-top: 10px; color: #94a3b8; font-size: 0.85rem;'>"
        $html += "<i class='fa-solid fa-circle-check' style='color: #2ecc71;'></i> Caches purged. Background Disk Cleanup (cleanmgr) is now running silently."
        $html += "</div></div>"

        Write-Output $html

        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) { & $AuditHelper -Target $Target -Action "$ActionLog ($displaySpace Freed)" -SharedRoot $SharedRoot }
        }
    } catch {
        Write-Output "`n[!] ERROR: Failed to parse storage data JSON."
    }
} else {
    Write-Output "`n[!] ERROR: No valid storage data returned from target."
}
