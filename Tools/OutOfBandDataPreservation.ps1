<#
.SYNOPSIS
    UHDC Web-Ready Tool: OutOfBandDataPreservation.ps1
.DESCRIPTION
    Securely extracts Google Chrome and Microsoft Edge bookmarks for a specified user.
    Bypasses SMB/File Sharing firewalls by reading the files locally on the target,
    encoding them to Base64, and transmitting them back via standard output streams.
    Attempts WinRM first. If blocked, falls back to PsExec as SYSTEM.
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# ====================================================================
# TRAINING DATA EXPORT (For Web UI Modal)
# ====================================================================
if ($GetTrainingData) {
    $data = @{
        StepName = "OUT-OF-BAND DATA PRESERVATION"
        Description = "We are bypassing standard SMB file-sharing firewalls using an Out-of-Band extraction technique. We execute a payload on the target that reads the user's Chrome and Edge bookmark files, encodes them into Base64 strings, and transmits them back to our console via standard command output streams. We then decode the strings locally and reconstruct the files. We attempt this over WinRM first, and fall back to PsExec if RPC is blocked."
        Code = "try { `$out = Invoke-Command -ComputerName `$Target -ScriptBlock `$Payload } catch { `$out = psexec.exe \\`$Target -s powershell.exe -EncodedCommand `$Base64 }`n# Decode Base64 output back into files locally"
        InPerson = "Opening File Explorer, typing '%LocalAppData%\Google\Chrome\User Data\Default' into the address bar, copying the 'Bookmarks' file, and saving it to a flash drive."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# ====================================================================
# CORE EXECUTION
# ====================================================================
Write-Output "========================================"
Write-Output "[UHDC] OUT-OF-BAND DATA PRESERVATION"
Write-Output "========================================"

# 1. VALIDATION
if ([string]::IsNullOrWhiteSpace($Target) -or [string]::IsNullOrWhiteSpace($TargetUser)) { 
    Write-Output "[!] ERROR: Both Target PC and Target User are required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "Out-of-Band Data Preservation Executed ($TargetUser)"

# 2. SETUP LOCAL DESTINATION
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmm")
$destFolder = "C:\UHDC\Bookmarks\$Target-$TargetUser-$timestamp"
if (-not (Test-Path $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }

# 3. DEFINE BASE64 EXTRACTION PAYLOAD
# This payload reads the files, encodes them, and wraps them in unique delimiters
$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'
    `$User = '$TargetUser'
    `$cPath = `"C:\Users\`$User\AppData\Local\Google\Chrome\User Data\Default\Bookmarks`"
    `$ePath = `"C:\Users\`$User\AppData\Local\Microsoft\Edge\User Data\Default\Bookmarks`"

    if (Test-Path `$cPath) {
        `$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes(`$cPath))
        Write-Output `"---CHROME_START---`$b64---CHROME_END---`"
    }
    if (Test-Path `$ePath) {
        `$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes(`$ePath))
        Write-Output `"---EDGE_START---`$b64---EDGE_END---`"
    }
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)
$RawOutput = $null
$MethodUsed = "WinRM"

# 4. EXECUTE REMOTE EXTRACTION
try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    Write-Output " > Extracting and encoding bookmarks..."

    $RawOutput = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $PayloadBlock
} catch {
    Write-Output "[!] WinRM Failed or Blocked. Initiating PsExec Fallback..."
    $MethodUsed = "PsExec"

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"
    if (Test-Path $psExecPath) {
        try {
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            $ArgsList = "/accepteula \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            # Capture the output stream directly from PsExec
            $RawOutput = & $psExecPath $ArgsList 2>&1
            $ActionLog += " [PsExec Fallback]"
        } catch {
            Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed."
            Write-Output "    Details: $($_.Exception.Message)"
            return
        }
    } else {
        Write-Output "`n[!] FATAL ERROR: WinRM failed and psexec.exe is missing from \Core."
        return
    }
}

# 5. DECODE AND RECONSTRUCT FILES LOCALLY
Write-Output " > Decoding Base64 streams and reconstructing files..."

# Join the output array into a single string to easily regex across it
$FullOutputString = $RawOutput -join ""
$foundData = $false

# Parse Chrome
if ($FullOutputString -match '---CHROME_START---(.*?)---CHROME_END---') {
    try {
        $bytes = [Convert]::FromBase64String($matches[1])
        [IO.File]::WriteAllBytes("$destFolder\Chrome_Bookmarks", $bytes)
        Write-Output " > [OK] Chrome Bookmarks successfully secured."
        $foundData = $true
    } catch { Write-Output " > [!] Error decoding Chrome data." }
} else {
    Write-Output " > [i] No Chrome bookmarks found for this user."
}

# Parse Edge
if ($FullOutputString -match '---EDGE_START---(.*?)---EDGE_END---') {
    try {
        $bytes = [Convert]::FromBase64String($matches[1])
        [IO.File]::WriteAllBytes("$destFolder\Edge_Bookmarks", $bytes)
        Write-Output " > [OK] Edge Bookmarks successfully secured."
        $foundData = $true
    } catch { Write-Output " > [!] Error decoding Edge data." }
} else {
    Write-Output " > [i] No Edge bookmarks found for this user."
}

# 6. FINISH & OPEN FOLDER
if ($foundData) {
    Write-Output "`n[UHDC SUCCESS] Data Preservation complete via $MethodUsed! Opening local destination folder..."
    Start-Process explorer.exe -ArgumentList "/select,`"$destFolder`""

    # --- AUDIT LOG INJECTION ---
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action $ActionLog -SharedRoot $SharedRoot
        }
    }
} else {
    Write-Output "`n[!] No bookmarks found for user $TargetUser on $Target."
    Remove-Item $destFolder -Force -ErrorAction SilentlyContinue
}