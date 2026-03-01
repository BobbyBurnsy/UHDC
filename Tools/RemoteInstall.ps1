# RemoteInstall.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Provides a dark-themed GUI interface to manage and silently deploy
# software to a remote target using PsExec (SYSTEM context). Supports saving commonly
# used application UNC paths and silent installation arguments to a central JSON library.

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
        } else {
            Write-Host " [UHDC] [!] Error: SharedRoot path is missing and config.json not found."
            return
        }
    } catch { return }
}

if ([string]::IsNullOrWhiteSpace($Target)) { return }

Write-Host "========================================"
Write-Host " [UHDC] REMOTE SILENT INSTALLER: $Target"
Write-Host "========================================"

# 1. Fast Ping Check
if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# 2. Setup Paths dynamically
$LibraryFile = Join-Path -Path $SharedRoot -ChildPath "Core\SoftwareLibrary.json"

function Load-Lib {
    if (Test-Path $LibraryFile) {
        $raw = Get-Content $LibraryFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        if ($null -eq $raw) { return @() }
        if ($raw -is [System.Array]) { return $raw } else { return @($raw) }
    } else { return @() }
}
function Save-Lib {
    param($d)
    $d | ConvertTo-Json -Depth 2 | Set-Content $LibraryFile -Force
}

$lib = Load-Lib

# 3. Build the Menu Options
$MenuOptions = @()
foreach ($app in $lib) {
    $MenuOptions += [PSCustomObject]@{
        Action = "INSTALL"
        Name   = $app.Name
        Path   = $app.Path
        Args   = $app.Args
        ID     = $app.ID
    }
}

# Add our control options at the bottom of the list
$MenuOptions += [PSCustomObject]@{ Action = "CUSTOM"; Name = "[*] Custom One-Off Install"; Path = "---"; Args = "---"; ID = "" }
$MenuOptions += [PSCustomObject]@{ Action = "ADD";    Name = "[+] Add New App to Library"; Path = "---"; Args = "---"; ID = "" }
$MenuOptions += [PSCustomObject]@{ Action = "DELETE"; Name = "[-] Delete App from Library";Path = "---"; Args = "---"; ID = "" }

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
# CUSTOM DARK THEMED SELECTION MENU
# ------------------------------------------------------------------
[xml]$MenuXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="UHDC: Remote Installer - $Target" Height="450" Width="750" Background="#1E1E1E" WindowStartupLocation="CenterScreen" Topmost="True">
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Text="Select Software Action for $Target" Foreground="#00A2ED" FontSize="18" FontWeight="Bold" Margin="0,0,0,10"/>

        <ListView Name="AppList" Grid.Row="1" Background="#2D2D30" Foreground="White" BorderBrush="#555" FontSize="14" Margin="0,0,0,15">
            <ListView.View>
                <GridView>
                    <GridViewColumn Header="Action" DisplayMemberBinding="{Binding Action}" Width="80"/>
                    <GridViewColumn Header="Application Name" DisplayMemberBinding="{Binding Name}" Width="220"/>
                    <GridViewColumn Header="UNC Path" DisplayMemberBinding="{Binding Path}" Width="380"/>
                </GridView>
            </ListView.View>
        </ListView>

        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="BtnCancel" Content="Cancel" Width="100" Height="35" Margin="0,0,10,0" Background="#444" Foreground="White" Cursor="Hand" BorderThickness="0"/>
            <Button Name="BtnExecute" Content="Execute Selection" Width="140" Height="35" Background="#28A745" Foreground="White" Cursor="Hand" BorderThickness="0" FontWeight="Bold"/>
        </StackPanel>
    </Grid>
</Window>
"@

$MenuReader = (New-Object System.Xml.XmlNodeReader $MenuXAML)
$MenuWin = [Windows.Markup.XamlReader]::Load($MenuReader)

$AppList = $MenuWin.FindName("AppList")
$BtnExecute = $MenuWin.FindName("BtnExecute")
$BtnCancel = $MenuWin.FindName("BtnCancel")

foreach ($item in $MenuOptions) { $AppList.Items.Add($item) | Out-Null }

$Selection = $null

$BtnExecute.Add_Click({
    if ($AppList.SelectedItem) {
        $script:Selection = $AppList.SelectedItem
        $MenuWin.Close()
    } else {
        [System.Windows.MessageBox]::Show("Please select an item from the list.", "Selection Required", "OK", "Warning")
    }
})

$BtnCancel.Add_Click({ $MenuWin.Close() })

# Show the Dark UI
$MenuWin.ShowDialog() | Out-Null

if (-not $Selection) {
    Write-Host " [UHDC] [i] Installation aborted by user."
    Write-Host "========================================`n"
    return
}

$installer = $null

