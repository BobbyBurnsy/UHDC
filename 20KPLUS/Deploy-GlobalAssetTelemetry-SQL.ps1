<#
.SYNOPSIS
    UHDC Enterprise Agent: Deploy-GlobalAssetTelemetry-SQL.ps1
.DESCRIPTION
    Creates the local agent directory, writes the SQL telemetry payload, and registers
    an Event-Driven Scheduled Task (Event ID 10000) to trigger it.
    Runs under the NT AUTHORITY\SYSTEM context, utilizing Integrated Security
    to authenticate to the SQL Server as the AD Computer Object.
#>

$ErrorActionPreference = "Stop"

Write-Output "======================================================="
Write-Output " [UHDC] DEPLOYING SQL TELEMETRY AGENT"
Write-Output "======================================================="

# --- Create Local Agent Directory ---
$AgentDir = "C:\ProgramData\UHDC"
if (-not (Test-Path $AgentDir)) {
    Write-Output "[+] Creating local agent directory..."
    New-Item -Path $AgentDir -ItemType Directory -Force | Out-Null
}

# --- Write SQL Telemetry Payload ---
$PayloadPath = Join-Path $AgentDir "UHDC_Telemetry_SQL.ps1"

# Update Server and Initial Catalog to match your environment
$PayloadScript = @'
$ErrorActionPreference = "SilentlyContinue"

$SqlConnectionString = "Server=tcp:YOUR-SQL-SERVER,1433;Initial Catalog=UHDCTelemetry;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;"

$ComputerName = $env:COMPUTERNAME
$LoggedInUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
if ($LoggedInUser) { $LoggedInUser = $LoggedInUser.Split('\')[-1] } else { $LoggedInUser = "Unknown" }

$ActiveAdapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Sort-Object InterfaceMetric | Select-Object -First 1
$ActiveIP = (Get-NetIPAddress -InterfaceAlias $ActiveAdapter.Name -AddressFamily IPv4 | Where-Object IPAddress -notmatch '^169\.254\.|127\.0\.0\.1').IPAddress | Select-Object -First 1

if ($ActiveIP -and $LoggedInUser -ne "Unknown") {

    $SqlQuery = @"
        MERGE INTO AssetTelemetry AS target
        USING (SELECT @User AS Username, @Computer AS ComputerName, @IP AS IPAddress, @MAC AS MACAddress, @Seen AS LastSeen) AS source
        ON target.Username = source.Username AND target.ComputerName = source.ComputerName
        WHEN MATCHED THEN
            UPDATE SET IPAddress = source.IPAddress, MACAddress = source.MACAddress, LastSeen = source.LastSeen
        WHEN NOT MATCHED THEN
            INSERT (Username, ComputerName, IPAddress, MACAddress, LastSeen)
            VALUES (source.Username, source.ComputerName, source.IPAddress, source.MACAddress, source.LastSeen);
"@

    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $SqlConnectionString
    $SqlConnection.Open()

    $SqlCmd = $SqlConnection.CreateCommand()
    $SqlCmd.CommandText = $SqlQuery

    $SqlCmd.Parameters.AddWithValue("@User", $LoggedInUser) | Out-Null
    $SqlCmd.Parameters.AddWithValue("@Computer", $ComputerName) | Out-Null
    $SqlCmd.Parameters.AddWithValue("@IP", $ActiveIP) | Out-Null
    $SqlCmd.Parameters.AddWithValue("@MAC", if ($ActiveAdapter.MacAddress) { $ActiveAdapter.MacAddress } else { "N/A" }) | Out-Null
    $SqlCmd.Parameters.AddWithValue("@Seen", (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")) | Out-Null

    $SqlCmd.ExecuteNonQuery() | Out-Null
    $SqlConnection.Close()
}
'@

Write-Output "[+] Writing SQL payload to disk..."
$PayloadScript | Out-File -FilePath $PayloadPath -Encoding UTF8 -Force

# --- Register Event-Driven Scheduled Task ---
$TaskName = "UHDC Global Asset Telemetry (SQL)"

Write-Output "[+] Registering Event 10000 Scheduled Task..."

$TaskXML = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and EventID=10000]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId> <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <Hidden>true</Hidden>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\ProgramData\UHDC\UHDC_Telemetry_SQL.ps1"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Xml $TaskXML -Force | Out-Null

Write-Output "[OK] UHDC SQL Telemetry Agent Deployed Successfully."

