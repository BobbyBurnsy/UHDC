# UHDC Enterprise Deployment & Security Guide
**Version:** 1.0.0 | **Classification:** Internal / Administrator Use Only

## Executive Summary
The Unified Help Desk Console (UHDC) is an agentless, multi-threaded orchestration platform designed to consolidate Active Directory, Microsoft Intune, and native Windows management protocols into a single pane of glass. 

Because the UHDC utilizes powerful administrative protocols (WinRM, RPC, PsExec) and operates under the `NT AUTHORITY\SYSTEM` context during fallback executions, **strict adherence to this deployment guide is mandatory** to prevent lateral movement vulnerabilities and ensure a Zero-Trust operational boundary.

---

## 1. Architectural Topology
The UHDC operates on a "Share-First" deployment model. It does not require a dedicated web server (like IIS or Apache) or a SQL database. 

1. **The Central Repository:** A single, secured network share hosts the UHDC codebase, the `SoftwareLibrary`, and the `UserHistory.json` database.
2. **The Micro-API Engine:** Technicians launch the console locally. The `AppLogic.ps1` script spins up a localized HTTP listener (Port 5050) on their machine, acting as the API gateway between the HTML frontend and the PowerShell backend.
3. **The Telemetry Diode:** Endpoints run a lightweight, event-driven scheduled task that drops their current IP and logged-in user into a strictly controlled "Write-Only" drop folder.

---

## 2. Prerequisites

### Network & Firewall Requirements
To ensure seamless remote remediation, the following ports must be permitted from the Help Desk VLAN to the Endpoint VLAN:
* **TCP 5985 (HTTP):** Windows Remote Management (WinRM) - *Primary Execution Protocol*
* **TCP 445 (SMB):** File Sharing - *Required for PsExec fallback and Out-of-Band data extraction*
* **TCP 135 & Dynamic RPC:** *Required for legacy WMI queries (if WinRM fails)*
* **UDP 9:** Wake-on-LAN (WoL) - *Required for Zero-Touch Mass Deployment*

### Microsoft Graph API (Entra ID)
The UHDC utilizes Pass-Through Authentication. It does **not** use a hidden Service Principal or App Registration. Technicians must already possess the appropriate Entra ID / Intune Administrator roles (e.g., *Helpdesk Administrator*, *Intune Administrator*) to execute cloud workflows.

---

## 3. Deployment Phase 1: The Zero-Trust Data Diode
The most critical security configuration is the Telemetry Drop Box. If configured incorrectly, a compromised endpoint could encrypt or delete your master asset database.

### Step 1: Create the Shares
On your secure infrastructure server (e.g., `\\CORP-FS01`), create the following directory structure:

    \UHDC_Production
        \Core
        \Tools
        \Logs
        \Config
        \TelemetryDrop

Share the root folder as a hidden share: `\\CORP-FS01\UHDC$`

### Step 2: Configure NTFS (Security) Permissions
You must create a "Write-Only" boundary for the `TelemetryDrop` folder. Endpoints must be able to drop files in, but cannot read, modify, or delete anything.

1. Right-click `\TelemetryDrop` -> **Properties** -> **Security** -> **Advanced**.
2. Disable inheritance and remove standard `Users`.
3. Add `Domain Computers`.
4. Click **Show advanced permissions**.
5. **CHECK ONLY:** `Create files / write data`, `Create folders / append data`, `Write attributes`.
6. **EXPLICITLY UNCHECK:** `Read data`, `Delete`, `Delete subfolders and files`, `Modify`.

### Step 3: Secure the Core Directory
The `\Core`, `\Tools`, and `\Logs` directories must be strictly limited to your IT Department.
* **Help Desk Security Group:** `Modify` access.
* **Domain Computers / Standard Users:** Explicit `Deny` or remove access entirely.

---

## 4. Deployment Phase 2: Endpoint Telemetry Agent
To populate the `UserHistory.json` database, you must deploy the telemetry agent to your fleet.

1. Open `Deploy-GlobalAssetTelemetry.ps1`.
2. Modify the `$DropShare` variable to point to your new drop box (e.g., `\\CORP-FS01\UHDC$\TelemetryDrop`).
3. Deploy this script to your Windows 10/11 endpoints via Microsoft Intune (as a PowerShell script) or MECM (SCCM). 
4. The script will register an Event-Driven Scheduled Task (Event ID 10000) that runs silently as `SYSTEM` whenever the computer connects to a network.

---

## 5. Deployment Phase 3: Console Initialization
1. Have a technician map to the `\\CORP-FS01\UHDC$` share.
2. Run `Launch-UHDC.cmd`.
3. On the first run, the console will generate a `config.json` file in the `\Config` directory.
4. Open `\Config\config.json` and configure your specific environment variables:
   * `TenantDomain`: Your primary Microsoft 365 domain (e.g., `acmecorp.com`). *This enforces the cross-tenant security boundary.*
   * `ImportantGroups`: An array of AD group keywords you want highlighted in the UI (e.g., `["VPN", "Admin"]`).
   * `Trainees`: An array of junior technician usernames (e.g., `["jsmith", "tjones"]`). *Users in this list are permanently locked into the Interactive Training Engine.*

5. Restart the console. The platform is now live.
