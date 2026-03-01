# ThemeManager.ps1 - Place this in the same folder as UHDC.ps1
# DESCRIPTION: A standalone GUI utility to hot-swap the color palette of the UHDC.

# Auto-Elevate to Administrator (Required to modify files in protected shares)
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

Add-Type -AssemblyName PresentationFramework

# ------------------------------------------------------------------
# THEME DICTIONARY (Must use 6 UNIQUE hex codes per theme to prevent regex collisions)
# ------------------------------------------------------------------
$Themes = [ordered]@{
    "Seahawks (Default)" = @{ BG_Main="#1E1E1E"; BG_Sec="#111111"; BG_Con="#0C0C0C"; BG_Btn="#2D2D30"; Acc_Pri="#00A2ED"; Acc_Sec="#00FF00" }
    "Cyberpunk 2077"     = @{ BG_Main="#0D0208"; BG_Sec="#000000"; BG_Con="#050104"; BG_Btn="#1A0510"; Acc_Pri="#00F0FF"; Acc_Sec="#FF003C" }
    "Dracula"            = @{ BG_Main="#282A36"; BG_Sec="#1E1F29"; BG_Con="#191A21"; BG_Btn="#44475A"; Acc_Pri="#BD93F9"; Acc_Sec="#50FA7B" }
    "The Matrix"         = @{ BG_Main="#000000"; BG_Sec="#010101"; BG_Con="#020202"; BG_Btn="#0D0D0D"; Acc_Pri="#00FF41"; Acc_Sec="#00FF42" }
    "Solarized Dark"     = @{ BG_Main="#002B36"; BG_Sec="#073642"; BG_Con="#001E26"; BG_Btn="#083642"; Acc_Pri="#268BD2"; Acc_Sec="#2AA198" }
    "Blood Moon"         = @{ BG_Main="#1A0000"; BG_Sec="#0D0000"; BG_Con="#050000"; BG_Btn="#260000"; Acc_Pri="#FF3333"; Acc_Sec="#FF8800" }
    "Deep Ocean"         = @{ BG_Main="#0F172A"; BG_Sec="#080C17"; BG_Con="#04060C"; BG_Btn="#1E293B"; Acc_Pri="#38BDF8"; Acc_Sec="#34D399" }
}

# ------------------------------------------------------------------
# GUI DEFINITION
# ------------------------------------------------------------------
[xml]$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="UHDC Theme Manager" Height="420" Width="450" Background="#1E1E1E" WindowStartupLocation="CenterScreen" ResizeMode="NoResize">

    <Window.Resources>
        <Style x:Key="ApplyBtn" TargetType="Button">
            <Setter Property="Background" Value="#28A745"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#218838"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#1E7E34"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <StackPanel Margin="20">
        <TextBlock Text="UHDC Theme Manager" Foreground="#00A2ED" FontSize="22" FontWeight="Bold" Margin="0,0,0,5"/>
        <TextBlock Text="Select a color profile to apply to the main console." Foreground="#AAAAAA" FontSize="12" Margin="0,0,0,20"/>

        <TextBlock Text="Select Theme Profile:" Foreground="White" FontWeight="Bold" Margin="0,0,0,5"/>
        <ComboBox Name="ThemeCombo" Height="30" FontSize="14" Margin="0,0,0,20" Background="#333" Foreground="Black"/>

        <TextBlock Text="Live Preview:" Foreground="White" FontWeight="Bold" Margin="0,0,0,5"/>
        <Border BorderBrush="#444" BorderThickness="1" Padding="15" Background="#111" CornerRadius="4" Margin="0,0,0,25">
            <StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                    <Rectangle Name="ColorPri" Width="24" Height="24" RadiusX="4" RadiusY="4" Margin="0,0,15,0" Fill="#00A2ED"/>
                    <TextBlock Text="Primary Accent (Headers, Borders)" Foreground="White" VerticalAlignment="Center" FontSize="13"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                    <Rectangle Name="ColorSec" Width="24" Height="24" RadiusX="4" RadiusY="4" Margin="0,0,15,0" Fill="#00FF00"/>
                    <TextBlock Text="Secondary Accent (Action Buttons, Output)" Foreground="White" VerticalAlignment="Center" FontSize="13"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal">
                    <Rectangle Name="ColorBG" Width="24" Height="24" RadiusX="4" RadiusY="4" Margin="0,0,15,0" Fill="#1E1E1E" Stroke="#555" StrokeThickness="1"/>
                    <TextBlock Text="Main Background" Foreground="White" VerticalAlignment="Center" FontSize="13"/>
                </StackPanel>
            </StackPanel>
        </Border>

        <Button Name="BtnApply" Content="Apply Theme to UHDC.ps1" Height="40" Style="{StaticResource ApplyBtn}"/>
        <TextBlock Name="StatusText" Text="Ready." Foreground="#AAAAAA" Margin="0,15,0,0" TextAlignment="Center" FontWeight="Bold"/>
    </StackPanel>
