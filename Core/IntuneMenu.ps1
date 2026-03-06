# IntuneMenu.ps1 - Place this script in the \Core folder
# DESCRIPTION: A dedicated helper script for Microsoft Intune management.
# It takes the target user's email address or the computer's hostname and
# constructs the direct URL to open the Microsoft Endpoint Manager portal.
# Features strict Cross-Agency Domain Filtering to prevent unauthorized access.
# Optimized for PowerShell 5.1 (TLS 1.2 Enforcement & Base64 Theme Decoding).

param(
    [Parameter(Mandatory=$false)]
    [string]$TargetComputer,

    [Parameter(Mandatory=$false)]
    [string]$TargetUser,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [hashtable]$SyncHash,

    [Parameter(Mandatory=$false)]
    [string]$ThemeB64
)

# --- TRAINING MODE HELPER (WPF Safe) ---
function Wait-TrainingStep {
    param([string]$Desc, [string]$Code)
    if ($null -ne $SyncHash) {
        $SyncHash.StepDesc = $Desc
        $SyncHash.StepCode = $Code
        $SyncHash.StepReady = $true
        $SyncHash.StepAck = $false

        while (-not $SyncHash.StepAck) {
            Start-Sleep -Milliseconds 200
            $Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
            if ($Dispatcher) {
                $Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
            }
        }

        if (-not $SyncHash.StepResult) {
            throw "Execution aborted by user during Training Mode."
        }
    }
}
# ----------------------------

# ------------------------------------------------------------------
# BULLETPROOF CONFIG LOADER & DOMAIN FILTERING
# ------------------------------------------------------------------
$OrgName = "IT"
try {
    $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
    $RootFolder = Split-Path -Path $ScriptDir
    $ConfigFile = Join-Path -Path $RootFolder -ChildPath "config.json"

    if (Test-Path $ConfigFile) {
        $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        $OrgName = $Config.OrganizationName
        if ([string]::IsNullOrWhiteSpace($SharedRoot)) { $SharedRoot = $Config.SharedNetworkRoot }
    }
} catch { }

$TechUPN = whoami /upn 2>$null
if (-not $TechUPN) {
    try { $TechUPN = (Get-ADUser $env:USERNAME -Properties UserPrincipalName).UserPrincipalName } catch {}
}
$TechDomain = if ($TechUPN -match "@(.*)$") { $matches[1] } else { "" }

# ------------------------------------------------------------------
# THEME ENGINE INTEGRATION
# ------------------------------------------------------------------
$ActiveColors = @{
    BG_Main = "#1E1E1E"; BG_Sec  = "#111111"; BG_Con  = "#0C0C0C"
    BG_Btn  = "#2D2D30"; Acc_Pri = "#00A2ED"; Acc_Sec = "#00FF00"
}

if (-not [string]::IsNullOrWhiteSpace($ThemeB64)) {
    try {
        $ThemeBytes = [Convert]::FromBase64String($ThemeB64)
        $ThemeJson = [System.Text.Encoding]::UTF8.GetString($ThemeBytes)
        $parsed = $ThemeJson | ConvertFrom-Json

        $ActiveColors.BG_Main = $parsed.BG_Main
        $ActiveColors.BG_Sec  = $parsed.BG_Sec
        $ActiveColors.BG_Con  = $parsed.BG_Con
        $ActiveColors.BG_Btn  = $parsed.BG_Btn
        $ActiveColors.Acc_Pri = $parsed.Acc_Pri
        $ActiveColors.Acc_Sec = $parsed.Acc_Sec
    } catch {}
}

# ------------------------------------------------------------------
# GRAPH API AUTHENTICATION
# ------------------------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scopes = @(
    "User.Read.All",
    "DeviceManagementManagedDevices.ReadWrite.All",
    "DeviceManagementManagedDevices.PrivilegedOperations.All",
    "BitlockerKey.Read.All",
    "DeviceLocalCredential.Read.All",
    "UserAuthenticationMethod.ReadWrite.All"
)

if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    try { Connect-MgGraph -Scopes $scopes -ErrorAction Stop }
    catch {
        [System.Windows.MessageBox]::Show("Failed to authenticate to Microsoft Graph API. Ensure the Microsoft.Graph module is installed and you have internet access.", "UHDC Error", "OK", "Error")
        return
    }
}

Add-Type -AssemblyName PresentationFramework

