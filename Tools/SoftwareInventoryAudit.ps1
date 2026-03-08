<#
.SYNOPSIS
    UHDC Web-Ready Tool: SoftwareInventoryAudit.ps1
.DESCRIPTION
    Remotely queries the target computer's registry to compile a list of installed software.
    Supports partial keyword matching. Bypasses the slow Win32_Product WMI class.
    Attempts WinRM first. If blocked by firewall, falls back to a Base64-encoded
    payload executed via PsExec as SYSTEM.
    Outputs a styled HTML table for the web dashboard.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser, # Unused here, but passed by AppLogic

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [string]$Keyword, # Passed via ExtraArgs from the Web UI

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# ====================================================================
# TRAINING DATA EXPORT (For Web UI Modal)
# ====================================================================
if ($GetTrainingData) {
    $data = @{
        StepName = "SOFTWARE INVENTORY AUDIT"
        Description = "We establish a remote WinRM session to query the target's registry. We specifically avoid the 'Win32_Product' WMI class because it is incredibly slow and triggers MSI reconfigurations. Instead, we rapidly read the 64-bit and 32-bit 'Uninstall' registry hives to pull the exact Display Name, Version, and Publisher. If the local firewall blocks WinRM, we automatically fall back to PsExec, passing a Base64-encoded PowerShell payload to safely extract the inventory as the SYSTEM account."
        Code = "try { `$json = Invoke-Command -ComputerName `$Target -ScriptBlock `$Payload } catch { `$json = psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Opening the Control Panel, navigating to 'Programs and Features' (appwiz.cpl), and scrolling through the list of installed applications."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] SOFTWARE INVENTORY AUDIT"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

# 1. Fast Ping Check
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = if ($Keyword) { "Software Audit Executed (Keyword: $Keyword)" } else { "Software Audit Executed (Full)" }

# 2. Define the core payload to extract software data as a JSON string
$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'
    `$Keyword = '$Keyword'

    # Define the 64-bit and 32-bit registry paths
    `$paths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    `$installed = Get-ItemProperty `$paths | 
        Where-Object { `$_.DisplayName -and `$_.SystemComponent -ne 1 -and `$_.ParentKeyName -eq `$null } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate

    if (-not [string]::IsNullOrWhiteSpace(`$Keyword)) {
        `$installed = `$installed | Where-Object { `$_.DisplayName -match `$Keyword -or `$_.Publisher -match `$Keyword }
    }

    # Deduplicate and sort
    `$installed = `$installed | Sort-Object DisplayName -Unique

    `$results = @()
    if (`$installed) {
        foreach (`$app in `$installed) {
            `$results += [PSCustomObject]@{
                Name      = `$app.DisplayName
                Version   = if (`$app.DisplayVersion) { `$app.DisplayVersion } else { 'N/A' }
                Publisher = if (`$app.Publisher) { `$app.Publisher } else { 'Unknown' }
            }
        }
    }

    # Compress to a single line and wrap in delimiters for safe extraction
    `$json = @(`$results) | ConvertTo-Json -Compress
    Write-Output `"---JSON_START---`$json---JSON_END---`"
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)
$RawOutputString = $null
$MethodUsed = "WinRM"

# 3. Execute Remote Query
try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
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
            Write-Output "    Details: $($_.Exception.Message)"
            return
        }
    } else {
        Write-Output "`n[!] FATAL ERROR: WinRM failed and psexec.exe is missing from \Core."
        return
    }
}

# 4. Process Data and Generate HTML
if ($RawOutputString -match '---JSON_START---(.*?)---JSON_END---') {
    try {
        $appData = $matches[1] | ConvertFrom-Json
        if ($appData -isnot [System.Array]) { $appData = @($appData) }

        if ($appData.Count -gt 0) {
            Write-Output "`n[UHDC SUCCESS] Found $($appData.Count) installed applications via $MethodUsed."

            # Build the HTML Payload
            $html = "<div style='margin-top: 15px; margin-bottom: 15px; max-height: 400px; overflow-y: auto; border: 1px solid #334155; border-radius: 8px; background: #0f172a; box-shadow: 0 4px 6px rgba(0,0,0,0.2);'>"
            $html += "<table style='width: 100%; border-collapse: collapse; font-family: system-ui, sans-serif; font-size: 0.85rem; text-align: left;'>"

            # Table Header (Sticky)
            $html += "<thead style='position: sticky; top: 0; background: #1e293b; color: #38bdf8; box-shadow: 0 2px 4px rgba(0,0,0,0.5);'>"
            $html += "<tr>"
            $html += "<th style='padding: 10px; border-bottom: 2px solid #334155; width: 50%;'>Application Name</th>"
            $html += "<th style='padding: 10px; border-bottom: 2px solid #334155; width: 20%;'>Version</th>"
            $html += "<th style='padding: 10px; border-bottom: 2px solid #334155; width: 30%;'>Publisher</th>"
            $html += "</tr></thead><tbody>"

            foreach ($app in $appData) {
                # [CRITICAL FIX] Sanitize HTML inputs to prevent XSS injections from malicious registry keys
                $safeName = $app.Name -replace '<', '&lt;' -replace '>', '&gt;'
                $safeVersion = $app.Version -replace '<', '&lt;' -replace '>', '&gt;'
                $safePublisher = $app.Publisher -replace '<', '&lt;' -replace '>', '&gt;'

                $html += "<tr style='border-bottom: 1px solid #1e293b;'>"
                $html += "<td style='padding: 8px; color: #f8fafc; font-weight: 500;'>$safeName</td>"
                $html += "<td style='padding: 8px; color: #2ecc71; font-family: Consolas, monospace;'>$safeVersion</td>"
                $html += "<td style='padding: 8px; color: #94a3b8;'>$safePublisher</td>"
                $html += "</tr>"
            }

            $html += "</tbody></table></div>"

            # Output the raw HTML directly into the telemetry stream
            Write-Output $html

            # --- AUDIT LOG INJECTION ---
            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) {
                    & $AuditHelper -Target $Target -Action $ActionLog -SharedRoot $SharedRoot
                }
            }
        } else {
            Write-Output "`n[i] No matching software found."
        }
    } catch {
        Write-Output "`n[!] ERROR: Failed to parse software data JSON."
    }
} else {
    Write-Output "`n[!] ERROR: No valid software data returned from target."
}