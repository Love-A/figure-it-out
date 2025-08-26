<#
.SYNOPSIS
    GUI to select deployment options during a ConfigMgr Task Sequence.

.DESCRIPTION
    WPF/XAML UI driven by external JSON config:
      - types (device roles)
      - affinity (business units per type)
      - shared (shared device options; default + optional per-affinity overrides)
      - rules (e.g., officeEnabledTypes, lockWin11, allowWin10Hotkey, win10OverrideGesture, postInstallOfficeNoticeTypes)
      - ui (title and labels)
    No hardcoded choice lists in code – everything comes from JSON.

.PARAMETER DevMode
    Run without SCCM TS environment (for local testing).

.PARAMETER ResetTS
    Clear relevant Task Sequence variables at start to avoid stale values.

.PARAMETER ConfigPath
    Path to OSDForm.config.json (else falls back to TS var OSDFormConfigPath, env OSD_FORM_CONFIG, then .\OSDForm.config.json).

.PARAMETER PresetType
    For dev: preselect a device type (must exist in config).

.PARAMETER PresetAffinity
    For dev: preselect an affinity value (should exist for the selected type).

.PARAMETER PresetShared
    For dev: preselect a shared option string (must match config).

.PARAMETER PresetOffice
    For dev: preselect "With" or "Without" (Microsoft 365 Apps).

.PARAMETER PresetWin11
    For dev: force Win11 (redundant if lockWin11=true).

.EXAMPLE
    .\Start-OSDForm.ps1 -ResetTS -ConfigPath .\OSDForm.config.json

.NOTES
    Author: Love A
    Filename: Start-OSDForm.ps1

.VERSION
    2025-08-18 - 3.2.1-en - Fix: robust defaulting for PSCustomObject/hashtable config; accept legacy
                           'win10OverrideGestures' (plural) but prefer singular 'win10OverrideGesture'.
                           Simple PreviewKeyDown hotkey kept.
#>

[CmdletBinding()]
param(
    [switch]$DevMode,
    [switch]$ResetTS,
    [string]$ConfigPath,
    [string]$PresetType,
    [string]$PresetAffinity,
    [string]$PresetShared,
    [ValidateSet('With','Without')]$PresetOffice,
    [switch]$PresetWin11
)

# -------------------------
# Logging
# -------------------------
$script:foldername = 'OSDForm'
function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [string]$LogFile,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )
    if (-not $LogFile) {
        $LogFile = Join-Path $PSScriptRoot ("{0}.log" -f $script:foldername)
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $logMessage
    Write-Output $logMessage
}

# -------------------------
# Helpers: UI + TS
# -------------------------
function Initialize-UiAndTs {
    try {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Application]::EnableVisualStyles()
        Write-Log -Message 'Loaded WPF/WinForms assemblies.' -Level INFO
    } catch {
        Write-Log -Message "Failed to load UI assemblies. $_" -Level ERROR
        throw
    }

    try {
        if ($DevMode) {
            $script:TSEnvironment = $null
            Write-Log -Message 'DevMode: skipping TSEnvironment init.' -Level INFO
        } else {
            $script:TSEnvironment = New-Object -ComObject Microsoft.SMS.TSEnvironment -ErrorAction Stop
            Write-Log -Message 'Initialized Microsoft.SMS.TSEnvironment.' -Level INFO
        }
    } catch {
        $script:TSEnvironment = $null
        Write-Log -Message "Task Sequence environment is not loaded, assuming dev. $_" -Level WARN
    }
}

function Sanitize-Xaml {
    param([Parameter(Mandatory)][string]$Xaml)
    $san = $Xaml
    $san = $san -replace '\s+x:Class="[^"]+"', ''
    $san = $san -replace 'openxmlformats\.affinity/markup-compatibility', 'openxmlformats.org/markup-compatibility'
    $san = $san -replace '\s+mc:Ignorable="[^"]*"', ''
    $san = $san -replace '\s+\w+\s*=\s*"{x:Null}"', ''
    $san = $san -replace 'x:Name=', 'Name='
    $san = $san -replace '\s+(SelectionChanged|TextChanged|Checked|Click|Selected)="[^"]*"', ''
    return $san
}