# ------------------------------------------------------------------
# UI DEFINITION (DYNAMIC XAML)
# ------------------------------------------------------------------
[string]$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="UHDC: $OrgName Device Manager" Height="580" Width="720" Background="%%BG_MAIN%%" WindowStartupLocation="CenterScreen">

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

    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Name="HeaderTitle" Text="UHDC Intune: Scanning Azure..." FontSize="18" Foreground="%%ACC_PRI%%" FontWeight="Bold" Margin="0,0,0,15" TextWrapping="Wrap"/>

        <WrapPanel Grid.Row="1" Name="ActionPanel" Orientation="Horizontal" Visibility="Collapsed" Margin="0,0,0,15">
            <Button Name="BtnBitLocker" Content="Get BitLocker Key" Width="130" Height="30" Margin="5" Style="{StaticResource ActionBtn}" Visibility="Collapsed"/>
            <Button Name="BtnLAPS" Content="Get LAPS Pass" Width="130" Height="30" Margin="5" Style="{StaticResource WarningBtn}" Visibility="Collapsed"/>
            <Button Name="BtnUnlock" Content="Remove Passcode" Width="130" Height="30" Margin="5" Style="{StaticResource WarningBtn}" Visibility="Collapsed"/>
            <Button Name="BtnWipe" Content="Remote Wipe" Width="130" Height="30" Margin="5" Style="{StaticResource DangerBtn}" Visibility="Collapsed"/>
            <Button Name="BtnSync" Content="Force Sync" Width="130" Height="30" Margin="5" Style="{StaticResource StdBtn}" Visibility="Collapsed"/>
            <Button Name="BtnReboot" Content="Reboot Device" Width="130" Height="30" Margin="5" Style="{StaticResource DangerBtn}" Visibility="Collapsed"/>
        </WrapPanel>

        <ListBox Grid.Row="2" Name="DeviceList" Background="%%BG_SEC%%" Foreground="%%ACC_PRI%%" FontSize="14" BorderBrush="#555555" BorderThickness="1" Margin="0,0,0,10" SelectionMode="Single"/>

        <TextBlock Grid.Row="3" Name="OutputText" Text="Select a device to see available actions." Foreground="%%ACC_SEC%%" TextWrapping="Wrap" Margin="0,10,0,10"/>

        <GroupBox Grid.Row="4" Header="User Authentication Methods (MFA)" Foreground="#AAAAAA" BorderBrush="#333333" Padding="0">
            <Border BorderThickness="4,0,0,0" BorderBrush="%%ACC_PRI%%" Background="%%BG_SEC%%" Padding="10">
                <StackPanel Orientation="Horizontal" Margin="5">
                    <Button Name="BtnMFA" Content="View MFA" Width="90" Height="30" Style="{StaticResource MasterBtn}" Margin="0,0,10,0"/>
                    <Button Name="BtnClearMFA" Content="Clear MFA" Width="90" Height="30" Style="{StaticResource DangerBtn}" Margin="0,0,10,0"/>
                    <TextBlock Text="Add Cell (+1 format):" Foreground="White" VerticalAlignment="Center" Margin="0,0,5,0"/>
                    <TextBox Name="InputPhone" Width="120" Height="25" Background="%%BG_MAIN%%" Foreground="%%ACC_PRI%%" BorderBrush="#555555" Padding="2" Margin="0,0,5,0"/>
                    <Button Name="BtnAddPhone" Content="Add SMS" Width="80" Height="30" Style="{StaticResource ActionBtn}"/>
                </StackPanel>
            </Border>
        </GroupBox>
    </Grid>
</Window>
"@

$XAML = $XAML -replace '%%BG_MAIN%%', $ActiveColors.BG_Main
$XAML = $XAML -replace '%%BG_SEC%%',  $ActiveColors.BG_Sec
$XAML = $XAML -replace '%%BG_CON%%',  $ActiveColors.BG_Con
$XAML = $XAML -replace '%%BG_BTN%%',  $ActiveColors.BG_Btn
$XAML = $XAML -replace '%%ACC_PRI%%', $ActiveColors.Acc_Pri
$XAML = $XAML -replace '%%ACC_SEC%%', $ActiveColors.Acc_Sec

$StringReader = New-Object System.IO.StringReader $XAML
$XmlReader = [System.Xml.XmlReader]::Create($StringReader)
$Form = [Windows.Markup.XamlReader]::Load($XmlReader)

