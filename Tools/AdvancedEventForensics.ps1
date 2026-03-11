<#
.SYNOPSIS
    UHDC Web-Ready Tool: RemoteEventLogViewer.ps1
.DESCRIPTION
    Remotely queries the System and Application event logs.
    If no keyword is provided, it pulls the last 25 Critical/Error events.
    If a keyword is provided, it deep-scans the last 10,000 events for matches.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [string]$Keyword,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# --- Export Training Data ---
if ($GetTrainingData) {
    $data = @{
        StepName = "REMOTE EVENT LOG VIEWER"
        Description = "While the UHDC uses PowerShell to parse and format thousands of logs into a clean UI table, a junior technician should know how to pull event logs manually from the command line. By utilizing Sysinternals PsExec, you can remotely execute the native Windows Event Utility ('wevtutil') to instantly grab the latest system events in plain text without needing to open the slow Event Viewer GUI."
        Code = "psexec \\`$Target wevtutil qe System /c:10 /f:text /rd:true"
        InPerson = "Opening Event Viewer (eventvwr.msc), navigating to Windows Logs -> System, and filtering the log for Critical and Error events."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[UHDC] REMOTE EVENT LOG VIEWER"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = if ($Keyword) { "Remote Event Log Viewer Executed (Keyword: $Keyword)" } else { "Remote Event Log Viewer Executed (Critical/Error)" }

$LocalTemp = "C:\UHDC\Logs"
if (-not (Test-Path $LocalTemp)) { New-Item -ItemType Directory -Path $LocalTemp -Force | Out-Null }
$Timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$ExportPath = "$LocalTemp\EventLogs_$Target_$Timestamp.csv"

$SafeKeyword = $Keyword -replace "'", "''"

$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'
    `$Keyword = '$SafeKeyword'
    `$logs = `$null

    if ([string]::IsNullOrWhiteSpace(`$Keyword)) {
        `$logs = Get-WinEvent -FilterHashtable @{LogName=@('System','Application'); Level=@(1,2)} -MaxEvents 25
    } else {
        `$logs = Get-WinEvent -LogName 'System','Application' -MaxEvents 10000 | 
                Where-Object { `$_.Message -match `$Keyword -or `$_.ProviderName -match `$Keyword } | 
                Select-Object -First 50
    }

    `$results = @()
    if (`$logs) {
        foreach (`$log in `$logs) {
            `$results += [PSCustomObject]@{
                TimeCreated = `$log.TimeCreated.ToString('MM/dd HH:mm:ss')
                Level       = `$log.LevelDisplayName
                Provider    = `$log.ProviderName
                Message     = `$log.Message
            }
        }
    }

    `$json = @(`$results) | ConvertTo-Json -Compress
    Write-Output `"---JSON_START---`$json---JSON_END---`"
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)
$RawOutputString = $null
$MethodUsed = "WinRM"

try {
    Write-Output "[i] Attempting connection to $Target via WinRM... (This may take a moment)"
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
        $logData = $matches[1] | ConvertFrom-Json
        if ($logData -isnot [System.Array]) { $logData = @($logData) }

        if ($logData.Count -gt 0) {
            Write-Output "`n[UHDC SUCCESS] Found $($logData.Count) matching logs via $MethodUsed."

            $logData | Export-Csv -Path $ExportPath -NoTypeInformation -Force

            $html = "<div style='margin-top: 15px; margin-bottom: 15px; max-height: 400px; overflow-y: auto; border: 1px solid #334155; border-radius: 8px; background: #0f172a; box-shadow: 0 4px 6px rgba(0,0,0,0.2);'>"
            $html += "<table style='width: 100%; border-collapse: collapse; font-family: system-ui, sans-serif; font-size: 0.85rem; text-align: left;'>"
            $html += "<thead style='position: sticky; top: 0; background: #1e293b; color: #38bdf8; box-shadow: 0 2px 4px rgba(0,0,0,0.5);'>"
            $html += "<tr><th style='padding: 10px; border-bottom: 2px solid #334155; width: 15%;'>Time</th><th style='padding: 10px; border-bottom: 2px solid #334155; width: 10%;'>Level</th><th style='padding: 10px; border-bottom: 2px solid #334155; width: 20%;'>Provider</th><th style='padding: 10px; border-bottom: 2px solid #334155; width: 55%;'>Message</th></tr></thead><tbody>"

            foreach ($log in $logData) {
                $levelColor = "#f8fafc"
                if ($log.Level -match "Error|Critical") { $levelColor = "#e74c3c" }
                elseif ($log.Level -match "Warning") { $levelColor = "#f1c40f" }

                $msg = $log.Message -replace '<', '&lt;' -replace '>', '&gt;'
                if ($msg.Length -gt 250) { $msg = $msg.Substring(0, 247) + "..." }

                $html += "<tr style='border-bottom: 1px solid #1e293b;'>"
                $html += "<td style='padding: 8px; color: #94a3b8; white-space: nowrap;'>$($log.TimeCreated)</td>"
                $html += "<td style='padding: 8px; color: $levelColor; font-weight: bold;'>$($log.Level)</td>"
                $html += "<td style='padding: 8px; color: #cbd5e1;'>$($log.Provider)</td>"
                $html += "<td style='padding: 8px; color: #f8fafc; word-wrap: break-word; max-width: 300px;'>$msg</td>"
                $html += "</tr>"
            }

            $html += "</tbody></table></div>"
            $html += "<div style='color: #94a3b8; font-size: 0.85rem; margin-bottom: 10px;'><i class='fa-solid fa-file-csv'></i> Dataset saved to: $ExportPath</div>"

            Write-Output $html

            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) {
                    & $AuditHelper -Target $Target -Action $ActionLog -SharedRoot $SharedRoot
                }
            }
        } else {
            Write-Output "`n[i] No matching event logs found."
        }
    } catch {
        Write-Output "`n[!] ERROR: Failed to parse event log data JSON."
    }
} else {
    Write-Output "`n[!] ERROR: No valid event log data returned from target."
}