function Build-FormFromXaml {
    param([Parameter(Mandatory)][string]$SanitizedXaml)
    try {
        [xml]$xml = $SanitizedXaml
        $reader   = New-Object System.Xml.XmlNodeReader $xml
        $form     = [Windows.Markup.XamlReader]::Load($reader)
        $script:Form = $form
        $xml.SelectNodes("//*[@Name]") | ForEach-Object {
            $n   = $_.Name
            $ctl = $form.FindName($n)
            if ($null -ne $ctl) {
                New-Variable -Name $n -Value $ctl -Scope Script -Force
                New-Variable -Name ("WPF{0}" -f $n) -Value $ctl -Scope Script -Force
            }
        }
        Write-Log -Message 'WPF controls bound to variables (with and without WPF* prefix).' -Level INFO
    } catch {
        Write-Log -Message "Failed to build WPF Form. $_" -Level ERROR
        throw
    }
}

function Set-TSVariable {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    if ($null -ne $script:TSEnvironment) {
        try {
            $script:TSEnvironment.Value($Name) = $Value
            Write-Log -Message "Set TS variable `${Name}=${Value}" -Level INFO
        } catch {
            Write-Log -Message "Failed to set TS variable `${Name}. $_" -Level ERROR
            throw
        }
    } else {
        Write-Log -Message "Dev/Test: would set TS var `${Name}=${Value}" -Level INFO
    }
}

function Initialize-Defaults {
    if (-not $ResetTS) { return }
    Set-TSVariable -Name 'OSDWin11Image'    -Value 'False'
    Set-TSVariable -Name 'OSDWin10Image'    -Value 'False'
    Set-TSVariable -Name 'OSDOfficeInclude' -Value 'False'
    Set-TSVariable -Name 'Office'           -Value ''
    Set-TSVariable -Name 'Type'             -Value ''
    Set-TSVariable -Name 'Affinity'         -Value ''
    Set-TSVariable -Name 'Shared'           -Value ''
    Set-TSVariable -Name 'OSDClientType'    -Value ''
    Set-TSVariable -Name 'OSDAffinity'      -Value ''
    Set-TSVariable -Name 'OSDShared'        -Value ''
    Write-Log -Message 'ResetTS applied: cleared relevant TS variables.' -Level INFO
}

function Invoke-SelfTest {
    try {
        Write-Log -Message ("SelfTest: DevMode={0}, TS={1}" -f $DevMode.IsPresent, ($null -ne $script:TSEnvironment)) -Level INFO
        Write-Log -Message ("Control TypeText: " + ($TypeTextBlock.GetType().FullName)) -Level INFO
        Write-Log -Message ("Control AffinityComboBox: " + ($AffinityComboBox.GetType().FullName)) -Level INFO
        Write-Log -Message ("Control RunButton: " + ($RunButton.GetType().FullName)) -Level INFO
    } catch {
        Write-Log -Message "SelfTest failed: $_" -Level WARN
    }
}

# --- Secret Win mode override ---
$script:WinOverride = 'Win11'
function Set-WinMode {
    param([ValidateSet('Win11','Win10')]$Mode)
    $script:WinOverride = $Mode
    if ($Mode -eq 'Win10') {
        $Win10RadioButton.IsEnabled = $true
        $Win10RadioButton.IsChecked = $true
        $Win11RadioButton.IsChecked = $false
        $Win11RadioButton.IsEnabled = $false
        Write-Log -Message 'Win10 override activated via hotkey.' -Level WARN
    } else {
        $Win11RadioButton.IsEnabled = $true
        $Win11RadioButton.IsChecked = $true
        $Win10RadioButton.IsChecked = $false
        $Win10RadioButton.IsEnabled = $false
        Write-Log -Message 'Win mode set to Win11 (locked).' -Level INFO
    }
}

