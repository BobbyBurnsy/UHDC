# RemoteInstall.ps1 - Place this script in the \Tools folder
# DESCRIPTION: Provides a themed GUI interface to manage and silently deploy
# software to a remote target using PsExec (SYSTEM context). Supports saving commonly
# used application UNC paths and silent installation arguments to a central JSON library.
# Optimized for PS 5.1 (WPF Dialog Fix, JSON Array Protection, Base64 Themes).

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
        } else {
            Write-Host " [UHDC] [!] Error: SharedRoot path is missing and config.json not found."
            return
        }
    } catch { return }
}

if ([string]::IsNullOrWhiteSpace($Target)) { return }

# ------------------------------------------------------------------
# THEME ENGINE INTEGRATION (Base64 Decoding for PS 5.1 Safety)
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

Write-Host "========================================"
Write-Host " [UHDC] REMOTE SILENT INSTALLER: $Target"
Write-Host "========================================"

# 1. Fast Ping Check (.NET Ping for PS 5.1 Safety)
$pingSender = New-Object System.Net.NetworkInformation.Ping
try {
    if ($pingSender.Send($Target, 1000).Status -ne "Success") {
        Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
        Write-Host "========================================`n"
        return
    }
} catch {
    Write-Host " [UHDC] [!] Offline. $Target is not responding to ping."
    Write-Host "========================================`n"
    return
}

# 2. Setup Paths & Library Functions
$LibraryFile = Join-Path -Path $SharedRoot -ChildPath "Core\SoftwareLibrary.json"

function Load-Lib {
    if (Test-Path $LibraryFile) {
        try {
            $raw = Get-Content $LibraryFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -eq $raw) { return @() }
            if ($raw -is [System.Array]) { return $raw } else { return @($raw) }
        } catch { return @() }
    } else { 
        $default = @(
            [PSCustomObject]@{ ID=1; Name="Google Chrome (Enterprise)"; Path="\\server\share\Software\GoogleChromeStandaloneEnterprise64.msi"; Args="/qn /norestart" }
        )
        Save-Lib $default
        return $default
    }
}

function Save-Lib {
    param($d)
    try {
        $arr = @($d)
        $jsonOutput = $arr | ConvertTo-Json -Depth 2 -ErrorAction Stop
        if ($arr.Count -eq 1 -and $jsonOutput -notmatch "^\s*\[") {
            $jsonOutput = "[$jsonOutput]"
        }
        Set-Content -Path $LibraryFile -Value $jsonOutput -Force
    } catch {
        Write-Host " [UHDC] [!] Failed to save Software Library." -ForegroundColor Red
    }
}

Add-Type -AssemblyName PresentationFramework