$HeaderTitle = $Form.FindName("HeaderTitle")
$DeviceList  = $Form.FindName("DeviceList")
$ActionPanel = $Form.FindName("ActionPanel")
$OutputText  = $Form.FindName("OutputText")

$BtnBitLocker = $Form.FindName("BtnBitLocker")
$BtnLAPS      = $Form.FindName("BtnLAPS")
$BtnUnlock    = $Form.FindName("BtnUnlock")
$BtnWipe      = $Form.FindName("BtnWipe")
$BtnSync      = $Form.FindName("BtnSync")
$BtnReboot    = $Form.FindName("BtnReboot")
$BtnMFA       = $Form.FindName("BtnMFA")
$BtnClearMFA  = $Form.FindName("BtnClearMFA")
$InputPhone   = $Form.FindName("InputPhone")
$BtnAddPhone  = $Form.FindName("BtnAddPhone")

$ResolvedUser = $null
$GlobalDevices = @()

# ------------------------------------------------------------------
# INITIALIZATION
# ------------------------------------------------------------------
$Form.Add_Loaded({
    if ([string]::IsNullOrWhiteSpace($TargetUser) -and [string]::IsNullOrWhiteSpace($TargetComputer)) {
        $HeaderTitle.Text = "Error: No User or Computer provided from GUI."
        return
    }

    $HeaderString = "UHDC Search:"
    $RawDeviceList = @()

    try {
        if (-not [string]::IsNullOrWhiteSpace($TargetComputer)) {
            $HeaderTitle.Text = "Scanning Intune for device: $TargetComputer..."
            [System.Windows.Forms.Application]::DoEvents()

            $deviceMatch = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$TargetComputer'" -ErrorAction SilentlyContinue
            if ($deviceMatch) {
                if ($TechDomain -and $deviceMatch.UserPrincipalName -and $deviceMatch.UserPrincipalName -notmatch $TechDomain) {
                    [System.Windows.MessageBox]::Show("Access Denied: The requested device ($TargetComputer) belongs to a different agency/domain ($($deviceMatch.UserPrincipalName)).", "Cross-Agency Block", "OK", "Error")
                } else {
                    $RawDeviceList += $deviceMatch
                    $HeaderString += " [Device Found]"
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($TargetUser)) {
            $HeaderTitle.Text = "Scanning Azure AD for user: $TargetUser..."
            [System.Windows.Forms.Application]::DoEvents()

            $users = Get-MgUser -Filter "userPrincipalName eq '$TargetUser' or mail eq '$TargetUser' or mailNickname eq '$TargetUser' or displayName eq '$TargetUser' or startsWith(userPrincipalName,'$TargetUser')" -All -ErrorAction SilentlyContinue

            if ($users -and $users.Count -gt 0) {
                $ResolvedUser = $users[0]

                if ($TechDomain -and $ResolvedUser.UserPrincipalName -notmatch $TechDomain) {
                    [System.Windows.MessageBox]::Show("Access Denied: The requested user ($($ResolvedUser.UserPrincipalName)) belongs to a different agency/domain.", "Cross-Agency Block", "OK", "Error")
                    $ResolvedUser = $null
                } else {
                    $HeaderString += " [$($ResolvedUser.DisplayName)]"
                    $userDevices = Get-MgDeviceManagementManagedDevice -Filter "userId eq '$($ResolvedUser.Id)'" -ErrorAction SilentlyContinue
                    if ($userDevices) { $RawDeviceList += $userDevices }
                }
            } else {
                $HeaderString += " [User Not Found]"
            }
        }

        $HeaderTitle.Text = $HeaderString

        if ($RawDeviceList.Count -gt 0) {
            $GlobalDevices = $RawDeviceList | Select-Object -Unique -Property Id | Sort-Object deviceName

            foreach ($dev in $GlobalDevices) {
                $status = if ($dev.ComplianceState -eq "compliant") { "[OK]" } else { "[X]" }
                $DeviceList.Items.Add("$status [$($dev.OperatingSystem)] $($dev.DeviceName) - $($dev.SerialNumber)") | Out-Null
            }
        } else {
            $DeviceList.Items.Add("No managed devices found for this User or PC.") | Out-Null
            $DeviceList.IsEnabled = $false
        }
    } catch {
        $HeaderTitle.Text = "API Communication Error."
    }
})

$DeviceList.Add_SelectionChanged({
    if ($DeviceList.SelectedIndex -ge 0 -and $GlobalDevices) {
        $ActionPanel.Visibility = "Visible"
        $OutputText.Text = "Ready..."
        $selectedDev = $GlobalDevices[$DeviceList.SelectedIndex]

        $BtnBitLocker.Visibility = "Collapsed"
        $BtnLAPS.Visibility      = "Collapsed"
        $BtnUnlock.Visibility    = "Collapsed"
        $BtnWipe.Visibility      = "Collapsed"
        $BtnSync.Visibility      = "Collapsed"
        $BtnReboot.Visibility    = "Collapsed"

        if ($selectedDev) {
            $BtnSync.Visibility = "Visible"
            $BtnWipe.Visibility = "Visible"

            if ($selectedDev.OperatingSystem -match "Windows") {
                $BtnBitLocker.Visibility = "Visible"
                $BtnLAPS.Visibility      = "Visible"
                $BtnReboot.Visibility    = "Visible"
            }

            if ($selectedDev.OperatingSystem -match "iOS|Android|iPadOS") {
                $BtnUnlock.Visibility = "Visible"
            }
        }
    }
})

$BtnBitLocker.Add_Click({
    $dev = $GlobalDevices[$DeviceList.SelectedIndex]
    Wait-TrainingStep -Desc "STEP 2: RETRIEVE BITLOCKER KEY" -Code "Get-MgInformationProtectionBitlockerRecoveryKey -Filter `"deviceId eq '`$(`$dev.AzureAdDeviceId)'`""
    $OutputText.Text = "UHDC: Querying Entra ID for keys..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $keys = Get-MgInformationProtectionBitlockerRecoveryKey -Filter "deviceId eq '$($dev.AzureAdDeviceId)'" -Property "key"
        if ($keys) { $OutputText.Text = "RECOVERY KEY: $($keys[0].Key)" }
        else { $OutputText.Text = "No keys found for this device." }
    } catch { $OutputText.Text = "Insufficient permissions to read keys." }
})

$BtnLAPS.Add_Click({
    $dev = $GlobalDevices[$DeviceList.SelectedIndex]
    Wait-TrainingStep -Desc "STEP 3: RETRIEVE CLOUD LAPS" -Code "Invoke-MgGraphRequest -Method GET -Uri `"https://graph.microsoft.com/v1.0/deviceLocalCredentials?`$filter=deviceId eq '`$(`$dev.AzureAdDeviceId)'`""
    $OutputText.Text = "UHDC: Retrieving Cloud LAPS..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceLocalCredentials?`$filter=deviceId eq '$($dev.AzureAdDeviceId)'&`$select=credentials"
        $lapsData = Invoke-MgGraphRequest -Method GET -Uri $uri
        if ($lapsData.value) { $OutputText.Text = "CLOUD LAPS: $($lapsData.value.credentials.password)" }
        else { $OutputText.Text = "No Cloud LAPS data available." }
    } catch { $OutputText.Text = "LAPS retrieval failed." }
})

$BtnUnlock.Add_Click({
    $dev = $GlobalDevices[$DeviceList.SelectedIndex]
    Wait-TrainingStep -Desc "STEP 4: REMOVE MOBILE PASSCODE" -Code "Invoke-MgRemoveDeviceManagementManagedDevicePasscode -ManagedDeviceId `$dev.Id"
    if ([System.Windows.MessageBox]::Show("Remove Passcode from this mobile device?", "UHDC Confirm", "YesNo") -eq "Yes") {
        Invoke-MgRemoveDeviceManagementManagedDevicePasscode -ManagedDeviceId $dev.Id
        $OutputText.Text = "UHDC: Mobile unlock command dispatched."
    }
})

$BtnWipe.Add_Click({
    $dev = $GlobalDevices[$DeviceList.SelectedIndex]
    Wait-TrainingStep -Desc "STEP 5: REMOTE WIPE" -Code "Invoke-MgWipeDeviceManagementManagedDevice -ManagedDeviceId `$dev.Id"
    $msg = "WARNING: You are about to issue a REMOTE FACTORY RESET for $($dev.DeviceName).`n`nThis will permanently erase all data on the device. Are you absolutely sure?"
    if ([System.Windows.MessageBox]::Show($msg, "UHDC DANGER: WIPE DEVICE", "YesNo", "Warning") -eq "Yes") {
        $OutputText.Text = "UHDC: Sending Wipe command..."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            Invoke-MgWipeDeviceManagementManagedDevice -ManagedDeviceId $dev.Id -ErrorAction Stop
            $OutputText.Text = "[UHDC SUCCESS] Wipe command dispatched to $($dev.DeviceName)."
        } catch {
            $OutputText.Text = "Wipe failed: $($_.Exception.Message)"
        }
    }
})

