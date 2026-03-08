<#
.SYNOPSIS
    UHDC Web-Ready Tool: LocalPrivilegeAuditing.ps1
.DESCRIPTION
    Remotely queries the target computer to list all members of the local
    "Administrators" group, displaying their Name, Type (User/Group), and Source (Local/AD).
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
        StepName = "LOCAL PRIVILEGE AUDITING"
        Description = "We establish a WinRM session to query the local SAM (Security Account Manager) database of the target machine. We specifically target the built-in 'Administrators' group and return its members, identifying whether they are local accounts or Active Directory objects. If the local firewall blocks WinRM, we automatically fall back to PsExec, passing a Base64-encoded PowerShell payload to safely extract the audit data as the SYSTEM account."
        Code = "try { `$json = Invoke-Command -ComputerName `$Target -ScriptBlock `$Payload } catch { `$json = psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }"
        InPerson = "Right-click the Start Menu, select 'Computer Management' (compmgmt.msc), expand 'Local Users and Groups', click 'Groups', and double-click the 'Administrators' group to view its members."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] LOCAL PRIVILEGE AUDITING"
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

$ActionLog = "Local Privilege Audit Executed"

# 2. Define the core payload to extract admin data as a JSON string
$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'
    `$admins = Get-LocalGroupMember -Group 'Administrators'

    `$results = @()
    foreach (`$admin in `$admins) {
        `$results += [PSCustomObject]@{
            Name   = `$admin.Name
            Source = `$admin.PrincipalSource
            Type   = `$admin.ObjectClass
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
        $adminData = $matches[1] | ConvertFrom-Json

        # Ensure it's an array even if only one admin was found
        if ($adminData -isnot [System.Array]) { $adminData = @($adminData) }

        if ($adminData.Count -gt 0) {
            Write-Output "`n[UHDC SUCCESS] Local Administrators retrieved via $MethodUsed!`n"

            # Build the HTML Payload
            $html = "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid #e74c3c; margin-top: 10px; margin-bottom: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
            $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 16px;'><i class='fa-solid fa-user-shield'></i> Local Administrators Group</div>"

            $html += "<div style='display: flex; flex-direction: column; gap: 8px;'>"

            foreach ($admin in $adminData) {
                # [CRITICAL FIX] Sanitize HTML inputs to prevent XSS injections
                $safeName = $admin.Name -replace '<', '&lt;' -replace '>', '&gt;'
                $safeSource = $admin.Source -replace '<', '&lt;' -replace '>', '&gt;'

                # Determine Icon based on Type
                $icon = "fa-user"
                if ($admin.Type -match "Group") { $icon = "fa-users" }

                # Determine Color based on Source
                $sourceColor = "#94a3b8" # Default Gray for Local
                if ($admin.Source -match "ActiveDirectory") { $sourceColor = "#3498db" } # Blue for AD
                elseif ($admin.Source -match "MicrosoftAccount") { $sourceColor = "#2ecc71" } # Green for MSA

                $html += "<div style='display: grid; grid-template-columns: 30px 1fr 120px; align-items: center; background: #0f172a; padding: 10px 12px; border-radius: 6px; border: 1px solid #334155;'>"
                $html += "<div style='color: #cbd5e1;'><i class='fa-solid $icon'></i></div>"
                $html += "<div style='color: #f8fafc; font-weight: 500; font-size: 0.95rem; word-break: break-all;'>$safeName</div>"
                $html += "<div style='color: $sourceColor; font-size: 0.8rem; text-align: right; font-weight: bold; text-transform: uppercase;'>$safeSource</div>"
                $html += "</div>"
            }

            $html += "</div></div>"

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
            Write-Output "`n[i] No members found in the Administrators group."
        }
    } catch {
        Write-Output "`n[!] ERROR: Failed to parse administrator data JSON."
        Write-Output "    Details: $($_.Exception.Message)"
    }
} else {
    Write-Output "`n[!] ERROR: No valid administrator data returned from target."
}