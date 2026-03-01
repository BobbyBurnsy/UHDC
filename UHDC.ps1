# ==============================================================================================
# UHDC.ps1 - Unified Help Desk Console (Master Script)
# Place this script in the ROOT folder (e.g., \\Server\Share\UHDC\)
# DESCRIPTION: The main GUI and asynchronous runspace engine for the UHDC platform.
# Features Role-Based Access Control (RBAC) and an Interactive Training Engine.
# ==============================================================================================

# ------------------------------------------------------------------
# AUTO-ELEVATE TO ADMINISTRATOR
# ------------------------------------------------------------------
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

# ------------------------------------------------------------------
# ENVIRONMENT SETUP & DYNAMIC CONFIGURATION
# ------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName Microsoft.VisualBasic

# Determine the application directory regardless of how it was launched
if ($MyInvocation.MyCommand.Path) {
    $AppDir = Split-Path $MyInvocation.MyCommand.Path
} else {
    $AppDir = [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

$ConfigFile = Join-Path -Path $AppDir -ChildPath "config.json"

# First-Run Setup
if (-not (Test-Path $ConfigFile)) {
    $Template = [ordered]@{
        OrganizationName  = "Acme Corp"
        SharedNetworkRoot = "\\YOUR-SERVER\YourShare\UHDC"
        MasterAdmins      = @("YourAdmin1", "YourAdmin2")
        Trainees          = @("NewHireUser1", "NewHireUser2")
    }
    $Template | ConvertTo-Json -Depth 3 | Out-File $ConfigFile -Force

    [System.Windows.MessageBox]::Show("First run detected!`n`nA configuration file has been generated at:`n$ConfigFile`n`nPlease open it and enter your IT network paths.", "Setup Required", "OK", "Information")
    Exit
}

# Load Configuration
try {
    $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

    $SharedRoot = $Config.SharedNetworkRoot
    if ($SharedRoot.EndsWith("\")) {
        $SharedRoot = $SharedRoot.Substring(0, $SharedRoot.Length - 1)
    }

    $MasterAdmins = if ($Config.MasterAdmins) { $Config.MasterAdmins } else { @() }
    $Trainees     = if ($Config.Trainees) { $Config.Trainees } else { @() }
    $OrgName      = $Config.OrganizationName
} catch {
    [System.Windows.MessageBox]::Show("Error reading config.json. Check formatting.", "Config Error", "OK", "Error")
    Exit
}

# ------------------------------------------------------------------
# PREREQUISITE FOLDER & FILE CHECKS
# ------------------------------------------------------------------
$RequiredFolders = @(
    (Join-Path $SharedRoot "Logs"),
    (Join-Path $SharedRoot "Logs\Presence"),
    (Join-Path $SharedRoot "Core"),
    (Join-Path $SharedRoot "Tools")
)

foreach ($Folder in $RequiredFolders) {
    if (-not (Test-Path $Folder)) {
        try { New-Item -ItemType Directory -Path $Folder -Force | Out-Null } catch {}
    }
}

$CoreFolder   = Join-Path -Path $SharedRoot -ChildPath "Core"
$ToolsFolder  = Join-Path -Path $SharedRoot -ChildPath "Tools"
$AuditLogPath = Join-Path -Path $SharedRoot -ChildPath "Logs\ConsoleAudit.csv"
$PresenceDir  = Join-Path -Path $SharedRoot -ChildPath "Logs\Presence"

# Ensure PsExec is available for system-level commands
$psExecPath = Join-Path -Path $CoreFolder -ChildPath "psexec.exe"
if (-not (Test-Path $psExecPath)) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "https://live.sysinternals.com/psexec.exe" -OutFile $psExecPath -UseBasicParsing -ErrorAction Stop
        Unblock-File $psExecPath -ErrorAction SilentlyContinue
    } catch {
        [System.Windows.MessageBox]::Show("PsExec.exe missing and auto-download failed.`n`nPlace psexec.exe manually in: $CoreFolder", "Prerequisite Missing", "OK", "Warning")
    }
}

# ------------------------------------------------------------------
# INITIALIZE ASYNC RUNSPACE POOL
# ------------------------------------------------------------------
$RunspacePool = [runspacefactory]::CreateRunspacePool(1, 15)
$RunspacePool.ApartmentState = "STA"
$RunspacePool.Open()

# ------------------------------------------------------------------
# 1. DEFINE THE UI (DYNAMIC 4-QUADRANT XAML)
# ------------------------------------------------------------------
[xml]$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Unified Help Desk Console (UHDC)" Height="950" Width="1350" Background="#1E1E1E" WindowStartupLocation="CenterScreen">

    <Window.Resources>
        <!-- Standard Button Style -->
        <Style x:Key="StdBtn" TargetType="Button">
            <Setter Property="Background" Value="#2D2D30"/>
            <Setter Property="Foreground" Value="#00A2ED"/>
            <Setter Property="BorderBrush" Value="#444444"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#00FF00"/>
                                <Setter Property="Foreground" Value="#00FF00"/>
                                <Setter TargetName="border" Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Color="#00FF00" BlurRadius="12" ShadowDepth="0" Opacity="0.7"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#00FF00"/>
                                <Setter Property="Foreground" Value="#1E1E1E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Action Button Style (Green Text) -->
        <Style x:Key="ActionBtn" TargetType="Button" BasedOn="{StaticResource StdBtn}">
            <Setter Property="Foreground" Value="#00FF00"/>
        </Style>

        <!-- Danger Button Style (Red Hover) -->
        <Style x:Key="DangerBtn" TargetType="Button">
            <Setter Property="Background" Value="#2D2D30"/>
            <Setter Property="Foreground" Value="#00A2ED"/>
            <Setter Property="BorderBrush" Value="#444444"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#FF4444"/>
                                <Setter Property="Foreground" Value="#FF4444"/>
                                <Setter TargetName="border" Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Color="#FF4444" BlurRadius="12" ShadowDepth="0" Opacity="0.7"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF4444"/>
                                <Setter Property="Foreground" Value="#1E1E1E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Warning Button Style (Yellow Hover) -->
        <Style x:Key="WarningBtn" TargetType="Button">
            <Setter Property="Background" Value="#2D2D30"/>
            <Setter Property="Foreground" Value="#00A2ED"/>
            <Setter Property="BorderBrush" Value="#444444"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#FFD700"/>
                                <Setter Property="Foreground" Value="#FFD700"/>
                                <Setter TargetName="border" Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Color="#FFD700" BlurRadius="12" ShadowDepth="0" Opacity="0.7"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FFD700"/>
                                <Setter Property="Foreground" Value="#1E1E1E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Master Admin Button Style (Purple Hover) -->
        <Style x:Key="MasterBtn" TargetType="Button">
            <Setter Property="Background" Value="#2D2D30"/>
            <Setter Property="Foreground" Value="#00A2ED"/>
            <Setter Property="BorderBrush" Value="#444444"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#B366FF"/>
                                <Setter Property="Foreground" Value="#B366FF"/>
                                <Setter TargetName="border" Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Color="#B366FF" BlurRadius="12" ShadowDepth="0" Opacity="0.7"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#B366FF"/>
                                <Setter Property="Foreground" Value="#1E1E1E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <TextBlock Grid.Row="0" Text="$OrgName IT Dashboard" FontSize="26" Foreground="#00A2ED" FontWeight="Bold" Margin="5,0,0,5"/>

        <!-- MOTD Ticker -->
        <Grid Grid.Row="1" Height="30" Background="#111111" Margin="5,0,5,10" >
            <Canvas Name="MotdCanvas" ClipToBounds="True">
                <TextBlock Name="MotdScrollText" Foreground="#00FF00" FontSize="16" FontFamily="Consolas" FontWeight="Bold" Canvas.Left="1350" Canvas.Top="4" Text="Loading Announcements..."/>
            </Canvas>
        </Grid>

        <!-- Main Content Area -->
        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="1.35*"/>
                <ColumnDefinition Width="1.45*"/>
            </Grid.ColumnDefinitions>

            <!-- LEFT COLUMN -->
            <Grid Grid.Column="0" Margin="0,0,5,0">
                <Grid.RowDefinitions>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <!-- Q1: AD User Intelligence -->
                <GroupBox Grid.Row="0" Header="AD User Intelligence &amp; Actions" Foreground="#AAAAAA" BorderBrush="#333333" Margin="5" Padding="0">
                    <Border BorderThickness="4,0,0,0" BorderBrush="#00A2ED" Background="#161616" Padding="10">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>

                            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
                                <TextBlock Text="Username:" Foreground="White" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="14"/>
                                <TextBox Name="ADInput" Width="180" Height="28" FontSize="14" Background="#111111" Foreground="#00A2ED" BorderBrush="#555555" Padding="2" ToolTip="Enter an Employee ID, Username, or First/Last name."/>
                                <Button Name="BtnADLookup" Content="Search AD" Width="100" Height="28" Margin="10,0,0,0" Style="{StaticResource StdBtn}" ToolTip="Query Active Directory for this user's details and known PCs."/>
                                <Button Name="BtnDisabledAD" Content="Disabled Users" Width="120" Height="28" Margin="10,0,0,0" Style="{StaticResource StdBtn}" ToolTip="Generate a full report of all disabled accounts in the domain."/>
                                <Button Name="BtnGlobalMap" Content="Compile Global Map" Width="150" Height="28" Margin="10,0,0,0" Style="{StaticResource MasterBtn}" ToolTip="Compile a master map of all known active nodes on the network."/>
                                <ComboBox Name="UserSelectCombo" Width="350" Height="28" Margin="10,0,0,0" Visibility="Collapsed" Background="#EEEEEE" Foreground="Black" Cursor="Hand" ToolTip="Multiple matches found. Select the correct user."/>
                            </StackPanel>

                            <WrapPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,10">
                                <Button Name="BtnUnlock" Content="Unlock AD" Width="75" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Unlock the targeted user's Active Directory account."/>
                                <Button Name="BtnResetPwd" Content="Reset Pwd" Width="75" Height="30" Margin="2" Style="{StaticResource DangerBtn}" ToolTip="Force a password reset for the targeted AD User."/>
                                <Button Name="BtnIntune" Content="Intune Menu" Width="85" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Launch the Intune management helper for this user/device."/>
                                <Button Name="BtnBookmarkBackup" Content="Bkmk Backup" Width="95" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Remotely backup Chrome and Edge bookmarks for this user."/>
                                <Button Name="BtnBrowserReset" Content="Browser Reset" Width="95" Height="30" Margin="2" Style="{StaticResource DangerBtn}" ToolTip="Wipe corrupted browser profiles (Requires both Target PC and AD User)."/>
                                <Button Name="BtnNetworkScan" Content="Net Scan" Width="70" Height="30" Margin="2" Style="{StaticResource StdBtn}" ToolTip="Scan the computers in a given UserID's object group to see which PC they are on and update location history."/>
                                <Button Name="BtnAddLoc" Content="+ Add PC" Width="65" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Manually link a PC name to a User in the historical database."/>
                                <Button Name="BtnRemLoc" Content="- Rem PC" Width="65" Height="30" Margin="2" Style="{StaticResource WarningBtn}" ToolTip="Select and remove an incorrect PC from a User's history."/>
                            </WrapPanel>

                            <TextBox Name="ADOutputConsole" Grid.Row="2" Background="#0C0C0C" Foreground="#00FF00" FontFamily="Consolas" FontSize="16" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" BorderThickness="1" BorderBrush="#333333"/>
                        </Grid>
                    </Border>
                </GroupBox>

                <!-- Q4: Command Center & Presence -->
                <GroupBox Grid.Row="1" Header="Command Center (Active Techs)" Foreground="#AAAAAA" BorderBrush="#333333" Margin="5" Padding="0">
                    <Border BorderThickness="4,0,0,0" BorderBrush="#00A2ED" Background="#161616" Padding="10">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="30"/>
                            </Grid.RowDefinitions>

                            <WrapPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
                                <Button Name="BtnNetSend" Content="Net Send" Width="80" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Send a direct Windows pop-up message to a specific PC."/>
                                <Button Name="BtnAddMOTD" Content="+ MOTD" Width="70" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Pin a new Message of the Day to the top of the chat."/>
                                <Button Name="BtnDelMOTD" Content="- MOTD" Width="70" Height="30" Margin="2" Style="{StaticResource WarningBtn}" ToolTip="Remove an existing pinned Message of the Day."/>
                            </WrapPanel>

                            <TextBox Name="OnlineUsersConsole" Grid.Row="1" Background="#0C0C0C" Foreground="#28A745" FontFamily="Consolas" FontSize="14" IsReadOnly="True" VerticalScrollBarVisibility="Hidden" TextWrapping="Wrap" BorderThickness="1" BorderBrush="#333333"/>
                        </Grid>
                    </Border>
                </GroupBox>
            </Grid>

            <!-- RIGHT COLUMN -->
            <Grid Grid.Column="1" Margin="5,0,0,0">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <!-- Q3: Remote Access & Diagnostics -->
                <GroupBox Grid.Row="0" Header="Remote Access &amp; Diagnostics" Foreground="#AAAAAA" BorderBrush="#333333" Margin="5" Padding="0">
                    <Border BorderThickness="4,0,0,0" BorderBrush="#00A2ED" Background="#161616" Padding="10">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
                                <TextBlock Text="Target PC:" Foreground="White" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                <TextBox Name="ComputerInput" Width="160" Height="25" Background="#111111" Foreground="#00A2ED" FontWeight="Bold" BorderBrush="#555555" Padding="2" ToolTip="Enter a specific Target PC Name or IP Address."/>
                            </StackPanel>
                            <WrapPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,10">
                                <Button Name="BtnSCCM" Content="SCCM" Width="60" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Launch SCCM Remote Control Viewer for the target PC."/>
                                <Button Name="BtnMSRA" Content="MSRA" Width="60" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Send a Windows Remote Assistance invitation to the target."/>
                                <Button Name="BtnCShare" Content="Open C$" Width="65" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Open the hidden C$ administrative share in File Explorer."/>
                                <Button Name="BtnSessions" Content="Sessions" Width="65" Height="30" Margin="2" Style="{StaticResource StdBtn}" ToolTip="Check which user accounts are actively logged into this PC."/>
                                <Button Name="BtnLAPS" Content="LAPS" Width="55" Height="30" Margin="2" Style="{StaticResource StdBtn}" ToolTip="Retrieve the rotating Local Administrator Password from AD."/>
                                <Button Name="BtnDeploy" Content="Deploy GUI" Width="90" Height="30" Margin="2" Style="{StaticResource MasterBtn}" ToolTip="Push the compiled UHDC Network Shortcut directly to a coworker's PC."/>
                            </WrapPanel>
                            <TextBox Name="ComputerOutputConsole" Grid.Row="2" Height="120" Background="#0C0C0C" Foreground="#00FF00" FontFamily="Consolas" FontSize="13" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" BorderThickness="1" BorderBrush="#333333"/>
                        </Grid>
                    </Border>
                </GroupBox>

                <!-- Q2: Endpoint Remediation & Core Tools -->
                <GroupBox Grid.Row="1" Header="Endpoint Remediation &amp; Core Tools" Foreground="#AAAAAA" BorderBrush="#333333" Margin="5" Padding="0">
                    <Border BorderThickness="4,0,0,0" BorderBrush="#00A2ED" Background="#161616" Padding="10">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
                                <TextBlock Text="Target PC:" Foreground="White" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                <TextBox Name="PluginInput" Width="160" Height="25" Background="#111111" Foreground="#00A2ED" FontWeight="Bold" BorderBrush="#555555" Padding="2" ToolTip="Enter a specific Target PC Name or IP Address."/>
                            </StackPanel>
                            <WrapPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,10">
                                <Button Name="BtnNetInfo" Content="Network Info" Width="95" Height="30" Margin="2" Style="{StaticResource StdBtn}" ToolTip="Pull live IP, MAC address, and adapter details from the PC."/>
                                <Button Name="BtnUptime" Content="Get Uptime" Width="85" Height="30" Margin="2" Style="{StaticResource StdBtn}" ToolTip="Check how long the target PC has been running since its last reboot."/>
                                <Button Name="BtnGetLogs" Content="Event Logs" Width="80" Height="30" Margin="2" Style="{StaticResource StdBtn}" ToolTip="Pull recent Critical/Error logs and export them to a CSV."/>
                                <Button Name="BtnChkBit" Content="BitLocker" Width="80" Height="30" Margin="2" Style="{StaticResource StdBtn}" ToolTip="Check drive encryption status and retrieve recovery keys."/>
                                <Button Name="BtnBatRep" Content="Battery Rpt" Width="85" Height="30" Margin="2" Style="{StaticResource StdBtn}" ToolTip="Generate a detailed laptop battery health and cycle report."/>
                                <Button Name="BtnSmartWar" Content="Smart Warranty" Width="110" Height="30" Margin="2" Style="{StaticResource StdBtn}" ToolTip="Pull hardware model, serial number, and active warranty status."/>
                                <Button Name="BtnLocAdm" Content="Local Admins" Width="95" Height="30" Margin="2" Style="{StaticResource StdBtn}" ToolTip="List all user accounts that have local administrator rights."/>
                                <Button Name="BtnEnRDP" Content="Enable RDP" Width="85" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Remotely enable Remote Desktop connections and adjust the firewall."/>
                                <Button Name="BtnRegDNS" Content="Fix/Reg DNS" Width="85" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Force the target PC to update its IP records with the Domain Controller."/>
                                <Button Name="BtnFixSpool" Content="Fix Spooler" Width="85" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Restart the print spooler service to clear stuck print jobs."/>
                                <Button Name="BtnGPUpdate" Content="Force GPUpdate" Width="110" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Force a background Group Policy update on the target PC."/>
                                <Button Name="BtnMapDrives" Content="Push Refresh Drives" Width="135" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Force the target PC to reconnect missing network drives."/>
                                <Button Name="BtnRemInstall" Content="Remote Install" Width="110" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Push standard software packages silently to the target PC."/>
                                <Button Name="BtnDeepClean" Content="Deep Clean" Width="95" Height="30" Margin="2" Style="{StaticResource WarningBtn}" ToolTip="Clear temp files, web caches, and windows update files remotely."/>
                                <Button Name="BtnRestartSCCM" Content="Restart SCCM" Width="100" Height="30" Margin="2" Style="{StaticResource WarningBtn}" ToolTip="Restart the local SMS Agent Host service to fix SCCM hangs."/>
                                <Button Name="BtnRestart" Content="Restart Options" Width="110" Height="30" Margin="2" Style="{StaticResource DangerBtn}" ToolTip="Initiate a graceful or forced remote reboot."/>
                            </WrapPanel>
                            <TextBox Name="PluginOutputConsole" Grid.Row="2" Background="#0C0C0C" Foreground="#00FF00" FontFamily="Consolas" FontSize="13" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" BorderThickness="1" BorderBrush="#333333"/>
                        </Grid>
                    </Border>
                </GroupBox>

            </Grid>
        </Grid>

        <!-- Footer / Status Bar -->
        <Grid Grid.Row="3" Margin="5,10,5,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Name="StatusBar" Grid.Column="0" Text="Ready..." Foreground="#28A745" FontWeight="Bold" VerticalAlignment="Center"/>
            <CheckBox Name="CbTrainingMode" Grid.Column="1" Content="Training Mode" Foreground="#FFD700" FontWeight="Bold" VerticalAlignment="Center" ToolTip="Enable interactive step-by-step execution." Cursor="Hand"/>
        </Grid>
    </Grid>
</Window>
"@

$XmlReader = New-Object System.Xml.XmlNodeReader $XAML
$Form = [System.Windows.Markup.XamlReader]::Load($XmlReader)

# ------------------------------------------------------------------
# 2. MAP UI ELEMENTS & RBAC
# ------------------------------------------------------------------
$ADInput         = $Form.FindName("ADInput")
$PluginInput     = $Form.FindName("PluginInput")
$ComputerInput   = $Form.FindName("ComputerInput")
$UserSelectCombo = $Form.FindName("UserSelectCombo")
$StatusBar       = $Form.FindName("StatusBar")
$CbTrainingMode  = $Form.FindName("CbTrainingMode")

# Output Consoles
$ADOutputConsole       = $Form.FindName("ADOutputConsole")
$PluginOutputConsole   = $Form.FindName("PluginOutputConsole")
$ComputerOutputConsole = $Form.FindName("ComputerOutputConsole")
$OnlineUsersConsole    = $Form.FindName("OnlineUsersConsole")

# MOTD Elements
$MotdCanvas     = $Form.FindName("MotdCanvas")
$MotdScrollText = $Form.FindName("MotdScrollText")

# Q1/Q3 Buttons
$BtnADLookup       = $Form.FindName("BtnADLookup")
$BtnDisabledAD     = $Form.FindName("BtnDisabledAD")
$BtnSCCM           = $Form.FindName("BtnSCCM")
$BtnMSRA           = $Form.FindName("BtnMSRA")
$BtnCShare         = $Form.FindName("BtnCShare")
$BtnSessions       = $Form.FindName("BtnSessions")
$BtnLAPS           = $Form.FindName("BtnLAPS")
$BtnAddLoc         = $Form.FindName("BtnAddLoc")
$BtnRemLoc         = $Form.FindName("BtnRemLoc")
$BtnUnlock         = $Form.FindName("BtnUnlock")
$BtnResetPwd       = $Form.FindName("BtnResetPwd")
$BtnNetworkScan    = $Form.FindName("BtnNetworkScan")
$BtnIntune         = $Form.FindName("BtnIntune")
$BtnBookmarkBackup = $Form.FindName("BtnBookmarkBackup")
$BtnBrowserReset   = $Form.FindName("BtnBrowserReset")
$BtnDeploy         = $Form.FindName("BtnDeploy")

# Q2 Buttons
$BtnNetInfo     = $Form.FindName("BtnNetInfo")
$BtnUptime      = $Form.FindName("BtnUptime")
$BtnGetLogs     = $Form.FindName("BtnGetLogs")
$BtnChkBit      = $Form.FindName("BtnChkBit")
$BtnBatRep      = $Form.FindName("BtnBatRep")
$BtnSmartWar    = $Form.FindName("BtnSmartWar")
$BtnLocAdm      = $Form.FindName("BtnLocAdm")
$BtnEnRDP       = $Form.FindName("BtnEnRDP")
$BtnRegDNS      = $Form.FindName("BtnRegDNS")
$BtnFixSpool    = $Form.FindName("BtnFixSpool")
$BtnGPUpdate    = $Form.FindName("BtnGPUpdate")
$BtnRestartSCCM = $Form.FindName("BtnRestartSCCM")
$BtnMapDrives   = $Form.FindName("BtnMapDrives")
$BtnDeepClean   = $Form.FindName("BtnDeepClean")
$BtnRemInstall  = $Form.FindName("BtnRemInstall")
$BtnRestart     = $Form.FindName("BtnRestart")
$BtnGlobalMap   = $Form.FindName("BtnGlobalMap")

# Q4 Communications Buttons
$BtnNetSend = $Form.FindName("BtnNetSend")
$BtnAddMOTD = $Form.FindName("BtnAddMOTD")
$BtnDelMOTD = $Form.FindName("BtnDelMOTD")

# --- ROLE-BASED ACCESS CONTROL (RBAC) ---
if (-not ($MasterAdmins -contains $env:USERNAME)) {
    $BtnGlobalMap.Visibility = "Collapsed"
    $BtnDeploy.Visibility = "Collapsed"
}

if ($Trainees -contains $env:USERNAME) {
    $CbTrainingMode.IsChecked = $true
}

# ------------------------------------------------------------------
# AUDIT LOGGING FUNCTION
# ------------------------------------------------------------------
function Write-AuditLog {
    param([string]$Action, [string]$Target)
    try {
        $LogEntry = [PSCustomObject]@{
            Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Tech      = $env:USERNAME
            Target    = if ($Target) { $Target } else { "N/A" }
            Action    = $Action
        }
        $LogEntry | Export-Csv -Path $AuditLogPath -Append -NoTypeInformation -Force
    } catch { }
}

# ------------------------------------------------------------------
# 3. INTERACTIVE TRAINING ENGINE (SYNC HASH)
# ------------------------------------------------------------------
$global:UHDCSync = [hashtable]::Synchronized(@{
    StepReady  = $false
    StepDesc   = ""
    StepCode   = ""
    StepResult = $false
    StepAck    = $false
})

function Show-StepDialog {
    [xml]$TrainXAML = @"
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            Title="UHDC Training Mode - Step Execution" WindowStyle="ToolWindow" WindowStartupLocation="CenterScreen" Topmost="True" ResizeMode="NoResize" SizeToContent="Height" Width="650" Background="#1E1E1E">
        <Grid Margin="20">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Text="TRAINING MODE: STEP EXECUTION" Grid.Row="0" Foreground="#FFD700" FontSize="14" FontWeight="Bold" Margin="0,0,0,10"/>
            <TextBlock Name="StepDesc" Grid.Row="1" Foreground="White" FontSize="16" TextWrapping="Wrap" Margin="0,0,0,20"/>

            <TextBlock Text="Underlying PowerShell Command:" Grid.Row="2" Foreground="#00A2ED" FontSize="13" FontWeight="Bold" Margin="0,0,0,5"/>
            <TextBox Name="StepCode" Grid.Row="3" Background="#0C0C0C" Foreground="#00FF00" FontFamily="Consolas" FontSize="14" IsReadOnly="True" TextWrapping="Wrap" Padding="10" BorderBrush="#444" BorderThickness="1" Margin="0,0,0,20"/>

            <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
                <Button Name="BtnAbort" Content="Abort Tool" Width="100" Height="35" Background="#FF4444" Foreground="White" BorderThickness="0" Margin="0,0,10,0" Cursor="Hand" FontWeight="Bold"/>
                <Button Name="BtnExecute" Content="Execute Step" Width="130" Height="35" Background="#28A745" Foreground="White" BorderThickness="0" Cursor="Hand" FontWeight="Bold"/>
            </StackPanel>
        </Grid>
    </Window>
"@
    $Reader = (New-Object System.Xml.XmlNodeReader $TrainXAML)
    $StepWin = [Windows.Markup.XamlReader]::Load($Reader)

    $StepWin.FindName("StepDesc").Text = $global:UHDCSync.StepDesc
    $StepWin.FindName("StepCode").Text = $global:UHDCSync.StepCode

    $BtnAbort   = $StepWin.FindName("BtnAbort")
    $BtnExecute = $StepWin.FindName("BtnExecute")

    $BtnAbort.Add_Click({
        $global:UHDCSync.StepResult = $false
        $global:UHDCSync.StepAck = $true
        $StepWin.Close()
    })

    $BtnExecute.Add_Click({
        $global:UHDCSync.StepResult = $true
        $global:UHDCSync.StepAck = $true
        $StepWin.Close()
    })

    $StepWin.Add_Closed({
        if (-not $global:UHDCSync.StepAck) {
            $global:UHDCSync.StepResult = $false
            $global:UHDCSync.StepAck = $true
        }
    })

    $StepWin.ShowDialog() | Out-Null
}

$TrainingTimer = New-Object System.Windows.Threading.DispatcherTimer
$TrainingTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$TrainingTimer.Add_Tick({
    if ($global:UHDCSync.StepReady) {
        $global:UHDCSync.StepReady = $false
        Show-StepDialog
    }
})
$TrainingTimer.Start()

# ------------------------------------------------------------------
# 4. CORE ASYNC ENGINE
# ------------------------------------------------------------------
function Invoke-UHDCScriptAsync {
    param(
        [string]$ScriptName,
        [bool]$RequiresTarget,
        $SourceInputBox,
        $TargetOutputConsole,
        [string]$ScriptDir = $CoreFolder,
        [string]$SecondaryTarget = ""
    )

    $Target = if ($SourceInputBox) { $SourceInputBox.Text } else { "" }

    if ($RequiresTarget -and [string]::IsNullOrWhiteSpace($Target)) {
        $StatusBar.Text = "Error: Target Required."
        return
    }

    $ScriptPath = Join-Path $ScriptDir $ScriptName
    $TargetOutputConsole.Text += ">>> Executing $ScriptName...`r`n"

    $PS = [powershell]::Create()
    [void]$PS.AddScript({
        param($Path, $Tgt, $ReqTgt, $Dispatcher, $OutBox, $PC1, $PC2, $SecTgt, $SharedRoot, $SyncHash, $IsTraining)
        try {
            # Only pass the SyncHash to the tool if Training Mode is checked
            $hashToPass = if ($IsTraining) { $SyncHash } else { $null }

            if ($ReqTgt -and $SecTgt) {
                $Result = & $Path $Tgt $SecTgt -SharedRoot $SharedRoot -SyncHash $hashToPass *>&1 | Out-String
            } elseif ($ReqTgt) {
                $Result = & $Path $Tgt -SharedRoot $SharedRoot -SyncHash $hashToPass *>&1 | Out-String
            } else {
                $Result = & $Path -SharedRoot $SharedRoot -SyncHash $hashToPass *>&1 | Out-String
            }

            $Dispatcher.Invoke([Action]{
                # Intercept the GUI Magic Tag to auto-fill the target boxes
                if ($Result -match '(?m)\[GUI:UPDATE_TARGET:(.+?)\]') {
                    $NewPC = $matches[1].Trim()
                    $PC1.Text = $NewPC
                    $PC2.Text = $NewPC
                    $OutBox.Text += "[INTEL] Auto-Filled Target PC: $NewPC to Action panels.`r`n"
                    $Result = $Result -replace '(?m)\[GUI:UPDATE_TARGET:.+?\]\r?\n?', ''
                }
                $OutBox.Text += $Result
                $OutBox.ScrollToEnd()
            })
        } catch {
            $errMessage = $_.Exception.Message
            $Dispatcher.Invoke([Action]{
                $OutBox.Text += "[!] ERROR: $errMessage`r`n"
            })
        }
    })

    # Pass arguments cleanly to the runspace
    [void]$PS.AddArgument($ScriptPath)
    [void]$PS.AddArgument($Target)
    [void]$PS.AddArgument($RequiresTarget)
    [void]$PS.AddArgument($Form.Dispatcher)
    [void]$PS.AddArgument($TargetOutputConsole)
    [void]$PS.AddArgument($ComputerInput)
    [void]$PS.AddArgument($PluginInput)
    [void]$PS.AddArgument($SecondaryTarget)
    [void]$PS.AddArgument($SharedRoot)
    [void]$PS.AddArgument($global:UHDCSync)
    [void]$PS.AddArgument([bool]$CbTrainingMode.IsChecked)

    $PS.RunspacePool = $RunspacePool
    [void]$PS.BeginInvoke()
}

# ------------------------------------------------------------------
# 5. BUTTON LOGIC & EVENT MAPPING
# ------------------------------------------------------------------

# ==========================================
# Q1: AD INTELLIGENCE & ACTIONS
# ==========================================

$ADInput.Add_KeyDown({
    if ($_.Key -eq 'Return') {
        $_.Handled = $true
        $BtnADLookup.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    }
})

$BtnADLookup.Add_Click({
    $Target = $ADInput.Text
    if ([string]::IsNullOrWhiteSpace($Target)) { return }

    $ComputerInput.Text = ""
    $PluginInput.Text = ""

    Write-AuditLog -Action "Searched AD User" -Target $Target
    $users = @()
    try {
        $users = @(Get-ADUser -Filter "anr -eq '$Target'" -Properties DisplayName, Title, Office, Department, Description -ErrorAction SilentlyContinue)
    } catch {}

    if ($users.Count -eq 1) {
        $ADInput.Text = $users[0].SamAccountName
        Invoke-UHDCScriptAsync -ScriptName "SmartUserSearch.ps1" `
                               -RequiresTarget $true `
                               -SourceInputBox $ADInput `
                               -TargetOutputConsole $ADOutputConsole
    } elseif ($users.Count -gt 1) {
        $UserSelectCombo.Items.Clear()
        $UserSelectCombo.Visibility = "Visible"
        foreach ($u in $users) {
            $LocInfo = if ($u.Office) { " - Office: $($u.Office)" } elseif ($u.Department) { " - Dept: $($u.Department)" } elseif ($u.Description) { " - PC: $($u.Description)" } else { "" }
            $UserSelectCombo.Items.Add("$($u.DisplayName)$LocInfo ($($u.SamAccountName))") | Out-Null
        }
        $UserSelectCombo.IsDropDownOpen = $true
    } else {
        Invoke-UHDCScriptAsync -ScriptName "SmartUserSearch.ps1" `
                               -RequiresTarget $true `
                               -SourceInputBox $ADInput `
                               -TargetOutputConsole $ADOutputConsole
    }
})

$UserSelectCombo.Add_SelectionChanged({
    if ($UserSelectCombo.SelectedIndex -ge 0 -and $UserSelectCombo.SelectedItem -match '\(([^)]+)\)$') {
        $ADInput.Text = $matches[1]
        $UserSelectCombo.Visibility = "Collapsed"

        $ComputerInput.Text = ""
        $PluginInput.Text = ""

        Invoke-UHDCScriptAsync -ScriptName "SmartUserSearch.ps1" `
                               -RequiresTarget $true `
                               -SourceInputBox $ADInput `
                               -TargetOutputConsole $ADOutputConsole
    }
})

$BtnDisabledAD.Add_Click({
    $ADOutputConsole.Text += ">>> Querying Active Directory for all Disabled Users...`r`n"
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $DisabledUsers = Get-ADUser -Filter "Enabled -eq `$false" -Properties Title, Office, Department -ErrorAction Stop |
                         Select-Object Name, SamAccountName, Title, Office, Department

        if ($DisabledUsers) {
            $ADOutputConsole.Text += "[SUCCESS] Found $($DisabledUsers.Count) disabled accounts. Opening grid view...`r`n"
            $DisabledUsers | Out-GridView -Title "Active Directory - Disabled Accounts Report"
            Write-AuditLog -Action "Pulled Disabled AD Users Report" -Target "Global"
        } else {
            $ADOutputConsole.Text += "[i] No disabled users found in the domain.`r`n"
        }
    } catch {
        $errMessage = $_.Exception.Message
        $ADOutputConsole.Text += "[!] ERROR querying AD: $errMessage`r`n"
    }
    $ADOutputConsole.ScrollToEnd()
})

$BtnUnlock.Add_Click({
    $Target = $ADInput.Text
    if ([string]::IsNullOrWhiteSpace($Target)) { return }

    $ADOutputConsole.Text += ">>> Attempting to unlock AD Account: $Target...`r`n"
    try {
        Unlock-ADAccount -Identity $Target -ErrorAction Stop
        $ADOutputConsole.Text += "[SUCCESS] Account Unlocked.`r`n"
        Write-AuditLog -Action "Unlocked AD Account" -Target $Target
    } catch {
        $ADOutputConsole.Text += "[!] Failed to unlock account.`r`n"
    }
    $ADOutputConsole.ScrollToEnd()
})

$BtnResetPwd.Add_Click({
    $Target = $ADInput.Text
    if ([string]::IsNullOrWhiteSpace($Target)) { return }

    $NewPwd = [Microsoft.VisualBasic.Interaction]::InputBox("Enter the NEW PASSWORD for $($Target):", "Reset AD Password", "")
    if ([string]::IsNullOrWhiteSpace($NewPwd)) { return }

    $ADOutputConsole.Text += ">>> Attempting to reset AD Password for: $Target...`r`n"
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $securePwd = ConvertTo-SecureString $NewPwd -AsPlainText -Force
        Set-ADAccountPassword -Identity $Target -NewPassword $securePwd -Reset -ErrorAction Stop
        Set-ADUser -Identity $Target -ChangePasswordAtLogon $false -ErrorAction Stop
        $ADOutputConsole.Text += "[SUCCESS] Password reset successfully.`r`n"
        Write-AuditLog -Action "Reset AD Password" -Target $Target
    } catch {
        $ADOutputConsole.Text += "[!] Failed to reset password.`r`n"
    }
    $ADOutputConsole.ScrollToEnd()
})

