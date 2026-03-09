# Unified Help Desk Console (UHDC)

**Version:** 1.0.0  
**Architecture:** Agentless, Multi-Threaded Orchestration  
**License:** GNU General Public License v3.0 (See LICENSE.md)

## Executive Summary
The Unified Help Desk Console (UHDC) is an enterprise-grade orchestration platform designed to consolidate Active Directory, Microsoft Intune, and native Windows management protocols into a single pane of glass. It bridges the gap between complex backend infrastructure and Tier 1 help desk usability, drastically reducing Mean Time to Resolution (MTTR) through Live-Call Remediation.

⚠️ **SECURITY WARNING & LIABILITY DISCLAIMER**  
The UHDC utilizes powerful administrative protocols (WinRM, RPC, PsExec) and operates under the NT AUTHORITY\SYSTEM context during fallback executions. Misconfiguration of the network shares or SQL databases can expose your environment to lateral movement vulnerabilities. **This software is provided "AS IS", without warranty of any kind.** By deploying this software, you assume all risks associated with its use. Please read LICENSE.md for the full liability waiver before proceeding.

---

## 1. Architectural Prerequisites

### Network & Firewall Requirements
To ensure seamless remote remediation, the following ports must be permitted from the Help Desk VLAN to the Endpoint VLAN:
* **TCP 5985 (HTTP):** Windows Remote Management (WinRM) - Primary Execution Protocol
* **TCP 445 (SMB):** File Sharing - Required for PsExec fallback and Out-of-Band data extraction
* **TCP 135 & Dynamic RPC:** Required for legacy WMI queries (if WinRM fails)
* **UDP 9:** Wake-on-LAN (WoL) - Required for Zero-Touch Mass Deployment

### Workstation Dependencies
Technicians running the console must have the following installed on their local machines:
* **RSAT: Active Directory Domain Services** (For LDAP queries)
* **Microsoft Graph API Modules** (For Intune/Entra ID integration)

*Note: You can run Install-UHDCDependencies.ps1 as Administrator to automatically bootstrap these requirements.*

---

## 2. Standard Deployment Guide (Environments < 10,000 Endpoints)

The standard deployment utilizes a "Share-First" architecture. It relies on a highly efficient, flat-file JSON database and an SMB drop-box to track asset telemetry with zero infrastructure overhead.

### Step 1: Create the Central Repository
On your secure infrastructure server (e.g., \\CORP-FS01), create the following directory structure and share the root folder as a hidden share (e.g., \\CORP-FS01\UHDC$):

    \UHDC_Production
        \Core
        \Tools
        \Logs
        \Config
        \TelemetryDrop

### Step 2: Secure the Zero-Trust Data Diode
The \TelemetryDrop folder must be configured as a "Write-Only" boundary. Endpoints must be able to drop files in, but cannot read, modify, or delete anything.
1. Right-click \TelemetryDrop -> Properties -> Security -> Advanced.
2. Disable inheritance and remove standard Users.
3. Add Domain Computers.
4. Click Show advanced permissions.
5. CHECK ONLY: Create files / write data, Create folders / append data, Write attributes.
6. EXPLICITLY UNCHECK: Read data, Delete, Delete subfolders and files, Modify.

### Step 3: Deploy the Telemetry Agent
1. Open Deploy-GlobalAssetTelemetry.ps1.
2. Modify the $DropShare variable to point to your new drop box (e.g., \\CORP-FS01\UHDC$\TelemetryDrop).
3. Deploy this script to your Windows 10/11 endpoints via Microsoft Intune or MECM (SCCM). It registers an Event-Driven Scheduled Task (Event ID 10000) that runs silently as SYSTEM.

### Step 4: Console Initialization
1. Have a technician map to the \\CORP-FS01\UHDC$ share and run Launch-UHDC.cmd.
2. On the first run, the console will generate a config.json file in the \Config directory.
3. Open \Config\config.json and configure your TenantDomain (e.g., acmecorp.com) to enforce cross-tenant security boundaries.
4. Restart the console.

