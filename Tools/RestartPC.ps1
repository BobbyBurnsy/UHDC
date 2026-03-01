# RestartPC.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Provides a dark-themed GUI menu to send power commands (Restart,
# Shutdown, Logoff) to a remote target. It utilizes PsExec to execute native
# shutdown.exe commands locally on the target, effectively bypassing common WMI
# and RPC firewall blocks.

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [hashtable]$SyncHash
)

# --- TRAINING MODE HELPER (WPF Safe) ---
function Wait-TrainingStep {
    param([string]$Desc, [string]$Code)
    if ($null -ne $SyncHash) {
        $SyncHash.StepDesc = $Desc
        $SyncHash.StepCode = $Code
        $SyncHash.StepReady = $true
        $SyncHash.StepAck = $false

        # Pause the script until the GUI user clicks Execute or Abort
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
# BULLETPROOF CONFIG LOADER (Fallback if run standalone)
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

Add-Type -AssemblyName PresentationFramework

# ------------------------------------------------------------------
# CUSTOM DARK THEMED INPUT BOX FUNCTION
# ------------------------------------------------------------------
function Show-DarkInputBox {
    param([string]$Title, [string]$Prompt, [string]$DefaultText = "")

    [xml]$InputXAML = @"
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            Title="$Title" SizeToContent="Height" Width="450" Background="#1E1E1E" WindowStartupLocation="CenterScreen" Topmost="True" ResizeMode="NoResize">
        <StackPanel Margin="15">
            <TextBlock Text="$Prompt" Foreground="White" FontSize="14" Margin="0,0,0,10" TextWrapping="Wrap"/>
            <TextBox Name="InputBox" Text="$DefaultText" Background="#333333" Foreground="#00A2ED" FontSize="14" Height="28" Padding="4" BorderBrush="#555"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,15,0,0">
                <Button Name="BtnCancel" Content="Cancel" Width="80" Height="30" Margin="0,0,10,0" Background="#444" Foreground="White" Cursor="Hand" BorderThickness="0"/>
                <Button Name="BtnOK" Content="OK" Width="80" Height="30" Background="#00A2ED" Foreground="White" Cursor="Hand" BorderThickness="0" FontWeight="Bold"/>
            </StackPanel>
        </StackPanel>
    </Window>
"@
    $Reader = (New-Object System.Xml.XmlNodeReader $InputXAML)
    $InputWin = [Windows.Markup.XamlReader]::Load($Reader)

    $InputBox = $InputWin.FindName("InputBox")
    $BtnOK = $InputWin.FindName("BtnOK")
    $BtnCancel = $InputWin.FindName("BtnCancel")

    $Result = $null

    $BtnOK.Add_Click({
        $script:Result = $InputBox.Text
        $InputWin.Close()
    })
    $BtnCancel.Add_Click({ $InputWin.Close() })

    $InputWin.ShowDialog() | Out-Null
    return $Result
}

# ------------------------------------------------------------------
# 1. TARGET VALIDATION (GUI Fallback)
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

# Fast Ping Test
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping." -ForegroundColor Red
    return
}

# STANDARD PATHING: Rely strictly on the \Core folder as defined by UHDC
$psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

if (-not (Test-Path $psExecPath)) {
    Write-Host " [UHDC] [!] ERROR: psexec.exe not found at $psExecPath"
    Write-Host "        Please ensure the UHDC console has downloaded it to the \Core folder."
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

# ------------------------------------------------------------------
# CUSTOM DARK THEMED SELECTION MENU
# ------------------------------------------------------------------
[xml]$MenuXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="UHDC: Power Controls - $Target" Height="350" Width="650" Background="#1E1E1E" WindowStartupLocation="CenterScreen" Topmost="True">
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Text="Select Power Action for $Target" Foreground="#00A2ED" FontSize="18" FontWeight="Bold" Margin="0,0,0,10"/>

        <ListView Name="ActionList" Grid.Row="1" Background="#2D2D30" Foreground="White" BorderBrush="#555" FontSize="14" Margin="0,0,0,15">
            <ListView.View>
                <GridView>
                    <GridViewColumn Header="Action" DisplayMemberBinding="{Binding Action}" Width="150"/>
                    <GridViewColumn Header="Description" DisplayMemberBinding="{Binding Description}" Width="450"/>
                </GridView>
            </ListView.View>
        </ListView>

        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="BtnCancel" Content="Cancel" Width="100" Height="35" Margin="0,0,10,0" Background="#444" Foreground="White" Cursor="Hand" BorderThickness="0"/>
            <Button Name="BtnExecute" Content="Execute Command" Width="140" Height="35" Background="#DC3545" Foreground="White" Cursor="Hand" BorderThickness="0" FontWeight="Bold"/>
        </StackPanel>
    </Grid>
</Window>
"@

$MenuReader = (New-Object System.Xml.XmlNodeReader $MenuXAML)
$MenuWin = [Windows.Markup.XamlReader]::Load($MenuReader)

$ActionList = $MenuWin.FindName("ActionList")
$BtnExecute = $MenuWin.FindName("BtnExecute")
$BtnCancel = $MenuWin.FindName("BtnCancel")

foreach ($item in $MenuOptions) { $ActionList.Items.Add($item) | Out-Null }

$Selection = $null

$BtnExecute.Add_Click({
    if ($ActionList.SelectedItem) {
        $script:Selection = $ActionList.SelectedItem
        $MenuWin.Close()
    } else {
        [System.Windows.MessageBox]::Show("Please select an action from the list.", "Selection Required", "OK", "Warning")
    }
})

$BtnCancel.Add_Click({ $MenuWin.Close() })

$MenuWin.ShowDialog() | Out-Null

if (-not $Selection) {
    Write-Host " [UHDC] [i] Power action cancelled." -ForegroundColor DarkGray
    return
}

# ------------------------------------------------------------------
# 3. EXECUTE SELECTED ACTION VIA PSEXEC
# ------------------------------------------------------------------
try {
    switch ($Selection.Command) {
        "Restart" {
            Wait-TrainingStep `
                -Desc "STEP 1: STANDARD RESTART`n`nWHEN TO USE THIS:`nUse this for general troubleshooting when a user is actively working on the PC. It gives them a 60-second warning to save their documents before the computer reboots.`n`nWHAT IT DOES:`nWe use PsExec to run the native 'shutdown.exe' command on the target. The '/r' flag means restart, and '/t 60' sets a 60-second timer.`n`nIN-PERSON EQUIVALENT:`nClicking the Start Menu, selecting the Power icon, and clicking 'Restart'." `
                -Code "psexec.exe \\$Target -s shutdown /r /t 60"

            Write-Host " [UHDC] [EXEC] Initiating standard restart on $Target..." -ForegroundColor Cyan
            Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s shutdown /r /t 60" -Wait -NoNewWindow
            Write-Host " [UHDC SUCCESS] Restart command sent." -ForegroundColor Green
        }
        "ForceRestart" {
            Wait-TrainingStep `
                -Desc "STEP 1: FORCE RESTART`n`nWHEN TO USE THIS:`nUse this when a computer is completely frozen, stuck on a black screen, or a rogue application is preventing a standard restart. WARNING: The user will lose any unsaved work.`n`nWHAT IT DOES:`nWe add the '/f' (force) flag and set the timer to '/t 0'. This tells Windows to instantly kill all running applications without waiting for them to close gracefully.`n`nIN-PERSON EQUIVALENT:`nHolding down the physical power button on the laptop for 5 seconds until the machine hard-powers off, then turning it back on." `
                -Code "psexec.exe \\$Target -s shutdown /r /f /t 0"

            Write-Host " [UHDC] [EXEC] Initiating FORCE restart on $Target..." -ForegroundColor Red
            Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s shutdown /r /f /t 0" -Wait -NoNewWindow
            Write-Host " [UHDC SUCCESS] Force restart command sent." -ForegroundColor Green
        }
        "Logoff" {
            Wait-TrainingStep `
                -Desc "STEP 1: FORCE LOGOFF`n`nWHEN TO USE THIS:`nUse this when a user's profile is locked up, their Start Menu won't open, or you need to kick a disconnected user off a shared workstation without rebooting the entire PC.`n`nWHAT IT DOES:`nInstead of 'shutdown.exe', we use PsExec to run 'rwinsta console'. This forcefully terminates the active Windows session (the 'console' session) and returns the PC to the Ctrl+Alt+Del login screen.`n`nIN-PERSON EQUIVALENT:`nPressing Ctrl+Alt+Del and selecting 'Sign out', or opening Task Manager, going to the 'Users' tab, right-clicking the user, and selecting 'Disconnect'." `
                -Code "psexec.exe \\$Target -s rwinsta console"

            Write-Host " [UHDC] [EXEC] Forcing user logoff on $Target..." -ForegroundColor Yellow
            Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s rwinsta console" -Wait -NoNewWindow
            Write-Host " [UHDC SUCCESS] Logoff command sent." -ForegroundColor Green
        }
        "Shutdown" {
            Wait-TrainingStep `
                -Desc "STEP 1: REMOTE SHUTDOWN`n`nWHEN TO USE THIS:`nUse this when a computer was left on over the weekend, or you need to power down a machine before a physical desk move.`n`nWHAT IT DOES:`nWe use the '/s' flag to tell Windows to shut down completely instead of restarting.`n`nIN-PERSON EQUIVALENT:`nClicking the Start Menu, selecting the Power icon, and clicking 'Shut down'." `
                -Code "psexec.exe \\$Target -s shutdown /s /f /t 0"

            Write-Host " [UHDC] [EXEC] Initiating remote shutdown on $Target..." -ForegroundColor Cyan
            Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s shutdown /s /f /t 0" -Wait -NoNewWindow
            Write-Host " [UHDC SUCCESS] Shutdown command sent." -ForegroundColor Green
        }
        "Abort" {
            Wait-TrainingStep `
                -Desc "STEP 1: ABORT PENDING RESTART`n`nWHEN TO USE THIS:`nUse this if you accidentally sent a 60-second restart command to the wrong PC, or if a Windows Update is threatening to reboot the PC while the user is in the middle of a presentation.`n`nWHAT IT DOES:`nWe use the '/a' (abort) flag. This cancels any active shutdown or restart timers currently ticking down on the target machine.`n`nIN-PERSON EQUIVALENT:`nOpening the Run dialog (Win+R) or Command Prompt and quickly typing 'shutdown /a' before the timer runs out." `
                -Code "psexec.exe \\$Target -s shutdown /a"

            Write-Host " [UHDC] [EXEC] Attempting to abort pending restart on $Target..." -ForegroundColor Cyan
            Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s shutdown /a" -Wait -NoNewWindow
            Write-Host " [UHDC SUCCESS] Abort command sent." -ForegroundColor Green
        }
    }

    # --- AUDIT LOG INJECTION ---
    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action "Power Control Executed: $($Selection.Command)" -SharedRoot $SharedRoot
        }
    }
    # ---------------------------

} catch {
    Write-Host " [UHDC ERROR] Execution failed: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "========================================================`n"