$BtnIntune.Add_Click({
    $UserQuery = $ADInput.Text
    $ComputerQuery = $ComputerInput.Text
    $EmailToPass = $UserQuery

    if (-not [string]::IsNullOrWhiteSpace($UserQuery) -and $UserQuery -notmatch "@") {
        try {
            $adObj = Get-ADUser -Identity $UserQuery -Properties EmailAddress -ErrorAction SilentlyContinue
            if ($adObj.EmailAddress) {
                $EmailToPass = $adObj.EmailAddress
            }
        } catch {}
    }

    $IntuneScript = Join-Path -Path $CoreFolder -ChildPath "IntuneMenu.ps1"
    Start-Process PowerShell -ArgumentList "-File `"$IntuneScript`" -TargetComputer `"$ComputerQuery`" -TargetUser `"$EmailToPass`" -SharedRoot `"$SharedRoot`""
})

$BtnBookmarkBackup.Add_Click({
    Invoke-UHDCScriptAsync -ScriptName "BookmarkBackup.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $ComputerInput `
                           -TargetOutputConsole $ADOutputConsole `
                           -SecondaryTarget $ADInput.Text `
                           -ScriptDir $ToolsFolder
})

$BtnBrowserReset.Add_Click({
    Write-AuditLog -Action "Executed Browser Reset" -Target $ComputerInput.Text
    Invoke-UHDCScriptAsync -ScriptName "BrowserReset.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $ComputerInput `
                           -TargetOutputConsole $ADOutputConsole `
                           -SecondaryTarget $ADInput.Text `
                           -ScriptDir $ToolsFolder
})

