<#
.SYNOPSIS
    UHDC Web-Ready Tool: AutomatedWarrantyRouting.ps1
.DESCRIPTION
    Queries the target computer's WMI/CIM repository for its Make and Serial Number,
    then automatically constructs the correct vendor support/warranty webpage URL.
    Attempts WinRM first. If blocked by firewall, falls back to a Base64-encoded
    payload executed via PsExec as SYSTEM.
    Outputs a styled HTML card with a clickable link for the web dashboard.
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
        StepName = "AUTOMATED WARRANTY ROUTING"
        Description = "We establish a remote WinRM session to query the target computer's motherboard (Win32_BIOS) for its embedded Serial Number/Service Tag, and the system enclosure (Win32_ComputerSystem) for the Manufacturer (Make). We then use that data to dynamically generate a direct link to the vendor's warranty portal. If the local firewall blocks WinRM, we automatically fall back to PsExec, passing a Base64-encoded PowerShell payload to safely extract the hardware telemetry as the SYSTEM account."
        Code = "try { `$json = Invoke-Command -ComputerName `$Target -ScriptBlock `$Payload } catch { `$json = psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Flipping the laptop over to read the tiny printed sticker on the bottom chassis, opening a web browser, navigating to the vendor's support page, and manually typing the alphanumeric serial number into the search box."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] AUTOMATED WARRANTY ROUTING"
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

$ActionLog = "Automated Warranty Routing Executed"

# 2. Define the core payload to extract hardware data as a JSON string
$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'

    `$bios = Get-CimInstance -ClassName Win32_BIOS
    `$cs   = Get-CimInstance -ClassName Win32_ComputerSystem

    `$results = @()
    if (`$bios -and `$cs) {
        `$results += [PSCustomObject]@{
            Make   = `$cs.Manufacturer
            Serial = `$bios.SerialNumber
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
        $hwData = $matches[1] | ConvertFrom-Json

        # Ensure it's an array
        if ($hwData -isnot [System.Array]) { $hwData = @($hwData) }

        if ($hwData.Count -gt 0) {
            Write-Output "`n[UHDC SUCCESS] Hardware telemetry retrieved via $MethodUsed!`n"

            $make   = $hwData[0].Make.Trim()
            $serial = $hwData[0].Serial.Trim()

            # 5. URL Construction Logic
            $url = ""
            $vendorColor = "#3498db" # Default Blue

            # Dell Logic
            if ($make -match "Dell") {
                $url = "https://www.dell.com/support/home/en-us/product-support/servicetag/$serial/overview"
                $vendorColor = "#0076ce" # Dell Blue
            }
            # Lenovo Logic
            elseif ($make -match "Lenovo") {
                $url = "https://pcsupport.lenovo.com/us/en/search?query=$serial"
                $vendorColor = "#e2231a" # Lenovo Red
            }
            # HP Logic
            elseif ($make -match "HP|Hewlett-Packard") {
                $url = "https://support.hp.com/us-en/check-warranty"
                $vendorColor = "#0096d6" # HP Blue
            }
            # Microsoft Surface Logic
            elseif ($make -match "Microsoft") {
                $url = "https://mybusinessservice.surface.com/"
                $vendorColor = "#737373" # MS Gray
            }

            # 6. Build the HTML Payload
            $html = "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid $vendorColor; margin-top: 10px; margin-bottom: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
            $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 12px;'><i class='fa-solid fa-laptop-medical'></i> Hardware Warranty Lookup</div>"

            $html += "<div style='display: grid; grid-template-columns: 80px 1fr; gap: 8px; font-size: 0.95rem; margin-bottom: 16px;'>"
            $html += "<span style='color: #94a3b8;'>Make:</span><span style='color: #cbd5e1;'>$make</span>"
            $html += "<span style='color: #94a3b8;'>Serial:</span><span style='color: #2ecc71; font-weight: bold; font-family: Consolas, monospace; letter-spacing: 1px;'>$serial</span>"
            $html += "</div>"

            if ($url) {
                $html += "<a href='$url' target='_blank' style='display: inline-block; background: $vendorColor; color: white; padding: 8px 16px; border-radius: 4px; text-decoration: none; font-weight: bold; font-size: 0.9rem; transition: opacity 0.2s;' onmouseover='this.style.opacity=0.8' onmouseout='this.style.opacity=1'><i class='fa-solid fa-external-link-alt'></i> Open Vendor Portal</a>"
                if ($make -match "Microsoft") {
                    $html += "<div style='color: #f1c40f; font-size: 0.8rem; margin-top: 8px;'><i class='fa-solid fa-triangle-exclamation'></i> Note: Microsoft requires admin login to view Surface warranties.</div>"
                }
            } else {
                $html += "<div style='color: #e74c3c; font-size: 0.9rem;'><i class='fa-solid fa-circle-xmark'></i> Auto-detect failed for vendor. Please look up the serial number manually.</div>"
            }

            $html += "</div>"

            # Output the raw HTML directly into the telemetry stream
            Write-Output $html

            # --- AUDIT LOG INJECTION ---
            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) {
                    & $AuditHelper -Target $Target -Action "Checked Warranty ($make - Serial: $serial)" -SharedRoot $SharedRoot
                }
            }
            # ---------------------------
        } else {
            Write-Output "`n[i] No hardware data found."
        }
    } catch {
        Write-Output "`n[!] ERROR: Failed to parse hardware data JSON."
        Write-Output "    Details: $($_.Exception.Message)"
    }
} else {
    Write-Output "`n[!] ERROR: No valid hardware data returned from target."
}