# ------------------------------------------------------------------
# CUSTOM THEMED INPUT BOX FUNCTION (PS 5.1 WPF Fix)
# ------------------------------------------------------------------
function Show-ThemedInputBox {
    param([string]$Title, [string]$Prompt, [string]$DefaultText = "")

    [string]$InputXAML = @"
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            Title="$Title" SizeToContent="Height" Width="450" Background="%%BG_MAIN%%" WindowStartupLocation="CenterScreen" Topmost="True" ResizeMode="NoResize">
        <StackPanel Margin="15">
            <TextBlock Text="$Prompt" Foreground="White" FontSize="14" Margin="0,0,0,10" TextWrapping="Wrap"/>
            <TextBox Name="InputBox" Text="$DefaultText" Background="%%BG_SEC%%" Foreground="%%ACC_PRI%%" FontSize="14" Height="28" Padding="4" BorderBrush="#555"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,15,0,0">
                <Button Name="BtnCancel" Content="Cancel" Width="80" Height="30" Margin="0,0,10,0" Background="#444" Foreground="White" Cursor="Hand" BorderThickness="0" IsCancel="True"/>
                <Button Name="BtnOK" Content="OK" Width="80" Height="30" Background="%%ACC_PRI%%" Foreground="%%BG_MAIN%%" Cursor="Hand" BorderThickness="0" FontWeight="Bold" IsDefault="True"/>
            </StackPanel>
        </StackPanel>
    </Window>
"@
    $InputXAML = $InputXAML -replace '%%BG_MAIN%%', $ActiveColors.BG_Main
    $InputXAML = $InputXAML -replace '%%BG_SEC%%', $ActiveColors.BG_Sec
    $InputXAML = $InputXAML -replace '%%ACC_PRI%%', $ActiveColors.Acc_Pri

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
# 3. MAIN MENU LOOP
# ------------------------------------------------------------------
$installer = $null

while ($true) {
    $lib = Load-Lib

    $MenuOptions = @()
    foreach ($app in $lib) {
        $MenuOptions += [PSCustomObject]@{ Action = "INSTALL"; Name = $app.Name; Path = $app.Path; Args = $app.Args; ID = $app.ID }
    }
    $MenuOptions += [PSCustomObject]@{ Action = "CUSTOM"; Name = "[*] Custom One-Off Install"; Path = "---"; Args = "---"; ID = "" }
    $MenuOptions += [PSCustomObject]@{ Action = "ADD";    Name = "[+] Add New App to Library"; Path = "---"; Args = "---"; ID = "" }
    $MenuOptions += [PSCustomObject]@{ Action = "DELETE"; Name = "[-] Delete App from Library";Path = "---"; Args = "---"; ID = "" }

    [string]$MenuXAML = @"
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            Title="UHDC: Remote Installer - $Target" Height="450" Width="750" Background="%%BG_MAIN%%" WindowStartupLocation="CenterScreen" Topmost="True">
        <Grid Margin="15">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Text="Select Software Action for $Target" Foreground="%%ACC_PRI%%" FontSize="18" FontWeight="Bold" Margin="0,0,0,10"/>

            <ListView Name="AppList" Grid.Row="1" Background="%%BG_BTN%%" Foreground="White" BorderBrush="#555" FontSize="14" Margin="0,0,0,15">
                <ListView.View>
                    <GridView>
                        <GridViewColumn Header="Action" DisplayMemberBinding="{Binding Action}" Width="80"/>
                        <GridViewColumn Header="Application Name" DisplayMemberBinding="{Binding Name}" Width="220"/>
                        <GridViewColumn Header="UNC Path" DisplayMemberBinding="{Binding Path}" Width="380"/>
                    </GridView>
                </ListView.View>
            </ListView>

            <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
                <Button Name="BtnCancel" Content="Cancel" Width="100" Height="35" Margin="0,0,10,0" Background="#444" Foreground="White" Cursor="Hand" BorderThickness="0" IsCancel="True"/>
                <Button Name="BtnExecute" Content="Execute Selection" Width="140" Height="35" Background="#28A745" Foreground="White" Cursor="Hand" BorderThickness="0" FontWeight="Bold" IsDefault="True"/>
            </StackPanel>
        </Grid>
    </Window>
"@
    $MenuXAML = $MenuXAML -replace '%%BG_MAIN%%', $ActiveColors.BG_Main
    $MenuXAML = $MenuXAML -replace '%%BG_BTN%%', $ActiveColors.BG_Btn
    $MenuXAML = $MenuXAML -replace '%%ACC_PRI%%', $ActiveColors.Acc_Pri

    $StringReader = New-Object System.IO.StringReader $MenuXAML
    $XmlReader = [System.Xml.XmlReader]::Create($StringReader)
    $MenuWin = [System.Windows.Markup.XamlReader]::Load($XmlReader)

    $AppList = $MenuWin.FindName("AppList")
    $BtnExecute = $MenuWin.FindName("BtnExecute")

    foreach ($item in $MenuOptions) { $AppList.Items.Add($item) | Out-Null }

    $BtnExecute.Add_Click({
        if ($AppList.SelectedItem) { $MenuWin.DialogResult = $true } 
        else { [System.Windows.MessageBox]::Show("Please select an item from the list.", "Selection Required", "OK", "Warning") }
    })

    if ($MenuWin.ShowDialog() -eq $true) {
        $Selection = $AppList.SelectedItem

        if ($Selection.Action -eq "ADD") {
            $n = Show-ThemedInputBox -Title "UHDC Add App" -Prompt "Enter Display Name (e.g., Google Chrome):"
            if (-not $n) { continue }
            $p = Show-ThemedInputBox -Title "UHDC Add App" -Prompt "Enter UNC Path to Installer:" -DefaultText "\\server\share\installer.exe"
            if (-not $p) { continue }
            $a = Show-ThemedInputBox -Title "UHDC Add App" -Prompt "Enter Silent Switches (e.g., /S /q):" -DefaultText "/S"

            $newID = if ($lib.Count -gt 0) { ([int]($lib | Select-Object -ExpandProperty ID | Measure-Object -Maximum).Maximum) + 1 } else { 1 }
            $lib += [PSCustomObject]@{ID=$newID; Name=$n.Trim(); Path=$p.Trim(); Args=$a.Trim()}
            Save-Lib $lib
            Write-Host " [UHDC] [+] Added '$n' to Library."
            continue 
        }
        elseif ($Selection.Action -eq "DELETE") {
            if ($lib.Count -eq 0) { Write-Host " [UHDC] [i] Library is already empty."; continue }

            $StringReaderDel = New-Object System.IO.StringReader $MenuXAML
            $XmlReaderDel = [System.Xml.XmlReader]::Create($StringReaderDel)
            $DelWin = [System.Windows.Markup.XamlReader]::Load($XmlReaderDel)

            $DelWin.Title = "UHDC: Delete App from Library"
            $DelWin.FindName("BtnExecute").Content = "Delete Selected"
            $DelWin.FindName("BtnExecute").Background = "#DC3545"
            $DelList = $DelWin.FindName("AppList")
            foreach ($item in $lib) { $DelList.Items.Add($item) | Out-Null }

            $DelWin.FindName("BtnExecute").Add_Click({
                if ($DelList.SelectedItem) { $DelWin.DialogResult = $true }
            })

            if ($DelWin.ShowDialog() -eq $true) {
                $delSel = $DelList.SelectedItem
                $lib = $lib | Where-Object { $_.ID -ne $delSel.ID }
                Save-Lib $lib
                Write-Host " [UHDC] [-] Removed '$($delSel.Name)' from Library."
            }
            continue 
        }
        elseif ($Selection.Action -eq "CUSTOM") {
            $path = Show-ThemedInputBox -Title "UHDC Custom Install" -Prompt "Enter UNC Path to Installer:" -DefaultText "\\server\share\installer.exe"
            if (-not $path) { continue }
            $args = Show-ThemedInputBox -Title "UHDC Custom Install" -Prompt "Enter Silent Switches (e.g., /S /q):"
            $installer = [PSCustomObject]@{Name="Custom App"; Path=$path.Trim(); Args=$args.Trim()}
            break 
        }
        elseif ($Selection.Action -eq "INSTALL") {
            $installer = $Selection
            break 
        }
    } else {
        Write-Host " [UHDC] [i] Installation aborted by user."
        Write-Host "========================================`n"
        return
    }
}

# ------------------------------------------------------------------
# 4. EXECUTE INSTALLATION
# ------------------------------------------------------------------
if ($installer) {
    Write-Host "`n [UHDC] [!] Deploying $($installer.Name) to $Target..."
    Write-Host "      Path: $($installer.Path)"
    Write-Host "      Args: $($installer.Args)"

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if (Test-Path $psExecPath) {
        try {
            Wait-TrainingStep `
                -Desc "STEP 1: SILENT REMOTE INSTALLATION`n`nWHEN TO USE THIS:`nUse this when a user needs a standard application (like Google Chrome, Adobe Reader, or Zoom) installed, but they do not have local administrator rights, or you want to install it in the background without interrupting their work.`n`nWHAT IT DOES:`nWe are using PsExec to connect to the target PC as the 'SYSTEM' account. We then execute the installer directly from the network share using 'silent' command-line switches (like /S or /qn). This bypasses UAC prompts and hides the installation wizard from the user.`n`nIN-PERSON EQUIVALENT:`nIf you were physically at the user's desk, you would open File Explorer, navigate to the network share, double-click the installer, type in your admin credentials when prompted by UAC, and click 'Next' through the installation wizard." `
                -Code "psexec.exe \\$Target -s `"$($installer.Path)`" $($installer.Args)"

            Write-Host "  > [UHDC] Installing in background... (Please wait)"

            Start-Process $psExecPath -ArgumentList "/accepteula \\$Target -s `"$($installer.Path)`" $($installer.Args)" -Wait -NoNewWindow

            Write-Host " [UHDC SUCCESS] Deployment command finished."

            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) {
                    & $AuditHelper -Target $Target -Action "Deployed Software: $($installer.Name)" -SharedRoot $SharedRoot
                }
            }
        } catch {
            Write-Host " [UHDC] [!] ERROR: Execution failed. $($_.Exception.Message)"
        }
    } else {
        Write-Host " [UHDC] [!] ERROR: psexec.exe not found at $psExecPath"
    }
}

Write-Host "========================================`n"