# Unified Help Desk Console (UHDC)
**Architected by:** Bobby Burns  
**Version:** 1.0.0  

The Unified Help Desk Console (UHDC) is an advanced, multi-threaded, web-driven orchestration platform designed for Enterprise IT Help Desks. It replaces fragmented scripts and portals with a "Single Pane of Glass" HTML dashboard powered by a local PowerShell Micro-API engine.

---

## ⚠️ CRITICAL LEGAL DISCLAIMER & LIABILITY WAIVER
**READ CAREFULLY BEFORE DEPLOYING THIS SOFTWARE.**

By downloading, installing, or using the Unified Help Desk Console (UHDC), you acknowledge and agree to the following:

1. **NO WARRANTY:** This software is provided "AS IS", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement.
2. **ZERO LIABILITY:** In no event shall the author (**Bobby Burns**) or contributors be liable for any claim, damages, financial loss, data loss, network breaches, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with the software or the use or other dealings in the software.
3. **MISCONFIGURATION RISK:** This software utilizes powerful administrative tools (including PsExec, WinRM, and WMI) running under the `SYSTEM` context. **Improper configuration of the Telemetry Drop Box architecture (detailed below) can expose your network to lateral movement or ransomware attacks.** You are solely responsible for verifying your NTFS and Share permissions, firewall rules, and Active Directory configurations. 
4. **USE AT YOUR OWN RISK:** You assume all responsibility for testing this software in a secure development environment prior to production deployment.

---

## 🚀 Core Architecture

UHDC is built on a highly resilient, fault-tolerant execution pipeline:
* **Micro-API Engine:** `AppLogic.ps1` acts as a local web server (Port 5050), routing JSON payloads between the HTML frontend and the PowerShell backend.
* **WinRM-to-PsExec Fallback:** Every remote tool attempts to execute natively via WinRM for maximum speed. If RPC traffic is blocked by endpoint firewalls, the engine seamlessly encodes the payload into Base64 and forces execution via PsExec under the `SYSTEM` context.
* **Out-of-Band Data Extraction:** Tools like Event Forensics and Bookmark Backups bypass SMB file-sharing firewalls by encoding files into Base64 strings on the target, transmitting them via standard output streams, and decoding them locally.

## 🛠️ Capabilities

### 1. Intelligence & Telemetry
* **Identity & Asset Correlation:** Instantly maps users to their physical devices using AD attributes and historical telemetry.
* **Global Asset Telemetry:** A Zero-Trust background engine that tracks user IP and device changes in real-time.
* **Cloud Identity Orchestrator:** A Graph API overlay for Entra ID/Intune to retrieve BitLocker keys, LAPS passwords, and manage MFA without opening a web portal.

### 2. Endpoint Remediation
* **Zero-Touch Mass Deployment:** PDQ-style parallel software deployment to single or comma-separated lists of computers.
* **Deep Storage Remediation:** Safely purges MECM caches, Temp folders, and triggers background Disk Cleanup.
* **Chromium Profile Rebuild:** Backs up bookmarks, kills locked processes, wipes corrupted AppData, and restores bookmarks.
* **Service & Network Orchestration:** Remotely fixes Print Spoolers, forces GPUpdates, restarts MECM agents, and remediates DNS routing issues.

### 3. Diagnostics & Forensics
* **Advanced Event Forensics:** Deep-scans remote event logs and returns a styled HTML table while silently saving a full CSV backup.
* **Hardware Degradation Analysis:** Queries raw WMI classes to calculate exact battery health (mWh) and degradation percentages.
* **Automated Warranty Routing:** Extracts BIOS serial numbers and dynamically generates links to Dell, Lenovo, HP, or Microsoft warranty portals.

---

## 🔒 REQUIRED SETUP: Zero-Trust Telemetry Drop Box (Standard Deployment)

To track users in real-time without increasing your endpoint attack surface, UHDC uses an Event-Driven Agent (`Deploy-GlobalAssetTelemetry.ps1`). When a user connects to the network, the agent drops a tiny JSON file into a central network share.

