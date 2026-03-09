<#
.SYNOPSIS
    Unified Help Desk Console (UHDC) - HTML/API Engine (AppLogic.ps1)
#>

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " [UHDC] MICRO-API ENGINE INITIALIZING" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ------------------------------------------------------------------
# 1. PREREQUISITE FOLDER CHECKS
# ------------------------------------------------------------------
$RequiredFolders = @("Core", "Tools", "Logs", "Config", "TelemetryDrop")
foreach ($Folder in $RequiredFolders) {
    $FolderPath = Join-Path $ScriptRoot $Folder
    if (-not (Test-Path $FolderPath)) { 
        Write-Host "[+] Creating missing directory: $Folder" -ForegroundColor DarkGray
        New-Item -ItemType Directory -Path $FolderPath -Force | Out-Null 
    }
}

# ------------------------------------------------------------------
# 2. CONFIG.JSON AUTO-GENERATION
# ------------------------------------------------------------------
$ConfigPath = Join-Path $ScriptRoot "Config\config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[!] First run detected! Generating default config.json..." -ForegroundColor Yellow

    $Template = [ordered]@{
        Organization = @{
            CompanyName = "Acme Corp"
            TenantDomain = "acmecorp.com"
        }
        ActiveDirectory = @{
            ImportantGroups = @("VPN", "M365", "Admin", "License", "Finance")
        }
        AccessControl = @{
            MasterAdmins = @("Admin1", "Admin2")
            Trainees = @("NewHire1")
        }
    }
    $Template | ConvertTo-Json -Depth 3 | Out-File $ConfigPath -Force

    Write-Host "`n[ACTION REQUIRED] A default config.json has been created in the \Config folder." -ForegroundColor Red
    Write-Host "Please open it, enter your Tenant Domain, and restart this script." -ForegroundColor Red
    Pause; exit
}

# Load Configuration
$Global:Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$Global:TenantDomain = $Global:Config.Organization.TenantDomain
Write-Host "[OK] Configuration loaded for $($Global:Config.Organization.CompanyName)" -ForegroundColor Green

# ------------------------------------------------------------------
# 3. PSEXEC AUTO-DOWNLOAD
# ------------------------------------------------------------------
$psExecPath = Join-Path $ScriptRoot "Core\psexec.exe"
if (-not (Test-Path $psExecPath)) {
    Write-Host "[i] PsExec.exe missing. Downloading from Microsoft Sysinternals..." -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "https://live.sysinternals.com/psexec.exe" -OutFile $psExecPath -UseBasicParsing -ErrorAction Stop
        Unblock-File $psExecPath -ErrorAction SilentlyContinue
        Write-Host "[OK] PsExec downloaded successfully." -ForegroundColor Green
    } catch {
        Write-Host "[!] Failed to download PsExec. Please place it in \Core manually." -ForegroundColor Red
    }
}

# ------------------------------------------------------------------
# 4. START WEB SERVER & ORPHAN CLEANUP
# ------------------------------------------------------------------
$Port = 5050
$Url = "http://localhost:$Port/"
$HttpListener = New-Object System.Net.HttpListener
$HttpListener.Prefixes.Add($Url)

try {
    $HttpListener.Start()
} catch {
    Write-Host "[!] Port $Port is in use. Cleaning up orphaned UHDC processes..." -ForegroundColor Yellow
    $currentPID = $PID

    # Hunt down any other powershell.exe instances specifically running AppLogic.ps1
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | 
        Where-Object { $_.CommandLine -match "AppLogic.ps1" -and $_.ProcessId -ne $currentPID } | 
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    Start-Sleep -Seconds 2
    $HttpListener.Start()
}

Write-Host "[UHDC] Micro-API Engine Started on Port $Port" -ForegroundColor Cyan

# Pre-load Identity Module
Write-Host "[UHDC] Pre-loading Identity Module..." -ForegroundColor DarkGray
try {
    . (Join-Path $ScriptRoot "Core\IdentityMenu.ps1")
} catch {
    Write-Host "[!] Failed to load Identity Module. Cloud features disabled." -ForegroundColor Yellow
}

Write-Host "[UHDC] Rendering HTML Interface..." -ForegroundColor Cyan
Start-Process "msedge.exe" -ArgumentList "--app=$Url"

