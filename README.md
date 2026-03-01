# Unified Help Desk Console (UHDC)

> **An enterprise-grade IT support dashboard engineered for rapid live-call resolution, automated diagnostics, and technician upskilling.**

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)
![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey?logo=windows)
![License](https://img.shields.io/badge/License-Custom-orange)

**Created by:** [Bobby Burns](https://github.com/BobbyBurnsy) | **Documentation:** [UHDC.io](https://uhdc.io)

---

## 📖 Overview

The **Unified Help Desk Console (UHDC)** is an advanced, centralized dashboard built entirely in PowerShell and WPF. It was designed to solve two critical problems in modern IT support: the fragmentation of administrative portals, and the steep learning curve required to onboard new help desk technicians.

By integrating Active Directory, Microsoft Intune, and native Windows management protocols (WinRM/RPC/SMB) into a single pane of glass, the UHDC allows technicians to perform complex diagnostic and remediation tasks instantly.

### 🚀 Core Pillars

* **⚡ Live Call Resolution:** Stop putting users on hold to navigate slow web portals. Map users to their physical hardware, retrieve BitLocker keys, reset corrupted browser profiles, and push software deployments instantly while actively talking to the user.
* **🎓 Interactive Training Engine:** Don't just click buttons. The built-in Training Mode pauses execution to teach junior technicians the underlying PowerShell, WMI, and Graph API logic, transforming every support ticket into a micro-learning opportunity.
* **🎨 Enterprise Customization:** Use the standalone `ThemeManager.ps1` to hot-swap the entire color profile of the console to match your specific IT department's branding.
* **🛡️ Asynchronous Architecture:** Utilizes a multi-threaded Runspace Pool to ensure the GUI remains highly responsive, even when executing heavy network-wide scans or remote deployments.

---

## 🛠️ The Arsenal (Key Features)

* **Smart User Search:** Cross-references Active Directory profiles with historic hardware telemetry to instantly map users to their physical devices and calculate exact password expirations.
* **Intune Graph API Manager:** A contextual GUI overlay for Microsoft Entra ID. Bypass web portals to instantly retrieve Cloud LAPS passwords, reset MFA methods, and execute remote device wipes.
* **Deep Clean & Remediation:** Safely purge SCCM caches, clear stuck print spoolers, and reset corrupted Chrome/Edge profiles (while automatically backing up user bookmarks).
* **PsExec Deployment Engine:** Parses a centralized software library to silently push payloads and execute installations under the `NT AUTHORITY\SYSTEM` context, bypassing the PowerShell "Double-Hop" restriction.

---

## 🏗️ Architecture & Directory Structure

UHDC is designed with a **"Share-First"** architecture. A single central installation on a secure network share can power an entire IT department.

```text
UHDC/
├── UHDC.ps1                    # Master Console source code
├── ThemeManager.ps1            # Standalone GUI for color profile customization
├── config.json                 # Auto-generated network path & RBAC configuration
├── Core/                       # Background engines & local databases
│   ├── UserHistory.json        # The additive asset map database
│   ├── GlobalNetworkMap.ps1    # Automated asset discovery engine
│   ├── SmartUserSearch.ps1     # AD Intelligence engine
│   ├── IntuneMenu.ps1          # Graph API UI overlay
│   ├── NetworkScan.ps1         # Context-aware subnet locator
│   ├── Helper_AuditLog.ps1     # Centralized CSV auditing
│   └── psexec.exe              # (Auto-downloaded from Microsoft on first run)
├── Tools/                      # Functional workstation remediation modules
│   ├── DeepClean.ps1
│   ├── BrowserReset.ps1
│   ├── RemoteInstall.ps1
│   ├── Get-EventLogs.ps1
│   ├── Fix-PrintSpooler.ps1
│   └── ... (18 total tools)
└── Logs/                       # Presence data & audit trails
```

---

## ⚙️ Getting Started / Deployment

Windows blocks PowerShell scripts downloaded from the internet by default, and this console requires Administrator privileges for many of its core functions.

1. **Download/Extract** the repository to a secure network share accessible by your IT team (e.g., `\\Server\IT_Share\UHDC`).
2. **Unblock the Files:** Open an administrative PowerShell window and run `Unblock-File -Path \\Server\IT_Share\UHDC\* -Recurse`.
3. **First Run & Dependencies:** Execute `UHDC.ps1`. The script will detect it is running for the first time, generate a `config.json` file in the root directory, and prompt you to fill in your specific network paths. *Note: To comply with Microsoft licensing, the console will automatically download `psexec.exe` directly from `live.sysinternals.com` into your `\Core` folder during this initial setup.*
4. **Deploy to Techs:** Once configured, use the built-in **"Deploy GUI"** button within the console to push a perfectly formatted desktop shortcut to your coworkers' PCs.

---

## ⚖️ Licensing & Commercial Terms

UHDC is distributed under a tiered "Site License" model. One license covers your entire organization (unlimited technicians).

| Tier | Managed Endpoints | Annual Site License |
| :--- | :--- | :--- |
| **Community** | < 1,000 PCs | **FREE** |
| **Professional** | 1,000 - 5,000 PCs | **$499 USD** |
| **Enterprise** | 5,001 - 10,000 PCs | **$899 USD** |
| **Custom** | 10,000+ PCs | **Contact for Custom Quote** |

### 🟢 Community Use
* Free for personal use, non-profits, and educational institutions.
* Free for commercial organizations managing fewer than 1,000 computers.

### 🟡 Paid Site Licenses (Pro & Enterprise)
Organizations exceeding 1,000 endpoints must purchase an annual Site License. Fees support the continued development of the UHDC core engine.
* **Compliance:** To arrange payment and receive your **Commercial Use Certificate**, please contact [Bobby Burns](https://github.com/BobbyBurnsy) directly via GitHub.

---

## ⚠️ Legal Disclaimer & Liability Waiver

**Copyright (c) 2026 Bobby Burns. All Rights Reserved.**

**PLEASE READ CAREFULLY. BY USING THIS SOFTWARE, YOU AGREE TO THESE TERMS.**

1.  **"AS-IS" PROVISION:** This software is provided "AS IS", without warranty of any kind, express or implied.
2.  **LIMITATION OF LIABILITY:** In no event shall the author be liable for any direct, indirect, or consequential damages (including data loss or system downtime) arising from the use of this software.
3.  **NO SUPPORT:** The author is under no obligation to provide technical support or bug fixes unless a commercial SLA is negotiated.
4.  **ADMINISTRATIVE RISK:** This tool executes powerful commands (Remote File Deletion, Service Restarts, Registry Modifications, Active Directory modifications). You assume 100% of the risk associated with running these commands on your network.

---

*Built with ❤️ and PowerShell by Bobby Burns.*