</Window>
"@

$Reader = (New-Object System.Xml.XmlNodeReader $XAML)
$Form = [Windows.Markup.XamlReader]::Load($Reader)

# Map UI Elements
$ThemeCombo = $Form.FindName("ThemeCombo")
$ColorPri   = $Form.FindName("ColorPri")
$ColorSec   = $Form.FindName("ColorSec")
$ColorBG    = $Form.FindName("ColorBG")
$BtnApply   = $Form.FindName("BtnApply")
$StatusText = $Form.FindName("StatusText")

# Populate Dropdown
foreach ($key in $Themes.Keys) {
    $ThemeCombo.Items.Add($key) | Out-Null
}
$ThemeCombo.SelectedIndex = 0

# Update Preview Colors on Selection
$ThemeCombo.Add_SelectionChanged({
    $sel = $ThemeCombo.SelectedItem
    if ($sel) {
        $ColorPri.Fill = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Themes[$sel].Acc_Pri)
        $ColorSec.Fill = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Themes[$sel].Acc_Sec)
        $ColorBG.Fill  = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Themes[$sel].BG_Main)
    }
})

# ------------------------------------------------------------------
# APPLY THEME LOGIC
# ------------------------------------------------------------------
$BtnApply.Add_Click({
    $TargetFile = Join-Path -Path $PSScriptRoot -ChildPath "UHDC.ps1"

    if (-not (Test-Path $TargetFile)) {
        $StatusText.Text = "ERROR: UHDC.ps1 not found in this folder."
        $StatusText.Foreground = "Red"
        return
    }

    $FileContent = Get-Content $TargetFile -Raw
    $CurrentThemeName = $null

    # 1. Detect Current Theme
    foreach ($key in $Themes.Keys) {
        if ($FileContent.Contains($Themes[$key].Acc_Pri)) {
            $CurrentThemeName = $key
            break
        }
    }

    if (-not $CurrentThemeName) {
        $StatusText.Text = "ERROR: Could not detect current theme in UHDC.ps1."
        $StatusText.Foreground = "Red"
        return
    }

    # 2. Execute Swap
    $Old = $Themes[$CurrentThemeName]
    $New = $Themes[$ThemeCombo.SelectedItem]

    # We use .Replace() instead of -replace to avoid regex escaping issues
    $FileContent = $FileContent.Replace($Old.BG_Main, $New.BG_Main)
    $FileContent = $FileContent.Replace($Old.BG_Sec, $New.BG_Sec)
    $FileContent = $FileContent.Replace($Old.BG_Con, $New.BG_Con)
    $FileContent = $FileContent.Replace($Old.BG_Btn, $New.BG_Btn)
    $FileContent = $FileContent.Replace($Old.Acc_Pri, $New.Acc_Pri)
    $FileContent = $FileContent.Replace($Old.Acc_Sec, $New.Acc_Sec)

    try {
        Set-Content -Path $TargetFile -Value $FileContent -Force
        $StatusText.Text = "SUCCESS! Restart UHDC to see changes."
        $StatusText.Foreground = "#00FF00"

        # Note for compiled users
        if (Test-Path (Join-Path $PSScriptRoot "UHDC.exe")) {
            [System.Windows.MessageBox]::Show("Theme applied to UHDC.ps1 successfully!`n`nNote: Because you have a compiled UHDC.exe in this folder, you will need to re-run your compiler script to bake the new colors into the executable.", "Recompilation Required", "OK", "Information")
        }
    } catch {
        $StatusText.Text = "ERROR: Failed to save UHDC.ps1 (File in use?)"
        $StatusText.Foreground = "Red"
    }
})

$Form.ShowDialog() | Out-Null