# 4. Handle the User's Selection
switch ($Selection.Action) {
    "ADD" {
        $n = Show-DarkInputBox -Title "UHDC Add App" -Prompt "Enter Display Name (e.g., Google Chrome):"
        if (-not $n) { return }
        $p = Show-DarkInputBox -Title "UHDC Add App" -Prompt "Enter UNC Path to Installer:" -DefaultText "\\server\share\installer.exe"
        if (-not $p) { return }
        $a = Show-DarkInputBox -Title "UHDC Add App" -Prompt "Enter Silent Switches (e.g., /S /q):" -DefaultText "/S"

        $newID = if ($lib.Count -gt 0) { ([int]($lib | Select-Object -ExpandProperty ID | Measure-Object -Maximum).Maximum) + 1 } else { 1 }

        $lib += [PSCustomObject]@{ID=$newID; Name=$n; Path=$p; Args=$a}
        Save-Lib $lib
        Write-Host " [UHDC SUCCESS] Added '$n' to Library! Run the tool again to install it."
        return
    }
    "DELETE" {
        if ($lib.Count -eq 0) { Write-Host " [UHDC] [i] Library is already empty."; return }

        # Re-use the dark menu for deletion
        $DelWin = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $MenuXAML))
        $DelWin.Title = "UHDC: Delete App from Library"
        $DelWin.FindName("BtnExecute").Content = "Delete Selected"
        $DelWin.FindName("BtnExecute").Background = "#DC3545" # Red for delete
        $DelList = $DelWin.FindName("AppList")

        foreach ($item in $lib) { $DelList.Items.Add($item) | Out-Null }

        $delSel = $null
        $DelWin.FindName("BtnExecute").Add_Click({
            if ($DelList.SelectedItem) { $script:delSel = $DelList.SelectedItem; $DelWin.Close() }
        })
        $DelWin.FindName("BtnCancel").Add_Click({ $DelWin.Close() })

        $DelWin.ShowDialog() | Out-Null

        if ($delSel) {
            $lib = $lib | Where-Object { $_.ID -ne $delSel.ID }
            Save-Lib $lib
            Write-Host " [UHDC SUCCESS] Removed '$($delSel.Name)' from Library."
        }
        return
    }
    "CUSTOM" {
        $path = Show-DarkInputBox -Title "UHDC Custom Install" -Prompt "Enter UNC Path to Installer:" -DefaultText "\\server\share\installer.exe"
        if (-not $path) { return }
        $args = Show-DarkInputBox -Title "UHDC Custom Install" -Prompt "Enter Silent Switches (e.g., /S /q):"
        $installer = [PSCustomObject]@{Name="Custom App"; Path=$path; Args=$args}
    }
    "INSTALL" {
        $installer = $Selection
    }
}

# 5. Execute Installation
if ($installer) {
    Write-Host "`n [UHDC] [!] Deploying $($installer.Name) to $Target..."
    Write-Host "      Path: $($installer.Path)"
    Write-Host "      Args: $($installer.Args)"

    # STANDARD PATHING: Rely strictly on the \Core folder as defined by UHDC
    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {
        try {

            # ------------------------------------------------------------------
            # STEP 1: EXECUTE SILENT INSTALLATION
            # ------------------------------------------------------------------
            Wait-TrainingStep `
                -Desc "STEP 1: SILENT REMOTE INSTALLATION`n`nWHEN TO USE THIS:`nUse this when a user needs a standard application (like Google Chrome, Adobe Reader, or Zoom) installed, but they do not have local administrator rights, or you want to install it in the background without interrupting their work.`n`nWHAT IT DOES:`nWe are using PsExec to connect to the target PC as the 'SYSTEM' account. We then execute the installer directly from the network share using 'silent' command-line switches (like /S or /qn). This bypasses UAC prompts and hides the installation wizard from the user.`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would open File Explorer, navigate to the network share, double-click the installer, type in your admin credentials when prompted by UAC, and click 'Next' through the installation wizard." `
                -Code "psexec.exe \\$Target -s `"$($installer.Path)`" $($installer.Args)"

            Write-Host "  > [UHDC] Installing in background... (Please wait)"
            # Execute PsExec silently
            Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s `"$($installer.Path)`" $($installer.Args)" -Wait -NoNewWindow
            Write-Host " [UHDC SUCCESS] Deployment command finished."

            # --- AUDIT LOG INJECTION ---
            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) {
                    & $AuditHelper -Target $Target -Action "Deployed Software: $($installer.Name)" -SharedRoot $SharedRoot
                }
            }
            # ---------------------------

        } catch {
            Write-Host " [UHDC] [!] ERROR: Execution failed. $($_.Exception.Message)"
        }
    } else {
        Write-Host " [UHDC] [!] ERROR: psexec.exe not found at $psExecPath"
        Write-Host "        Please ensure the UHDC console has downloaded it to the \Core folder."
    }
}

Write-Host "========================================`n"