try {
    while ($HttpListener.IsListening) {
        $Context = $HttpListener.GetContext()
        $Request = $Context.Request
        $Response = $Context.Response

        if ($Request.Url.AbsolutePath -eq "/") {
            $HtmlPath = Join-Path $ScriptRoot "MainUI.html"
            $HtmlContent = Get-Content $HtmlPath -Raw
            $Buffer = [System.Text.Encoding]::UTF8.GetBytes($HtmlContent)
            $Response.ContentType = "text/html"
            $Response.ContentLength64 = $Buffer.Length
            $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
        }
        elseif ($Request.Url.AbsolutePath -eq "/api/telemetry" -and $Request.HttpMethod -eq "GET") {
            $MasterDB = Join-Path $ScriptRoot "Core\UserHistory.json"
            $JsonResponse = if (Test-Path $MasterDB) { Get-Content $MasterDB -Raw } else { '[]' }
            $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
            $Response.ContentType = "application/json"
            $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
        }

		# --- REMOTE ACCESS LAUNCHER ---
        elseif ($Request.Url.AbsolutePath -eq "/api/remote/connect" -and $Request.HttpMethod -eq "POST") {
            $StreamReader = New-Object System.IO.StreamReader $Request.InputStream
            $RequestBody = $StreamReader.ReadToEnd() | ConvertFrom-Json
            $Method = $RequestBody.Method 
            $TargetPC = $RequestBody.TargetPC

            Write-Host ">>> Launching $Method against $TargetPC..." -ForegroundColor Yellow

            $ResponseObj = @{ status = "success"; message = "" }

            try {
                switch ($Method) {
                    "SCCM" {
                        $sccmPath = "C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\i386\CmRcViewer.exe"
                        if (Test-Path $sccmPath) {
                            Start-Process $sccmPath -ArgumentList $TargetPC
                            $ResponseObj.message = "SCCM CmRcViewer launched for $TargetPC."
                        } else {
                            $ResponseObj.status = "error"
                            $ResponseObj.message = "CmRcViewer.exe not found. Is the SCCM Admin Console installed locally?"
                        }
                    }
                    "MSRA" {
                        Start-Process "msra.exe" -ArgumentList "/offerRA $TargetPC"
                        $ResponseObj.message = "MSRA Invitation sent to $TargetPC."
                    }
                    "TeamViewer" {
                        $tvPath = "C:\Program Files\TeamViewer\TeamViewer.exe"
                        if (Test-Path $tvPath) {
                            Start-Process $tvPath -ArgumentList "-i $TargetPC"
                            $ResponseObj.message = "TeamViewer launched targeting $TargetPC."
                        } else {
                            $ResponseObj.status = "error"
                            $ResponseObj.message = "TeamViewer.exe not found in standard directory."
                        }
                    }
                    "CShare" {
                        Start-Process "explorer.exe" -ArgumentList "\\$TargetPC\c$"
                        $ResponseObj.message = "Opened hidden C$ administrative share for $TargetPC."
                    }
                }
            } catch {
                $ResponseObj.status = "error"
                $ResponseObj.message = "Failed to launch remote tool: $($_.Exception.Message)"
            }

            $JsonResponse = $ResponseObj | ConvertTo-Json -Depth 3 -Compress
            $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
            $Response.ContentType = "application/json"
            $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
        }

        # --- FETCH TRAINING DATA ---
        elseif ($Request.Url.AbsolutePath -eq "/api/tools/training" -and $Request.HttpMethod -eq "POST") {
            $StreamReader = New-Object System.IO.StreamReader $Request.InputStream
            $RequestBody = $StreamReader.ReadToEnd() | ConvertFrom-Json
            $ScriptName = $RequestBody.Script
            $ExtraArgs = $RequestBody.ExtraArgs

            # Check both Tools and Core folders for the script
            $ScriptPath = Join-Path $ScriptRoot "Tools\$ScriptName"
            if (-not (Test-Path $ScriptPath)) { $ScriptPath = Join-Path $ScriptRoot "Core\$ScriptName" }

            if (Test-Path $ScriptPath) {
                try {
                    $Params = @{ GetTrainingData = $true }
                    if ($null -ne $ExtraArgs) {
                        foreach ($prop in $ExtraArgs.psobject.properties) {
                            $Params[$prop.Name] = $prop.Value
                        }
                    }
                    $RawOutput = & $ScriptPath @Params | Out-String
                    $JsonResponse = $RawOutput.Trim()
                } catch {
                    $JsonResponse = (@{ error = "Failed to load training data." } | ConvertTo-Json -Compress)
                }
            } else {
                $JsonResponse = (@{ error = "Script not found." } | ConvertTo-Json -Compress)
            }

            $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
            $Response.ContentType = "application/json"
            $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
        }

        # --- EXECUTE TOOL (Dynamic Routing) ---
        elseif ($Request.Url.AbsolutePath -eq "/api/tools/execute" -and $Request.HttpMethod -eq "POST") {
            $StreamReader = New-Object System.IO.StreamReader $Request.InputStream
            $RequestBody = $StreamReader.ReadToEnd() | ConvertFrom-Json

            $ScriptName = $RequestBody.Script
            $TargetPC = $RequestBody.Target
            $TargetUser = $RequestBody.TargetUser
            $ExtraArgs = $RequestBody.ExtraArgs

            $ResponseObj = @{ status = "error"; message = ""; output = "" }

            # [SECURITY PATCH] 1. Prevent Path Traversal (Must be alphanumeric + .ps1)
            if ($ScriptName -notmatch "^[a-zA-Z0-9_-]+\.ps1$") {
                $ResponseObj.message = "SECURITY ALERT: Invalid script name format."
                Write-Host "[!] Path Traversal Attempt Blocked: $ScriptName" -ForegroundColor Red
                goto SendResponse
            }

            # [SECURITY PATCH] 2. Prevent Command Injection on Target Hostname
            # Allows alphanumeric, hyphens, periods, and commas (for mass deploy)
            if (-not [string]::IsNullOrWhiteSpace($TargetPC) -and $TargetPC -notmatch "^[a-zA-Z0-9_.,-]+$") {
                $ResponseObj.message = "SECURITY ALERT: Invalid characters in Target PC name."
                Write-Host "[!] Command Injection Attempt Blocked: $TargetPC" -ForegroundColor Red
                goto SendResponse
            }

            # Check both Tools and Core folders
            $ScriptPath = Join-Path $ScriptRoot "Tools\$ScriptName"
            if (-not (Test-Path $ScriptPath)) { $ScriptPath = Join-Path $ScriptRoot "Core\$ScriptName" }

            Write-Host ">>> Executing $ScriptName against $TargetPC..." -ForegroundColor Yellow

            if (Test-Path $ScriptPath) {
                try {
                    $Params = @{
                        Target = $TargetPC
                        TargetUser = $TargetUser
                        SharedRoot = $ScriptRoot
                    }

                    if ($null -ne $ExtraArgs) {
                        foreach ($prop in $ExtraArgs.psobject.properties) {
                            $Params[$prop.Name] = $prop.Value
                        }
                    }

                    $RawOutput = & $ScriptPath @Params *>&1 | Out-String

                    $ResponseObj.status = "success"
                    $ResponseObj.message = "Executed"
                    $ResponseObj.output = $RawOutput.Trim()
                } catch {
                    $ResponseObj.message = "Script execution failed: $($_.Exception.Message)"
                }
            } else {
                $ResponseObj.message = "Script not found: $ScriptName"
            }

            :SendResponse
            $JsonResponse = $ResponseObj | ConvertTo-Json -Depth 3 -Compress
            $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
            $Response.ContentType = "application/json"
            $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
        }

        # --- AD INTELLIGENCE SEARCH ---
        elseif ($Request.Url.AbsolutePath -eq "/api/identity/search" -and $Request.HttpMethod -eq "POST") {
            $StreamReader = New-Object System.IO.StreamReader $Request.InputStream
            $RequestBody = $StreamReader.ReadToEnd() | ConvertFrom-Json
            $Query = $RequestBody.Query

            Write-Host ">>> Executing Identity & Asset Correlation for $Query..." -ForegroundColor Yellow
            $ScriptPath = Join-Path $ScriptRoot "Core\IdentityAssetCorrelation.ps1"

            if (Test-Path $ScriptPath) {
                try {
                    $RawOutput = & $ScriptPath -TargetUser $Query -SharedRoot $ScriptRoot -AsJson 6>$null | Out-String
                    $JsonResponse = $RawOutput.Trim()
                    if ([string]::IsNullOrWhiteSpace($JsonResponse)) { 
                        $JsonResponse = (@{ Status = "error"; Message = "No data returned." } | ConvertTo-Json -Compress)
                    }
                } catch {
                    $JsonResponse = (@{ Status = "error"; Message = "AD Query failed: $($_.Exception.Message)" } | ConvertTo-Json -Compress)
                }
            } else {
                $JsonResponse = (@{ Status = "error"; Message = "IdentityAssetCorrelation.ps1 not found." } | ConvertTo-Json -Compress)
            }

            $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
            $Response.ContentType = "application/json"
            $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
        }

        # --- AD IDENTITY ACTIONS ---
        elseif ($Request.Url.AbsolutePath -eq "/api/identity/action" -and $Request.HttpMethod -eq "POST") {
            $StreamReader = New-Object System.IO.StreamReader $Request.InputStream
            $RequestBody = $StreamReader.ReadToEnd() | ConvertFrom-Json
            $Action = $RequestBody.Action 
            $TargetUser = $RequestBody.TargetUser

            Write-Host ">>> Executing $Action on $TargetUser..." -ForegroundColor Yellow

            $ResponseObj = @{ status = "success"; message = "" }

            try {
                switch ($Action) {
                    "UnlockAccount" { 
                        Unlock-ADAccount -Identity $TargetUser -ErrorAction Stop
                        $ResponseObj.message = "AD Account unlocked successfully." 
                    }
                    "ResetPassword" { 
                        $Temp = Reset-UHDCPassword -TargetUPN $TargetUser
                        $ResponseObj.message = "Password Reset. Temp: $Temp" 
                    }
                }
            } catch {
                $ResponseObj.status = "error"
                $ResponseObj.message = "Action failed. Verify AD Permissions."
            }

            $JsonResponse = $ResponseObj | ConvertTo-Json -Depth 3 -Compress
            $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
            $Response.ContentType = "application/json"
            $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
        }

        # --- FIRE & FORGET BACKGROUND TASKS ---
        elseif ($Request.Url.AbsolutePath -eq "/api/tools/background" -and $Request.HttpMethod -eq "POST") {
            $StreamReader = New-Object System.IO.StreamReader $Request.InputStream
            $RequestBody = $StreamReader.ReadToEnd() | ConvertFrom-Json
            $ScriptName = $RequestBody.Script

            $ScriptPath = Join-Path $ScriptRoot "Core\$ScriptName"

            Write-Host ">>> Spawning detached background engine: $ScriptName..." -ForegroundColor Magenta

            $ResponseObj = @{ status = "error"; message = "" }

            if (Test-Path $ScriptPath) {
                try {
                    $ArgsList = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -SharedRoot `"$ScriptRoot`""
                    Start-Process "powershell.exe" -ArgumentList $ArgsList

                    $ResponseObj.status = "success"
                    $ResponseObj.message = "$ScriptName launched in the background. You can continue working."
                } catch {
                    $ResponseObj.message = "Failed to launch background process."
                }
            } else {
                $ResponseObj.message = "Script not found: $ScriptName"
            }

            $JsonResponse = $ResponseObj | ConvertTo-Json -Depth 3 -Compress
            $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
            $Response.ContentType = "application/json"
            $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
        }
		
		        # --- GRACEFUL SHUTDOWN ROUTE ---
        elseif ($Request.Url.AbsolutePath -eq "/api/system/shutdown" -and $Request.HttpMethod -eq "POST") {
            Write-Host ">>> Shutdown signal received from UI. Terminating engine..." -ForegroundColor Yellow
            $Response.StatusCode = 200
            $Response.Close()
            $HttpListener.Stop()
            break # Breaks the infinite while loop, allowing the script to exit cleanly
        }
		
        else { $Response.StatusCode = 404 }

        $Response.Close()
    }
}
finally {
    $HttpListener.Stop()
    $HttpListener.Close()
}
