# ==============================================================================================
# UHDC.ps1 - Unified Help Desk Console (Master Script)
# Place this script in the ROOT folder (e.g., \\Server\Share\UHDC\)
# DESCRIPTION: The main GUI and asynchronous runspace engine for the UHDC platform.
# Fully optimized for PowerShell 5.1 compatibility.
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
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
# THEME ENGINE & USER PREFERENCES (PS 5.1 Optimized)
# ------------------------------------------------------------------
$Themes = [ordered]@{
    "PNW (Default)"      = @{ BG_Main="#1E1E1E"; BG_Sec="#111111"; BG_Con="#0C0C0C"; BG_Btn="#2D2D30"; Acc_Pri="#00A2ED"; Acc_Sec="#00FF00" }
    "Maritime Retro"     = @{ BG_Main="#0C2340"; BG_Sec="#071526"; BG_Con="#030A13"; BG_Btn="#113159"; Acc_Pri="#FFC425"; Acc_Sec="#00A6CE" }
    "Midnight Terminal"  = @{ BG_Main="#0D0208"; BG_Sec="#000000"; BG_Con="#050104"; BG_Btn="#1A0510"; Acc_Pri="#00F0FF"; Acc_Sec="#FF003C" }
    "Deep Amethyst"      = @{ BG_Main="#282A36"; BG_Sec="#1E1F29"; BG_Con="#191A21"; BG_Btn="#44475A"; Acc_Pri="#BD93F9"; Acc_Sec="#50FA7B" }
    "Mainframe"          = @{ BG_Main="#050F05"; BG_Sec="#020802"; BG_Con="#010401"; BG_Btn="#0A1A0A"; Acc_Pri="#00FF41"; Acc_Sec="#00FF42" }
    "Solarized Dark"     = @{ BG_Main="#002B36"; BG_Sec="#073642"; BG_Con="#001E26"; BG_Btn="#083642"; Acc_Pri="#268BD2"; Acc_Sec="#2AA198" }
    "Blood Moon"         = @{ BG_Main="#1A0000"; BG_Sec="#0D0000"; BG_Con="#050000"; BG_Btn="#260000"; Acc_Pri="#FF3333"; Acc_Sec="#FF8800" }
    "Deep Ocean"         = @{ BG_Main="#0F172A"; BG_Sec="#080C17"; BG_Con="#04060C"; BG_Btn="#1E293B"; Acc_Pri="#38BDF8"; Acc_Sec="#34D399" }
    "Death Valley"       = @{ BG_Main="#2E251E"; BG_Sec="#1F1813"; BG_Con="#140F0C"; BG_Btn="#3D3228"; Acc_Pri="#D97736"; Acc_Sec="#E8B07D" }
    "Olympics"           = @{ BG_Main="#1A2421"; BG_Sec="#111816"; BG_Con="#0B100E"; BG_Btn="#23312D"; Acc_Pri="#4A90E2"; Acc_Sec="#10B981" }
    "Cascades"           = @{ BG_Main="#1E2227"; BG_Sec="#14171A"; BG_Con="#0D0F12"; BG_Btn="#282D33"; Acc_Pri="#00B4D8"; Acc_Sec="#E2E8F0" }
    "Shenandoah"         = @{ BG_Main="#2A1610"; BG_Sec="#1C0E0A"; BG_Con="#110806"; BG_Btn="#381D15"; Acc_Pri="#F97316"; Acc_Sec="#FBBF24" }
    "Patagonia"          = @{ BG_Main="#1E1B4B"; BG_Sec="#110F2E"; BG_Con="#0A091A"; BG_Btn="#2D286B"; Acc_Pri="#FB923C"; Acc_Sec="#A78BFA" }
}

$UsersFile = Join-Path -Path $CoreFolder -ChildPath "users.json"
$UserPrefs = @{}

# Load existing preferences (PS 5.1 PSCustomObject to Hashtable mapping)
if (Test-Path $UsersFile) {
    try {
        $rawPrefs = Get-Content $UsersFile -Raw | ConvertFrom-Json
        foreach ($prop in $rawPrefs.psobject.properties) {
            $UserPrefs[$prop.Name] = $prop.Value
        }
    } catch {}
}

# Determine active colors for current user
$ActiveThemeName = "PNW (Default)"
$ActiveColors = $Themes[$ActiveThemeName]

if ($UserPrefs.ContainsKey($env:USERNAME)) {
    $pref = $UserPrefs[$env:USERNAME]
    if ($pref.ThemeName -eq "Custom" -and $null -ne $pref.CustomColors) {
        $ActiveThemeName = "Custom"
        # Explicitly map to a hashtable to prevent PS 5.1 serialization quirks
        $ActiveColors = @{
            BG_Main = $pref.CustomColors.BG_Main
            BG_Sec  = $pref.CustomColors.BG_Sec
            BG_Con  = $pref.CustomColors.BG_Con
            BG_Btn  = $pref.CustomColors.BG_Btn
            Acc_Pri = $pref.CustomColors.Acc_Pri
            Acc_Sec = $pref.CustomColors.Acc_Sec
        }
    } elseif ($Themes.ContainsKey($pref.ThemeName)) {
        $ActiveThemeName = $pref.ThemeName
        $ActiveColors = $Themes[$ActiveThemeName]
    }
}

