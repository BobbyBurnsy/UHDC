<#
.SYNOPSIS
    UHDC Web-Ready Tool: CustomScriptOrchestrator.ps1
.DESCRIPTION
    Acts as a backend controller for the Custom Script Library UI.
    Reads custom .ps1 scripts from a network share and executes them remotely
    in memory, capturing the output. Supports single and mass deployments.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [string]$Action = "Execute",

    [Parameter(Mandatory=$false)]
    [string]$ScriptName,

    [Parameter(Mandatory=$false)]
    [string]$ScriptPath,

    [Parameter(Mandatory=$false)]
    [string]$ScriptID,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# --- Export Training Data ---
if ($GetTrainingData) {
    $data = @{
        StepName = "CUSTOM SCRIPT ORCHESTRATOR"
        Description = "While the UHDC uses in-memory ScriptBlocks and WinRM for mass concurrency, a junior technician should know how to manually deploy a PowerShell script to a remote machine. By utilizing Sysinternals PsExec, you can remotely invoke the PowerShell executable, bypass the local execution policy, and run a script directly from a network share as the SYSTEM account."
        Code = "psexec \\`$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"\\server\share\scripts\YourScript.ps1`""
        InPerson = "Copying a .ps1 file to a flash drive, walking to the user's desk, opening PowerShell as Administrator, and running the script manually."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Library Management ---
$LibraryFile = Join-Path -Path $SharedRoot -ChildPath "Core\ScriptLibrary.json"

function Load-Lib {
    if (Test-Path $LibraryFile) {
        try {
            $raw = Get-Content $LibraryFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -eq $raw) { return @() }
            if ($raw -is [System.Array]) { return $raw } else { return @($raw) }
        } catch { return @() }
    } else { 
        $default = @(
            [PSCustomObject]@{ ID=1; Name="Clear DNS Cache (Example)"; Path="\\server\share\Scripts\ClearDNS.ps1" }
        )
        $default | ConvertTo-Json -Depth 2 | Set-Content $LibraryFile -Force
        return $default
    }
}

function Save-Lib {
    param($d)
    $d | ConvertTo-Json -Depth 2 | Set-Content $LibraryFile -Force
}

# --- UI Library Management ---
if ($Action -eq "GetLibrary") {
    $lib = Load-Lib
    $lib | ConvertTo-Json -Depth 2 | Write-Output
    return
}

if ($Action -eq "AddScript") {
    $lib = Load-Lib
    $newID = if ($lib.Count -gt 0) { ([int]($lib | Select-Object -ExpandProperty ID | Measure-Object -Maximum).Maximum) + 1 } else { 1 }
    $lib += [PSCustomObject]@{ ID=$newID; Name=$ScriptName.Trim(); Path=$ScriptPath.Trim() }
    Save-Lib $lib

    $SafeScriptName = $ScriptName.Trim() -replace '<', '&lt;' -replace '>', '&gt;'
    Write-Output "[UHDC] [+] Added '$SafeScriptName' to the Custom Script Library."
    return
}

if ($Action -eq "DeleteScript") {
    $lib = Load-Lib
    $lib = $lib | Where-Object { $_.ID -ne [int]$ScriptID }
    Save-Lib $lib
    Write-Output "[UHDC] [-] Script removed from the Custom Script Library."
    return
}

# --- Main Execution ---
if ($Action -eq "Execute") {

    if ([string]::IsNullOrWhiteSpace($Target)) { Write-Output "[!] ERROR: Target PC(s) required."; return }
    if (-not (Test-Path $ScriptPath)) { Write-Output "[!] ERROR: Cannot read script at $ScriptPath. Verify path and permissions."; return }

    # Sanitize ScriptName for HTML output
    $SafeScriptName = $ScriptName -replace '<', '&lt;' -replace '>', '&gt;'

    $PayloadString = Get-Content $ScriptPath -Raw
    $PayloadBlock = [scriptblock]::Create($PayloadString)

    $TargetArray = @($Target -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    # --- Single Target Execution ---
    if ($TargetArray.Count -eq 1) {
        $SingleTarget = $TargetArray[0]
        Write-Output "========================================"
        Write-Output "[UHDC] CUSTOM SCRIPT EXECUTION"
        Write-Output "========================================"
        Write-Output "[i] Executing '$SafeScriptName' on $SingleTarget..."

        if (-not (Test-Connection -ComputerName $SingleTarget -Count 1 -Quiet)) { Write-Output "[!] Offline."; return }

        try {
            Write-Output " > Executing via WinRM..."
            $Output = Invoke-Command -ComputerName $SingleTarget -ScriptBlock $PayloadBlock -ErrorAction Stop | Out-String
            Write-Output "`n[UHDC SUCCESS] Script Output:`n$Output"
        } catch {
            Write-Output "[!] WinRM Failed. Initiating PsExec Fallback..."
            if (Test-Path $psExecPath) {
                try {
                    $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
                    $EncodedCommand = [Convert]::ToBase64String($Bytes)
                    $ArgsList = "/accepteula \\$SingleTarget -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"

                    $Output = & $psExecPath $ArgsList 2>&1 | Out-String
                    Write-Output "`n[UHDC SUCCESS] Script Output (via PsExec):`n$Output"
                } catch { Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed." }
            } else { Write-Output "`n[!] FATAL ERROR: psexec.exe is missing." }
        }

        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) { & $AuditHelper -Target $SingleTarget -Action "Executed Custom Script: $ScriptName" -SharedRoot $SharedRoot }
        }
        return
    }

    # --- Mass Execution ---
    Write-Output "========================================"
    Write-Output "[UHDC] MASS SCRIPT EXECUTION"
    Write-Output "========================================"
    Write-Output "[i] Script: $SafeScriptName"
    Write-Output "[i] Total Targets: $($TargetArray.Count)"

    $Online = @(); $Offline = @(); $SuccessWinRM = @(); $SuccessPsExec = @(); $Failed = @()

    Write-Output "`n[1/3] Performing rapid ping sweep..."
    foreach ($t in $TargetArray) { if (Test-Connection -ComputerName $t -Count 1 -Quiet) { $Online += $t } else { $Offline += $t } }

    if ($Online.Count -gt 0) {
        Write-Output "`n[2/3] Dispatching parallel WinRM commands..."

        $WinRMJob = Invoke-Command -ComputerName $Online -ScriptBlock $PayloadBlock -ErrorVariable WinRMErrors -ErrorAction SilentlyContinue -AsJob
        Wait-Job $WinRMJob | Out-Null
        $JobResults = Receive-Job $WinRMJob
		Remove-Job $WinRMJob -Force

        $FailedWinRM = @()
        foreach ($err in $WinRMErrors) { if ($err.TargetObject) { $FailedWinRM += $err.TargetObject.ToString().ToUpper() } }
        foreach ($t in $Online) { if ($FailedWinRM -contains $t.ToUpper()) { $FailedWinRM += $t } else { $SuccessWinRM += $t } }

        if ($FailedWinRM.Count -gt 0) {
            Write-Output "`n[3/3] Initiating PsExec fallback for blocked targets..."
            if (Test-Path $psExecPath) {
                $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
                $EncodedCommand = [Convert]::ToBase64String($Bytes)

                foreach ($t in $FailedWinRM) {
                    try {
                        $ArgsList = "/accepteula \\$t -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
                        $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru
                        if ($Process.ExitCode -eq 0) { $SuccessPsExec += $t } else { $Failed += $t }
                    } catch { $Failed += $t }
                }
            } else { $Failed += $FailedWinRM }
        }
    }

    $TotalSuccess = $SuccessWinRM.Count + $SuccessPsExec.Count
    $html = "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid #9b59b6; margin-top: 15px; margin-bottom: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
    $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 12px;'><i class='fa-solid fa-scroll'></i> Mass Script Execution Report</div>"
    $html += "<div style='display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 10px;'>"
    $html += "<div style='background: #0f172a; padding: 10px; border-radius: 6px; border: 1px solid #334155;'><span style='color: #94a3b8; font-size: 0.85rem;'>Total Targets</span><br><span style='color: #f8fafc; font-size: 1.2rem; font-weight: bold;'>$($TargetArray.Count)</span></div>"
    $html += "<div style='background: #0f172a; padding: 10px; border-radius: 6px; border: 1px solid #334155;'><span style='color: #94a3b8; font-size: 0.85rem;'>Successful Executions</span><br><span style='color: #2ecc71; font-size: 1.2rem; font-weight: bold;'>$TotalSuccess</span></div>"
    $html += "</div>"

    if ($Offline.Count -gt 0) { $html += "<div style='color: #e74c3c; font-size: 0.85rem; margin-top: 8px;'><i class='fa-solid fa-triangle-exclamation'></i> <strong>$($Offline.Count) Offline:</strong> $($Offline -join ', ')</div>" }
    if ($Failed.Count -gt 0) { $html += "<div style='color: #f1c40f; font-size: 0.85rem; margin-top: 8px;'><i class='fa-solid fa-circle-xmark'></i> <strong>$($Failed.Count) Failed:</strong> $($Failed -join ', ')</div>" }
    $html += "</div>"
    Write-Output $html

    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) { & $AuditHelper -Target "MASS SCRIPT ($TotalSuccess PCs)" -Action "Executed Script: $ScriptName" -SharedRoot $SharedRoot }
    }
}