$BtnNetworkScan.Add_Click({
    Invoke-UHDCScriptAsync -ScriptName "NetworkScan.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $ADInput `
                           -TargetOutputConsole $ADOutputConsole
})

$BtnAddLoc.Add_Click({
    $User = [Microsoft.VisualBasic.Interaction]::InputBox("1. Enter the USERNAME you want to update:", "Manual History Entry", $ADInput.Text)
    if ([string]::IsNullOrWhiteSpace($User)) { return }

    $PCName = [Microsoft.VisualBasic.Interaction]::InputBox("2. Enter the COMPUTER NAME for $($User):", "Manual History Entry", $ComputerInput.Text)
    if ([string]::IsNullOrWhiteSpace($PCName)) { return }

    $ADOutputConsole.Text += ">>> Manually assigning '$PCName' to user '$User'...`r`n"
    $HelperPath = Join-Path -Path $CoreFolder -ChildPath "Helper_UpdateHistory.ps1"

    if (Test-Path $HelperPath) {
        & $HelperPath -User $User -Computer $PCName -SharedRoot $SharedRoot
        $ADOutputConsole.Text += "[SUCCESS] History Database Updated.`r`n"
    }
    $ADOutputConsole.ScrollToEnd()
})

$BtnRemLoc.Add_Click({
    $TargetUser = $ADInput.Text
    if ([string]::IsNullOrWhiteSpace($TargetUser)) {
        $TargetUser = [Microsoft.VisualBasic.Interaction]::InputBox("Enter the USERNAME you want to manage:", "Remove History Entry", "")
        if ([string]::IsNullOrWhiteSpace($TargetUser)) { return }
    }

    $HistoryFile = Join-Path -Path $CoreFolder -ChildPath "UserHistory.json"
    if (-not (Test-Path $HistoryFile)) {
        $ADOutputConsole.Text += "[!] No UserHistory.json found.`r`n"
        return
    }

    $allData = Get-Content $HistoryFile -Raw | ConvertFrom-Json
    $userPCs = $allData | Where-Object { $_.User -eq $TargetUser }

    if ($null -eq $userPCs -or $userPCs.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No computer history found for '$TargetUser'.", "Empty History", "OK", "Information")
        return
    }

    if ($userPCs -isnot [System.Array]) { $userPCs = @($userPCs) }

    $PCtoRemove = $userPCs | Select-Object User, Computer, LastSeen, Source | Out-GridView -Title "Select the PC to REMOVE for $TargetUser" -PassThru

    if ($PCtoRemove) {
        $ADOutputConsole.Text += ">>> Removing '$($PCtoRemove.Computer)' from '$($TargetUser)'...`r`n"
        [System.Windows.Forms.Application]::DoEvents()

        $HelperPath = Join-Path -Path $CoreFolder -ChildPath "Helper_RemoveHistory.ps1"
        if (Test-Path $HelperPath) {
            & $HelperPath -User $TargetUser -Computer $PCtoRemove.Computer -SharedRoot $SharedRoot
            $ADOutputConsole.Text += "[SUCCESS] PC Removed and Database Protected.`r`n"
        } else {
            $ADOutputConsole.Text += "[!] Error: Helper_RemoveHistory.ps1 is missing from Core folder.`r`n"
        }
        $ADOutputConsole.ScrollToEnd()
    }
})

