@echo off
TITLE UHDC - Unified Help Desk Console
COLOR 0B

:: --- 1. Check for Administrator Privileges ---
:: (Required to start the local web server, modify local firewall, and run PsExec)
net session >nul 2>&1
if %errorLevel% == 0 (
    goto :AdminConfirmed
) else (
    echo [!] Administrative privileges required. Requesting elevation...
    powershell -Command "Start-Process '%~dpnx0' -Verb RunAs"
    exit /b
)

:AdminConfirmed
:: --- 2. Map UNC paths and change to the script directory ---
:: (pushd is critical here because cmd.exe does not support UNC paths natively)
pushd "%~dp0"

CLS
echo =======================================================
echo  [UHDC] UNIFIED HELP DESK CONSOLE
echo  Engineered for Enterprise IT
echo =======================================================
echo.

:: --- 3. Verify Core Engine Exists ---
if not exist "AppLogic.ps1" (
    COLOR 0C
    echo [!] FATAL ERROR: AppLogic.ps1 not found.
    echo     Please ensure you are launching this from the root UHDC directory.
    pause
    exit /b
)

echo [i] Initializing Micro-API Engine...
echo [i] Please leave this window open. Closing it will terminate the console.
echo.

:: --- 4. Launch the PowerShell Engine ---
:: (Bypassing local execution policies)
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "AppLogic.ps1"

:: --- 5. Cleanup and Exit ---
:: (If the engine crashes or is closed)
popd
pause
