# Get-SmartWarranty.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Queries the target computer's WMI/CIM repository for its Make and Serial Number,
# then automatically constructs and opens the correct vendor support/warranty webpage (Dell, Lenovo, HP, MS).

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
Write-Host " [UHDC] WARRANTY LOOKUP: $Target"
Write-Host "========================================"

# 1. Fast Ping Check
# Prevents the background runspace from hanging on an offline PC.
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# 2. Hardware Query
try {
    Write-Host " [UHDC] [i] Querying Hardware Info..."

    # ------------------------------------------------------------------
    # STEP 1: QUERY WMI/CIM FOR HARDWARE INFO
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 1: QUERY HARDWARE INFORMATION`n`nWHEN TO USE THIS:`nUse this when a user reports physical hardware damage (e.g., cracked screen, failing drive, swollen battery) or when preparing to order replacement parts and you need to verify if the device is still covered under the manufacturer's active warranty or accidental damage protection plan.`n`nWHAT IT DOES:`nWe are establishing a remote WMI/CIM session to query the target computer's motherboard (Win32_BIOS) for its embedded Serial Number/Service Tag, and the system enclosure (Win32_ComputerSystem) for the Manufacturer (Make).`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would flip the laptop over and read the tiny printed sticker on the bottom chassis, or open an elevated Command Prompt and type 'wmic bios get serialnumber' followed by 'wmic computersystem get manufacturer'." `
        -Code "`$bios = Get-CimInstance -ComputerName $Target -ClassName Win32_BIOS`n`$cs = Get-CimInstance -ComputerName $Target -ClassName Win32_ComputerSystem"

    # We query both in one try block to catch RPC/Access Denied errors immediately.
    $bios = Get-CimInstance -ComputerName $Target -ClassName Win32_BIOS -ErrorAction Stop
    $cs   = Get-CimInstance -ComputerName $Target -ClassName Win32_ComputerSystem -ErrorAction Stop

    $make   = $cs.Manufacturer.Trim()
    $serial = $bios.SerialNumber.Trim()

    Write-Host "  > Make:   $make"
    Write-Host "  > Serial: $serial"

    # 3. URL Construction Logic
    $url = ""

    # Dell Logic (Matches 'Dell Inc.' or 'Dell Computer Corp')
    if ($make -match "Dell") {
        $url = "https://www.dell.com/support/home/en-us/product-support/servicetag/$serial/overview"
    }
    # Lenovo Logic (Matches 'LENOVO')
    elseif ($make -match "Lenovo") {
        $url = "https://pcsupport.lenovo.com/us/en/search?query=$serial"
    }
    # HP Logic (Matches 'HP' or 'Hewlett-Packard')
    elseif ($make -match "HP|Hewlett-Packard") {
        $url = "https://support.hp.com/us-en/check-warranty"
    }
    # Microsoft Surface Logic (Matches 'Microsoft Corporation')
    elseif ($make -match "Microsoft") {
        Write-Host "  > [UHDC] Note: Microsoft usually requires a login to view Surface warranties." -ForegroundColor Yellow
        $url = "https://mybusinessservice.surface.com/"
    }

    if ($url) {

        # ------------------------------------------------------------------
        # STEP 2: LAUNCH VENDOR PORTAL
        # ------------------------------------------------------------------
        Wait-TrainingStep `
            -Desc "STEP 2: LAUNCH VENDOR WARRANTY PORTAL`n`nWHEN TO USE THIS:`nImmediately after retrieving the serial number to check the exact expiration date and entitlement level (e.g., Next Business Day Onsite vs. Depot Repair).`n`nWHAT IT DOES:`nWe are using the retrieved Manufacturer name to automatically determine the correct vendor support portal (Dell, Lenovo, HP, or Microsoft). We then inject the Serial Number directly into the URL and launch it in your local default web browser.`n`nIN-PERSON EQUIVALENT:`nYou would open a web browser, search for 'Dell Warranty Check' (or the respective vendor), navigate to their support page, manually type the alphanumeric serial number into the search box, and click Submit." `
            -Code "Start-Process `"$url`""

        Write-Host " [UHDC SUCCESS] Opening Warranty Page in your default browser..."
        # Launching the URL directly lets Windows handle the default browser choice.
        Start-Process $url

        # --- AUDIT LOG INJECTION ---
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                & $AuditHelper -Target $Target -Action "Checked Warranty ($make - Serial: $serial)" -SharedRoot $SharedRoot
            }
        }
        # ---------------------------

    } else {
        Write-Host " [UHDC] [i] Auto-detect failed for vendor: $make"
        Write-Host "      (Serial number $serial is available for manual lookup)"
    }

} catch {
    Write-Host "`n [UHDC ERROR] Could not query CIM/WMI."
    Write-Host "      Possible cause: Firewall, RPC error, or Access Denied."
    Write-Host "      Details: $($_.Exception.Message)"
}

Write-Host "========================================`n"