**If you do not configure these permissions exactly as written, a compromised endpoint could encrypt or delete your master database.**

### Step 1: Create the Share
1. On your server, create a folder named `TelemetryDrop`.
2. Share it as a hidden share: `TelemetryDrop$`

### Step 2: Configure Share Permissions
* Grant `Domain Computers` -> **Change** and **Read**.

### Step 3: Configure NTFS (Security) Permissions (CRITICAL)
This creates a "Write-Only Data Diode." Endpoints can drop files in, but cannot read, modify, or delete anything.
1. Right-click the folder -> **Properties** -> **Security** -> **Advanced**.
2. Disable inheritance and remove standard Users/Computers.
3. Add `Domain Computers`.
4. Click **Show advanced permissions**.
5. **CHECK ONLY THE FOLLOWING:**
   * `Create files / write data`
   * `Create folders / append data`
   * `Write attributes`
6. **ENSURE THESE ARE UNCHECKED:**
   * `Read data`
   * `Delete`
   * `Delete subfolders and files`
   * `Modify`

### Step 4: Deploy the Agent
Deploy `Deploy-GlobalAssetTelemetry.ps1` to your endpoints via Intune, MECM, or GPO. Ensure you edit the `$DropShare` variable inside the script to point to your new `\\Server\TelemetryDrop$` share.

---

## 🏢 Enterprise SQL Architecture (20,000+ Endpoints)

The standard JSON flat-file database and SMB Drop Box architecture is highly efficient for small-to-medium enterprises. However, in massive environments exceeding 20,000 endpoints, the volume of concurrent network events (e.g., the "8:00 AM Logon Storm") can bottleneck standard SMB file shares.

If you are deploying UHDC in a massive, multi-domain forest, **do not use the standard JSON setup.** Instead, navigate to the **`20KPLUS`** directory included in this repository. It contains a **Direct-to-SQL telemetry pipeline** that replaces the JSON architecture. 
* **Infinite Concurrency:** Endpoints execute lightweight SQL commands directly against the database.
* **Integrated Security:** Utilizes Active Directory Computer Accounts (`DOMAIN\PC$`) to authenticate to the SQL server, eliminating hardcoded credentials.
* **Microsecond Lookups:** The UI queries the SQL database directly, returning asset locations instantly regardless of fleet size.

Please read the `Enterprise_Deployment_Guide.md` located inside the `20KPLUS` folder for strict SQL schema and firewall hardening instructions.

---

## 💳 Pricing & Licensing

UHDC is available in three tiers to accommodate organizations of any size, from small teams to global enterprises.

### COMMUNITY
**$0**
*Free forever for up to 3 Technicians.*
* Up to 1,000 Managed Endpoints
* Full Active Directory Integration
* Microsoft Graph API / Intune Modules
* Interactive Training Engine
* Zero Hidden Telemetry

### PROFESSIONAL
**$499 /tech/yr**
*For growing IT departments and MSPs.*
* **Everything in Community, plus:**
* Unlimited Managed Endpoints
* Commercial Use Certificate
* Priority Email Support
* Funds continued core development

### CUSTOM
**Let's Talk**
*For massive, multi-domain global enterprises.*
* **Everything in Professional, plus:**
* Optimized for multi-domain forests
* Distributed scanning nodes
* Dedicated Account Manager
* Custom deployment consultation

---

## 💻 How to Launch

1. Clone or download this repository to your local machine.
2. Ensure you have local Administrator privileges.
3. Double-click **`Launch-UHDC.cmd`**.
   * *This script will automatically request UAC elevation, bypass local execution policies, start the API engine, and launch the dashboard in Microsoft Edge App Mode.*
4. On first run, a `config.json` file will be generated in the `\Config` folder. Open it, enter your Tenant Domain, and restart the console.

---
*Engineered for Enterprise IT. Built by Bobby Burns.*