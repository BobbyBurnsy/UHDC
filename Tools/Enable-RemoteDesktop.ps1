# Enable-RemoteDesktop.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Remotely enables RDP on the target machine by modifying the registry (fDenyTSConnections),
# opening the Windows Firewall for the Remote Desktop profile, and ensuring the TermService is running.

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

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
Write-Host " [UHDC] REMOTE DESKTOP CONFIGURATION"
Write-Host "========================================"

# 1. Fast Ping Check to prevent WinRM timeouts
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# 2. Execute RDP Enable Steps
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    # ------------------------------------------------------------------
    # STEP 1: REGISTRY MODIFICATION
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 1: ENABLE RDP IN REGISTRY`n`nWHEN TO USE THIS:`nUse this when you need to establish a Remote Desktop connection to a PC, but the feature is currently disabled in the system settings.`n`nWHAT IT DOES:`nWe are remotely modifying the 'fDenyTSConnections' registry key. Changing this value from 1 (Deny) to 0 (Allow) tells Windows to accept incoming Terminal Services (RDP) connections.`n`nIN-PERSON EQUIVALENT:`nOpen System Properties (sysdm.cpl) > Remote tab > Select 'Allow remote connections to this computer'." `
        -Code "Invoke-Command -ComputerName $Target -ScriptBlock { Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 }"

    Write-Host "  > [1/3] Enabling RDP in Registry..."
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0 -ErrorAction Stop
    }

    # ------------------------------------------------------------------
    # STEP 2: FIREWALL CONFIGURATION
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 2: OPEN WINDOWS FIREWALL`n`nWHEN TO USE THIS:`nUse this when RDP is enabled in the registry, but connections are still timing out because the local Windows Defender Firewall is blocking port 3389.`n`nWHAT IT DOES:`nWe are using the NetSecurity module to enable the predefined 'Remote Desktop' firewall rule group across the active network profiles.`n`nIN-PERSON EQUIVALENT:`nOpen Windows Defender Firewall > 'Allow an app or feature through Windows Defender Firewall' > Check the box for 'Remote Desktop'." `
        -Code "Invoke-Command -ComputerName $Target -ScriptBlock { Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' }"

    Write-Host "  > [2/3] Opening Windows Firewall for RDP (Port 3389)..."
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null
    }

    # ------------------------------------------------------------------
    # STEP 3: SERVICE CONFIGURATION
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 3: START TERMINAL SERVICE`n`nWHEN TO USE THIS:`nUse this to ensure the underlying Remote Desktop Service is actually running and actively listening for connections.`n`nWHAT IT DOES:`nWe are configuring the 'TermService' to start automatically on boot, and then forcefully starting it right now.`n`nIN-PERSON EQUIVALENT:`nOpen Services (services.msc), locate 'Remote Desktop Services', right-click and select Properties, change Startup type to 'Automatic', and click 'Start'." `
        -Code "Invoke-Command -ComputerName $Target -ScriptBlock { Set-Service -Name 'TermService' -StartupType Automatic; Start-Service -Name 'TermService' }"

    Write-Host "  > [3/3] Ensuring TermService is running..."
    Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Set-Service -Name "TermService" -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name "TermService" -ErrorAction SilentlyContinue
    }

    Write-Host "`n [UHDC SUCCESS] RDP Enabled, Firewall Opened, and Service Started!"
    Write-Host " [UHDC] [i] You can try connecting using MSRA or RDP now."

    # --- AUDIT LOG INJECTION ---
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Remote Desktop Enabled (Registry/Firewall)" -SharedRoot $SharedRoot
        }
    }
    # ---------------------------

} catch {
    Write-Host "`n [UHDC ERROR] Could not enable RDP."
    Write-Host "     $($_.Exception.Message)"
}

Write-Host "========================================`n"