@echo off
TITLE UHDC Launcher

:: Step 1: Force the script to recognize its current folder
cd /d "%~dp0"

echo Initializing Unified HelpDesk Console...
echo Unblocking downloaded script files...

:: Step 2: Unblock all .ps1 files in this folder and subfolders
powershell.exe -NoProfile -Command "Get-ChildItem -Path '%~dp0' -Recurse -Filter *.ps1 | Unblock-File"

echo Launching UHDC as Administrator...

:: Step 3: Launch the main script with Admin rights and Bypass execution policy
powershell.exe -NoProfile -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0UHDC.ps1\"' -Verb RunAs"

exit