$BtnGlobalMap.Add_Click({
    Invoke-UHDCScriptAsync -ScriptName "GlobalNetworkMap.ps1" `
                           -RequiresTarget $false `
                           -SourceInputBox $null `
                           -TargetOutputConsole $ADOutputConsole
})

# ==========================================
# Q3: REMOTE ACCESS & DIAGNOSTICS
# ==========================================

$BtnSCCM.Add_Click({
    $sccmPath = "C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\i386\CmRcViewer.exe"

    if (-not [string]::IsNullOrWhiteSpace($ComputerInput.Text)) {
        if (Test-Path $sccmPath) {
            Start-Process $sccmPath $ComputerInput.Text
        } else {
            $ComputerOutputConsole.Text += "[!] ERROR: CmRcViewer.exe not found. Is the SCCM Admin Console installed locally?`r`n"
            $ComputerOutputConsole.ScrollToEnd()
        }
    }
})

$BtnMSRA.Add_Click({
    if ($ComputerInput.Text) {
        Start-Process "msra.exe" "/offerRA $($ComputerInput.Text)"
    }
})

$BtnCShare.Add_Click({
    if ($ComputerInput.Text) {
        Invoke-Item "\\$($ComputerInput.Text)\C$"
    }
})

$BtnSessions.Add_Click({
    Invoke-UHDCScriptAsync -ScriptName "Helper_CheckSessions.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $ComputerInput `
                           -TargetOutputConsole $ComputerOutputConsole
})

