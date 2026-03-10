<#
.SYNOPSIS
    UHDC Web-Ready Core: Helper_UpdateHistory.ps1
.DESCRIPTION
    Manually injects or updates a specific User-to-PC mapping 
    inside the central UserHistory.json database.
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$User,

    [Parameter(Mandatory=$false)]
    [string]$Computer,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot
)

# --- Load Configuration ---
if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    try {
        $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
        $RootFolder = Split-Path -Path $ScriptDir
        $ConfigFile = Join-Path -Path $RootFolder -ChildPath "config.json"

        if (Test-Path $ConfigFile) {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $SharedRoot = $Config.SharedNetworkRoot
        } else {
            Write-Output "[!] Error: SharedRoot path is missing and config.json not found."
            return
        }
    } catch {
        Write-Output "[!] Error: Failed to resolve SharedRoot."
        return
    }
}

if ([string]::IsNullOrWhiteSpace($User) -or [string]::IsNullOrWhiteSpace($Computer)) {
    Write-Output "[!] Error: User and Computer must be provided."
    return
}

$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"
$BackupFile  = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.bak"
$TempFile    = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.tmp"

# --- Read Database ---
$db = @{}
$initialCount = 0

if (Test-Path $HistoryFile) {
    if ((Get-Item $HistoryFile).Length -gt 100) {
        Copy-Item -Path $HistoryFile -Destination $BackupFile -Force
    }

    try {
        $content = Get-Content $HistoryFile -Raw -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($content)) {
            $raw = $content | ConvertFrom-Json
            if ($raw -isnot [System.Array]) { $raw = @($raw) }

            foreach ($entry in $raw) {
                if ($entry.User -and $entry.Computer) {
                    $key = "$($entry.User)-$($entry.Computer)"
                    $db[$key] = $entry
                }
            }
            $initialCount = $db.Count
        }
    } catch {
        Write-Output "`n[!] CRITICAL: JSON Parsing failed. Aborting to prevent data wipe."
        return
    }
}

# --- Update Record ---
$scanKey = "$User-$Computer"
$timeStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm")

if ($db.ContainsKey($scanKey)) {
    $db[$scanKey].LastSeen = $timeStamp
    $db[$scanKey].Source   = "UHDC-Update"
} else {
    $db[$scanKey] = [PSCustomObject]@{
        User     = $User
        Computer = $Computer
        LastSeen = $timeStamp
        Source   = "UHDC-Update"
    }
}

# --- Write to Disk ---
if ($db.Count -ge $initialCount -and $db.Count -gt 0) {
    try {
        $finalList = @($db.Values | Sort-Object User)
        $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($jsonOutput)) {
            throw "Generated JSON string was completely empty."
        }

        Set-Content -Path $TempFile -Value $jsonOutput -Force -ErrorAction Stop
        Move-Item -Path $TempFile -Destination $HistoryFile -Force -ErrorAction Stop

    } catch {
        Write-Output "`n[!] ERROR SAVING: $($_.Exception.Message)"
        if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Output "`n[!] PROTECTION TRIGGERED: Attempted to save fewer records than loaded."
    Write-Output "    Operation aborted to protect database."
}
} else {
    Write-Output "`n[!] PROTECTION TRIGGERED: Attempted to save fewer records than loaded."
    Write-Output "    Operation aborted to protect database."

}
