# Unified Help Desk Console (UHDC)

**Version:** 1.0.0  
**Architecture:** Agentless, Multi-Threaded Orchestration  
**License:** Dual-Licensed (Community GPLv3 / Commercial Enterprise)

## Executive Summary
The Unified Help Desk Console (UHDC) is an enterprise-grade orchestration platform designed to consolidate Active Directory, Microsoft Intune, and native Windows management protocols into a single pane of glass. 

By bridging the gap between complex backend infrastructure and Tier 1 help desk usability, the UHDC enables Live-Call Remediation—allowing technicians to resolve complex endpoint issues on the first touch without requiring users to navigate portals or wait for background syncs.

---

## 1. Security Architecture & Attack Surface Assessment

Deploying any centralized orchestration tool inherently alters your network's attack surface. The UHDC is engineered to minimize this footprint by operating on a **100% Agentless** architecture, but it relies heavily on the integrity of your internal network permissions. 

Please review the following honest assessment of the attack surface and the required mitigations before deployment.

### The Risks
1. **The Centralized Script Repository:** The UHDC operates from a central network share (`UHDC$`). If an attacker gains write access to this share, they could inject malicious code into the `.ps1` files. Because Help Desk technicians execute these scripts with high privileges against endpoints, this represents a severe supply-chain/lateral movement risk.
2. **Execution Protocols:** The UHDC utilizes Windows Remote Management (WinRM) and PsExec (SMB/RPC) to execute commands. PsExec operates under the `NT AUTHORITY\SYSTEM` context on the target machine. If these ports are left open globally across your network, they can be leveraged by ransomware for lateral movement.

### The Mitigations (How to secure the UHDC)
1. **Strict NTFS Isolation:** The `UHDC$` share must be locked down using the Principle of Least Privilege. Standard users and standard endpoints must have **Zero Access** (not even Read access) to this directory. Only authorized IT personnel should have `Modify` rights.
2. **Network Micro-Segmentation:** Do not open WinRM (TCP 5985) or SMB (TCP 445) globally via Group Policy. You must restrict inbound traffic on these ports at the Windows Defender Firewall level so that endpoints only accept connections originating from your dedicated IT/Help Desk IP subnets.
3. **Agentless Telemetry:** Unlike legacy tools, the UHDC does not require endpoints to write telemetry data to a central drop-box. The central database (`UserHistory.json`) is updated exclusively by the Help Desk technicians' machines via authenticated WMI polling, eliminating the need for globally writable network shares.

---

## 2. Architectural Prerequisites

### Network & Firewall Requirements
To ensure seamless remote remediation, the following ports must be permitted **from the Help Desk VLAN to the Endpoint VLAN**:
* **TCP 5985 (HTTP):** Windows Remote Management (WinRM) - *Primary Execution Protocol*
* **TCP 445 (SMB):** File Sharing - *Required for PsExec fallback and Out-of-Band data extraction*
* **TCP 135 & Dynamic RPC:** *Required for legacy WMI queries (if WinRM fails)*
* **UDP 9:** Wake-on-LAN (WoL) - *Required for Zero-Touch Mass Deployment*

### Workstation Dependencies
Technicians running the console must have the following installed on their local machines:
* **RSAT: Active Directory Domain Services** (For LDAP queries)
* **Microsoft Graph API Modules** (For Intune/Entra ID integration)

*Note: You can run `Install-UHDCDependencies.ps1` as Administrator to automatically bootstrap these requirements on a new technician's workstation.*

---

## 3. Standard Deployment Guide (Environments < 20,000 Endpoints)

The standard deployment utilizes a "Share-First" architecture. It relies on a highly efficient, flat-file JSON database and background WMI polling to track asset telemetry with zero infrastructure overhead.

### Step 1: Create the Central Repository
On your secure infrastructure server (e.g., `\\CORP-FS01`), create the following directory structure and share the root folder as a hidden share (e.g., `\\CORP-FS01\UHDC$`):

    \UHDC_Production
        \Core
        \Tools
        \Logs
        \Config

### Step 2: Lock Down NTFS Permissions (Critical)
You must strictly limit access to this share to prevent lateral movement or script tampering.
1. Right-click the `\UHDC_Production` folder -> **Properties** -> **Security** -> **Advanced**.
2. Disable inheritance and remove standard `Users` and `Domain Computers`.
3. Add your **Help Desk / IT Security Group** and grant them `Modify` access.
4. Verify that standard users cannot read or write to this directory.

### Step 3: Console Initialization
1. Have a technician map to the `\\CORP-FS01\UHDC$` share and run `Launch-UHDC.cmd`.
2. On the first run, the console will generate a `config.json` file in the `\Config` directory.
3. Open `\Config\config.json` and configure your `TenantDomain` (e.g., `acmecorp.com`) to enforce cross-tenant security boundaries for the Microsoft Graph API.
4. Restart the console.

### Step 4: Populate the Intelligence Database
Because the UHDC is agentless, it must scan the network to build its initial User-to-Computer map.
1. In the UHDC Web UI, click **Network Asset Tracker** in the left sidebar.
2. The console will spawn a background PowerShell engine that queries Active Directory for all active workstations, pings them, and extracts the logged-in user and MAC address via WMI.
3. *Note: For a network of ~4,000 endpoints, this scan takes approximately 60-90 minutes. You can schedule this script (`\Core\NetworkAssetTracker.ps1`) to run daily via a standard Windows Scheduled Task on your management server to keep the database fresh.*

---

## 4. Enterprise Deployment Guide (20K+ Endpoints / SQL Architecture)

For massive, global, multi-domain forests exceeding 20,000 endpoints, standard SMB file shares will eventually bottleneck during morning logon storms, and WMI ping sweeps take too long to complete. 

For these environments, the UHDC seamlessly pivots to a **Direct-to-SQL telemetry pipeline**. 

If you are deploying to an environment of this size, please refer to the `20KPLUS_Architecture.md` guide located in the `\20KPLUS` directory. It contains instructions for building the SQL schema, deploying the SQL-based endpoint agent, and implementing Microsoft JEA (Just Enough Administration) for absolute Zero-Trust execution.

---

## 5. Disclaimer of Warranty and Limitation of Liability

**READ CAREFULLY BEFORE DEPLOYING THIS SOFTWARE IN A PRODUCTION ENVIRONMENT.**

The Unified Help Desk Console (UHDC) is a powerful administrative orchestration tool. It is designed to execute commands, modify system configurations, and deploy software across enterprise networks using highly privileged protocols.

MISCONFIGURATION OF THE NETWORK SHARES, SQL DATABASES, OR EXECUTION POLICIES REQUIRED BY THIS SOFTWARE CAN EXPOSE YOUR NETWORK TO SEVERE SECURITY VULNERABILITIES. 

THIS SOFTWARE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND. BY DEPLOYING THIS SOFTWARE, YOU ASSUME ALL RISKS ASSOCIATED WITH ITS USE. Please read `LICENSE.md` for the full liability waiver and dual-licensing terms before proceeding.
