# RestartPC.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Provides a dark-themed GUI menu to send power commands (Restart,
# Shutdown, Logoff) to a remote target. It utilizes PsExec to execute native
# shutdown.exe commands locally on the target, effectively bypassing common WMI
# and RPC firewall blocks.
# Optimized for PS 5.1 (WPF Dialog Fix, Base64 Themes, .NET Ping).

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

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
# BULLETPROOF CONFIG LOADER
# ------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    try {
        $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
        $RootFolder = Split-Path -Path $ScriptDir
        $ConfigFile = Join-Path -Path $RootFolder -ChildPath "config.json"

        if (Test-Path $ConfigFile) {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $SharedRoot = $Config.SharedNetworkRoot
        }
    } catch { }
}

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

Add-Type -AssemblyName PresentationFramework

# ------------------------------------------------------------------
# CUSTOM THEMED INPUT BOX FUNCTION
# ------------------------------------------------------------------
function Show-DarkInputBox {
    param([string]$Title, [string]$Prompt, [string]$DefaultText = "")

    [string]$InputXAML = @"
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            Title="$Title" SizeToContent="Height" Width="450" Background="%%BG_MAIN%%" WindowStartupLocation="CenterScreen" Topmost="True" ResizeMode="NoResize">
        <StackPanel Margin="15">
            <TextBlock Text="$Prompt" Foreground="White" FontSize="14" Margin="0,0,0,10" TextWrapping="Wrap"/>
            <TextBox Name="InputBox" Text="$DefaultText" Background="%%BG_CON%%" Foreground="%%ACC_SEC%%" FontSize="14" Height="28" Padding="4" BorderBrush="#555"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,15,0,0">
                <Button Name="BtnCancel" Content="Cancel" Width="80" Height="30" Margin="0,0,10,0" Background="%%BG_BTN%%" Foreground="White" Cursor="Hand" BorderThickness="0" IsCancel="True"/>
                <Button Name="BtnOK" Content="OK" Width="80" Height="30" Background="%%ACC_PRI%%" Foreground="%%BG_MAIN%%" Cursor="Hand" BorderThickness="0" FontWeight="Bold" IsDefault="True"/>
            </StackPanel>
        </StackPanel>
    </Window>
"@
    $InputXAML = $InputXAML -replace '%%BG_MAIN%%', $ActiveColors.BG_Main
    $InputXAML = $InputXAML -replace '%%BG_CON%%', $ActiveColors.BG_Con
    $InputXAML = $InputXAML -replace '%%BG_BTN%%', $ActiveColors.BG_Btn
    $InputXAML = $InputXAML -replace '%%ACC_PRI%%', $ActiveColors.Acc_Pri
    $InputXAML = $InputXAML -replace '%%ACC_SEC%%', $ActiveColors.Acc_Sec

    $StringReader = New-Object System.IO.StringReader $InputXAML
    $XmlReader = [System.Xml.XmlReader]::Create($StringReader)
    $InputWin = [System.Windows.Markup.XamlReader]::Load($XmlReader)

    $InputBox = $InputWin.FindName("InputBox")
    $BtnOK = $InputWin.FindName("BtnOK")

    $InputWin.Add_Loaded({
        $InputBox.Focus()
        $InputBox.SelectAll()
    })

    $BtnOK.Add_Click({ 
        $InputWin.DialogResult = $true 
    })

    if ($InputWin.ShowDialog() -eq $true) {
        return $InputBox.Text
    }
    return $null
}

# ------------------------------------------------------------------
# 1. TARGET VALIDATION
# ------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Target)) {
    $Target = Show-DarkInputBox -Title "Target Required" -Prompt "Enter Target PC to Restart/Logoff:"

    if ([string]::IsNullOrWhiteSpace($Target)) {
        Write-Host " [UHDC] [!] Action cancelled (No target provided)." -ForegroundColor Yellow
        return
    }
}

Write-Host "========================================================"
Write-Host " [UHDC] POWER CONTROLS: $Target"
Write-Host "========================================================"

$pingSender = New-Object System.Net.NetworkInformation.Ping
try {
    if ($pingSender.Send($Target, 1000).Status -ne "Success") {
        Write-Host " [UHDC] [!] Offline. $Target is not responding to ping." -ForegroundColor Red
        return
    }
} catch {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping." -ForegroundColor Red
    return
}

$psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

if (-not (Test-Path $psExecPath)) {
    Write-Host " [UHDC] [!] ERROR: psexec.exe not found at $psExecPath"
    return
}

# ------------------------------------------------------------------
# 2. BUILD GRAPHICAL MENU OPTIONS
# ------------------------------------------------------------------
$MenuOptions = @(
    [PSCustomObject]@{ Action = "1. Standard Restart"; Command = "Restart"; Description = "Reboots in 60 seconds. Prompts user to save work." }
    [PSCustomObject]@{ Action = "2. Force Restart"; Command = "ForceRestart"; Description = "Immediate reboot. Unsaved work WILL be lost." }
    [PSCustomObject]@{ Action = "3. Force Logoff"; Command = "Logoff"; Description = "Forces the active user session to log out." }
    [PSCustomObject]@{ Action = "4. Shutdown PC"; Command = "Shutdown"; Description = "Turns the computer off completely." }
    [PSCustomObject]@{ Action = "5. Abort Restart"; Command = "Abort"; Description = "Cancels a pending shutdown/restart timer." }
)

Write-Host " [UHDC] >>> Opening Graphical Power Menu..." -ForegroundColor Cyan

