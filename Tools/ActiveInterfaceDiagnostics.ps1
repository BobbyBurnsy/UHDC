<#
.SYNOPSIS
    UHDC Web-Ready Tool: ActiveInterfaceDiagnostics.ps1
.DESCRIPTION
    Remotely queries the target for active network adapters (Status=Up).
    It filters out loopback/APIPA addresses and correlates IPv4 addresses with
    Interface Descriptions, MAC Addresses, and Link Speeds.
    Attempts WinRM first. If blocked by firewall, falls back to a Base64-encoded
    payload executed via PsExec as SYSTEM.
    Outputs a styled HTML payload for the web dashboard.
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
        StepName = "ACTIVE INTERFACE DIAGNOSTICS"
        Description = "We establish a remote WinRM session to query the target's active network adapters and IPv4 addresses. We filter out disconnected adapters, loopback addresses (127.0.0.1), and APIPA addresses (169.254.x.x), then correlate the valid IP to its physical MAC address and negotiated link speed. If the local firewall blocks WinRM, we automatically fall back to PsExec, passing a Base64-encoded PowerShell payload to safely extract the network telemetry as the SYSTEM account."
        Code = "try { `$json = Invoke-Command -ComputerName `$Target -ScriptBlock `$Payload } catch { `$json = psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Open an elevated Command Prompt and type 'ipconfig /all', or press Win+R, type 'ncpa.cpl' (Network Connections), double-click the active adapter, and click 'Details...'."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] ACTIVE INTERFACE DIAGNOSTICS"
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

$ActionLog = "Active Interface Diagnostics Executed"

# 2. Define the core payload to extract network data as a JSON string
$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'
    `$adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
    `$ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -notmatch '169.254|127.0'

    `$results = @()
    foreach (`$ip in `$ips) {
        `$matchAdapter = `$adapters | Where-Object Name -eq `$ip.InterfaceAlias
        `$results += [PSCustomObject]@{
            Adapter = `$ip.InterfaceAlias
            Desc    = if (`$matchAdapter) { `$matchAdapter.InterfaceDescription } else { 'Unknown' }
            IP      = `$ip.IPAddress
            MAC     = if (`$matchAdapter) { `$matchAdapter.MacAddress } else { 'N/A' }
            Speed   = if (`$matchAdapter) { `$matchAdapter.LinkSpeed } else { 'N/A' }
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
            # Safely encode the payload to Base64 for PS 5.1 execution
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            $ArgsList = "/accepteula \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"

            # Capture output and filter out PsExec banner noise
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
        $netData = $matches[1] | ConvertFrom-Json

        # Ensure it's an array even if only one adapter was found
        if ($netData -isnot [System.Array]) { $netData = @($netData) }

        if ($netData.Count -gt 0) {
            Write-Output "`n[UHDC SUCCESS] Network interfaces retrieved via $MethodUsed!`n"

            # Build the HTML Payload
            $html = "<div style='display: flex; flex-direction: column; gap: 12px; margin-top: 10px; margin-bottom: 10px;'>"

            foreach ($nic in $netData) {
                # Dynamically choose the icon based on the adapter description
                $icon = "fa-network-wired"
                if ($nic.Desc -match "Wi-Fi|Wireless|802\.11|WLAN") { $icon = "fa-wifi" }

                $html += "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid #3498db; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
                $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 12px;'><i class='fa-solid $icon'></i> $($nic.Adapter)</div>"

                $html += "<div style='display: grid; grid-template-columns: 100px 1fr; gap: 8px; font-size: 0.9rem;'>"

                $html += "<span style='color: #94a3b8;'>Description:</span>"
                $html += "<span style='color: #cbd5e1;'>$($nic.Desc)</span>"

                $html += "<span style='color: #94a3b8;'>IPv4 Address:</span>"
                $html += "<span style='color: #2ecc71; font-weight: bold;'>$($nic.IP)</span>"

                $html += "<span style='color: #94a3b8;'>MAC Address:</span>"
                $html += "<span style='color: #cbd5e1; font-family: Consolas, monospace;'>$($nic.MAC)</span>"

                $html += "<span style='color: #94a3b8;'>Link Speed:</span>"
                $html += "<span style='color: #cbd5e1;'>$($nic.Speed)</span>"

                $html += "</div></div>"
            }

            $html += "</div>"

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
            Write-Output "`n[i] No active IPv4 interfaces found."
        }
    } catch {
        Write-Output "`n[!] ERROR: Failed to parse network data JSON."
        Write-Output "    Details: $($_.Exception.Message)"
    }
} else {
    Write-Output "`n[!] ERROR: No valid network data returned from target."
}