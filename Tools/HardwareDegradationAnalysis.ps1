<#
.SYNOPSIS
    UHDC Web-Ready Tool: HardwareDegradationAnalysis.ps1
.DESCRIPTION
    Queries the raw WMI/CIM battery classes to extract exact milliwatt-hour (mWh) metrics. 
    It calculates the degradation percentage and outputs a styled HTML payload.
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
        StepName = "HARDWARE DEGRADATION ANALYSIS"
        Description = "Instead of generating a clunky HTML file, we establish a remote WinRM session to query the raw WMI/CIM classes ('BatteryStaticData' and 'BatteryFullChargedCapacity'). We extract the exact milliwatt-hour (mWh) metrics, calculate the degradation percentage, and render a graphical health bar directly in the console."
        Code = "try { `$json = Invoke-Command -ComputerName `$Target -ScriptBlock `$Payload } catch { `$json = psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Opening an elevated Command Prompt, typing 'powercfg /batteryreport', opening the generated HTML file, and manually doing the math between Design Capacity and Full Charge Capacity."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[UHDC] HARDWARE DEGRADATION ANALYSIS"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "Hardware Degradation Analysis Executed"

$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'

    `$static = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData
    `$full = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity

    `$results = @()
    if (`$static -and `$full) {
        for (`$i=0; `$i -lt `$static.Count; `$i++) {
            `$d = `$static[`$i].DesignedCapacity
            `$f = `$full[`$i].FullChargedCapacity
            `$results += [PSCustomObject]@{ Design = `$d; Full = `$f }
        }
    }

    `$json = @(`$results) | ConvertTo-Json -Compress
    Write-Output `"---JSON_START---`$json---JSON_END---`"
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)
$RawOutputString = $null
$MethodUsed = "WinRM"

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
            return
        }
    } else {
        Write-Output "`n[!] FATAL ERROR: WinRM failed and psexec.exe is missing from \Core."
        return
    }
}

if ($RawOutputString -match '---JSON_START---(.*?)---JSON_END---') {
    try {
        $batteryData = $matches[1] | ConvertFrom-Json
        if ($batteryData -isnot [System.Array]) { $batteryData = @($batteryData) }

        if ($batteryData.Count -gt 0) {
            Write-Output "`n[UHDC SUCCESS] Battery telemetry retrieved via $MethodUsed!`n"

            $html = "<div style='display: flex; flex-direction: column; gap: 12px; margin-top: 10px; margin-bottom: 10px;'>"

            foreach ($bat in $batteryData) {
                $design = $bat.Design
                $full = $bat.Full

                if ($design -eq 0) { $design = 1 }

                $healthPct = [math]::Round(($full / $design) * 100, 1)
                if ($healthPct -gt 100) { $healthPct = 100 }

                $barColor = "#2ecc71"
                if ($healthPct -lt 75) { $barColor = "#f1c40f" }
                if ($healthPct -lt 50) { $barColor = "#e74c3c" }

                $html += "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid $barColor; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
                $html += "<div style='color: #f8fafc; font-weight: bold; margin-bottom: 12px; font-size: 1.1rem;'><i class='fa-solid fa-battery-half'></i> Hardware Battery Health</div>"
                $html += "<div style='display: flex; justify-content: space-between; margin-bottom: 6px; font-size: 0.9rem;'>"
                $html += "<span style='color: #94a3b8;'>Design Capacity:</span><span style='color: #f8fafc;'>$($design.ToString('N0')) mWh</span></div>"
                $html += "<div style='display: flex; justify-content: space-between; margin-bottom: 12px; font-size: 0.9rem;'>"
                $html += "<span style='color: #94a3b8;'>Full Charge Capacity:</span><span style='color: #f8fafc;'>$($full.ToString('N0')) mWh</span></div>"
                $html += "<div style='width: 100%; background: #0f172a; border-radius: 6px; height: 10px; overflow: hidden; margin-bottom: 8px;'>"
                $html += "<div style='width: $($healthPct)%; background: $barColor; height: 100%; border-radius: 6px;'></div></div>"
                $html += "<div style='text-align: right; color: $barColor; font-weight: bold; font-size: 0.95rem;'>$healthPct% Health</div></div>"
            }

            $html += "</div>"
            Write-Output $html

            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) {
                    & $AuditHelper -Target $Target -Action $ActionLog -SharedRoot $SharedRoot
                }
            }
        } else {
            Write-Output "`n[i] No battery data found. (Is this a desktop PC?)"
        }
    } catch {
        Write-Output "`n[!] ERROR: Failed to parse battery data JSON."
    }
} else {
    Write-Output "`n[!] ERROR: No valid battery data returned from target. (Is this a desktop PC?)"
}
