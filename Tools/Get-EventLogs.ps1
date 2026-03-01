# Get-EventLogs.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Remotely queries the System and Application event logs.
# If no keyword is provided, it pulls the last 5 Critical/Error events.
# If a keyword is provided, it deep-scans the last 10,000 events for matches.
# Results are exported to a local CSV in C:\UHDC\Logs and previewed in the console.

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$Keyword,

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
Write-Host " [UHDC] REMOTE EVENT LOG DIAGNOSTICS"
Write-Host "========================================"

# Define local export directory (Branded for UHDC)
$LocalTemp = "C:\UHDC\Logs"
if (-not (Test-Path $LocalTemp)) {
    New-Item -ItemType Directory -Path $LocalTemp -Force | Out-Null
}

# Create a unique filename with timestamp
$Timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$ExportPath = "$LocalTemp\EventLogs_$Target_$Timestamp.csv"

try {
    # ------------------------------------------------------------------
    # STEP 1: QUERY EVENT LOGS
    # ------------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($Keyword)) {

        Wait-TrainingStep `
            -Desc "STEP 1: QUERY CRITICAL & ERROR LOGS`n`nWHEN TO USE THIS:`nUse this when a user reports unexpected reboots (BSODs), system hangs, or general instability, but doesn't have a specific error code.`n`nWHAT IT DOES:`nWe are using the 'Get-WinEvent' cmdlet to remotely query the target's System and Application logs. Since no keyword was provided, we are filtering specifically for Level 1 (Critical) and Level 2 (Error) events, pulling the 5 most recent occurrences.`n`nIN-PERSON EQUIVALENT:`nOpen Event Viewer (eventvwr.msc), expand 'Windows Logs', select 'System', click 'Filter Current Log' on the right pane, and check the boxes for 'Critical' and 'Error'." `
            -Code "Get-WinEvent -ComputerName $Target -FilterHashtable @{LogName=@('System','Application'); Level=@(1,2)} -MaxEvents 5"

        Write-Host "  > [1/2] Pulling last 5 Critical/Error logs from System & Application..."
        $logs = Get-WinEvent -ComputerName $Target -FilterHashtable @{LogName=@('System','Application'); Level=@(1,2)} -MaxEvents 5 -ErrorAction Stop
    } else {

        Wait-TrainingStep `
            -Desc "STEP 1: DEEP SCAN FOR KEYWORD`n`nWHEN TO USE THIS:`nUse this when troubleshooting a specific failing application (e.g., 'Outlook', 'Teams') or a specific error code provided by the user.`n`nWHAT IT DOES:`nWe are using 'Get-WinEvent' to pull the last 10,000 events from the System and Application logs, and then piping them into a 'Where-Object' filter to find exact matches for your keyword in either the Message body or the Provider Name.`n`nIN-PERSON EQUIVALENT:`nOpen Event Viewer (eventvwr.msc), select the 'Application' log, click 'Find...' on the right pane, type your keyword, and click 'Find Next' repeatedly." `
            -Code "Get-WinEvent -ComputerName $Target -LogName 'System','Application' -MaxEvents 10000 | Where-Object { `$_.Message -match '$Keyword' -or `$_.ProviderName -match '$Keyword' }"

        Write-Host "  > [1/2] Deep searching last 10,000 events for keyword: '$Keyword'..."
        Write-Host "    (This may take a moment to filter...)"
        $logs = Get-WinEvent -ComputerName $Target -LogName 'System','Application' -MaxEvents 10000 -ErrorAction Stop |
                Where-Object { $_.Message -match $Keyword -or $_.ProviderName -match $Keyword }
    }

    if ($null -ne $logs -and $logs.Count -gt 0) {
        Write-Host "  [UHDC SUCCESS] Found $($logs.Count) matching logs."

        # ------------------------------------------------------------------
        # STEP 2: EXPORT AND DISPLAY
        # ------------------------------------------------------------------
        Wait-TrainingStep `
            -Desc "STEP 2: EXPORT AND ANALYZE`n`nWHEN TO USE THIS:`nEvent logs contain massive blocks of text that are difficult to read in a standard console window. Exporting them to a spreadsheet allows for easy sorting, filtering, and sharing with higher-tier support teams.`n`nWHAT IT DOES:`nWe are selecting the most relevant properties (Time, ID, Level, Provider, and Message) and exporting them to a local CSV file. We then automatically open File Explorer to highlight the new file for immediate review.`n`nIN-PERSON EQUIVALENT:`nIn Event Viewer, right-click the filtered log view and select 'Save Filtered Log File As...', save it as a CSV to the Desktop, and open it in Excel." `
            -Code "`$logs | Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, LogName, Message | Export-Csv -Path '$ExportPath' -NoTypeInformation`nStart-Process explorer.exe -ArgumentList `"/select,\`"$ExportPath\`"`""

        # --- EXPORT ENGINE ---
        Write-Host "  > [2/2] Exporting results to CSV..."
        $logs | Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, LogName, Message |
                Export-Csv -Path $ExportPath -NoTypeInformation -Force

        Write-Host "  [i] Full results exported to: $ExportPath`n"

        # Automatically open File Explorer and instantly highlight the new file!
        Start-Process explorer.exe -ArgumentList "/select,`"$ExportPath`""
        # -------------------------

        # Console HUD Output: Limit to 15 so we don't flood the GUI
        $consoleLogs = $logs | Select-Object -First 15
        foreach ($log in $consoleLogs) {
            Write-Host "  [$($log.TimeCreated)] [$($log.LevelDisplayName)] $($log.ProviderName)"
            # This strips out crazy line breaks so it fits nicely in your console HUD
            $msg = $log.Message.Replace("`r`n", " ").Replace("`n", " ")
            if ($msg.Length -gt 150) { $msg = $msg.Substring(0, 147) + "..." }
            Write-Host "  > $msg`n"
        }

        if ($logs.Count -gt 15) {
            Write-Host "  [+] ... plus $($logs.Count - 15) more hidden from console. Open the CSV to view them all!" -ForegroundColor Yellow
        }

        # --- AUDIT LOG INJECTION ---
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                $actionStr = if ($Keyword) { "Queried Event Logs (Keyword: $Keyword)" } else { "Queried Event Logs (Critical/Error)" }
                & $AuditHelper -Target $Target -Action $actionStr -SharedRoot $SharedRoot
            }
        }
        # ---------------------------

    } else {
        Write-Host "  [UHDC] [i] No matching event logs found."
    }
} catch {
    Write-Host "  [UHDC] [!] ERROR querying Event Logs: $($_.Exception.Message)"
}