$BtnLAPS.Add_Click({
    $Target = $ComputerInput.Text
    if ([string]::IsNullOrWhiteSpace($Target)) { return }

    $ComputerOutputConsole.Text += ">>> Querying LAPS Password for $Target...`r`n"
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $laps = Get-ADComputer -Identity $Target -Properties "ms-Mcs-AdmPwd", "msLAPS-Password" -ErrorAction Stop
        $pwd = if ($laps."ms-Mcs-AdmPwd") { $laps."ms-Mcs-AdmPwd" } elseif ($laps."msLAPS-Password") { $laps."msLAPS-Password" } else { $null }

        if ($pwd) {
            $ComputerOutputConsole.Text += "[SUCCESS] Local Admin Password: $pwd`r`n"
            Write-AuditLog -Action "Viewed LAPS Password" -Target $Target
        } else {
            $ComputerOutputConsole.Text += "[!] No LAPS password found.`r`n"
        }
    } catch {
        $ComputerOutputConsole.Text += "[!] Failed to query LAPS.`r`n"
    }
    $ComputerOutputConsole.ScrollToEnd()
})

$BtnDeploy.Add_Click({
    $TgtPC = $ComputerInput.Text
    $TgtUser = $ADInput.Text

    if ([string]::IsNullOrWhiteSpace($TgtPC) -or [string]::IsNullOrWhiteSpace($TgtUser)) {
        $StatusBar.Text = "Error: Need PC and AD User."
        return
    }

    $ComputerOutputConsole.Text += ">>> Deploying UHDC Network Shortcut to $TgtPC...`r`n"

    $PS = [powershell]::Create()
    [void]$PS.AddScript({
        param($PC, $User, $Dispatcher, $Console, $SharedRoot, $IconPath)
        try {
            $Base = "\\$PC\C$\Users\$User"
            $Desktop = "\\$PC\C$\Users\Public\Desktop"

            $WildcardOD = Get-ChildItem -Path $Base -Filter "OneDrive*" -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path "$($_.FullName)\Desktop" } | Select-Object -ExpandProperty FullName -First 1

            if ($WildcardOD) {
                $Desktop = "$WildcardOD\Desktop"
            } elseif (Test-Path "$Base\Desktop") {
                $Desktop = "$Base\Desktop"
            }

            $TargetExe = Join-Path $SharedRoot "UHDC.exe"

            $LocalLnk = "$env:TEMP\UHDC.lnk"
            $WshShell = New-Object -ComObject WScript.Shell
            $Shortcut = $WshShell.CreateShortcut($LocalLnk)

            $Shortcut.TargetPath = $TargetExe
            $Shortcut.WorkingDirectory = $SharedRoot
            $Shortcut.Description = "Unified Help Desk Console"

            if (Test-Path $IconPath) { $Shortcut.IconLocation = $IconPath }
            $Shortcut.Save()

            Copy-Item $LocalLnk -Destination "$Desktop\UHDC.lnk" -Force

            $Dispatcher.Invoke([Action]{
                $Console.Text += "[SUCCESS] Deployed Shortcut to $PC Desktop.`r`n"
            })
        } catch {
            $err = $_.Exception.Message
            $Dispatcher.Invoke([Action]{ $Console.Text += "[!] DEPLOY ERROR: $err`r`n" })
        }
    })

    [void]$PS.AddArgument($TgtPC)
    [void]$PS.AddArgument($TgtUser)
    [void]$PS.AddArgument($Form.Dispatcher)
    [void]$PS.AddArgument($ComputerOutputConsole)
    [void]$PS.AddArgument($SharedRoot)
    [void]$PS.AddArgument((Join-Path -Path $CoreFolder -ChildPath "UHDC.ico"))

    $PS.RunspacePool = $RunspacePool
    [void]$PS.BeginInvoke()
})

