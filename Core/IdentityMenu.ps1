<#
.SYNOPSIS
    UHDC Web-Ready Core: IdentityMenu.ps1
.DESCRIPTION
    Authenticates to Microsoft Graph for Identity management.
    Dot-sourced by AppLogic.ps1 on startup. Fails gracefully if modules 
    are missing so the main Web UI can still load.
#>

$ErrorActionPreference = "Continue"
$Global:GraphConnected = $false

# ------------------------------------------------------------------------
# 1. DEFINE DELEGATED PERMISSIONS (RBAC)
# ------------------------------------------------------------------------
$GraphScopes = @(
    "User.ReadWrite.All",
    "UserAuthenticationMethod.ReadWrite.All", 
    "Directory.Read.All"
)

Write-Host ">>> [IDENTITY] Verifying Microsoft.Graph module..." -ForegroundColor DarkGray

# ------------------------------------------------------------------------
# 2. DEPENDENCY INJECTION & CONNECTION (GRACEFUL FALLBACK)
# ------------------------------------------------------------------------
try {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Host "[!] Microsoft.Graph module is missing. Cloud Identity features will be disabled." -ForegroundColor Yellow
    }
    elseif (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Identity.SignIns)) {
        Write-Host "[!] Microsoft.Graph.Identity module is missing. Cloud Identity features will be disabled." -ForegroundColor Yellow
    }
    else {
        # Attempt connection (Will prompt for login on the server console on first run)
        Connect-MgGraph -Scopes $GraphScopes -NoWelcome -ErrorAction Stop

        # ------------------------------------------------------------------------
        # 3. THE "ZERO TRUST" BOUNDARY CHECK
        # ------------------------------------------------------------------------
        $CurrentContext = Get-MgContext
        $TechUPN = $CurrentContext.Account

        Write-Host ">>> [IDENTITY] Authenticated as: $TechUPN" -ForegroundColor Cyan

        if ($TechUPN -notmatch $Global:TenantDomain) {
            Disconnect-MgGraph
            Write-Host "[!] SECURITY BLOCK: Technician UPN ($TechUPN) does not match tenant domain ($Global:TenantDomain). Cloud features disabled." -ForegroundColor Red
        } else {
            Write-Host ">>> [IDENTITY] Boundary check passed. Graph API connection locked." -ForegroundColor Green
            $Global:GraphConnected = $true
        }
    }
}
catch {
    Write-Host "[!] Graph API Authentication Failed or Cancelled. Cloud features will be disabled." -ForegroundColor Yellow
}

# ========================================================================
# 4. CORE ACTION FUNCTIONS (Called by AppLogic.ps1 API Routes)
# ========================================================================

function Reset-UHDCPassword {
    param([string]$TargetUPN)

    if (-not $Global:GraphConnected) { throw "Graph API is not connected. Cannot reset cloud password." }

    try {
        $TempPassword = "UHDC-" + (New-Guid).ToString().Substring(0,8) + "!"
        $PasswordProfile = @{
            Password = $TempPassword
            ForceChangePasswordNextSignIn = $true
        }

        Update-MgUser -UserId $TargetUPN -PasswordProfile $PasswordProfile -ErrorAction Stop

        Write-Host "[SUCCESS] Password reset for $TargetUPN. Temp Password: $TempPassword" -ForegroundColor Green
        return $TempPassword
    } catch {
        throw "Graph API Error: $($_.Exception.Message)"
    }
}

function Clear-UHDCUserMFA {
    param([string]$TargetUPN)

    if (-not $Global:GraphConnected) { throw "Graph API is not connected. Cannot clear MFA." }

    try {
        $AuthMethods = Get-MgUserAuthenticationMethod -UserId $TargetUPN -ErrorAction Stop
        $cleared = 0

        foreach ($Method in $AuthMethods) {
            if ($Method.AdditionalProperties['@odata.type'] -match 'microsoftAuthenticatorAuthenticationMethod|phoneAuthenticationMethod') {
                Remove-MgUserAuthenticationMethod -UserId $TargetUPN -AuthenticationMethodId $Method.Id -ErrorAction Stop
                $cleared++
            }
        }

        Write-Host "[SUCCESS] Cleared $cleared MFA methods for $TargetUPN" -ForegroundColor Green
        return "Successfully cleared $cleared MFA methods. User must re-register."
    } catch {
        throw "Graph API Error: $($_.Exception.Message)"
    }
}

function Revoke-UHDCSessions {
    param([string]$TargetUPN)

    if (-not $Global:GraphConnected) { throw "Graph API is not connected. Cannot revoke sessions." }

    try {
        Revoke-MgUserSignInSession -UserId $TargetUPN -ErrorAction Stop | Out-Null
        Write-Host "[SUCCESS] All active cloud sessions revoked for $TargetUPN" -ForegroundColor Green
        return "All active Entra ID sessions have been revoked."
    } catch {
        throw "Graph API Error: $($_.Exception.Message)"
    }
}

return $true