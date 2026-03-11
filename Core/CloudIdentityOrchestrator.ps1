<#
.SYNOPSIS
    UHDC Web-Ready Core: IntuneEntraManager.ps1
.DESCRIPTION
    A headless API router for Microsoft Intune and Entra ID management.
    Takes an Action parameter from the Web UI to retrieve devices, BitLocker keys,
    LAPS passwords, or manage MFA methods via the Microsoft Graph API.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [string]$Action = "GetDevices",

    [Parameter(Mandatory=$false)]
    [string]$DeviceId,

    [Parameter(Mandatory=$false)]
    [string]$PhoneNumber,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# --- Export Training Data ---
if ($GetTrainingData) {
    $data = @{
        StepName = "INTUNE & ENTRA MANAGER"
        Description = "Because this module interacts with Entra ID and Intune, there is no classic 'CMD' equivalent. The modern command-line for the Microsoft Cloud is the Graph API. While the UHDC automates the complex authentication and device correlation, a junior technician should know how to manually pull critical data, like a BitLocker recovery key, directly from a standard PowerShell terminal using the Microsoft.Graph module."
        Code = "Get-MgInformationProtectionBitlockerRecoveryKey -Filter `"deviceId eq '<AzureAD-Device-ID>'`""
        InPerson = "Logging into the Microsoft Endpoint Manager (Intune) web portal, searching for the user or device, navigating to the 'Recovery Keys' tab, and copying the 48-digit key."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Graph API Authentication & Domain Filtering ---
$scopes = @(
    "User.Read.All",
    "DeviceManagementManagedDevices.ReadWrite.All",
    "DeviceManagementManagedDevices.PrivilegedOperations.All",
    "BitlockerKey.Read.All",
    "DeviceLocalCredential.Read.All",
    "UserAuthenticationMethod.ReadWrite.All"
)

if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
    try { Connect-MgGraph -Scopes $scopes -ErrorAction Stop }
    catch { Write-Output '{"error":"Failed to authenticate to Microsoft Graph API."}'; return }
}

$TechUPN = (Get-MgContext).Account
$TechDomain = if ($TechUPN -match "@(.*)$") { $matches[1] } else { "" }

$EmailToPass = $TargetUser
if (-not [string]::IsNullOrWhiteSpace($TargetUser) -and $TargetUser -notmatch "@") {
    try {
        $adObj = Get-ADUser -Identity $TargetUser -Properties EmailAddress -ErrorAction SilentlyContinue
        if ($adObj.EmailAddress) { $EmailToPass = $adObj.EmailAddress }
        else { $EmailToPass = "$TargetUser@$TechDomain" }
    } catch { $EmailToPass = "$TargetUser@$TechDomain" }
}

if (-not [string]::IsNullOrWhiteSpace($EmailToPass) -and $EmailToPass -match "@(.*)$") {
    if ($matches[1] -ne $TechDomain) {
        Write-Output '{"error":"Cross-Agency Block: Target user belongs to a different domain."}'
        return
    }
}

# --- Action Routing ---
try {
    switch ($Action) {
        "GetDevices" {
            $RawDeviceList = @()
            $ResolvedUser = $null

            if (-not [string]::IsNullOrWhiteSpace($Target)) {
                $deviceMatch = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$Target'" -ErrorAction SilentlyContinue
                if ($deviceMatch) { $RawDeviceList += $deviceMatch }
            }

            if (-not [string]::IsNullOrWhiteSpace($EmailToPass)) {
                $users = Get-MgUser -Filter "userPrincipalName eq '$EmailToPass' or mail eq '$EmailToPass'" -ErrorAction SilentlyContinue
                if ($users) {
                    $ResolvedUser = $users[0]
                    $userDevices = Get-MgDeviceManagementManagedDevice -Filter "userId eq '$($ResolvedUser.Id)'" -ErrorAction SilentlyContinue
                    if ($userDevices) { $RawDeviceList += $userDevices }
                }
            }

            if ($RawDeviceList.Count -gt 0) {
                $GlobalDevices = $RawDeviceList | Select-Object -Unique -Property Id | Sort-Object deviceName
                $exportList = @()
                foreach ($dev in $GlobalDevices) {
                    $exportList += [PSCustomObject]@{
                        Id = $dev.Id
                        AzureAdDeviceId = $dev.AzureAdDeviceId
                        DeviceName = $dev.DeviceName
                        OS = $dev.OperatingSystem
                        Compliance = $dev.ComplianceState
                        Serial = $dev.SerialNumber
                    }
                }
                $exportList | ConvertTo-Json -Depth 3 | Write-Output
            } else {
                Write-Output "[]"
            }
        }

        "GetBitLocker" {
            $keys = Get-MgInformationProtectionBitlockerRecoveryKey -Filter "deviceId eq '$DeviceId'" -Property "key" -ErrorAction Stop
            if ($keys) { 
                $keyStr = $($keys[0].Key)
                $html = "<div style='display: flex; justify-content: space-between; align-items: center; color:#2ecc71; font-weight:bold; font-size:1.1rem;'>"
                $html += "<span><i class='fa-solid fa-key'></i> RECOVERY KEY: $keyStr</span>"
                $html += "<button onclick=`"copyToClipboard('$keyStr', this)`" style='background: transparent; border: 1px solid #2ecc71; color: #2ecc71; padding: 4px 8px; border-radius: 4px; cursor: pointer; font-size: 0.8rem;'><i class='fa-regular fa-copy'></i> Copy</button>"
                $html += "</div>"
                Write-Output $html
            }
            else { Write-Output "<div style='color:#e74c3c;'><i class='fa-solid fa-triangle-exclamation'></i> No BitLocker keys found for this device in Entra ID.</div>" }
        }

        "GetLAPS" {
            $uri = "https://graph.microsoft.com/v1.0/deviceLocalCredentials?`$filter=deviceId eq '$DeviceId'&`$select=credentials"
            $lapsData = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
            if ($lapsData.value) { 
                $pwStr = $($lapsData.value.credentials.password)
                $html = "<div style='display: flex; justify-content: space-between; align-items: center; color:#f1c40f; font-weight:bold; font-size:1.1rem;'>"
                $html += "<span><i class='fa-solid fa-user-shield'></i> CLOUD LAPS: $pwStr</span>"
                $html += "<button onclick=`"copyToClipboard('$pwStr', this)`" style='background: transparent; border: 1px solid #f1c40f; color: #f1c40f; padding: 4px 8px; border-radius: 4px; cursor: pointer; font-size: 0.8rem;'><i class='fa-regular fa-copy'></i> Copy</button>"
                $html += "</div>"
                Write-Output $html
            }
            else { Write-Output "<div style='color:#e74c3c;'><i class='fa-solid fa-triangle-exclamation'></i> No Cloud LAPS data available for this device.</div>" }
        }

        "Wipe" {
            Invoke-MgWipeDeviceManagementManagedDevice -ManagedDeviceId $DeviceId -ErrorAction Stop
            Write-Output "<div style='color:#3498db;'><i class='fa-solid fa-skull'></i> [UHDC SUCCESS] Remote Wipe command dispatched to Intune.</div>"
        }

        "Sync" {
            Invoke-MgSyncDeviceManagementManagedDevice -ManagedDeviceId $DeviceId -ErrorAction Stop
            Write-Output "<div style='color:#3498db;'><i class='fa-solid fa-rotate'></i> [UHDC SUCCESS] MDM Sync command dispatched to Intune.</div>"
        }

        "Reboot" {
            Invoke-MgRebootDeviceManagementManagedDevice -ManagedDeviceId $DeviceId -ErrorAction Stop
            Write-Output "<div style='color:#3498db;'><i class='fa-solid fa-power-off'></i> [UHDC SUCCESS] Remote Reboot command dispatched to Intune.</div>"
        }

        "GetMFA" {
            $user = Get-MgUser -UserId $EmailToPass -ErrorAction Stop
            $methods = Get-MgUserAuthenticationPhoneMethod -UserId $user.Id -ErrorAction SilentlyContinue
            if ($methods) {
                $html = "<strong><i class='fa-solid fa-mobile-screen'></i> Registered MFA Phones:</strong><br>"
                foreach ($m in $methods) { $html += "- $($m.PhoneType): $($m.PhoneNumber)<br>" }
                Write-Output "<div style='color:#cbd5e1;'>$html</div>"
            } else { Write-Output "<div style='color:#e74c3c;'><i class='fa-solid fa-triangle-exclamation'></i> No MFA phone methods found for this user.</div>" }
        }

        "ClearMFA" {
            $user = Get-MgUser -UserId $EmailToPass -ErrorAction Stop
            $methods = Get-MgUserAuthenticationPhoneMethod -UserId $user.Id -ErrorAction SilentlyContinue
            $cleared = 0
            foreach ($m in $methods) {
                Remove-MgUserAuthenticationPhoneMethod -UserId $user.Id -PhoneAuthenticationMethodId $m.Id -ErrorAction Stop
                $cleared++
            }
            Write-Output "<div style='color:#2ecc71;'><i class='fa-solid fa-check'></i> [UHDC SUCCESS] Cleared $cleared MFA methods. User must re-register on next login.</div>"
        }

        "AddSMS" {
            $user = Get-MgUser -UserId $EmailToPass -ErrorAction Stop
            New-MgUserAuthenticationPhoneMethod -UserId $user.Id -PhoneType "mobile" -PhoneNumber $PhoneNumber -ErrorAction Stop
            Write-Output "<div style='color:#2ecc71;'><i class='fa-solid fa-check'></i> [UHDC SUCCESS] $PhoneNumber added as primary SMS MFA.</div>"
        }
    }
} catch {
    Write-Output "<div style='color:#e74c3c;'><i class='fa-solid fa-circle-xmark'></i> [!] Graph API Error: $($_.Exception.Message)</div>"
}