# ==========================================
# Q2: ENDPOINT REMEDIATION & CORE TOOLS
# ==========================================

$BtnNetInfo.Add_Click({
    Invoke-UHDCScriptAsync -ScriptName "Get-NetworkInfo.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder
})

$BtnUptime.Add_Click({
    Invoke-UHDCScriptAsync -ScriptName "Get-Uptime.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder
})

$BtnGetLogs.Add_Click({
    $Keyword = [Microsoft.VisualBasic.Interaction]::InputBox("Enter a keyword to search System/Application logs.`n`n(Leave blank to just pull the last 5 Critical/Error logs):", "Search PC Logs", "")
    if ($null -eq $Keyword) { return }

    Write-AuditLog -Action "Pulled PC Event Logs" -Target $PluginInput.Text

    Invoke-UHDCScriptAsync -ScriptName "Get-EventLogs.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder `
                           -SecondaryTarget $Keyword
})

$BtnChkBit.Add_Click({
    Invoke-UHDCScriptAsync -ScriptName "Check-BitLocker.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder
})

$BtnBatRep.Add_Click({
    Invoke-UHDCScriptAsync -ScriptName "Get-BatteryReport.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder
})

$BtnSmartWar.Add_Click({
    Invoke-UHDCScriptAsync -ScriptName "Get-SmartWarranty.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder
})

