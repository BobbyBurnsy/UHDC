<#
.SYNOPSIS
    UHDC Web-Ready Tool: ZeroTouchSoftwareDeployment.ps1
.DESCRIPTION
    Acts as a backend controller for the Zero-Touch Deployment Library UI.
    Supports single and mass deployments via WinRM and PsExec.
    Includes Wake-on-LAN (WoL) functionality for offline targets.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [string]$Action = "Install",

    [Parameter(Mandatory=$false)]
    [string]$AppName,

    [Parameter(Mandatory=$false)]
    [string]$AppPath,

    [Parameter(Mandatory=$false)]
    [string]$AppArgs,

    [Parameter(Mandatory=$false)]
    [string]$AppID,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# --- Wake-on-LAN Helper ---
function Send-MagicPacket {
    param([string]$MacAddress)
    try {
        $cleanMac = $MacAddress -replace '[:-]',''
        $macByteArray = [byte[]]($cleanMac -split '(.{2})' -ne '' | ForEach-Object { [convert]::ToByte($_, 16) })
        $magicPacket = [byte[]](,0xFF * 6) + ($macByteArray * 16)

        $udpClient = New-Object System.Net.Sockets.UdpClient
        $udpClient.Connect([System.Net.IPAddress]::Broadcast, 9)
        $udpClient.Send($magicPacket, $magicPacket.Length) | Out-Null
        $udpClient.Close()
        return $true
    } catch { return $false }
}

