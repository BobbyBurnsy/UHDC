# Get-NetworkInfo.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Remotely queries the target for active network adapters (Status=Up).
# It filters out loopback/APIPA addresses and correlates IPv4 addresses with
# Interface Descriptions, MAC Addresses, and Link Speeds.

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
        } else {
            Write-Host " [UHDC] [!] Error: SharedRoot path is missing and config.json not found."
            return
        }
    } catch { }
}

if ([string]::IsNullOrWhiteSpace($Target)) { return }

Write-Host "========================================"
Write-Host " [UHDC] NETWORK INTERFACE DIAGNOSTICS"
Write-Host "========================================"

# 1. Fast Ping Check
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# 2. Remote Network Query
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    # ------------------------------------------------------------------
    # STEP 1: QUERY ACTIVE ADAPTERS
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 1: QUERY ACTIVE NETWORK INTERFACES`n`nWHEN TO USE THIS:`nUse this when troubleshooting network connectivity, verifying if a user is on Wi-Fi or Ethernet, checking link speeds for performance issues (e.g., 100Mbps vs 1Gbps), or retrieving a MAC address for DHCP reservations.`n`nWHAT IT DOES:`nWe are establishing a WinRM session to query the target's active network adapters and IPv4 addresses. We filter out disconnected adapters, loopback addresses (127.0.0.1), and APIPA addresses (169.254.x.x), then correlate the valid IP to its physical MAC address and negotiated link speed.`n`nIN-PERSON EQUIVALENT:`nOpen an elevated Command Prompt and type 'ipconfig /all', or press Win+R, type 'ncpa.cpl' (Network Connections), double-click the active adapter, and click 'Details...'." `
        -Code "Invoke-Command -ComputerName $Target -ScriptBlock {`n    `$adapters = Get-NetAdapter | Where-Object Status -eq 'Up'`n    `$ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -notmatch '169.254|127.0'`n    # Correlate IP to Adapter MAC/Speed`n}"

    $netData = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        # Get active adapters and valid IPs
        $adapters = Get-NetAdapter | Where-Object Status -eq 'Up'
        $ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -notmatch "169.254|127.0"

        $results = @()
        foreach ($ip in $ips) {
            # Match the IP to its physical/virtual adapter
            $matchAdapter = $adapters | Where-Object Name -eq $ip.InterfaceAlias

            $results += [PSCustomObject]@{
                Adapter = $ip.InterfaceAlias
                Desc    = if ($matchAdapter) { $matchAdapter.InterfaceDescription } else { "Unknown" }
                IP      = $ip.IPAddress
                MAC     = if ($matchAdapter) { $matchAdapter.MacAddress } else { "N/A" }
                Speed   = if ($matchAdapter) { $matchAdapter.LinkSpeed } else { "N/A" }
            }
        }
        return $results
    }

    if ($netData) {
        Write-Host "`n --- Active Interfaces ---"
        # Print cleanly without using Format-Table so the WPF GUI doesn't mangle it
        foreach ($nic in $netData) {
            Write-Host "  > Adapter: $($nic.Adapter)"
            Write-Host "    Desc:    $($nic.Desc)"
            Write-Host "    IP:      $($nic.IP)"
            Write-Host "    MAC:     $($nic.MAC)"
            Write-Host "    Speed:   $($nic.Speed)`n"
        }

        # --- AUDIT LOG INJECTION ---
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                & $AuditHelper -Target $Target -Action "Queried Network Info (IP/MAC)" -SharedRoot $SharedRoot
            }
        }
        # ---------------------------
    } else {
        Write-Host "`n [UHDC] [i] No active IPv4 interfaces found."
    }

} catch {
    Write-Host "`n [UHDC ERROR] Could not query network info."
    Write-Host "     $($_.Exception.Message)"
}

Write-Host "========================================`n"