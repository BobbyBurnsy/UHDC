# Helper_UpdateHistory.ps1 - Place this script in the \Core folder
# DESCRIPTION: Manually injects or updates a specific User-to-PC mapping 
# inside the central UserHistory.json database. This is triggered by the GUI's 
# "Add PC" button, allowing techs to instantly update a user's location 
# without waiting for the Global Network Map to run.

param(
    [Parameter(Mandatory=$false)]
    [string]$User,
    
    [Parameter(Mandatory=$false)]
    [string]$Computer,
    
    [Parameter(Mandatory=$false)]
    [string]$SharedRoot
)

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
            Write-Host " [UHDC] [!] Error: SharedRoot path is missing and config.json not found." -ForegroundColor Red
            return
        }
    } catch {
        Write-Host " [UHDC] [!] Error: Failed to resolve SharedRoot." -ForegroundColor Red
        return
    }
}

if ([string]::IsNullOrWhiteSpace($User) -or [string]::IsNullOrWhiteSpace($Computer)) {
    Write-Host " [UHDC] [!] Error: User and Computer must be provided." -ForegroundColor Red
    return
}

# Use Join-Path to guarantee perfect slashes (Updated to target the Core folder)
$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"
$BackupFile  = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.bak"
$TempFile    = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.tmp"

# 1. READ EXISTING DATABASE SAFELY
$db = @{}
$initialCount = 0

if (Test-Path $HistoryFile) {
    # CRITICAL: Only backup if the file is healthy (>100 bytes).
    # This stops a corrupted 0-byte file from overwriting a good backup.
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
        Write-Host "`n [UHDC] [!] CRITICAL: JSON Parsing failed. Aborting to prevent data wipe." -ForegroundColor Red
        return
    }
}

# 2. ADD OR UPDATE THE RECORD
$scanKey = "$User-$Computer"
$timeStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm")

if ($db.ContainsKey($scanKey)) {
    $db[$scanKey].LastSeen = $timeStamp
    $db[$scanKey].Source   = "UHDC-Update"
} else {
    # Cast as PSCustomObject so it perfectly matches the parsed JSON format
    $db[$scanKey] = [PSCustomObject]@{
        User     = $User
        Computer = $Computer
        LastSeen = $timeStamp
        Source   = "UHDC-Update"
    }
}

# 3. WRITE BACK TO DISK (ATOMIC & PROTECTED)
if ($db.Count -ge $initialCount -and $db.Count -gt 0) {
    try {
        $finalList = @($db.Values | Sort-Object User)
        
        # STEP A: Convert to JSON *in memory* first. 
        # If this crashes, the file is untouched.
        $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -ErrorAction Stop
        
        if ([string]::IsNullOrWhiteSpace($jsonOutput)) {
            throw "Generated JSON string was completely empty."
        }
        
        # STEP B: Write to a temporary file.
        Set-Content -Path $TempFile -Value $jsonOutput -Force -ErrorAction Stop
        
        # STEP C: Atomic Swap. Instantly replace the live file.
        Move-Item -Path $TempFile -Destination $HistoryFile -Force -ErrorAction Stop
        
    } catch {
        Write-Host "`n [UHDC] [!] ERROR SAVING: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Host "`n [UHDC] [!] PROTECTION TRIGGERED: Attempted to save fewer records than loaded." -ForegroundColor Red
    Write-Host "      Operation aborted to protect database." -ForegroundColor Yellow
}