$BtnMFA.Add_Click({
    if (-not $ResolvedUser) {
        $OutputText.Text = "MFA requires a successfully linked User Account."
        return
    }
    Wait-TrainingStep -Desc "STEP 6: VIEW MFA METHODS" -Code "Get-MgUserAuthenticationPhoneMethod -UserId `$ResolvedUser.Id"
    $OutputText.Text = "UHDC: Fetching registered MFA phones..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $methods = Get-MgUserAuthenticationPhoneMethod -UserId $ResolvedUser.Id
        if ($methods) {
            $msg = "Registered Methods:`n"
            foreach ($m in $methods) { $msg += "- $($m.PhoneType): $($m.PhoneNumber)`n" }
            $OutputText.Text = $msg
        } else { $OutputText.Text = "No MFA phone methods found." }
    } catch { $OutputText.Text = "Failed to access authentication methods." }
})

$BtnClearMFA.Add_Click({
    if (-not $ResolvedUser) {
        $OutputText.Text = "MFA requires a successfully linked User Account."
        return
    }
    Wait-TrainingStep -Desc "STEP 7: CLEAR MFA METHODS" -Code "`$methods = Get-MgUserAuthenticationPhoneMethod -UserId `$ResolvedUser.Id`nforeach (`$m in `$methods) { Remove-MgUserAuthenticationPhoneMethod -UserId `$ResolvedUser.Id -PhoneAuthenticationMethodId `$m.Id }"
    if ([System.Windows.MessageBox]::Show("Are you sure you want to DELETE all registered MFA phone numbers for $($ResolvedUser.DisplayName)? They will be forced to re-register on next login.", "Clear MFA", "YesNo", "Warning") -eq "Yes") {
        $OutputText.Text = "UHDC: Clearing MFA methods..."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $methods = Get-MgUserAuthenticationPhoneMethod -UserId $ResolvedUser.Id
            $cleared = 0
            foreach ($m in $methods) {
                Remove-MgUserAuthenticationPhoneMethod -UserId $ResolvedUser.Id -PhoneAuthenticationMethodId $m.Id -ErrorAction Stop
                $cleared++
            }
            $OutputText.Text = "[UHDC SUCCESS] Cleared $cleared MFA methods. User must re-register."
        } catch { $OutputText.Text = "Failed to clear MFA: $($_.Exception.Message)" }
    }
})