---

## 3. Enterprise Deployment Guide (10K+ Endpoints / SQL Architecture)

For global, multi-domain forests exceeding 20,000 endpoints, standard SMB file shares will bottleneck during morning logon storms. The UHDC seamlessly pivots to a Direct-to-SQL telemetry pipeline to eliminate file-lock contention.

### Step 1: Database Preparation
On your Microsoft SQL Server, create a new database named UHDCTelemetry. Execute the following query to build the schema:

    CREATE TABLE AssetTelemetry (
        Username VARCHAR(100),
        ComputerName VARCHAR(100),
        IPAddress VARCHAR(50),
        MACAddress VARCHAR(50),
        LastSeen DATETIME,
        PRIMARY KEY (Username, ComputerName)
    );
    CREATE INDEX IX_Username ON AssetTelemetry(Username);
    CREATE INDEX IX_ComputerName ON AssetTelemetry(ComputerName);

### Step 2: Create the Stored Procedure (Least Privilege)
To prevent a compromised endpoint from dropping your SQL table, create this Stored Procedure to handle the upsert logic:

    CREATE PROCEDURE dbo.UpsertAssetTelemetry
        @Username VARCHAR(100), @ComputerName VARCHAR(100), @IPAddress VARCHAR(50), @MACAddress VARCHAR(50), @LastSeen DATETIME
    AS
    BEGIN
        SET NOCOUNT ON;
        MERGE INTO AssetTelemetry AS target
        USING (SELECT @Username AS Username, @ComputerName AS ComputerName) AS source
        ON target.Username = source.Username AND target.ComputerName = source.ComputerName
        WHEN MATCHED THEN UPDATE SET IPAddress = @IPAddress, MACAddress = @MACAddress, LastSeen = @LastSeen
        WHEN NOT MATCHED THEN INSERT (Username, ComputerName, IPAddress, MACAddress, LastSeen) VALUES (@Username, @ComputerName, @IPAddress, @MACAddress, @LastSeen);
    END

*Grant the Domain Computers AD group EXECUTE permissions on this Stored Procedure. Do not grant them direct table access.*

### Step 3: Upgrade the UHDC Core
1. Open your central \Config\config.json file and add your SQL connection string:
   "Database": { "ConnectionString": "Server=tcp:YOUR-SQL-SERVER,1433;Initial Catalog=UHDCTelemetry;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;" }
2. Navigate to your central \Core directory.
3. Delete the existing IdentityAssetCorrelation.ps1 (the JSON version).
4. Copy the new IdentityAssetCorrelation.ps1 from the 20KPLUS folder into the \Core directory.
5. You may now safely delete the \TelemetryDrop folder and the GlobalAssetTelemetry.ps1 background aggregator, as they are no longer needed.

### Step 4: Deploy the SQL Endpoint Agent
1. Open Deploy-GlobalAssetTelemetry-SQL.ps1 from the 20KPLUS folder.
2. Update the $SqlConnectionString variable inside the payload to match your SQL Server.
3. Deploy this script to your fleet via Intune or MECM. The endpoints will now authenticate directly to SQL using their Active Directory Computer Accounts (DOMAIN\PC$).

---

## 4. Security & Governance

The UHDC operates on a Zero-Trust architectural philosophy:
* **Identity-First RBAC:** The console utilizes Pass-Through Authentication via the Connect-MgGraph module. It operates strictly on Delegated Permissions and cannot grant technicians any access they do not natively possess in Entra ID.
* **Immutable Audit Trails:** Every execution is piped into a centralized, timestamped CSV database (or Windows Event Log in the 20K+ architecture) via SMB/RPC. It programmatically stamps the technician’s identity and the target hardware ID for forensic review.
* **No Hidden Telemetry:** All organizational execution data, asset maps, and audit logs remain exclusively within your tenant’s controlled environment. The software does not "phone home."