# -------------------------
# Helpers: Config
# -------------------------
function Get-EffectiveConfigPath {
    if ($ConfigPath) { return $ConfigPath }
    try {
        if ($script:TSEnvironment -and $script:TSEnvironment.Value("OSDFormConfigPath")) {
            return $script:TSEnvironment.Value("OSDFormConfigPath")
        }
    } catch {}
    if ($env:OSD_FORM_CONFIG) { return $env:OSD_FORM_CONFIG }
    return (Join-Path -Path $PSScriptRoot -ChildPath "OSDForm.config.json")
}

# Utility to ensure nested property exists on PSCustomObject or Hashtable
function Ensure-NestedProperty {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object]$DefaultValue
    )
    if ($Object -is [hashtable]) {
        if (-not $Object.ContainsKey($Name)) { $Object[$Name] = $DefaultValue }
        return
    }
    # PSCustomObject or other PSObject
    $propNames = @()
    try { $propNames = $Object.PSObject.Properties.Name } catch { $propNames = @() }
    if ($propNames -notcontains $Name) {
        try { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $DefaultValue -Force } catch {}
    }
}

function Read-Config {
    $path = Get-EffectiveConfigPath
    try {
        if (Test-Path -LiteralPath $path) {
            $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
                Write-Log -Message "Loaded config: ${path}" -Level INFO
                return $cfg
            }
        }
        Write-Log -Message "Config not found or empty: ${path}" -Level ERROR
    } catch {
        Write-Log -Message "Config read/parse error at ${path}. $_" -Level ERROR
    }
    return $null
}

