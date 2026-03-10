<#
.SYNOPSIS
    UHDC Endpoint Agent: Deploy-GlobalAssetTelemetry.ps1
.DESCRIPTION
    Creates the local agent directory, writes the telemetry payload, and registers
    an Event-Driven Scheduled Task (Event ID 10000) to trigger it.
    Runs under the NT AUTHORITY\SYSTEM context.
#>

$ErrorActionPreference = "Stop"

# --- Create Local Agent Directory ---
$AgentDir = "C:\ProgramData\UHDC"
if (-not (Test-Path $AgentDir)) {
    New-Item -Path $AgentDir -ItemType Directory -Force | Out-Null
}

# --- Write Telemetry Payload ---
$PayloadPath = Join-Path $AgentDir "UHDC_Telemetry.ps1"

# Update this to your actual Write-Only Drop Share path
$PayloadScript = @'
$ErrorActionPreference = "SilentlyContinue"
$DropShare = "\\YOUR-SERVER\TelemetryDrop$" 

$ComputerName = $env:COMPUTERNAME
$LoggedInUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
if ($LoggedInUser) { $LoggedInUser = $LoggedInUser.Split('\')[-1] } else { $LoggedInUser = "Unknown" }

$ActiveAdapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Sort-Object InterfaceMetric | Select-Object -First 1
$ActiveIP = (Get-NetIPAddress -InterfaceAlias $ActiveAdapter.Name -AddressFamily IPv4 | Where-Object IPAddress -notmatch '^169\.254\.|127\.0\.0\.1').IPAddress | Select-Object -First 1

if ($ActiveIP -and $LoggedInUser -ne "Unknown") {
    $Payload = [ordered]@{
        User        = $LoggedInUser
        Computer    = $ComputerName
        IPAddress   = $ActiveIP
        MACAddress  = $ActiveAdapter.MacAddress
        LastSeen    = (Get-Date).ToString("yyyy-MM-dd HH:mm")
        Source      = "Event-Agent"
    }

    $OutFile = Join-Path $DropShare "$ComputerName-$([guid]::NewGuid().ToString().Substring(0,8)).json"
    $Payload | ConvertTo-Json -Compress | Out-File -FilePath $OutFile -Encoding UTF8 -Force
}
'@

$PayloadScript | Out-File -FilePath $PayloadPath -Encoding UTF8 -Force

# --- Register Event-Driven Scheduled Task ---
$TaskName = "UHDC Global Asset Telemetry"

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
      <Arguments>-ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\ProgramData\UHDC\UHDC_Telemetry.ps1"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Xml $TaskXML -Force | Out-Null

Write-Output "[OK] UHDC Telemetry Agent Deployed Successfully."


