<#
.SYNOPSIS
    UHDC Web-Ready Core: Helper_RemoveHistory.ps1
.DESCRIPTION
    Safely manages the central UserHistory.json database by 
    finding and deleting a specific User-to-PC mapping. This is used to 
    prune stale or incorrect location data while leaving the rest of the 
    database intact.
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$User,

    [Parameter(Mandatory=$false)]
    [string]$Computer,

    [Parameter(Mandatory=$false)]
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
            Write-Output "[!] Error: SharedRoot path is missing and config.json not found."
            return
        }
    } catch {
        Write-Output "[!] Error: Failed to resolve SharedRoot."
        return
    }
}

# Use Join-Path to guarantee perfect slashes
$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"
$BackupFile  = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.bak"
$TempFile    = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.tmp"

# 1. READ EXISTING DATABASE SAFELY
$db = @{}
$initialCount = 0

if (Test-Path $HistoryFile) {
    # CRITICAL: Only backup if the file is healthy (>100 bytes).
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

# 2. REMOVE THE TARGET RECORD
$scanKey = "$User-$Computer"

if ($db.ContainsKey($scanKey)) {
    $db.Remove($scanKey)
    $expectedCount = $initialCount - 1
    Write-Output " > Target record identified and removed from memory."
} else {
    Write-Output "[i] Record not found in database. Nothing removed."
    return
}

# 3. WRITE BACK TO DISK (STRICT ATOMIC PROTECTION)
# We strictly enforce that the new DB is exactly 1 record smaller.
if ($db.Count -eq $expectedCount -and $initialCount -gt 0) {
    try {
        $finalList = @($db.Values | Sort-Object User)

        # STEP A: Convert to JSON *in memory* first. 
        $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($jsonOutput)) {
            throw "Generated JSON string was completely empty."
        }

        # STEP B: Write to a temporary file.
        Set-Content -Path $TempFile -Value $jsonOutput -Force -ErrorAction Stop

        # STEP C: Atomic Swap. Instantly replace the live file.
        Move-Item -Path $TempFile -Destination $HistoryFile -Force -ErrorAction Stop

    } catch {
        Write-Output "`n[!] ERROR SAVING: $($_.Exception.Message)"
        if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Output "`n[!] PROTECTION TRIGGERED: Record count mismatch. Aborting save to protect database."
}