[string]$MenuXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="UHDC: Power Controls - $Target" Height="350" Width="650" Background="%%BG_MAIN%%" WindowStartupLocation="CenterScreen" Topmost="True">
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Text="Select Power Action for $Target" Foreground="%%ACC_PRI%%" FontSize="18" FontWeight="Bold" Margin="0,0,0,10"/>

        <ListView Name="ActionList" Grid.Row="1" Background="%%BG_SEC%%" Foreground="White" BorderBrush="#555" FontSize="14" Margin="0,0,0,15">
            <ListView.View>
                <GridView>
                    <GridViewColumn Header="Action" DisplayMemberBinding="{Binding Action}" Width="150"/>
                    <GridViewColumn Header="Description" DisplayMemberBinding="{Binding Description}" Width="450"/>
                </GridView>
            </ListView.View>
        </ListView>

        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="BtnCancel" Content="Cancel" Width="100" Height="35" Margin="0,0,10,0" Background="%%BG_BTN%%" Foreground="White" Cursor="Hand" BorderThickness="0" IsCancel="True"/>
            <Button Name="BtnExecute" Content="Execute Command" Width="140" Height="35" Background="#DC3545" Foreground="White" Cursor="Hand" BorderThickness="0" FontWeight="Bold" IsDefault="True"/>
        </StackPanel>
    </Grid>
</Window>
"@

$MenuXAML = $MenuXAML -replace '%%BG_MAIN%%', $ActiveColors.BG_Main
$MenuXAML = $MenuXAML -replace '%%BG_SEC%%', $ActiveColors.BG_Sec
$MenuXAML = $MenuXAML -replace '%%BG_BTN%%', $ActiveColors.BG_Btn
$MenuXAML = $MenuXAML -replace '%%ACC_PRI%%', $ActiveColors.Acc_Pri

$StringReader = New-Object System.IO.StringReader $MenuXAML
$XmlReader = [System.Xml.XmlReader]::Create($StringReader)
$MenuWin = [System.Windows.Markup.XamlReader]::Load($XmlReader)

$ActionList = $MenuWin.FindName("ActionList")
$BtnExecute = $MenuWin.FindName("BtnExecute")

foreach ($item in $MenuOptions) { $ActionList.Items.Add($item) | Out-Null }

$Selection = $null

$BtnExecute.Add_Click({
    if ($ActionList.SelectedItem) {
        $script:Selection = $ActionList.SelectedItem
        $MenuWin.DialogResult = $true
    } else {
        [System.Windows.MessageBox]::Show("Please select an action from the list.", "Selection Required", "OK", "Warning")
    }
})

if ($MenuWin.ShowDialog() -ne $true -or -not $Selection) {
    Write-Host " [UHDC] [i] Power action cancelled." -ForegroundColor DarkGray
    return
}

# ------------------------------------------------------------------
# 3. EXECUTE SELECTED ACTION VIA PSEXEC
# ------------------------------------------------------------------
try {
    switch ($Selection.Command) {
        "Restart" {
            Wait-TrainingStep -Desc "STEP 1: STANDARD RESTART" -Code "psexec.exe \\$Target -s shutdown /r /t 60"
            Write-Host " [UHDC] [EXEC] Initiating standard restart on $Target..." -ForegroundColor Cyan
            Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s shutdown /r /t 60" -Wait -NoNewWindow
            Write-Host " [UHDC SUCCESS] Restart command sent." -ForegroundColor Green
        }
        "ForceRestart" {
            Wait-TrainingStep -Desc "STEP 1: FORCE RESTART" -Code "psexec.exe \\$Target -s shutdown /r /f /t 0"
            Write-Host " [UHDC] [EXEC] Initiating FORCE restart on $Target..." -ForegroundColor Red
            Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s shutdown /r /f /t 0" -Wait -NoNewWindow
            Write-Host " [UHDC SUCCESS] Force restart command sent." -ForegroundColor Green
        }
        "Logoff" {
            Wait-TrainingStep -Desc "STEP 1: FORCE LOGOFF" -Code "psexec.exe \\$Target -s rwinsta console"
            Write-Host " [UHDC] [EXEC] Forcing user logoff on $Target..." -ForegroundColor Yellow
            Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s rwinsta console" -Wait -NoNewWindow
            Write-Host " [UHDC SUCCESS] Logoff command sent." -ForegroundColor Green
        }
        "Shutdown" {
            Wait-TrainingStep -Desc "STEP 1: REMOTE SHUTDOWN" -Code "psexec.exe \\$Target -s shutdown /s /f /t 0"
            Write-Host " [UHDC] [EXEC] Initiating remote shutdown on $Target..." -ForegroundColor Cyan
            Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s shutdown /s /f /t 0" -Wait -NoNewWindow
            Write-Host " [UHDC SUCCESS] Shutdown command sent." -ForegroundColor Green
        }
        "Abort" {
            Wait-TrainingStep -Desc "STEP 1: ABORT PENDING RESTART" -Code "psexec.exe \\$Target -s shutdown /a"
            Write-Host " [UHDC] [EXEC] Attempting to abort pending restart on $Target..." -ForegroundColor Cyan
            Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s shutdown /a" -Wait -NoNewWindow
            Write-Host " [UHDC SUCCESS] Abort command sent." -ForegroundColor Green
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Power Control Executed: $($Selection.Command)" -SharedRoot $SharedRoot
        }
    }
} catch {
    Write-Host " [UHDC ERROR] Execution failed: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "========================================================`n"