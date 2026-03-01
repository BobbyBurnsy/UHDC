# --- 1. AUTO-ELEVATE ---
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

# --- 2. THE ADMIN WINDOW STARTS HERE ---
Write-Host "--- ADMIN WINDOW ACTIVE ---" -ForegroundColor Cyan
Write-Host "If this window crashes, the error will be below." -ForegroundColor Yellow
Write-Host "Working Directory: $PSScriptRoot"

try {
    # Force the location to the script folder
    Set-Location $PSScriptRoot

    $SourceFile = "UHDC-Tech.ps1"
    $OutputFile = "UHDC-Tech.exe"
    $IconFile   = "UHDC.ico"

    # Verify ps2exe exists in this Admin session
    if (-not (Get-Command ps2exe -ErrorAction SilentlyContinue)) {
        Write-Host "Installing ps2exe module for Admin user..." -ForegroundColor Cyan
        Install-Module ps2exe -Scope CurrentUser -Force
    }

    Write-Host "[>] Starting ps2exe Compilation..." -ForegroundColor White
    
    # We run it directly here
    ps2exe -inputFile $SourceFile -outputFile $OutputFile -iconFile $IconFile -noConsole -requireAdmin

    Write-Host "`n[SUCCESS] Build Finished!" -ForegroundColor Green
}
catch {
    Write-Host "`n[!] ERROR DETECTED:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor White -BackgroundColor Red
}

Write-Host "`nBUILD PROCESS COMPLETE. Press ENTER to close this window." -ForegroundColor Gray
Read-Host