function Assert-Config {
    param([Parameter(Mandatory)]$Config)
    $errors = @()

    if (-not $Config.types -or $Config.types.Count -eq 0) {
        $errors += "Config.types is required and must be a non-empty array."
    }
    if (-not $Config.shared -or -not $Config.shared.default -or $Config.shared.default.Count -eq 0) {
        $errors += "Config.shared.default is required and must be a non-empty array."
    }

    # Ensure rules object exists and is extensible
    if (-not $Config.rules) {
        $Config | Add-Member -NotePropertyName rules -NotePropertyValue ([PSCustomObject]@{}) -Force
    }

    # Defaults under rules (works for existing PSCustomObject or legacy hashtable)
    Ensure-NestedProperty -Object $Config.rules -Name 'lockWin11' -DefaultValue $true
    Ensure-NestedProperty -Object $Config.rules -Name 'allowWin10Hotkey' -DefaultValue $true
    Ensure-NestedProperty -Object $Config.rules -Name 'officeEnabledTypes' -DefaultValue @($Config.types)
    Ensure-NestedProperty -Object $Config.rules -Name 'postInstallOfficeNoticeTypes' -DefaultValue @()

    # Gesture compatibility: prefer singular; if only plural exists, take first
    $hasSingular = $false
    try { $hasSingular = ($Config.rules.PSObject.Properties.Name -contains 'win10OverrideGesture') } catch {}
    $hasPlural = $false
    try { $hasPlural = ($Config.rules.PSObject.Properties.Name -contains 'win10OverrideGestures') } catch {}

    if (-not $hasSingular -and $hasPlural) {
        $first = ""
        try {
            $list = $Config.rules.win10OverrideGestures
            if ($null -ne $list) {
                if ($list -is [System.Collections.IEnumerable]) {
                    $first = ($list | Select-Object -First 1)
                } else {
                    $first = [string]$list
                }
            }
        } catch {}
        if ([string]::IsNullOrWhiteSpace($first)) { $first = 'Ctrl+Shift+W' }
        Ensure-NestedProperty -Object $Config.rules -Name 'win10OverrideGesture' -DefaultValue $first
    }

    Ensure-NestedProperty -Object $Config.rules -Name 'win10OverrideGesture' -DefaultValue 'Ctrl+Shift+W'

    # UI strings
    if (-not $Config.ui) {
        $Config | Add-Member -NotePropertyName ui -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    if (-not $Config.ui.title) { Ensure-NestedProperty -Object $Config.ui -Name 'title' -DefaultValue 'Select deployment options' }
    if (-not $Config.ui.strings) {
        $Config.ui | Add-Member -NotePropertyName strings -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $defaults = @{
        typeLabel     = "Type"
        affinityLabel = "Business unit"
        sharedLabel   = "Shared device?"
        officeLabel   = "Install Microsoft 365 Apps?"
        windowsLabel  = "Choose Windows version"
        runButton     = "Start deployment"
    }
    foreach ($k in $defaults.Keys) {
        Ensure-NestedProperty -Object $Config.ui.strings -Name $k -DefaultValue $defaults[$k]
    }

    if ($errors.Count -gt 0) {
        $msg = "Configuration error:`n- " + ($errors -join "`n- ")
        [System.Windows.MessageBox]::Show($msg, 'OSDForm: Configuration error', 'OK') | Out-Null
        Write-Log -Message $msg -Level ERROR
        throw $msg
    }

    # Hoist for quick use
    $script:AffinityMap        = $Config.affinity
    $script:SharedMap          = $Config.shared
    $script:OfficeEnabledTypes = @($Config.rules.officeEnabledTypes)
    $script:LockWin11          = [bool]$Config.rules.lockWin11
    $script:AllowWin10Hotkey   = [bool]$Config.rules.allowWin10Hotkey
    $script:PostInstallOfficeNoticeTypes = @($Config.rules.postInstallOfficeNoticeTypes)
    $script:Win10OverrideGesture = [string]$Config.rules.win10OverrideGesture
    $script:UiStrings          = $Config.ui.strings
    return $Config
}

function Requires-SharedSelection {
    param([string]$Affinity)
    if ([string]::IsNullOrEmpty($Affinity)) { return $false }
    return ($script:SharedMap.PSObject.Properties.Name -contains $Affinity)
}

function Populate-TypeResource {
    param([Parameter(Mandatory)]$Config)
    [void]$Form.Resources.Remove("Type")
    [void]$Form.Resources.Add("Type", @($Config.types))
}

function Populate-SharedDefault {
    [void]$Form.Resources.Remove("Shared")
    [void]$Form.Resources.Add("Shared", @($script:SharedMap.default))
}

# -------------------------
# Simple gesture parsing (single gesture like "Ctrl+Shift+W")
# -------------------------
function Convert-ToModifierMask {
    param([string[]]$Modifiers)
    $mask = [System.Windows.Input.ModifierKeys]::None
    foreach ($m in $Modifiers) {
        switch ($m.Trim().ToLower()) {
            'ctrl'  { $mask = $mask -bor [System.Windows.Input.ModifierKeys]::Control }
            'shift' { $mask = $mask -bor [System.Windows.Input.ModifierKeys]::Shift }
            'alt'   { $mask = $mask -bor [System.Windows.Input.ModifierKeys]::Alt }
            'win'   { $mask = $mask -bor [System.Windows.Input.ModifierKeys]::Windows }
        }
    }
    return $mask
}

function Parse-SimpleGesture {
    param([Parameter(Mandatory)][string]$Gesture)
    $parts = $Gesture -split '\+'
    $key   = $parts[-1].Trim().ToUpper()
    $mods  = if ($parts.Count -gt 1) { Convert-ToModifierMask -Modifiers $parts[0..($parts.Count-2)] } else { [System.Windows.Input.ModifierKeys]::None }
    [pscustomobject]@{ KeyName = $key; Mods = $mods }
}

# -------------------------
# XAML (sanitized at runtime)
# -------------------------
$InputXML = @"
<Window x:Name="OSDFrontendHTA"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        Title="Device Customization" Height="420" Width="360" WindowStartupLocation="CenterScreen" Topmost="True" IsManipulationEnabled="False">
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="7*"/>
            <ColumnDefinition Width="103*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
            <RowDefinition Height="32*"/>
            <RowDefinition Height="65*"/>
            <RowDefinition Height="66*"/>
            <RowDefinition Height="200*"/>
        </Grid.RowDefinitions>

        <ComboBox Name="TypeComboBox"
                  HorizontalAlignment="Left" Margin="4,32,0,0" VerticalAlignment="Top" Width="300"
                  IsReadOnly="True"
                  ItemsSource="{DynamicResource Type}" Height="22" Grid.Column="1" Grid.RowSpan="2" />

        <ComboBox Name="SharedComboBox"
                  HorizontalAlignment="Left" VerticalAlignment="Top" Width="300"
                  IsReadOnly="True" Margin="4,64,0,0" Grid.Row="2" Height="22" Grid.Column="1"
                  ItemsSource="{DynamicResource Shared}" Grid.RowSpan="2" />

        <ComboBox Name="AffinityComboBox"
                  HorizontalAlignment="Left" Margin="4,65,0,0" VerticalAlignment="Top" Width="300"
                  IsReadOnly="True"
                  ItemsSource="{DynamicResource Affinity}" Height="22" Grid.Row="1" Grid.Column="1" Grid.RowSpan="2" />

        <TextBlock Name="OfficeTextBlock" HorizontalAlignment="Left" Margin="4,36,0,0" TextWrapping="Wrap"
                   VerticalAlignment="Top" Grid.Row="3" Height="16" Width="300" Grid.Column="1"/>

        <RadioButton GroupName="Office" Content="With" Name="RadioButton_Yes"
                     HorizontalAlignment="Left" Margin="4,56,0,0" VerticalAlignment="Top"
                     IsChecked="False" Grid.Row="3" Height="14" Width="60" Grid.Column="1"/>

        <RadioButton GroupName="Office" Content="Without" Name="RadioButton_No"
                     HorizontalAlignment="Left" Margin="70,56,0,0" VerticalAlignment="Top"
                     IsChecked="False" Grid.Row="3" Height="14" Width="70" Grid.Column="1"/>

        <RadioButton Name="Win10RadioButton" GroupName="Windows" IsChecked="False"
                     Grid.Column="1" Content="Windows 10" HorizontalAlignment="Left" Margin="4,108,0,0" Grid.Row="3" VerticalAlignment="Top"/>
        <RadioButton Name="Win11RadioButton" GroupName="Windows" IsChecked="True"
                     Grid.Column="1" Content="Windows 11" HorizontalAlignment="Left" Margin="4,123,0,0" Grid.Row="3" VerticalAlignment="Top"/>

        <TextBlock Name="WindowsTextBlock" Grid.Column="1" HorizontalAlignment="Left" Margin="4,92,0,0"
                   Grid.Row="3" TextWrapping="Wrap" Text="Choose Windows version" VerticalAlignment="Top"/>

        <Button Name="RunButton" HorizontalAlignment="Left" Margin="100,160,0,0" VerticalAlignment="Top"
                Height="34" Width="140" Grid.Row="3" Grid.Column="1" Content="Start deployment" />

        <TextBlock Name="AffinityTextBlock" HorizontalAlignment="Left" Margin="4,47,0,2" TextWrapping="Wrap"
                   Text="Business unit" Grid.Row="1" Grid.Column="1"/>
        <TextBlock Name="TypeTextBlock" Margin="4,13,0,3" TextWrapping="Wrap" Text="Type" Grid.Column="1" HorizontalAlignment="Left"/>
        <TextBlock Name="SharedTextBlock" HorizontalAlignment="Left" Margin="4,47,0,3" TextWrapping="Wrap"
                   Text="Shared device?" Grid.Row="2" Grid.Column="1"/>
    </Grid>
</Window>
"@

# -------------------------
# Main
# -------------------------
try {
    Initialize-UiAndTs
    Initialize-Defaults

    $sanitized = Sanitize-Xaml -Xaml $InputXML
    Build-FormFromXaml -SanitizedXaml $sanitized

    # Load & validate config (mandatory)
    $Config = Read-Config
    if ($null -eq $Config) { return }
    $Config = Assert-Config -Config $Config  # throws with message box if invalid

    # --- UI texts ---
    $Form.Title             = $Config.ui.title
    $TypeTextBlock.Text     = $Config.ui.strings.typeLabel
    $AffinityTextBlock.Text = $Config.ui.strings.affinityLabel
    $SharedTextBlock.Text   = $Config.ui.strings.sharedLabel
    $OfficeTextBlock.Text   = $Config.ui.strings.officeLabel
    $WindowsTextBlock.Text  = $Config.ui.strings.windowsLabel
    $RunButton.Content      = $Config.ui.strings.runButton

    # --- Initial state ---
    $SharedComboBox.IsEnabled   = $false
    $AffinityComboBox.IsEnabled = $false
    if ($Config.rules.lockWin11) { Set-WinMode -Mode 'Win11' } else { Set-WinMode -Mode 'Win11' } # adjustable later

    # --- Resources from config ---
    Populate-TypeResource -Config $Config
    Populate-SharedDefault

    # --- Type change handler (config-driven) ---
    $TypeComboBox.Add_SelectionChanged({
        [void]$Form.Resources.Remove("Affinity")
        $AffinityComboBox.IsEnabled = $false
        $SharedComboBox.SelectedIndex = -1
        $SharedComboBox.IsEnabled = $false

        $RadioButton_Yes.IsChecked = $false
        $RadioButton_No.IsChecked  = $false

        $selectedType = [string]$TypeComboBox.SelectedItem

        # Affinity list for selected type
        if ($script:AffinityMap -and $script:AffinityMap.PSObject.Properties.Name -contains $selectedType) {
            $affList = @($script:AffinityMap.$selectedType)
            if ($affList.Count -gt 0) {
                [void]$Form.Resources.Add("Affinity", $affList)
                $AffinityComboBox.IsEnabled = $true
            }
        }

        # Office enabled only for configured types
        $officeEnabled = $script:OfficeEnabledTypes -contains $selectedType
        $RadioButton_Yes.IsEnabled = $officeEnabled
        $RadioButton_No.IsEnabled  = $officeEnabled
        if ($officeEnabled) { $RadioButton_Yes.IsChecked = $true }

        # Re-apply Windows mode (preserve secret Win10 override)
        if ($script:WinOverride -eq 'Win10') { Set-WinMode -Mode 'Win10' } else { Set-WinMode -Mode 'Win11' }
    })

    # --- Affinity change handler (controls Shared) ---
    $AffinityComboBox.Add_SelectionChanged({
        $selectedAffinity = [string]$AffinityComboBox.SelectedItem
        [void]$Form.Resources.Remove("Shared")

        if ($script:SharedMap -and $script:SharedMap.PSObject.Properties.Name -contains $selectedAffinity) {
            [void]$Form.Resources.Add("Shared", @($script:SharedMap.$selectedAffinity))
            $SharedComboBox.IsEnabled   = $true
            $SharedComboBox.SelectedIndex = -1
        } else {
            [void]$Form.Resources.Add("Shared", @($script:SharedMap.default))
            $SharedComboBox.IsEnabled   = $false
            $SharedComboBox.SelectedIndex = -1
        }
    })

    # --- Secret hotkey: single simple gesture (PreviewKeyDown only) ---
    if ($script:AllowWin10Hotkey -and -not [string]::IsNullOrWhiteSpace($script:Win10OverrideGesture)) {
        $g = Parse-SimpleGesture -Gesture $script:Win10OverrideGesture
        $Form.Add_PreviewKeyDown({
            if (($_.KeyboardDevice.Modifiers -eq $g.Mods) -and ($_.Key.ToString().ToUpper() -eq $g.KeyName)) {
                Set-WinMode -Mode 'Win10'
                $_.Handled = $true
            }
        })
        Write-Log -Message ("Registered Win10 override gesture: " + $script:Win10OverrideGesture) -Level INFO
    }

    Invoke-SelfTest

    # --- Dev presets (if any) ---
    if ($DevMode) {
        if ($PresetType)      { $TypeComboBox.SelectedItem     = $PresetType }
        if ($PresetAffinity)  { $AffinityComboBox.SelectedItem = $PresetAffinity }
        if ($PresetShared)    { $SharedComboBox.SelectedItem   = $PresetShared }
        if ($PresetOffice) {
            if ($PresetOffice -eq 'With') { $RadioButton_Yes.IsChecked = $true } else { $RadioButton_No.IsChecked = $true }
        }
        if ($PresetWin11) { Set-WinMode -Mode 'Win11' }
        Write-Log -Message 'Applied Dev presets.' -Level INFO
    }

    # --- Run button ---
    $RunButton.Add_Click({
        if ([string]::IsNullOrEmpty([string]$TypeComboBox.SelectedItem)) {
            [System.Windows.MessageBox]::Show("Please choose a device type.", 'Select Type', 'OK') | Out-Null
            return
        }
        $type     = [string]$TypeComboBox.SelectedItem
        $affinity = [string]$AffinityComboBox.SelectedItem
        $shared   = [string]$SharedComboBox.SelectedItem

        # If config defines affinity groups for the type, require a choice
        if ($script:AffinityMap -and $script:AffinityMap.PSObject.Properties.Name -contains $type) {
            if ([string]::IsNullOrEmpty($affinity)) {
                [System.Windows.MessageBox]::Show("Please choose a business unit.", 'Select Business Unit', 'OK') | Out-Null
                return
            }
        }

        # Require "shared" choice only when config defines specific options for this affinity
        if (Requires-SharedSelection -Affinity $affinity) {
            if ([string]::IsNullOrEmpty($shared)) {
                [System.Windows.MessageBox]::Show("Please specify if this is a shared device.", 'Shared Device', 'OK') | Out-Null
                return
            }
        }

        $officeStr = if ($RadioButton_Yes.IsChecked) { "With Microsoft 365 Apps" } elseif ($RadioButton_No.IsChecked) { "Without Microsoft 365 Apps" } else { "" }
        $winStr    = if ($script:WinOverride -eq 'Win10') { 'Windows 10' } else { 'Windows 11' }

        # Optional notice for certain types when "Without"
        if (($script:PostInstallOfficeNoticeTypes -contains $type) -and $RadioButton_No.IsChecked) {
            $msg = @"
This device will be configured as:
  * Type: ${type}
  * Business unit: ${affinity}
  * Microsoft 365 Apps: Not preinstalled
  NOTE: Apps will be installed later by policy.

Click 'Cancel' to adjust your choices or 'OK' to continue.
"@
            $ans = [System.Windows.MessageBox]::Show($msg, 'Confirm Selection', 'OKCancel')
            if ($ans -ne 'OK') { return }
        } else {
            $msg = @"
This device will be configured as:
  * Type: ${type}
  * Business unit: ${affinity}
  * ${officeStr}
  * ${winStr}

Click 'Cancel' to adjust your choices or 'OK' to continue.
"@
            $ans = [System.Windows.MessageBox]::Show($msg, 'Confirm Selection', 'OKCancel')
            if ($ans -ne 'OK') { return }
        }

        Write-Log -Message ("Confirmed: Type={0}, BusinessUnit={1}, Shared={2}, Office={3}, WinMode={4}" -f $type,$affinity,$shared,$officeStr,$script:WinOverride) -Level INFO

        try {
            # TS variables
            if ($type)     { Set-TSVariable -Name 'OSDClientType' -Value $type }
            if ($affinity) { Set-TSVariable -Name 'OSDAffinity' -Value $affinity }
            if ($shared)   { Set-TSVariable -Name 'OSDShared' -Value $shared }

            if ($officeStr) { Set-TSVariable -Name 'Office' -Value $officeStr }
            Set-TSVariable -Name 'OSDOfficeInclude' -Value (($RadioButton_Yes.IsChecked) -as [bool]).ToString()

            if ($script:WinOverride -eq 'Win10') {
                Set-TSVariable -Name 'OSDWin11Image' -Value 'False'
                Set-TSVariable -Name 'OSDWin10Image' -Value 'True'
            } else {
                Set-TSVariable -Name 'OSDWin11Image' -Value 'True'
                Set-TSVariable -Name 'OSDWin10Image' -Value 'False'
            }
        } finally {
            $Form.Close()
        }
    })

    [void]$Form.ShowDialog()
}
catch {
    Write-Log -Message "Unhandled error: $_" -Level ERROR
    throw
}