# --- Export Training Data ---
if ($GetTrainingData) {
    $data = @{
        StepName = "ZERO-TOUCH SOFTWARE DEPLOYMENT"
        Description = "While the UHDC uses WMI and PowerShell runspaces to deploy software asynchronously, a junior technician should know how to push an installer manually. By utilizing Sysinternals PsExec, you can remotely execute an installer as the SYSTEM account. This bypasses the 'Double-Hop' authentication issue, allowing the target machine's computer account to pull the installer directly from a network share and install it silently in the background."
        Code = "psexec \\`$Target -s msiexec.exe /i `"\\server\share\installer.msi`" /qn /norestart"
        InPerson = "Walking desk to desk with a flash drive, copying the installer to the desktop, and clicking through the installation wizard. Alternatively, opening an elevated command prompt and typing the silent install command."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Library Management ---
$LibraryFile = Join-Path -Path $SharedRoot -ChildPath "Core\SoftwareLibrary.json"
$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"

function Load-Lib {
    if (Test-Path $LibraryFile) {
        try {
            $raw = Get-Content $LibraryFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -eq $raw) { return @() }
            if ($raw -is [System.Array]) { return $raw } else { return @($raw) }
        } catch { return @() }
    } else { 
        $default = @(
            [PSCustomObject]@{ ID=1; Name="Google Chrome (Enterprise)"; Path="\\server\share\Software\GoogleChromeStandaloneEnterprise64.msi"; Args="/qn /norestart" }
        )
        $default | ConvertTo-Json -Depth 2 | Set-Content $LibraryFile -Force
        return $default
    }
}

function Save-Lib {
    param($d)
    $d | ConvertTo-Json -Depth 2 | Set-Content $LibraryFile -Force
}

if ($Action -eq "GetLibrary") {
    $lib = Load-Lib
    $lib | ConvertTo-Json -Depth 2 | Write-Output
    return
}

if ($Action -eq "AddApp") {
    $lib = Load-Lib
    $newID = if ($lib.Count -gt 0) { ([int]($lib | Select-Object -ExpandProperty ID | Measure-Object -Maximum).Maximum) + 1 } else { 1 }
    $lib += [PSCustomObject]@{ ID=$newID; Name=$AppName.Trim(); Path=$AppPath.Trim(); Args=$AppArgs.Trim() }
    Save-Lib $lib
    Write-Output "[UHDC] [+] Added '$AppName' to the central Software Library."
    return
}

if ($Action -eq "DeleteApp") {
    $lib = Load-Lib
    $lib = $lib | Where-Object { $_.ID -ne [int]$AppID }
    Save-Lib $lib
    Write-Output "[UHDC] [-] Application removed from the central Software Library."
    return
}

# --- Main Execution ---
if ($Action -eq "Install") {

    if ([string]::IsNullOrWhiteSpace($Target)) { 
        Write-Output "[!] ERROR: Target PC(s) required."
        return 
    }

    $SafeAppName = $AppName -replace '<', '&lt;' -replace '>', '&gt;'
    $TargetArray = @($Target -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $PayloadString = @"
        `$ErrorActionPreference = 'SilentlyContinue'
        `$proc = Start-Process -FilePath `"$AppPath`" -ArgumentList `"$AppArgs`" -Wait -WindowStyle Hidden -PassThru
        if (`$proc) { Write-Output `"EXIT_CODE:`$(`$proc.ExitCode)`" }
"@

    $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
    $EncodedCommand = [Convert]::ToBase64String($Bytes)
    $wmiPayload = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    # --- Single Target Deployment ---
    if ($TargetArray.Count -eq 1) {
        $SingleTarget = $TargetArray[0]
        Write-Output "========================================"
        Write-Output "[UHDC] ZERO-TOUCH DEPLOYMENT"
        Write-Output "========================================"
        Write-Output "[i] Deploying $SafeAppName to $SingleTarget..."

        if (-not (Test-Connection -ComputerName $SingleTarget -Count 1 -Quiet)) { 
            Write-Output "[!] $SingleTarget is offline. Attempting Wake-on-LAN..."
            $Woken = $false
            if (Test-Path $HistoryFile) {
                try {
                    $dbRaw = Get-Content $HistoryFile -Raw -ErrorAction Stop | ConvertFrom-Json
                    if ($dbRaw -isnot [System.Array]) { $dbRaw = @($dbRaw) }
                } catch {
                    $dbRaw = @()
                    Write-Output " > [!] Telemetry DB locked or unavailable. Skipping WoL."
                }

                $dbEntry = $dbRaw | Where-Object { $_.Computer -eq $SingleTarget -and $_.MACAddress -ne $null } | Select-Object -First 1
                if ($dbEntry) {
                    Write-Output " > Sending Magic Packet to $($dbEntry.MACAddress)..."
                    Send-MagicPacket -MacAddress $dbEntry.MACAddress | Out-Null
                    Write-Output " > Waiting 45 seconds for boot..."
                    Start-Sleep -Seconds 45
                    if (Test-Connection -ComputerName $SingleTarget -Count 1 -Quiet) {
                        Write-Output " > [SUCCESS] Target is now awake!"
                        $Woken = $true
                    }
                } else { Write-Output " > [i] No MAC address found in telemetry. Cannot wake." }
            }

            if (-not $Woken) {
                Write-Output "[!] Target remains offline. Aborting deployment."
                return 
            }
        }

        try {
            Write-Output " > Initiating background installation via WinRM..."
            Invoke-Command -ComputerName $SingleTarget -ScriptBlock {
                param($cmd)
                Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd } | Out-Null
            } -ArgumentList $wmiPayload -ErrorAction Stop
            Write-Output "`n[UHDC SUCCESS] Deployment dispatched successfully via WinRM."
        } catch {
            Write-Output "[!] WinRM Failed. Initiating PsExec Fallback..."
            if (Test-Path $psExecPath) {
                try {
                    $ArgsList = "/accepteula \\$SingleTarget -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"

                    $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru
                    if ($Process.ExitCode -eq 0) { Write-Output "`n[UHDC SUCCESS] Deployment dispatched successfully via PsExec." } 
                    else { Write-Output "`n[!] ERROR: PsExec returned exit code $($Process.ExitCode)." }
                } catch { Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed." }
            } else { Write-Output "`n[!] FATAL ERROR: psexec.exe is missing from \Core." }
        }

        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) { & $AuditHelper -Target $SingleTarget -Action "Deployed Software: $AppName" -SharedRoot $SharedRoot }
        }
        return
    }

    # --- Mass Deployment ---
    Write-Output "========================================"
    Write-Output "[UHDC] MASS ZERO-TOUCH DEPLOYMENT"
    Write-Output "========================================"
    Write-Output "[i] Application: $SafeAppName"
    Write-Output "[i] Total Targets: $($TargetArray.Count)"

    $Online = @(); $Offline = @(); $Woken = @(); $SuccessWinRM = @(); $SuccessPsExec = @(); $Failed = @()

    Write-Output "`n[1/4] Performing rapid ping sweep..."
    foreach ($t in $TargetArray) {
        if (Test-Connection -ComputerName $t -Count 1 -Quiet) { $Online += $t } else { $Offline += $t }
    }
    Write-Output " > Online: $($Online.Count) | Offline: $($Offline.Count)"

    if ($Offline.Count -gt 0 -and (Test-Path $HistoryFile)) {
        Write-Output "`n[2/4] Attempting Wake-on-LAN for offline targets..."
        try {
            $dbRaw = Get-Content $HistoryFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($dbRaw -isnot [System.Array]) { $dbRaw = @($dbRaw) }
        } catch {
            $dbRaw = @()
            Write-Output " > [!] Telemetry DB locked or unavailable. Skipping WoL."
        }

        $WokeSomeone = $false

        foreach ($offPC in $Offline) {
            $dbEntry = $dbRaw | Where-Object { $_.Computer -eq $offPC -and $_.MACAddress -ne $null } | Select-Object -First 1
            if ($dbEntry) {
                Write-Output " > Sending Magic Packet to $offPC ($($dbEntry.MACAddress))..."
                Send-MagicPacket -MacAddress $dbEntry.MACAddress | Out-Null
                $WokeSomeone = $true
            } else {
                Write-Output " > [i] No MAC address found in telemetry for $offPC."
            }
        }

        if ($WokeSomeone) {
            Write-Output " > Waiting 45 seconds for machines to boot..."
            Start-Sleep -Seconds 45

            $StillOffline = @()
            foreach ($offPC in $Offline) {
                if (Test-Connection -ComputerName $offPC -Count 1 -Quiet) {
                    Write-Output " > [SUCCESS] $offPC is now awake!"
                    $Online += $offPC
                    $Woken += $offPC
                } else {
                    $StillOffline += $offPC
                }
            }
            $Offline = $StillOffline
        }
    } else {
        Write-Output "`n[2/4] Skipping Wake-on-LAN (No offline targets or DB missing)."
    }

    if ($Online.Count -gt 0) {
        Write-Output "`n[3/4] Dispatching parallel WinRM commands..."

        $WinRMJob = Invoke-Command -ComputerName $Online -ScriptBlock {
            param($cmd)
            Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd } | Out-Null
        } -ArgumentList $wmiPayload -ErrorVariable WinRMErrors -ErrorAction SilentlyContinue -AsJob

        Wait-Job $WinRMJob | Out-Null
        $JobResults = Receive-Job $WinRMJob
        Remove-Job $WinRMJob -Force

        $FailedWinRM = @()
        foreach ($err in $WinRMErrors) {
            if ($err.TargetObject) { $FailedWinRM += $err.TargetObject.ToString().ToUpper() }
        }

        foreach ($t in $Online) {
            if ($FailedWinRM -contains $t.ToUpper()) { $FailedWinRM += $t } 
            else { $SuccessWinRM += $t }
        }

        Write-Output " > WinRM Success: $($SuccessWinRM.Count) | WinRM Blocked: $($FailedWinRM.Count)"

        if ($FailedWinRM.Count -gt 0) {
            Write-Output "`n[4/4] Initiating PsExec fallback for blocked targets..."
            if (Test-Path $psExecPath) {
                foreach ($t in $FailedWinRM) {
                    try {
                        $ArgsList = "/accepteula \\$t -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
                        $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru
                        if ($Process.ExitCode -eq 0) { $SuccessPsExec += $t } else { $Failed += $t }
                    } catch { $Failed += $t }
                }
            } else {
                Write-Output " > [!] psexec.exe missing. Cannot process fallbacks."
                $Failed += $FailedWinRM
            }
        }
    }

    $TotalSuccess = $SuccessWinRM.Count + $SuccessPsExec.Count
    $html = "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid #9b59b6; margin-top: 15px; margin-bottom: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
    $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 12px;'><i class='fa-solid fa-network-wired'></i> Mass Deployment Report</div>"

    $html += "<div style='display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 10px;'>"
    $html += "<div style='background: #0f172a; padding: 10px; border-radius: 6px; border: 1px solid #334155;'><span style='color: #94a3b8; font-size: 0.85rem;'>Total Targets</span><br><span style='color: #f8fafc; font-size: 1.2rem; font-weight: bold;'>$($TargetArray.Count)</span></div>"
    $html += "<div style='background: #0f172a; padding: 10px; border-radius: 6px; border: 1px solid #334155;'><span style='color: #94a3b8; font-size: 0.85rem;'>Successful Dispatches</span><br><span style='color: #2ecc71; font-size: 1.2rem; font-weight: bold;'>$TotalSuccess</span></div>"
    $html += "</div>"

    if ($Woken.Count -gt 0) { $html += "<div style='color: #3498db; font-size: 0.85rem; margin-top: 8px;'><i class='fa-solid fa-power-off'></i> <strong>$($Woken.Count) Woken via WoL:</strong> $($Woken -join ', ')</div>" }
    if ($Offline.Count -gt 0) { $html += "<div style='color: #e74c3c; font-size: 0.85rem; margin-top: 8px;'><i class='fa-solid fa-triangle-exclamation'></i> <strong>$($Offline.Count) Offline:</strong> $($Offline -join ', ')</div>" }
    if ($Failed.Count -gt 0) { $html += "<div style='color: #f1c40f; font-size: 0.85rem; margin-top: 8px;'><i class='fa-solid fa-circle-xmark'></i> <strong>$($Failed.Count) Failed:</strong> $($Failed -join ', ')</div>" }

    $html += "</div>"
    Write-Output $html

    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target "MASS DEPLOY ($TotalSuccess PCs)" -Action "Deployed Software: $AppName" -SharedRoot $SharedRoot
        }
    }
}
