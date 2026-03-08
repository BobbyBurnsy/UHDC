<#
.SYNOPSIS
    UHDC Dependency Bootstrapper: Install-UHDCDependencies.ps1
.DESCRIPTION
    Prepares a technician's local workstation to run the Unified Help Desk Console.
    - Enforces TLS 1.2 for secure external connections.
    - Configures the local Execution Policy.
    - Bootstraps the NuGet provider and trusts the PSGallery.
    - Installs the required Microsoft Graph API modules.
    - Verifies the presence of Active Directory RSAT tools.
#>

$ErrorActionPreference = "Stop"

Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host " [UHDC] WORKSTATION DEPENDENCY BOOTSTRAPPER" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------
# 1. ELEVATION CHECK
# ------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[!] CRITICAL ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "    Please right-click PowerShell and select 'Run as Administrator'." -ForegroundColor Yellow
    Pause
    exit
}

# ------------------------------------------------------------------
# 2. ENVIRONMENT PREPARATION
# ------------------------------------------------------------------
Write-Host "`n[1/4] Configuring Local Environment..." -ForegroundColor White

# Enforce TLS 1.2 (Required for PSGallery and Graph API)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host " > [OK] TLS 1.2 Enforced." -ForegroundColor Green

# Set Execution Policy to RemoteSigned to allow local script execution
$currentPolicy = Get-ExecutionPolicy
if ($currentPolicy -eq "Restricted") {
    Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
    Write-Host " > [OK] Execution Policy updated to RemoteSigned." -ForegroundColor Green
} else {
    Write-Host " > [OK] Execution Policy is already sufficient ($currentPolicy)." -ForegroundColor Green
}

# ------------------------------------------------------------------
# 3. PACKAGE MANAGER BOOTSTRAP
# ------------------------------------------------------------------
Write-Host "`n[2/4] Bootstrapping Package Providers..." -ForegroundColor White

try {
    # Ensure NuGet is installed and available
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Write-Host " > Installing NuGet Provider..." -ForegroundColor DarkGray
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    }
    Write-Host " > [OK] NuGet Provider ready." -ForegroundColor Green

    # Trust the PSGallery to prevent installation prompts
    $PSGallery = Get-PSRepository -Name "PSGallery" -ErrorAction SilentlyContinue
    if ($PSGallery.InstallationPolicy -ne "Trusted") {
        Write-Host " > Trusting PSGallery..." -ForegroundColor DarkGray
        Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted
    }
    Write-Host " > [OK] PSGallery is trusted." -ForegroundColor Green
} catch {
    Write-Host " > [!] Failed to configure package providers. Check your internet connection." -ForegroundColor Red
    exit
}

# ------------------------------------------------------------------
# 4. MICROSOFT GRAPH MODULE INSTALLATION
# ------------------------------------------------------------------
Write-Host "`n[3/4] Verifying Microsoft Graph API Modules..." -ForegroundColor White

# We only install the specific sub-modules we need to keep the footprint small,
# rather than installing the massive monolithic 'Microsoft.Graph' module.
$RequiredModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Identity.SignIns",
    "Microsoft.Graph.Users",
    "Microsoft.Graph.DeviceManagement"
)

foreach ($Module in $RequiredModules) {
    if (Get-Module -ListAvailable -Name $Module) {
        Write-Host " > [OK] $Module is already installed." -ForegroundColor Green
    } else {
        Write-Host " > Installing $Module (This may take a moment)..." -ForegroundColor Yellow
        try {
            Install-Module -Name $Module -Force -AllowClobber -AcceptLicense
            Write-Host "   -> Success." -ForegroundColor Green
        } catch {
            Write-Host "   -> [!] Failed to install $Module: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# ------------------------------------------------------------------
# 5. ACTIVE DIRECTORY RSAT VERIFICATION
# ------------------------------------------------------------------
Write-Host "`n[4/4] Verifying Active Directory RSAT Tools..." -ForegroundColor White

if (Get-Module -ListAvailable -Name ActiveDirectory) {
    Write-Host " > [OK] ActiveDirectory module found." -ForegroundColor Green
} else {
    Write-Host " > [!] WARNING: ActiveDirectory module is missing." -ForegroundColor Red
    Write-Host "       The UHDC requires the RSAT: Active Directory Domain Services tools." -ForegroundColor Yellow
    Write-Host "       To install, go to: Settings > Apps > Optional Features > Add a feature." -ForegroundColor Yellow
}

# ------------------------------------------------------------------
# FINISH
# ------------------------------------------------------------------
Write-Host "`n=======================================================" -ForegroundColor Cyan
Write-Host " [UHDC] BOOTSTRAP COMPLETE" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "Your workstation is now ready. You may launch the console using Launch-UHDC.cmd." -ForegroundColor White
Write-Host ""
Pause