# Encode theme for safe injection to subscripts across runspaces
$ThemeJson = $ActiveColors | ConvertTo-Json -Compress
$ThemeBytes = [System.Text.Encoding]::UTF8.GetBytes($ThemeJson)
$ThemeB64 = [Convert]::ToBase64String($ThemeBytes)

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
        Title="Unified Help Desk Console (UHDC)" Height="950" Width="1350" Background="%%BG_MAIN%%" WindowStartupLocation="CenterScreen">

    <Window.Resources>
        <Style x:Key="StdBtn" TargetType="Button">
            <Setter Property="Background" Value="%%BG_BTN%%"/>
            <Setter Property="Foreground" Value="%%ACC_PRI%%"/>
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
                                <Setter TargetName="border" Property="BorderBrush" Value="%%ACC_SEC%%"/>
                                <Setter Property="Foreground" Value="%%ACC_SEC%%"/>
                                <Setter TargetName="border" Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Color="%%ACC_SEC%%" BlurRadius="12" ShadowDepth="0" Opacity="0.7"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="%%ACC_SEC%%"/>
                                <Setter Property="Foreground" Value="%%BG_MAIN%%"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ActionBtn" TargetType="Button" BasedOn="{StaticResource StdBtn}">
            <Setter Property="Foreground" Value="%%ACC_SEC%%"/>
        </Style>

        <Style x:Key="DangerBtn" TargetType="Button">
            <Setter Property="Background" Value="%%BG_BTN%%"/>
            <Setter Property="Foreground" Value="%%ACC_PRI%%"/>
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
                                <Setter Property="Foreground" Value="%%BG_MAIN%%"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="WarningBtn" TargetType="Button">
            <Setter Property="Background" Value="%%BG_BTN%%"/>
            <Setter Property="Foreground" Value="%%ACC_PRI%%"/>
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
                                <Setter Property="Foreground" Value="%%BG_MAIN%%"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="MasterBtn" TargetType="Button">
            <Setter Property="Background" Value="%%BG_BTN%%"/>
            <Setter Property="Foreground" Value="%%ACC_PRI%%"/>
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
                                <Setter Property="Foreground" Value="%%BG_MAIN%%"/>
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

        <TextBlock Grid.Row="0" Text="$OrgName IT Dashboard" FontSize="26" Foreground="%%ACC_PRI%%" FontWeight="Bold" Margin="5,0,0,5"/>

        <Grid Grid.Row="1" Height="30" Background="%%BG_SEC%%" Margin="5,0,5,10" >
            <Canvas Name="MotdCanvas" ClipToBounds="True">
                <TextBlock Name="MotdScrollText" Foreground="%%ACC_SEC%%" FontSize="16" FontFamily="Consolas" FontWeight="Bold" Canvas.Left="1350" Canvas.Top="4" Text="Loading Announcements..."/>
            </Canvas>
        </Grid>

        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="1.35*"/>
                <ColumnDefinition Width="1.45*"/>
            </Grid.ColumnDefinitions>

            <Grid Grid.Column="0" Margin="0,0,5,0">
                <Grid.RowDefinitions>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <GroupBox Grid.Row="0" Header="AD User Intelligence &amp; Actions" Foreground="#AAAAAA" BorderBrush="#333333" Margin="5" Padding="0">
                    <Border BorderThickness="4,0,0,0" BorderBrush="%%ACC_PRI%%" Background="%%BG_SEC%%" Padding="10">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>

                            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
                                <TextBlock Text="Username:" Foreground="White" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="14"/>
                                <TextBox Name="ADInput" Width="180" Height="28" FontSize="14" Background="%%BG_MAIN%%" Foreground="%%ACC_PRI%%" BorderBrush="#555555" Padding="2" ToolTip="Enter an Employee ID, Username, or First/Last name."/>
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

                            <TextBox Name="ADOutputConsole" Grid.Row="2" Background="%%BG_CON%%" Foreground="%%ACC_SEC%%" FontFamily="Consolas" FontSize="16" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" BorderThickness="1" BorderBrush="#333333"/>
                        </Grid>
                    </Border>
                </GroupBox>

                <GroupBox Grid.Row="1" Header="Command Center (Active Techs)" Foreground="#AAAAAA" BorderBrush="#333333" Margin="5" Padding="0">
                    <Border BorderThickness="4,0,0,0" BorderBrush="%%ACC_PRI%%" Background="%%BG_SEC%%" Padding="10">
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

                            <TextBox Name="OnlineUsersConsole" Grid.Row="1" Background="%%BG_CON%%" Foreground="%%ACC_SEC%%" FontFamily="Consolas" FontSize="14" IsReadOnly="True" VerticalScrollBarVisibility="Hidden" TextWrapping="Wrap" BorderThickness="1" BorderBrush="#333333"/>
                        </Grid>
                    </Border>
                </GroupBox>
            </Grid>

            <Grid Grid.Column="1" Margin="5,0,0,0">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <GroupBox Grid.Row="0" Header="Remote Access &amp; Diagnostics" Foreground="#AAAAAA" BorderBrush="#333333" Margin="5" Padding="0">
                    <Border BorderThickness="4,0,0,0" BorderBrush="%%ACC_PRI%%" Background="%%BG_SEC%%" Padding="10">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
                                <TextBlock Text="Target PC:" Foreground="White" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                <TextBox Name="ComputerInput" Width="160" Height="25" Background="%%BG_MAIN%%" Foreground="%%ACC_PRI%%" FontWeight="Bold" BorderBrush="#555555" Padding="2" ToolTip="Enter a specific Target PC Name or IP Address."/>
                            </StackPanel>
                            <WrapPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,10">
                                <Button Name="BtnSCCM" Content="SCCM" Width="60" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Launch SCCM Remote Control Viewer for the target PC."/>
                                <Button Name="BtnMSRA" Content="MSRA" Width="60" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Send a Windows Remote Assistance invitation to the target."/>
                                <Button Name="BtnCShare" Content="Open C$" Width="65" Height="30" Margin="2" Style="{StaticResource ActionBtn}" ToolTip="Open the hidden C$ administrative share in File Explorer."/>
                                <Button Name="BtnSessions" Content="Sessions" Width="65" Height="30" Margin="2" Style="{StaticResource StdBtn}" ToolTip="Check which user accounts are actively logged into this PC."/>
                                <Button Name="BtnLAPS" Content="LAPS" Width="55" Height="30" Margin="2" Style="{StaticResource StdBtn}" ToolTip="Retrieve the rotating Local Administrator Password from AD."/>
                                <Button Name="BtnDeploy" Content="Deploy GUI" Width="90" Height="30" Margin="2" Style="{StaticResource MasterBtn}" ToolTip="Push the compiled UHDC Network Shortcut directly to a coworker's PC."/>
                            </WrapPanel>
                            <TextBox Name="ComputerOutputConsole" Grid.Row="2" Height="120" Background="%%BG_CON%%" Foreground="%%ACC_SEC%%" FontFamily="Consolas" FontSize="13" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" BorderThickness="1" BorderBrush="#333333"/>
                        </Grid>
                    </Border>
                </GroupBox>

                <GroupBox Grid.Row="1" Header="Endpoint Remediation &amp; Core Tools" Foreground="#AAAAAA" BorderBrush="#333333" Margin="5" Padding="0">
                    <Border BorderThickness="4,0,0,0" BorderBrush="%%ACC_PRI%%" Background="%%BG_SEC%%" Padding="10">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
                                <TextBlock Text="Target PC:" Foreground="White" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                <TextBox Name="PluginInput" Width="160" Height="25" Background="%%BG_MAIN%%" Foreground="%%ACC_PRI%%" FontWeight="Bold" BorderBrush="#555555" Padding="2" ToolTip="Enter a specific Target PC Name or IP Address."/>
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
                            <TextBox Name="PluginOutputConsole" Grid.Row="2" Background="%%BG_CON%%" Foreground="%%ACC_SEC%%" FontFamily="Consolas" FontSize="13" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" BorderThickness="1" BorderBrush="#333333"/>
                        </Grid>
                    </Border>
                </GroupBox>

            </Grid>
        </Grid>

        <Grid Grid.Row="3" Margin="5,10,5,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Name="StatusBar" Grid.Column="0" Text="Ready..." Foreground="#28A745" FontWeight="Bold" VerticalAlignment="Center"/>
            <Button Name="BtnTheme" Grid.Column="1" Content="[Theme Settings]" Background="Transparent" Foreground="%%ACC_PRI%%" BorderThickness="0" Cursor="Hand" Margin="0,0,20,0" FontWeight="Bold"/>
            <CheckBox Name="CbTrainingMode" Grid.Column="2" Content="Training Mode" Foreground="#FFD700" FontWeight="Bold" VerticalAlignment="Center" ToolTip="Enable interactive step-by-step execution." Cursor="Hand"/>
        </Grid>
    </Grid>