$BtnLocAdm.Add_Click({
    Invoke-UHDCScriptAsync -ScriptName "Get-LocalAdmins.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder
})

$BtnEnRDP.Add_Click({
    Write-AuditLog -Action "Enabled Remote Desktop" -Target $PluginInput.Text
    Invoke-UHDCScriptAsync -ScriptName "Enable-RemoteDesktop.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder
})

$BtnRegDNS.Add_Click({
    Write-AuditLog -Action "Forced DNS Registration" -Target $PluginInput.Text
    Invoke-UHDCScriptAsync -ScriptName "Register-DNS.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder
})

$BtnFixSpool.Add_Click({
    Write-AuditLog -Action "Restarted Print Spooler" -Target $PluginInput.Text
    Invoke-UHDCScriptAsync -ScriptName "Fix-PrintSpooler.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder
})

$BtnGPUpdate.Add_Click({
    Write-AuditLog -Action "Forced GPUpdate" -Target $PluginInput.Text
    Invoke-UHDCScriptAsync -ScriptName "Invoke-GPUpdate.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder
})

$BtnRestartSCCM.Add_Click({
    Write-AuditLog -Action "Restarted SCCM Agent" -Target $PluginInput.Text
    Invoke-UHDCScriptAsync -ScriptName "Restart-SCCMAgent.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder
})

$BtnMapDrives.Add_Click({
    Write-AuditLog -Action "Pushed Network Drives Refresh" -Target $PluginInput.Text
    Invoke-UHDCScriptAsync -ScriptName "PushRefreshDrives.ps1" -RequiresTarget $true -SourceInputBox $PluginInput -TargetOutputConsole $PluginOutputConsole -ScriptDir $ToolsFolder
})

$BtnDeepClean.Add_Click({
    Write-AuditLog -Action "Executed Deep Clean" -Target $PluginInput.Text
    Invoke-UHDCScriptAsync -ScriptName "DeepClean.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder
})

$BtnRemInstall.Add_Click({
    Invoke-UHDCScriptAsync -ScriptName "RemoteInstall.ps1" `
                           -RequiresTarget $true `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder
})

$BtnRestart.Add_Click({
    Write-AuditLog -Action "Initiated PC Restart Options" -Target $PluginInput.Text
    Invoke-UHDCScriptAsync -ScriptName "RestartPC.ps1" `
                           -RequiresTarget $false `
                           -SourceInputBox $PluginInput `
                           -TargetOutputConsole $PluginOutputConsole `
                           -ScriptDir $ToolsFolder
})

# ==========================================
# Q4: COMMAND CENTER & COMMUNICATIONS
# ==========================================