$BtnAddPhone.Add_Click({
    if (-not $ResolvedUser) {
        $OutputText.Text = "MFA requires a successfully linked User Account."
        return
    }
    $newPhone = $InputPhone.Text.Trim()
    if ($newPhone -match "^\+1") {
        Wait-TrainingStep -Desc "STEP 8: ADD SMS MFA" -Code "New-MgUserAuthenticationPhoneMethod -UserId `$ResolvedUser.Id -PhoneType `"mobile`" -PhoneNumber `$newPhone"
        $OutputText.Text = "UHDC: Adding $newPhone to account..."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            New-MgUserAuthenticationPhoneMethod -UserId $ResolvedUser.Id -PhoneType "mobile" -PhoneNumber $newPhone -ErrorAction Stop
            $OutputText.Text = "[UHDC SUCCESS] $newPhone added as primary SMS MFA."
            $InputPhone.Text = ""
        } catch { $OutputText.Text = "Error: $($_.Exception.Message)" }
    } else {
        $OutputText.Text = "Error: Use international format (+15550001111)"
    }
})

$BtnSync.Add_Click({
    $dev = $GlobalDevices[$DeviceList.SelectedIndex]
    Invoke-MgSyncDeviceManagementManagedDevice -ManagedDeviceId $dev.Id
    $OutputText.Text = "UHDC: Sync command dispatched."
})

$BtnReboot.Add_Click({
    $dev = $GlobalDevices[$DeviceList.SelectedIndex]
    if ([System.Windows.MessageBox]::Show("Send Reboot command to $($dev.DeviceName)?", "UHDC Confirm", "YesNo") -eq "Yes") {
        Invoke-MgRebootDeviceManagementManagedDevice -ManagedDeviceId $dev.Id
        $OutputText.Text = "UHDC: Reboot command dispatched."
    }
})

$Form.ShowDialog() | Out-Null