</Window>
"@

# Inject the active theme colors into the XAML string before loading
$XAML = $XAML -replace '%%BG_MAIN%%', $ActiveColors.BG_Main
$XAML = $XAML -replace '%%BG_SEC%%',  $ActiveColors.BG_Sec
$XAML = $XAML -replace '%%BG_CON%%',  $ActiveColors.BG_Con
$XAML = $XAML -replace '%%BG_BTN%%',  $ActiveColors.BG_Btn
$XAML = $XAML -replace '%%ACC_PRI%%', $ActiveColors.Acc_Pri
$XAML = $XAML -replace '%%ACC_SEC%%', $ActiveColors.Acc_Sec

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
$BtnTheme        = $Form.FindName("BtnTheme")

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
            xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
            Title="UHDC Training Mode - Step Execution" WindowStyle="ToolWindow" WindowStartupLocation="CenterScreen" Topmost="True" ResizeMode="NoResize" SizeToContent="Height" Width="750" Background="%%BG_MAIN%%">

        <Window.Resources>
            <Style x:Key="GlassBtn" TargetType="Button">
                <Setter Property="Background" Value="%%BG_BTN%%"/>
                <Setter Property="Foreground" Value="%%ACC_PRI%%"/>
                <Setter Property="BorderThickness" Value="1"/>
                <Setter Property="BorderBrush" Value="#444"/>
                <Setter Property="Cursor" Value="Hand"/>
                <Setter Property="Template">
                    <Setter.Value>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="border" Property="BorderBrush" Value="%%ACC_SEC%%"/>
                                    <Setter Property="Foreground" Value="%%ACC_SEC%%"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Setter.Value>
                </Setter>
            </Style>
        </Window.Resources>

        <Grid Margin="20">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/> <RowDefinition Height="Auto"/> <RowDefinition Height="Auto"/> <RowDefinition Height="Auto"/> <RowDefinition Height="Auto"/> <RowDefinition Height="Auto"/> <RowDefinition Height="Auto"/> </Grid.RowDefinitions>

            <Grid Grid.Row="0" Margin="0,0,0,15">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="TRAINING MODE: STEP EXECUTION" Foreground="#FFD700" FontSize="15" FontWeight="Bold" VerticalAlignment="Center"/>
                <Border Grid.Column="1" Background="%%BG_SEC%%" BorderBrush="%%ACC_PRI%%" BorderThickness="1" CornerRadius="12" Padding="10,4">
                    <TextBlock Name="XpText" Text="LEVEL 1 | 0 XP" Foreground="%%ACC_PRI%%" FontSize="13" FontWeight="Bold"/>
                </Border>
            </Grid>

            <TextBlock Name="StepDesc" Grid.Row="1" Foreground="White" FontSize="15" TextWrapping="Wrap" Margin="0,0,0,20" LineHeight="22"/>

            <Grid Grid.Row="2" Margin="0,0,0,5">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="Underlying PowerShell Logic:" Foreground="%%ACC_PRI%%" FontSize="13" FontWeight="Bold" VerticalAlignment="Bottom"/>
                <Button Name="BtnCopy" Grid.Column="1" Content="Copy Code" Width="90" Height="24" Style="{StaticResource GlassBtn}" FontSize="11"/>
            </Grid>

            <Border Grid.Row="3" Background="%%BG_CON%%" BorderBrush="#444" BorderThickness="1" CornerRadius="4" Margin="0,0,0,20">
                <RichTextBox Name="CodeBox" Background="Transparent" BorderThickness="0" Foreground="White" FontFamily="Consolas" FontSize="14" IsReadOnly="True" Padding="10">
                    <FlowDocument Name="CodeDoc" PagePadding="0"/>
                </RichTextBox>
            </Border>

            <StackPanel Grid.Row="4" Name="ParamPanel" Margin="0,0,0,20" Visibility="Collapsed">
                <TextBlock Text="Parameter Breakdown:" Foreground="%%ACC_PRI%%" FontSize="13" FontWeight="Bold" Margin="0,0,0,5"/>
                <ListView Name="ParamList" Background="%%BG_SEC%%" Foreground="White" BorderBrush="#444" FontSize="13">
                    <ListView.View>
                        <GridView>
                            <GridViewColumn Header="Parameter" DisplayMemberBinding="{Binding Parameter}" Width="150"/>
                            <GridViewColumn Header="Passed Value" DisplayMemberBinding="{Binding Value}" Width="200"/>
                            <GridViewColumn Header="Context" DisplayMemberBinding="{Binding Context}" Width="300"/>
                        </GridView>
                    </ListView.View>
                </ListView>
            </StackPanel>

            <Border Grid.Row="5" Name="FailureBorder" Background="#2A1111" BorderBrush="#FF4444" BorderThickness="1" CornerRadius="4" Padding="10" Margin="0,0,0,20" Visibility="Collapsed">
                <StackPanel>
                    <TextBlock Text="[!] Common Failure Points:" Foreground="#FF4444" FontSize="13" FontWeight="Bold" Margin="0,0,0,5"/>
                    <TextBlock Name="FailureText" Foreground="#FF9999" FontSize="13" TextWrapping="Wrap"/>
                </StackPanel>
            </Border>

            <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
                <Button Name="BtnAbort" Content="Abort Tool" Width="110" Height="35" Background="#FF4444" Foreground="White" BorderThickness="0" Margin="0,0,10,0" Cursor="Hand" FontWeight="Bold">
                    <Button.Resources>
                        <Style TargetType="Border"><Setter Property="CornerRadius" Value="4"/></Style>
                    </Button.Resources>
                </Button>
                <Button Name="BtnExecute" Content="Acknowledge &amp; Execute" Width="180" Height="35" Background="#28A745" Foreground="White" BorderThickness="0" Cursor="Hand" FontWeight="Bold">
                    <Button.Resources>
                        <Style TargetType="Border"><Setter Property="CornerRadius" Value="4"/></Style>
                    </Button.Resources>
                </Button>
            </StackPanel>
        </Grid>
    </Window>