$BtnNetSend.Add_Click({
    $Target = if ($ComputerInput.Text) { $ComputerInput.Text } else { [Microsoft.VisualBasic.Interaction]::InputBox("Enter the Target PC Name:", "Net Send", "") }
    if ([string]::IsNullOrWhiteSpace($Target)) { return }

    $Msg = [Microsoft.VisualBasic.Interaction]::InputBox("Enter the pop-up message to send to $($Target):", "Net Send", "")
    if ([string]::IsNullOrWhiteSpace($Msg)) { return }

    $OnlineUsersConsole.Text += ">>> Sending network pop-up to $Target...`r`n"
    [System.Windows.Forms.Application]::DoEvents()

    $Output = & cmd.exe /c "msg * /server:$Target `"$Msg`" 2>&1"

    if ($LASTEXITCODE -eq 0 -or [string]::IsNullOrWhiteSpace($Output)) {
        $OnlineUsersConsole.Text += "[SUCCESS] Message delivered to $Target.`r`n"
        Write-AuditLog -Action "Sent Net Send Message" -Target $Target
    } else {
        $OnlineUsersConsole.Text += "[!] FAILED: $Output`r`n"
    }
    $OnlineUsersConsole.ScrollToEnd()
})

$BtnAddMOTD.Add_Click({
    $txt = [Microsoft.VisualBasic.Interaction]::InputBox("Enter the Global Announcement text:", "New MOTD", "")
    if ($txt) {
        $MOTDFile = Join-Path -Path $SharedRoot -ChildPath "MOTD.json"
        $allMOTDs = if (Test-Path $MOTDFile) { Get-Content $MOTDFile -Raw | ConvertFrom-Json } else { @() }
        $allMOTDs = if ($allMOTDs -is [System.Array]) { $allMOTDs } else { @($allMOTDs) }

        $newMsg = [PSCustomObject]@{ Text = $txt; Timestamp = (Get-Date).ToString("MM/dd HH:mm") }
        ConvertTo-Json -InputObject @($allMOTDs + $newMsg) -Depth 2 | Set-Content $MOTDFile -Force

        Write-AuditLog -Action "Added MOTD: $txt" -Target "Global"
    }
})

$BtnDelMOTD.Add_Click({
    $MOTDFile = Join-Path -Path $SharedRoot -ChildPath "MOTD.json"
    if (-not (Test-Path $MOTDFile)) { return }

    $allMOTDs = Get-Content $MOTDFile -Raw | ConvertFrom-Json
    if ($null -eq $allMOTDs) { return }
    $allMOTDs = if ($allMOTDs -is [System.Array]) { $allMOTDs } else { @($allMOTDs) }

    $MotdToDelete = $allMOTDs | Out-GridView -Title "Select Announcement to DELETE" -PassThru
    if ($MotdToDelete) {
        $newList = @($allMOTDs | Where-Object { $_.Timestamp -ne $MotdToDelete.Timestamp -or $_.Text -ne $MotdToDelete.Text })
        if ($newList.Count -gt 0) {
            ConvertTo-Json -InputObject $newList -Depth 2 | Set-Content $MOTDFile -Force
        } else {
            Remove-Item $MOTDFile -Force
        }

        Write-AuditLog -Action "Removed MOTD: $($MotdToDelete.Text)" -Target "Global"
    }
})

# ------------------------------------------------------------------
# 6. AUTOMATED LIVE ENGINES (Presence & Ticker)
# ------------------------------------------------------------------

# Smooth Scrolling Ticker Timer
$ScrollTimer = New-Object System.Windows.Threading.DispatcherTimer
$ScrollTimer.Interval = [TimeSpan]::FromMilliseconds(20)
$ScrollTimer.Add_Tick({
    $currentLeft = [System.Windows.Controls.Canvas]::GetLeft($MotdScrollText)
    $textWidth = $MotdScrollText.ActualWidth
    $canvasWidth = $MotdCanvas.ActualWidth

    if ($textWidth -gt 0) {
        if ($currentLeft -lt -$textWidth) {
            [System.Windows.Controls.Canvas]::SetLeft($MotdScrollText, $canvasWidth)
        } else {
            [System.Windows.Controls.Canvas]::SetLeft($MotdScrollText, $currentLeft - 2)
        }
    }
})
$ScrollTimer.Start()

# Background Runspace for Presence and MOTD Reading
$PresencePS = [powershell]::Create()
[void]$PresencePS.AddScript({
    param($PDir, $SRoot, $User, $Dispatcher, $OnlineConsole, $MotdText)

    $lastDisplay = ""
    $lastMotd = ""

    while ($true) {
        # 1. Write our own heartbeat
        try {
            $MyFile = Join-Path -Path $PDir -ChildPath "Presence_$($User).txt"
            Set-Content -Path $MyFile -Value (Get-Date).Ticks -Force
        } catch {}

        # 2. Read others' heartbeats
        $display = ""
        try {
            $online = @()
            $cutoff = (Get-Date).AddMinutes(-5).Ticks
            $files = Get-ChildItem -Path $PDir -Filter "Presence_*.txt"
            foreach ($file in $files) {
                if ($file.LastWriteTime.Ticks -gt $cutoff) {
                    $techName = $file.Name -replace "Presence_", "" -replace "\.txt", ""
                    $online += $techName
                }
            }
            $display = if ($online.Count -gt 0) { ($online | Sort-Object) -join "  •  " } else { "No active technicians." }
        } catch {}

        # 3. Read MOTD
        $motdString = ""
        try {
            $motdFile = Join-Path -Path $SRoot -ChildPath "MOTD.json"
            if (Test-Path $motdFile) {
                $allMOTDs = Get-Content $motdFile -Raw | ConvertFrom-Json
                if ($allMOTDs) {
                    $allMOTDs = if ($allMOTDs -is [System.Array]) { $allMOTDs } else { @($allMOTDs) }
                    $motdString = ($allMOTDs | ForEach-Object { "[$($_.Timestamp)] $($_.Text)" }) -join "   |   "
                } else { $motdString = "No active network announcements." }
            } else { $motdString = "No active network announcements." }
        } catch {}

        # 4. Update UI only if changed
        if ($display -ne $lastDisplay -or $motdString -ne $lastMotd) {
            $lastDisplay = $display
            $lastMotd = $motdString

            [void]$Dispatcher.BeginInvoke([Action]{
                if ($display -ne "") { $OnlineConsole.Text = $display }
                if ($motdString -ne "") { $MotdText.Text = $motdString }
            })
        }
        Start-Sleep -Seconds 5
    }
})

[void]$PresencePS.AddArgument($PresenceDir)
[void]$PresencePS.AddArgument($SharedRoot)
[void]$PresencePS.AddArgument($env:USERNAME)
[void]$PresencePS.AddArgument($Form.Dispatcher)
[void]$PresencePS.AddArgument($OnlineUsersConsole)
[void]$PresencePS.AddArgument($MotdScrollText)

$PresencePS.RunspacePool = $RunspacePool
[void]$PresencePS.BeginInvoke()

# ------------------------------------------------------------------
# LAUNCH APPLICATION
# ------------------------------------------------------------------
$Form.ShowDialog() | Out-Null

# Cleanup on Exit
$ScrollTimer.Stop()
$TrainingTimer.Stop()
$RunspacePool.Dispose()