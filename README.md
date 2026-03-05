# Unified Help Desk Console (UHDC) - WPF Edition

**Version:** 9.0 (Classic WPF Architecture)  
**Compatibility:** Windows PowerShell 5.1 Native  
**Author / Lead Engineer:** Bobby Burns  

---

## 📜 License & Attribution
The WPF version of the Unified Help Desk Console is **100% Freeware**. You are free to deploy, modify, and use this tool within your organization without any cost. 

**Attribution Requirement:** If you borrow, fork, or adapt any scripts, XAML layouts, or underlying code from this project for your own tools, you **must** provide explicit credit to **Bobby Burns** and a link to my github page **www.github.com/BobbyBurnsy** in your documentation and source code.

---

## 🚀 Overview
The Unified Help Desk Console (UHDC) is a centralized, asynchronous WPF GUI built entirely in PowerShell 5.1. It is designed to empower IT Help Desk technicians, System Administrators, and Master Admins by consolidating Active Directory intelligence, Microsoft Intune management, and remote endpoint remediation into a single, high-performance dashboard.

By utilizing PowerShell Runspaces, the UHDC ensures the GUI remains fluid and responsive while executing heavy network scans, WMI queries, and API calls in the background.

## ✨ Key Features

*   **PowerShell 5.1 Native:** Fully optimized for the native Windows 10/11 environment. No PowerShell 7 installation required. Uses `.NET Ping` classes to prevent legacy WMI/DNS terminating errors.
*   **Asynchronous WPF Architecture:** A dynamic 4-quadrant layout. Active Directory intelligence is anchored on the left, while the Command Center and Help Desk Tools are docked on the right.
*   **Interactive Training Mode:** A gamified, step-by-step execution engine. Junior technicians can see the exact PowerShell code being executed, read plain-English explanations of what the code does, and earn XP for completing tasks.
*   **Intune & Entra ID Integration:** A dedicated Intune menu powered by the Microsoft Graph API (enforcing TLS 1.2). Manage BitLocker keys, Cloud LAPS, Remote Wipes, and User MFA methods with strict cross-agency domain filtering.
*   **Smart User Tracking:** Automatically correlates users to their physical PCs using a central `UserHistory.json` database, backed by the `NetworkScan.ps1` intelligence engine.
*   **Custom Theme Engine:** Personalize your console with built-in themes or create a **Custom** profile. Features a signature neon glow aesthetic:
    *   🔵 **Blue/Accent:** Standard actions.
    *   🔴 **Red:** Destructive/Danger actions (e.g., Remote Wipe, Force Restart).
    *   🟣 **Purple:** Master Admin tasks (e.g., Global Network Map, Deploy GUI).
*   **PsExec Fallbacks:** Automated firewall bypasses. If WinRM is blocked, tools automatically fall back to using `psexec.exe` to execute native commands locally on the target.

---

## 📂 File Structure
To ensure the console operates correctly, the files must be organized on your shared network drive as follows:

```text
\\YOUR-SERVER\Share\UHDC\
│
├── UHDC.ps1                 # The Master GUI Script
├── UHDC.exe                 # Compiled executable (via ps2exe)
├── UHDC.ico                 # Application Icon
├── config.json              # Auto-generated on first run
│
├── Core\                    # Core Intelligence & Helper Scripts
│   ├── NetworkScan.ps1      # (NOTE: Located here, NOT in Tools)
│   ├── GlobalNetworkMap.ps1
│   ├── SmartUserSearch.ps1
│   ├── IntuneMenu.ps1
│   ├── Helper_AuditLog.ps1
│   ├── Helper_CheckSessions.ps1
│   ├── Helper_UpdateHistory.ps1
│   ├── Helper_RemoveHistory.ps1
│   ├── psexec.exe           # Required for firewall fallbacks
│   ├── UserHistory.json     # Auto-generated tracking database
│   └── users.json           # Auto-generated user preferences/XP
│
├── Tools\                   # Endpoint Remediation Scripts
│   ├── BookmarkBackup.ps1
│   ├── BrowserReset.ps1
│   ├── Check-BitLocker.ps1
│   ├── DeepClean.ps1
│   ├── Enable-RemoteDesktop.ps1
│   ├── Fix-PrintSpooler.ps1
│   ├── Get-BatteryReport.ps1
│   ├── Get-EventLogs.ps1
│   ├── Get-LocalAdmins.ps1
│   ├── Get-NetworkInfo.ps1
│   ├── Get-SmartWarranty.ps1
│   ├── Get-Uptime.ps1
│   ├── Invoke-GPUpdate.ps1
│   ├── PushRefreshDrives.ps1
│   ├── Register-DNS.ps1
│   ├── RemoteInstall.ps1
│   ├── Restart-SCCMAgent.ps1
│   └── RestartPC.ps1
│
└── Logs\                    # Audit and Presence Tracking
    ├── ConsoleAudit.csv     # Centralized action logging
    └── Presence\            # Heartbeat files for active technicians