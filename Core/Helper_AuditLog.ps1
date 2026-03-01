# Helper_AuditLog.ps1 - Place this script in the \Core folder
# DESCRIPTION: The central logging engine for the UHDC platform. It accepts 
# parameters for the Target PC and the Action performed, grabs the executing 
# technician's username ($env:USERNAME), and appends a timestamped record 
# to the central ConsoleAudit.csv file for security and usage tracking.

param(
    [string]$Target,
    [string]$Action,
    [string]$Tech = $env:USERNAME,
    [string]$SharedRoot
)

# ------------------------------------------------------------------
# BULLETPROOF CONFIG LOADER
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
            return 
        }
    } catch {
        return
    }
}

# ------------------------------------------------------------------
# WRITE TO UNIFIED CSV LOG
# ------------------------------------------------------------------
$LogFolder = Join-Path -Path $SharedRoot -ChildPath "Logs"
if (-not (Test-Path $LogFolder)) { New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null }

$LogFile = Join-Path -Path $LogFolder -ChildPath "ConsoleAudit.csv"

try {
    $newEntry = [PSCustomObject]@{ 
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Tech      = $Tech
        Target    = if ($Target) { $Target } else { "N/A" }
        Action    = $Action 
    }
    
    $newEntry | Export-Csv -Path $LogFile -Append -NoTypeInformation -Force
} catch {
    Write-Host " [UHDC] [!] Failed to write to audit log: $($_.Exception.Message)" -ForegroundColor Red
}