"@

    # Inject active colors into the training pop-up
    $TrainXAML = $TrainXAML -replace '%%BG_MAIN%%', $ActiveColors.BG_Main
    $TrainXAML = $TrainXAML -replace '%%BG_SEC%%', $ActiveColors.BG_Sec
    $TrainXAML = $TrainXAML -replace '%%BG_CON%%', $ActiveColors.BG_Con
    $TrainXAML = $TrainXAML -replace '%%BG_BTN%%', $ActiveColors.BG_Btn
    $TrainXAML = $TrainXAML -replace '%%ACC_PRI%%', $ActiveColors.Acc_Pri
    $TrainXAML = $TrainXAML -replace '%%ACC_SEC%%', $ActiveColors.Acc_Sec

    $Reader = (New-Object System.Xml.XmlNodeReader $TrainXAML)
    $StepWin = [Windows.Markup.XamlReader]::Load($Reader)

    # Map UI Elements
    $StepDesc    = $StepWin.FindName("StepDesc")
    $CodeDoc     = $StepWin.FindName("CodeDoc")
    $BtnCopy     = $StepWin.FindName("BtnCopy")
    $ParamPanel  = $StepWin.FindName("ParamPanel")
    $ParamList   = $StepWin.FindName("ParamList")
    $FailureBrd  = $StepWin.FindName("FailureBorder")
    $FailureTxt  = $StepWin.FindName("FailureText")
    $XpText      = $StepWin.FindName("XpText")
    $BtnAbort    = $StepWin.FindName("BtnAbort")
    $BtnExecute  = $StepWin.FindName("BtnExecute")

    $RawCode = $global:UHDCSync.StepCode
    $StepDesc.Text = $global:UHDCSync.StepDesc

    # ==========================================
    # 1. GAMIFICATION / XP TRACKING
    # ==========================================
    $currentXP = 0
    if ($UserPrefs.ContainsKey($env:USERNAME) -and $UserPrefs[$env:USERNAME].XP) {
        $currentXP = [int]$UserPrefs[$env:USERNAME].XP
    }

    $xpGain = 50
    $newXP = $currentXP + $xpGain
    $level = [math]::Floor($newXP / 500) + 1
    $XpText.Text = "LEVEL $level | $newXP XP (+$xpGain XP)"

    # Save XP back to UserPrefs (PS 5.1 Safe Serialization)
    if (-not $UserPrefs.ContainsKey($env:USERNAME)) { $UserPrefs[$env:USERNAME] = @{} }
    $UserPrefs[$env:USERNAME].XP = $newXP
    try {
        $exportObj = New-Object PSObject
        foreach ($key in $UserPrefs.Keys) { 
            $exportObj | Add-Member -MemberType NoteProperty -Name $key -Value $UserPrefs[$key] -Force
        }
        $exportObj | ConvertTo-Json -Depth 3 | Set-Content $UsersFile -Force
    } catch {}

    # ==========================================
    # 2. SYNTAX HIGHLIGHTING ENGINE
    # ==========================================
    $Paragraph = New-Object System.Windows.Documents.Paragraph

    # Tokenize the code string (Strings, Variables, Parameters, Cmdlets, Others)
    $Tokens = [regex]::Matches($RawCode, "(`".*?`"|'.*?'|\\\$[a-zA-Z0-9_:]+|-[a-zA-Z0-9_]+|[a-zA-Z]+-[a-zA-Z]+|[^\s]+|\s+)")

    foreach ($Token in $Tokens) {
        $Run = New-Object System.Windows.Documents.Run($Token.Value)

        if ($Token.Value -match "^`".*`"$|^'.*'$") { 
            $Run.Foreground = "#E6DB74" # Strings (Yellow)
        } elseif ($Token.Value -match "^\\\$") { 
            $Run.Foreground = "#FFB86C" # Variables (Orange)
        } elseif ($Token.Value -match "^-[a-zA-Z]") { 
            $Run.Foreground = "#A6E22E" # Parameters (Green)
        } elseif ($Token.Value -match "^[A-Z][a-z]+-[A-Z][a-z]+") { 
            $Run.Foreground = "#66D9EF" # Cmdlets (Blue)
        } elseif ($Token.Value -match "^{|}|\[|\]|\(|\)$") {
            $Run.Foreground = "#F92672" # Brackets/Braces (Pink)
        } else { 
            $Run.Foreground = "#F8F8F2" # Default (White)
        }

        $Paragraph.Inlines.Add($Run)
    }
    $CodeDoc.Blocks.Add($Paragraph)

    # ==========================================
    # 3. COPY CODE FUNCTIONALITY
    # ==========================================
    $BtnCopy.Add_Click({
        [System.Windows.Clipboard]::SetText($RawCode)
        $BtnCopy.Content = "Copied!"
        $BtnCopy.Foreground = "#00FF00"

        # Reset button text after 2 seconds without freezing UI
        $resetTimer = New-Object System.Windows.Threading.DispatcherTimer
        $resetTimer.Interval = [TimeSpan]::FromSeconds(2)
        $resetTimer.Add_Tick({
            $BtnCopy.Content = "Copy Code"
            $BtnCopy.Foreground = $ActiveColors.Acc_Pri
            $resetTimer.Stop()
        })
        $resetTimer.Start()
    })

    # ==========================================
    # 4. AUTO-GENERATE PARAMETER BREAKDOWN
    # ==========================================
    # Regex to find "-Parameter Value" pairs in the code
    $paramRegex = "(?<param>-[a-zA-Z0-9]+)\s+(?<val>'[^']*'|`"[^`"]*`"|\$?[a-zA-Z0-9_:\\]+)"
    $paramMatches = [regex]::Matches($RawCode, $paramRegex)

    if ($paramMatches.Count -gt 0) {
        $ParamPanel.Visibility = "Visible"
        foreach ($m in $paramMatches) {
            $pName = $m.Groups['param'].Value
            $pVal  = $m.Groups['val'].Value

            # Contextual hints based on common parameters
            $pContext = "Standard argument passed to cmdlet."
            if ($pName -match "-ComputerName") { $pContext = "Directs the command over the network to the target PC." }
            if ($pName -match "-Force") { $pContext = "Bypasses standard confirmation prompts/locks." }
            if ($pName -match "-Recurse") { $pContext = "Applies action to all items inside sub-folders." }
            if ($pName -match "-ScriptBlock") { $pContext = "The payload of code executed on the remote machine." }
            if ($pName -match "-Filter") { $pContext = "Narrows down the search results from the API/AD." }

            $ParamList.Items.Add([PSCustomObject]@{
                Parameter = $pName
                Value = $pVal
                Context = $pContext
            }) | Out-Null
        }
    }

    # ==========================================
    # 5. CONTEXT-AWARE FAILURE POINTS
    # ==========================================
    $failMsg = ""
    if ($RawCode -match "Invoke-Command") {
        $failMsg = "- WinRM (Port 5985) is blocked by the target's Windows Firewall.`n- The target PC is turned off or off the VPN.`n- Your admin account lacks local admin rights on the target."
    } elseif ($RawCode -match "psexec") {
        $failMsg = "- SMB (Port 445) or RPC (Port 135) is blocked by the firewall.`n- The ADMIN$ share is disabled on the target.`n- PsExec.exe is missing from your \Core folder."
    } elseif ($RawCode -match "Get-CimInstance") {
        $failMsg = "- The WMI Repository on the target PC is corrupted.`n- WinRM (Port 5985) is blocked."
    } elseif ($RawCode -match "MgGraph|MgUser|MgDevice") {
        $failMsg = "- Your Entra ID session expired (Requires re-authentication).`n- You lack the required Intune RBAC roles (Delegated Permissions).`n- The target device is not enrolled in MDM."
    } elseif ($RawCode -match "Get-ADUser|Get-ADComputer") {
        $failMsg = "- Cannot reach the Domain Controller (Port 389/636).`n- The ActiveDirectory PowerShell module is not installed locally."
    }

    if ($failMsg) {
        $FailureBrd.Visibility = "Visible"
        $FailureTxt.Text = $failMsg
    }

    # ==========================================
    # 6. BUTTON EVENT HANDLERS
    # ==========================================
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
        param($Path, $Tgt, $ReqTgt, $Dispatcher, $OutBox, $PC1, $PC2, $SecTgt, $SharedRoot, $SyncHash, $IsTraining, $ThemeB64)
                try {
            $hashToPass = if ($IsTraining) { $SyncHash } else { $null }

            # Dynamically build parameters to prevent ParameterBinding crashes on older scripts
            $Splat = @{
                SharedRoot = $SharedRoot
                SyncHash   = $hashToPass
            }

            $ScriptCmd = Get-Command $Path -ErrorAction SilentlyContinue
            if ($ScriptCmd -and $ScriptCmd.Parameters.ContainsKey('ThemeB64')) {
                $Splat['ThemeB64'] = $ThemeB64
            }

            if ($ReqTgt -and $SecTgt) {
                $Result = & $Path $Tgt $SecTgt @Splat *>&1 | Out-String
            } elseif ($ReqTgt) {
                $Result = & $Path $Tgt @Splat *>&1 | Out-String
            } else {
                $Result = & $Path @Splat *>&1 | Out-String
            }

            $Dispatcher.Invoke([Action]{
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

    # Pass arguments cleanly to the runspace in the EXACT order of the param() block
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
    [void]$PS.AddArgument($ThemeB64) 

    $PS.RunspacePool = $RunspacePool
    [void]$PS.BeginInvoke()
}

# ------------------------------------------------------------------
# 5. THEME PICKER GUI
# ------------------------------------------------------------------
function Show-ThemePicker {
    [xml]$ThemeXAML = @"
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            Title="UHDC Theme Settings" Height="480" Width="450" Background="%%BG_MAIN%%" WindowStartupLocation="CenterScreen" ResizeMode="NoResize" Topmost="True">
        <StackPanel Margin="20">
            <TextBlock Text="UHDC Theme Manager" Foreground="%%ACC_PRI%%" FontSize="22" FontWeight="Bold" Margin="0,0,0,5"/>
            <TextBlock Text="Select a color profile or define your own." Foreground="#AAAAAA" FontSize="12" Margin="0,0,0,20"/>

            <TextBlock Text="Select Theme Profile:" Foreground="White" FontWeight="Bold" Margin="0,0,0,5"/>
            <ComboBox Name="ThemeCombo" Height="30" FontSize="14" Margin="0,0,0,20" Background="#333" Foreground="Black"/>

            <Grid Margin="0,0,0,20">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,0,10,10">
                    <TextBlock Text="Background Main:" Foreground="#CCC" FontSize="11"/>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox Name="TxtBgMain" Grid.Column="0" Height="24" Background="#222" Foreground="White" BorderBrush="#555" VerticalContentAlignment="Center"/>
                        <Button Name="BtnPickBgMain" Grid.Column="1" Content="..." Width="28" Height="24" Margin="5,0,0,0" Background="#333" BorderBrush="#555" Cursor="Hand" ToolTip="Pick Color"/>
                    </Grid>
                </StackPanel>
                <StackPanel Grid.Row="0" Grid.Column="1" Margin="0,0,0,10">
                    <TextBlock Text="Background Secondary:" Foreground="#CCC" FontSize="11"/>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox Name="TxtBgSec" Grid.Column="0" Height="24" Background="#222" Foreground="White" BorderBrush="#555" VerticalContentAlignment="Center"/>
                        <Button Name="BtnPickBgSec" Grid.Column="1" Content="..." Width="28" Height="24" Margin="5,0,0,0" Background="#333" BorderBrush="#555" Cursor="Hand" ToolTip="Pick Color"/>
                    </Grid>
                </StackPanel>
                <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,0,10,10">
                    <TextBlock Text="Console Background:" Foreground="#CCC" FontSize="11"/>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox Name="TxtBgCon" Grid.Column="0" Height="24" Background="#222" Foreground="White" BorderBrush="#555" VerticalContentAlignment="Center"/>
                        <Button Name="BtnPickBgCon" Grid.Column="1" Content="..." Width="28" Height="24" Margin="5,0,0,0" Background="#333" BorderBrush="#555" Cursor="Hand" ToolTip="Pick Color"/>
                    </Grid>
                </StackPanel>
                <StackPanel Grid.Row="1" Grid.Column="1" Margin="0,0,0,10">
                    <TextBlock Text="Button Background:" Foreground="#CCC" FontSize="11"/>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox Name="TxtBgBtn" Grid.Column="0" Height="24" Background="#222" Foreground="White" BorderBrush="#555" VerticalContentAlignment="Center"/>
                        <Button Name="BtnPickBgBtn" Grid.Column="1" Content="..." Width="28" Height="24" Margin="5,0,0,0" Background="#333" BorderBrush="#555" Cursor="Hand" ToolTip="Pick Color"/>
                    </Grid>
                </StackPanel>
                <StackPanel Grid.Row="2" Grid.Column="0" Margin="0,0,10,0">
                    <TextBlock Text="Primary Accent:" Foreground="#CCC" FontSize="11"/>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox Name="TxtAccPri" Grid.Column="0" Height="24" Background="#222" Foreground="White" BorderBrush="#555" VerticalContentAlignment="Center"/>
                        <Button Name="BtnPickAccPri" Grid.Column="1" Content="..." Width="28" Height="24" Margin="5,0,0,0" Background="#333" BorderBrush="#555" Cursor="Hand" ToolTip="Pick Color"/>
                    </Grid>
                </StackPanel>
                <StackPanel Grid.Row="2" Grid.Column="1" Margin="0,0,0,0">
                    <TextBlock Text="Secondary Accent:" Foreground="#CCC" FontSize="11"/>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox Name="TxtAccSec" Grid.Column="0" Height="24" Background="#222" Foreground="White" BorderBrush="#555" VerticalContentAlignment="Center"/>
                        <Button Name="BtnPickAccSec" Grid.Column="1" Content="..." Width="28" Height="24" Margin="5,0,0,0" Background="#333" BorderBrush="#555" Cursor="Hand" ToolTip="Pick Color"/>
                    </Grid>
                </StackPanel>
            </Grid>

            <Button Name="BtnSaveTheme" Content="Save &amp; Apply Theme" Height="40" Background="#28A745" Foreground="White" FontWeight="Bold" FontSize="14" Cursor="Hand" BorderThickness="0"/>
            <TextBlock Name="ThemeStatus" Text="" Foreground="#00FF00" Margin="0,15,0,0" TextAlignment="Center" FontWeight="Bold"/>
        </StackPanel>
    </Window>
"@
    # Inject current theme colors into the picker window itself
    $ThemeXAML = $ThemeXAML -replace '%%BG_MAIN%%', $ActiveColors.BG_Main
    $ThemeXAML = $ThemeXAML -replace '%%ACC_PRI%%', $ActiveColors.Acc_Pri

    $Reader = (New-Object System.Xml.XmlNodeReader $ThemeXAML)
    $ThemeWin = [Windows.Markup.XamlReader]::Load($Reader)

    $ThemeCombo = $ThemeWin.FindName("ThemeCombo")
    $TxtBgMain  = $ThemeWin.FindName("TxtBgMain"); $BtnPickBgMain = $ThemeWin.FindName("BtnPickBgMain")
    $TxtBgSec   = $ThemeWin.FindName("TxtBgSec");  $BtnPickBgSec  = $ThemeWin.FindName("BtnPickBgSec")
    $TxtBgCon   = $ThemeWin.FindName("TxtBgCon");  $BtnPickBgCon  = $ThemeWin.FindName("BtnPickBgCon")
    $TxtBgBtn   = $ThemeWin.FindName("TxtBgBtn");  $BtnPickBgBtn  = $ThemeWin.FindName("BtnPickBgBtn")
    $TxtAccPri  = $ThemeWin.FindName("TxtAccPri"); $BtnPickAccPri = $ThemeWin.FindName("BtnPickAccPri")
    $TxtAccSec  = $ThemeWin.FindName("TxtAccSec"); $BtnPickAccSec = $ThemeWin.FindName("BtnPickAccSec")

    $BtnSave    = $ThemeWin.FindName("BtnSaveTheme")
    $ThemeStatus= $ThemeWin.FindName("ThemeStatus")

    foreach ($key in $Themes.Keys) { $ThemeCombo.Items.Add($key) | Out-Null }
    $ThemeCombo.Items.Add("Custom") | Out-Null

    # Fallback if the user's saved theme name was renamed/deleted
    if ($ThemeCombo.Items.Contains($ActiveThemeName)) {
        $ThemeCombo.SelectedItem = $ActiveThemeName
    } else {
        $ThemeCombo.SelectedItem = "PNW (Default)"
    }

    # Enable/Disable inputs based on selection
    $ThemeCombo.Add_SelectionChanged({
        $sel = $ThemeCombo.SelectedItem
        $isCustom = ($sel -eq "Custom")

        $TxtBgMain.IsReadOnly = -not $isCustom; $BtnPickBgMain.IsEnabled = $isCustom
        $TxtBgSec.IsReadOnly  = -not $isCustom; $BtnPickBgSec.IsEnabled  = $isCustom
        $TxtBgCon.IsReadOnly  = -not $isCustom; $BtnPickBgCon.IsEnabled  = $isCustom
        $TxtBgBtn.IsReadOnly  = -not $isCustom; $BtnPickBgBtn.IsEnabled  = $isCustom
        $TxtAccPri.IsReadOnly = -not $isCustom; $BtnPickAccPri.IsEnabled = $isCustom
        $TxtAccSec.IsReadOnly = -not $isCustom; $BtnPickAccSec.IsEnabled = $isCustom

        if (-not $isCustom) {
            $c = $Themes[$sel]
            $TxtBgMain.Text = $c.BG_Main; $TxtBgSec.Text = $c.BG_Sec; $TxtBgCon.Text = $c.BG_Con
            $TxtBgBtn.Text = $c.BG_Btn;   $TxtAccPri.Text = $c.Acc_Pri; $TxtAccSec.Text = $c.Acc_Sec
        }
    })

    # Trigger the selection change manually to populate the boxes on load
    $ThemeCombo.RaiseEvent((New-Object System.Windows.Controls.SelectionChangedEventArgs([System.Windows.Controls.Primitives.Selector]::SelectionChangedEvent, @(), @($ThemeCombo.SelectedItem))))

    # --- COLOR PICKER HELPER FUNCTION ---
    function Get-ColorFromGrid ($InitialHex) {
        $colorDialog = New-Object System.Windows.Forms.ColorDialog
        $colorDialog.FullOpen = $true # Opens the advanced grid automatically

        try {
            if ($InitialHex -match "^#[0-9A-Fa-f]{6}$") {
                $colorDialog.Color = [System.Drawing.ColorTranslator]::FromHtml($InitialHex)
            }
        } catch {}

        if ($colorDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            # Convert the selected color back to a HEX string
            return "#{0:X2}{1:X2}{2:X2}" -f $colorDialog.Color.R, $colorDialog.Color.G, $colorDialog.Color.B
        }
        return $null
    }

    # --- WIRE UP THE PICKER BUTTONS ---
    $BtnPickBgMain.Add_Click({ $new = Get-ColorFromGrid $TxtBgMain.Text; if ($new) { $TxtBgMain.Text = $new } })
    $BtnPickBgSec.Add_Click({  $new = Get-ColorFromGrid $TxtBgSec.Text;  if ($new) { $TxtBgSec.Text = $new } })
    $BtnPickBgCon.Add_Click({  $new = Get-ColorFromGrid $TxtBgCon.Text;  if ($new) { $TxtBgCon.Text = $new } })
    $BtnPickBgBtn.Add_Click({  $new = Get-ColorFromGrid $TxtBgBtn.Text;  if ($new) { $TxtBgBtn.Text = $new } })
    $BtnPickAccPri.Add_Click({ $new = Get-ColorFromGrid $TxtAccPri.Text; if ($new) { $TxtAccPri.Text = $new } })
    $BtnPickAccSec.Add_Click({ $new = Get-ColorFromGrid $TxtAccSec.Text; if ($new) { $TxtAccSec.Text = $new } })

    # --- SAVE LOGIC ---
    $BtnSave.Add_Click({
        $sel = $ThemeCombo.SelectedItem
        $newPrefs = @{ ThemeName = $sel; CustomColors = $null }

        if ($sel -eq "Custom") {
            # Basic Hex Validation
            $hexRegex = "^#[0-9A-Fa-f]{6}$"
            if ($TxtBgMain.Text -notmatch $hexRegex -or $TxtAccPri.Text -notmatch $hexRegex) {
                $ThemeStatus.Text = "Error: Invalid Hex Code format (e.g. #1E1E1E)"
                $ThemeStatus.Foreground = "Red"
                return
            }
            $newPrefs.CustomColors = @{
                BG_Main = $TxtBgMain.Text; BG_Sec = $TxtBgSec.Text; BG_Con = $TxtBgCon.Text
                BG_Btn = $TxtBgBtn.Text; Acc_Pri = $TxtAccPri.Text; Acc_Sec = $TxtAccSec.Text
            }
        }

        $UserPrefs[$env:USERNAME] = $newPrefs

        # Save to JSON (PS 5.1 Safe Serialization)
        try {
            $exportObj = New-Object PSObject
            foreach ($key in $UserPrefs.Keys) {
                $exportObj | Add-Member -MemberType NoteProperty -Name $key -Value $UserPrefs[$key] -Force
            }
            $exportObj | ConvertTo-Json -Depth 3 | Set-Content $UsersFile -Force

            $ThemeStatus.Text = "Saved! Please restart UHDC to apply changes."
            $ThemeStatus.Foreground = "#00FF00"
        } catch {
            $ThemeStatus.Text = "Error saving to users.json"
            $ThemeStatus.Foreground = "Red"
        }
    })

    $ThemeWin.ShowDialog() | Out-Null
}

$BtnTheme.Add_Click({
    Show-ThemePicker
})

# ------------------------------------------------------------------
# 6. BUTTON LOGIC & EVENT MAPPING
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

    Start-Process PowerShell -ArgumentList "-WindowStyle Hidden -File `"$IntuneScript`" -TargetComputer `"$ComputerQuery`" -TargetUser `"$EmailToPass`" -SharedRoot `"$SharedRoot`" -ThemeB64 `"$ThemeB64`""
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
# 7. AUTOMATED LIVE ENGINES (Presence & Ticker)
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
            $display = if ($online.Count -gt 0) { ($online | Sort-Object) -join "  -  " } else { "No active technicians." }
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