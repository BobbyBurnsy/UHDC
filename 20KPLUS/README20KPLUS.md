# UHDC Enterprise SQL Architecture & Security Hardening (20K+ Endpoints)
**Version:** 1.0.0 | **Classification:** Internal / Administrator Use Only

## Overview
The standard Unified Help Desk Console (UHDC) utilizes a flat-file JSON database (UserHistory.json) and a network drop-box to track asset telemetry. While highly efficient for small-to-medium businesses, environments exceeding 20,000 endpoints generate a volume of concurrent network events (the "8:00 AM Logon Storm") that can bottleneck standard SMB file shares.

The files in this `20KPLUS` directory replace the JSON architecture with a Direct-to-SQL telemetry pipeline and introduce strict enterprise security controls.

### Key Advantages:
1. Infinite Concurrency: Endpoints execute a lightweight SQL command directly against the database, eliminating SMB file-lock bottlenecks.
2. Zero Background Aggregation: You no longer need to run the GlobalAssetTelemetry.ps1 background loop on your server.
3. Microsecond Lookups: The UI queries the SQL database directly, returning asset locations instantly regardless of fleet size.
4. Integrated Security: No hardcoded SQL passwords. The architecture uses Active Directory Computer Accounts (DOMAIN\PC$) to authenticate.

---

## Phase 1: Database Preparation

### 1. Create the Database and Table
On your Microsoft SQL Server (or Azure SQL instance), create a new database named UHDCTelemetry. Execute the following query to build the required schema:

    CREATE TABLE AssetTelemetry (
        Username VARCHAR(100),
        ComputerName VARCHAR(100),
        IPAddress VARCHAR(50),
        MACAddress VARCHAR(50),
        LastSeen DATETIME,
        PRIMARY KEY (Username, ComputerName)
    );

    -- Create indexes to ensure lightning-fast UI searches
    CREATE INDEX IX_Username ON AssetTelemetry(Username);
    CREATE INDEX IX_ComputerName ON AssetTelemetry(ComputerName);

### 2. Create the Stored Procedure (Strict Least Privilege)
To prevent a compromised endpoint from dropping your SQL table or modifying other records, your DBA must create this Stored Procedure to handle the upsert logic:

    CREATE PROCEDURE dbo.UpsertAssetTelemetry
        @Username VARCHAR(100),
        @ComputerName VARCHAR(100),
        @IPAddress VARCHAR(50),
        @MACAddress VARCHAR(50),
        @LastSeen DATETIME
    AS
    BEGIN
        SET NOCOUNT ON;
        MERGE INTO AssetTelemetry AS target
        USING (SELECT @Username AS Username, @ComputerName AS ComputerName) AS source
        ON target.Username = source.Username AND target.ComputerName = source.ComputerName
        WHEN MATCHED THEN
            UPDATE SET IPAddress = @IPAddress, MACAddress = @MACAddress, LastSeen = @LastSeen
        WHEN NOT MATCHED THEN
            INSERT (Username, ComputerName, IPAddress, MACAddress, LastSeen)
            VALUES (@Username, @ComputerName, @IPAddress, @MACAddress, @LastSeen);
    END

### 3. Configure SQL Permissions
Because the endpoint agent runs as NT AUTHORITY\SYSTEM, it authenticates to SQL as the machine itself.
* Grant the Domain Computers AD group EXECUTE permissions on dbo.UpsertAssetTelemetry. (Do not grant them INSERT/UPDATE/DELETE on the table itself).
* Grant your Help Desk Technicians AD group db_datareader (or explicit SELECT) permissions to the AssetTelemetry table so the UHDC console can query the data.

---

## Phase 2: Upgrading the UHDC Core

### 1. Update config.json
Open your central \Config\config.json file and add a Database block containing your SQL connection string. It should look like this:

    {
        "Organization": {
            "TenantDomain": "acmecorp.com",
            "CompanyName": "Acme Corp"
        },
        "Database": {
            "ConnectionString": "Server=tcp:YOUR-SQL-SERVER,1433;Initial Catalog=UHDCTelemetry;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;"
        },
        "ActiveDirectory": {
            "ImportantGroups": ["VPN", "M365", "Admin"]
        }
    }

### 2. Swap the Intelligence Engine
1. Navigate to your central \Core directory.
2. Delete the existing IdentityAssetCorrelation.ps1 (the JSON version).
3. Copy the new IdentityAssetCorrelation.ps1 from this 20KPLUS folder into the \Core directory. 

### 3. Decommission Legacy Components
Because you are now using SQL, you can safely delete the following legacy components from your central share:
* Delete the \TelemetryDrop folder.
* Delete GlobalAssetTelemetry.ps1 (The background aggregator is no longer needed).
* Delete UserHistory.json (Once you are confident the SQL database is populating).

---

## Phase 3: Deploying the SQL Endpoint Agent

1. Open Deploy-GlobalAssetTelemetry-SQL.ps1 in an editor.
2. Locate the $SqlConnectionString variable near the top of the embedded payload.
3. Update it to match your actual SQL Server details.
4. Ensure the script is calling the Stored Procedure ($SqlCmd.CommandType = [System.Data.CommandType]::StoredProcedure).
5. Deploy this script to your fleet via Microsoft Intune or MECM (SCCM) as a System-level PowerShell script.

---

## Phase 4: Enterprise Security Hardening (Mandatory for 20K+)

At 20,000+ endpoints, your threat model shifts to defending against advanced persistent threats (APTs) and ransomware operators looking for lateral movement vectors. You must implement the following controls.

### 1. Network Micro-Segmentation (Firewall Hardening)
Do not leave WinRM (Port 5985) open to the entire company. You must restrict it via Active Directory Group Policy (GPO).

1. Open Group Policy Management.
2. Navigate to: Computer Configuration > Policies > Windows Settings > Security Settings > Windows Defender Firewall.
3. Create a new Inbound Rule:
   * Port: TCP 5985
   * Action: Allow the connection
   * Scope (Remote IP Address): Add the specific IP Subnet of your Help Desk / IT Department (e.g., 10.50.0.0/16).
4. Result: If a user's laptop gets infected with ransomware in the Marketing subnet, it cannot use WinRM to spread to the Finance subnet. Only IT can initiate WinRM connections.

### 2. Code Signing the Telemetry Agent
Before deploying the SQL Telemetry Agent to 20,000 machines, sign it with your internal PKI. Run this on a machine with your Code Signing certificate installed:

    $cert = Get-ChildItem -Path Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1
    Set-AuthenticodeSignature -FilePath ".\Deploy-GlobalAssetTelemetry-SQL.ps1" -Certificate $cert

Then, in the Scheduled Task XML inside the deployment script, change -ExecutionPolicy Bypass to -ExecutionPolicy AllSigned.

### 3. The "Final Boss" of PowerShell Security: JEA (Just Enough Administration)
Currently, to use the UHDC, your Help Desk technicians must be members of the local Administrators group on all 20,000 endpoints. If you want to achieve absolute Zero-Trust, you implement Microsoft JEA.

1. JEA allows you to configure the WinRM listener on the endpoints to accept connections from standard, non-admin Help Desk users.
2. When the Help Desk user connects via the UHDC, WinRM spins up a temporary, virtual Administrator account just for that session.
3. You define a JEA Role Capability file (.psrc) that explicitly dictates exactly which cmdlets the Help Desk is allowed to run (e.g., Restart-Service, Get-WinEvent). If they try to run Format-Volume, JEA blocks it.


Implementing JEA is a massive infrastructure project, but it is the gold standard for securing platforms like the UHDC in Fortune 500 environments.
