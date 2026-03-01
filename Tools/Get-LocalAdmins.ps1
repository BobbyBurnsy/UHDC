# Get-LocalAdmins.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Remotely queries the target computer to list all members of the local
# "Administrators" group, displaying their Name, Type (User/Group), and Source (Local/AD).

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
Write-Host " [UHDC] LOCAL ADMINISTRATOR AUDIT"
Write-Host "========================================"

# 1. Fast Ping Check
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# 2. Query Local Administrators
try {
    Write-Host " [UHDC] [i] Connecting to $Target via WinRM..."

    # ------------------------------------------------------------------
    # STEP 1: QUERY LOCAL SAM DATABASE
    # ------------------------------------------------------------------
    Wait-TrainingStep `
        -Desc "STEP 1: QUERY LOCAL ADMINISTRATORS GROUP`n`nWHEN TO USE THIS:`nUse this when auditing a machine for unauthorized privilege escalation, verifying that LAPS (Local Administrator Password Solution) is functioning, or confirming a specific user/group has the necessary rights to install software.`n`nWHAT IT DOES:`nWe are establishing a WinRM session to query the local SAM (Security Account Manager) database of the target machine. We specifically target the built-in 'Administrators' group and return its members, identifying whether they are local accounts or Active Directory objects.`n`nIN-PERSON EQUIVALENT:`nRight-click the Start Menu, select 'Computer Management' (compmgmt.msc), expand 'Local Users and Groups', click 'Groups', and double-click the 'Administrators' group to view its members." `
        -Code "Invoke-Command -ComputerName $Target -ScriptBlock { Get-LocalGroupMember -Group 'Administrators' | Select-Object Name, PrincipalSource, ObjectClass }"

    # We grab the objects remotely and bring them back for local formatting
    $admins = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
        Get-LocalGroupMember -Group "Administrators" | Select-Object Name, PrincipalSource, ObjectClass
    }

    Write-Host "`n --- Administrators Group Members ---"

    if ($admins) {
        foreach ($admin in $admins) {
            # Strip out the PSComputerName property that Invoke-Command secretly adds
            $name = $admin.Name
            $source = $admin.PrincipalSource
            $type = $admin.ObjectClass

            Write-Host "  > $name"
            Write-Host "    Type:   $type"
            Write-Host "    Source: $source`n"
        }

        # --- AUDIT LOG INJECTION ---
        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) {
                & $AuditHelper -Target $Target -Action "Queried Local Administrators" -SharedRoot $SharedRoot
            }
        }
        # ---------------------------

    } else {
        Write-Host "  [UHDC] [i] No members found."
    }

} catch {
    Write-Host "`n [UHDC ERROR] Could not retrieve Local Admins."
    Write-Host "     $($_.Exception.Message)"
}

Write-Host "========================================`n"