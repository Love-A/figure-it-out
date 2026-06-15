# Start-OSDForm.ps1
<#
.SYNOPSIS
    GUI to select deployment options during a ConfigMgr Task Sequence.

.DESCRIPTION
    WPF/XAML UI driven by external JSON config:
      - types (device roles)
      - affinity (business units per type)
      - shared (shared device options; default + optional per-affinity overrides)
      - rules (e.g., officeEnabledTypes, lockWin11, allowWin10Hotkey, win10OverrideGesture, postInstallOfficeNoticeTypes)
      - ui (title, labels, and dialog messages)
    No hardcoded choice lists in code - everything comes from JSON.

    The technician's choices are written back as Task Sequence variables (see README).

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

    Exit codes:
      0  Completed (technician confirmed) OR cancelled (window closed) - GUI ran successfully.
      1  Unhandled error.
      3  Configuration error (missing/invalid/unreadable config).
    The TS variable 'OSDFormResult' is set to 'Completed' or 'Cancelled' so the
    Task Sequence can branch on whether the technician confirmed a selection.

.VERSION
    2026-06-15 - 4.0.0-en - Full refactor:
                            * Fixed Write-Log pipeline leak (functions returned arrays).
                            * lockWin11 now actually unlocks the Win10 choice when false.
                            * Missing/invalid config now hard-fails the step (exit 3) instead of
                              silently continuing the Task Sequence.
                            * UTF-8 encoding for config read and log write.
                            * Exit-code + OSDFormResult contract for the Task Sequence.
                            * All dialog texts moved to config (ui.messages) with English defaults.
                            * Clean StackPanel layout: auto-sizing, NoResize, default/cancel buttons.
                            * Approved PowerShell verbs throughout.
    Previous:
    2025-08-18 - 3.2.1-en - Robust defaulting for PSCustomObject/hashtable config; legacy plural gesture.
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
# Exit codes
# -------------------------
$script:ExitSuccess = 0
$script:ExitError   = 1
$script:ExitConfig  = 3

# -------------------------
# Logging
# -------------------------
$script:foldername = 'OSDForm'
$script:LogFile    = $null

function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )
    if (-not $script:LogFile) {
        $script:LogFile = Join-Path $PSScriptRoot ("{0}.log" -f $script:foldername)
    }
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    try {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Never let logging break the tool: fall back to %TEMP%
        try {
            $script:LogFile = Join-Path $env:TEMP ("{0}.log" -f $script:foldername)
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
    }
    # Console only (host stream) - does NOT pollute the success/pipeline stream.
    Write-Host $line
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

function ConvertTo-SafeXaml {
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

function New-FormFromXaml {
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
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    if ($null -ne $script:TSEnvironment) {
        try {
            $script:TSEnvironment.Value($Name) = $Value
            Write-Log -Message "Set TS variable $Name = $Value" -Level INFO
        } catch {
            Write-Log -Message "Failed to set TS variable $Name. $_" -Level ERROR
            throw
        }
    } else {
        Write-Log -Message "Dev/Test: would set TS var $Name = $Value" -Level INFO
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
    Set-TSVariable -Name 'OSDFormResult'    -Value ''
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

# --- Windows version mode ---
# Locked mode: only one radio is selectable (the other is disabled).
# Unlocked mode (lockWin11=false): both radios are enabled and the technician chooses.
function Set-WinMode {
    param(
        [ValidateSet('Win11','Win10')]$Mode,
        [switch]$Lock
    )
    if ($Mode -eq 'Win10') {
        $Win10RadioButton.IsEnabled = $true
        $Win10RadioButton.IsChecked = $true
        $Win11RadioButton.IsChecked = $false
        $Win11RadioButton.IsEnabled = -not $Lock
        Write-Log -Message ("Windows version set to Win10{0}." -f $(if ($Lock) {' (locked)'} else {''})) -Level INFO
    } else {
        $Win11RadioButton.IsEnabled = $true
        $Win11RadioButton.IsChecked = $true
        $Win10RadioButton.IsChecked = $false
        $Win10RadioButton.IsEnabled = -not $Lock
        Write-Log -Message ("Windows version set to Win11{0}." -f $(if ($Lock) {' (locked)'} else {''})) -Level INFO
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

# Ensure a property exists on a PSCustomObject or Hashtable (does not overwrite existing values)
function Set-DefaultProperty {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()][object]$DefaultValue
    )
    if ($Object -is [hashtable]) {
        if (-not $Object.ContainsKey($Name)) { $Object[$Name] = $DefaultValue }
        return
    }
    $propNames = @()
    try { $propNames = $Object.PSObject.Properties.Name } catch { $propNames = @() }
    if ($propNames -notcontains $Name) {
        try { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $DefaultValue -Force } catch {}
    }
}

# Show a configuration error to the technician, flag it, and stop the script.
function Stop-WithConfigError {
    param([Parameter(Mandatory)][string]$Message)
    $script:ConfigFailed = $true
    Write-Log -Message $Message -Level ERROR
    try {
        [System.Windows.MessageBox]::Show($Message, 'OSDForm: Configuration error', 'OK') | Out-Null
    } catch {}
    throw $Message
}

function Read-Config {
    $path = Get-EffectiveConfigPath
    try {
        if (-not (Test-Path -LiteralPath $path)) {
            Stop-WithConfigError -Message "Config not found: $path"
        }
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Stop-WithConfigError -Message "Config is empty: $path"
        }
        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
        Write-Log -Message "Loaded config: $path" -Level INFO
        return $cfg
    } catch {
        if ($script:ConfigFailed) { throw }   # already reported by Stop-WithConfigError
        Stop-WithConfigError -Message "Config read/parse error at ${path}: $_"
    }
}

function Confirm-Config {
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

    # Defaults under rules (works for PSCustomObject or legacy hashtable)
    Set-DefaultProperty -Object $Config.rules -Name 'lockWin11' -DefaultValue $true
    Set-DefaultProperty -Object $Config.rules -Name 'allowWin10Hotkey' -DefaultValue $true
    Set-DefaultProperty -Object $Config.rules -Name 'officeEnabledTypes' -DefaultValue @($Config.types)
    Set-DefaultProperty -Object $Config.rules -Name 'postInstallOfficeNoticeTypes' -DefaultValue @()

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
                if ($list -is [System.Collections.IEnumerable] -and $list -isnot [string]) {
                    $first = ($list | Select-Object -First 1)
                } else {
                    $first = [string]$list
                }
            }
        } catch {}
        if ([string]::IsNullOrWhiteSpace($first)) { $first = 'Ctrl+Shift+W' }
        Set-DefaultProperty -Object $Config.rules -Name 'win10OverrideGesture' -DefaultValue $first
    }
    Set-DefaultProperty -Object $Config.rules -Name 'win10OverrideGesture' -DefaultValue 'Ctrl+Shift+W'

    # UI block
    if (-not $Config.ui) {
        $Config | Add-Member -NotePropertyName ui -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    Set-DefaultProperty -Object $Config.ui -Name 'title' -DefaultValue 'Select deployment options'

    # UI label strings
    if (-not $Config.ui.strings) {
        $Config.ui | Add-Member -NotePropertyName strings -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $labelDefaults = @{
        typeLabel     = "Type"
        affinityLabel = "Business unit"
        sharedLabel   = "Shared device?"
        officeLabel   = "Install Microsoft 365 Apps?"
        windowsLabel  = "Choose Windows version"
        runButton     = "Start deployment"
        cancelButton  = "Cancel"
        officeWith    = "With"
        officeWithout = "Without"
    }
    foreach ($k in $labelDefaults.Keys) {
        Set-DefaultProperty -Object $Config.ui.strings -Name $k -DefaultValue $labelDefaults[$k]
    }

    # UI dialog messages (previously hardcoded in English)
    if (-not $Config.ui.messages) {
        $Config.ui | Add-Member -NotePropertyName messages -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $messageDefaults = @{
        selectTypePrompt       = "Please choose a device type."
        selectTypeTitle        = "Select type"
        selectAffinityPrompt   = "Please choose a business unit."
        selectAffinityTitle    = "Select business unit"
        selectSharedPrompt     = "Please specify if this is a shared device."
        selectSharedTitle      = "Shared device"
        confirmTitle           = "Confirm selection"
        confirmIntro           = "This device will be configured as:"
        confirmFooter          = "Click 'Cancel' to adjust your choices or 'OK' to continue."
        officeNotInstalledNote = "Microsoft 365 Apps: Not preinstalled (installed later by policy)."
        writeErrorMessage      = "Failed to write Task Sequence variables. See OSDForm.log for details."
        writeErrorTitle        = "OSDForm: Error"
    }
    foreach ($k in $messageDefaults.Keys) {
        Set-DefaultProperty -Object $Config.ui.messages -Name $k -DefaultValue $messageDefaults[$k]
    }

    if ($errors.Count -gt 0) {
        $msg = "Configuration error:`n- " + ($errors -join "`n- ")
        Stop-WithConfigError -Message $msg
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
    $script:Messages           = $Config.ui.messages
    return $Config
}

function Test-SharedSelectionRequired {
    param([string]$Affinity)
    if ([string]::IsNullOrEmpty($Affinity)) { return $false }
    return ($script:SharedMap.PSObject.Properties.Name -contains $Affinity)
}

function Set-TypeResource {
    param([Parameter(Mandatory)]$Config)
    [void]$Form.Resources.Remove("Type")
    [void]$Form.Resources.Add("Type", @($Config.types))
}

function Set-SharedDefaultResource {
    [void]$Form.Resources.Remove("Shared")
    [void]$Form.Resources.Add("Shared", @($script:SharedMap.default))
}

# -------------------------
# Simple gesture parsing (single gesture like "Ctrl+Shift+W")
# -------------------------
function ConvertTo-ModifierMask {
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

function ConvertFrom-Gesture {
    param([Parameter(Mandatory)][string]$Gesture)
    $parts = $Gesture -split '\+'
    $key   = $parts[-1].Trim().ToUpper()
    $mods  = if ($parts.Count -gt 1) { ConvertTo-ModifierMask -Modifiers $parts[0..($parts.Count-2)] } else { [System.Windows.Input.ModifierKeys]::None }
    [pscustomobject]@{ KeyName = $key; Mods = $mods }
}

# -------------------------
# XAML (sanitized at runtime)
# -------------------------
$InputXML = @"
<Window x:Name="OSDFrontend"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        Title="Device Customization"
        Width="400" SizeToContent="Height" MinHeight="300"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize" WindowStyle="SingleBorderWindow"
        ShowInTaskbar="False" Topmost="True">
    <Border Padding="18" Background="#FFFFFF">
        <StackPanel>
            <TextBlock Name="HeaderTextBlock" Text="Select deployment options"
                       FontSize="16" FontWeight="SemiBold" Margin="0,0,0,14" TextWrapping="Wrap"/>

            <TextBlock Name="TypeTextBlock" Text="Type" Margin="0,0,0,3"/>
            <ComboBox  Name="TypeComboBox" IsReadOnly="True" Height="26" Margin="0,0,0,12"
                       ItemsSource="{DynamicResource Type}"/>

            <TextBlock Name="AffinityTextBlock" Text="Business unit" Margin="0,0,0,3"/>
            <ComboBox  Name="AffinityComboBox" IsReadOnly="True" Height="26" Margin="0,0,0,12"
                       ItemsSource="{DynamicResource Affinity}"/>

            <TextBlock Name="SharedTextBlock" Text="Shared device?" Margin="0,0,0,3"/>
            <ComboBox  Name="SharedComboBox" IsReadOnly="True" Height="26" Margin="0,0,0,12"
                       ItemsSource="{DynamicResource Shared}"/>

            <TextBlock Name="OfficeTextBlock" Text="Install Microsoft 365 Apps?" Margin="0,0,0,5" TextWrapping="Wrap"/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                <RadioButton Name="RadioButton_Yes" GroupName="Office" Content="With" Margin="0,0,18,0" VerticalAlignment="Center"/>
                <RadioButton Name="RadioButton_No"  GroupName="Office" Content="Without" VerticalAlignment="Center"/>
            </StackPanel>

            <TextBlock Name="WindowsTextBlock" Text="Choose Windows version" Margin="0,0,0,5" TextWrapping="Wrap"/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,18">
                <RadioButton Name="Win11RadioButton" GroupName="Windows" Content="Windows 11" IsChecked="True" Margin="0,0,18,0" VerticalAlignment="Center"/>
                <RadioButton Name="Win10RadioButton" GroupName="Windows" Content="Windows 10" VerticalAlignment="Center"/>
            </StackPanel>

            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button Name="CancelButton" Content="Cancel" Width="90" Height="32" Margin="0,0,10,0" IsCancel="True"/>
                <Button Name="RunButton" Content="Start deployment" Width="150" Height="32" IsDefault="True"/>
            </StackPanel>
        </StackPanel>
    </Border>
</Window>
"@

# -------------------------
# Main
# -------------------------
$script:Completed    = $false
$script:ConfigFailed = $false
$exitCode            = $script:ExitSuccess

try {
    Initialize-UiAndTs
    Initialize-Defaults

    $sanitized = ConvertTo-SafeXaml -Xaml $InputXML
    New-FormFromXaml -SanitizedXaml $sanitized

    # Load & validate config (mandatory; throws -> exit 3 on failure)
    $Config = Read-Config
    $Config = Confirm-Config -Config $Config

    # --- UI texts ---
    $Form.Title             = $Config.ui.title
    $HeaderTextBlock.Text    = $Config.ui.title
    $TypeTextBlock.Text     = $Config.ui.strings.typeLabel
    $AffinityTextBlock.Text = $Config.ui.strings.affinityLabel
    $SharedTextBlock.Text   = $Config.ui.strings.sharedLabel
    $OfficeTextBlock.Text   = $Config.ui.strings.officeLabel
    $WindowsTextBlock.Text  = $Config.ui.strings.windowsLabel
    $RunButton.Content      = $Config.ui.strings.runButton
    $CancelButton.Content   = $Config.ui.strings.cancelButton
    $RadioButton_Yes.Content = $Config.ui.strings.officeWith
    $RadioButton_No.Content  = $Config.ui.strings.officeWithout

    # --- Initial state ---
    $SharedComboBox.IsEnabled   = $false
    $AffinityComboBox.IsEnabled = $false
    if ($script:LockWin11) {
        Set-WinMode -Mode 'Win11' -Lock      # Win11 only; Win10 reachable via hotkey
    } else {
        Set-WinMode -Mode 'Win11'            # both enabled, technician chooses
    }

    # --- Resources from config ---
    Set-TypeResource -Config $Config
    Set-SharedDefaultResource

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

    # --- Win10 override gesture: single simple gesture (PreviewKeyDown only) ---
    if ($script:AllowWin10Hotkey -and -not [string]::IsNullOrWhiteSpace($script:Win10OverrideGesture)) {
        $g = ConvertFrom-Gesture -Gesture $script:Win10OverrideGesture
        $Form.Add_PreviewKeyDown({
            if (($_.KeyboardDevice.Modifiers -eq $g.Mods) -and ($_.Key.ToString().ToUpper() -eq $g.KeyName)) {
                Set-WinMode -Mode 'Win10' -Lock
                Write-Log -Message 'Win10 override activated via hotkey.' -Level WARN
                $_.Handled = $true
            }
        })
        Write-Log -Message ("Registered Win10 override gesture: " + $script:Win10OverrideGesture) -Level INFO
    }

    Invoke-SelfTest

    # --- Dev presets (if any) ---
    if ($DevMode) {
        if ($PresetType) {
            if (@($Config.types) -notcontains $PresetType) {
                Write-Log -Message "PresetType '$PresetType' is not in config.types." -Level WARN
            }
            $TypeComboBox.SelectedItem = $PresetType
        }
        if ($PresetAffinity)  { $AffinityComboBox.SelectedItem = $PresetAffinity }
        if ($PresetShared)    { $SharedComboBox.SelectedItem   = $PresetShared }
        if ($PresetOffice) {
            if ($PresetOffice -eq 'With') { $RadioButton_Yes.IsChecked = $true } else { $RadioButton_No.IsChecked = $true }
        }
        if ($PresetWin11) { if ($script:LockWin11) { Set-WinMode -Mode 'Win11' -Lock } else { Set-WinMode -Mode 'Win11' } }
        Write-Log -Message 'Applied Dev presets.' -Level INFO
    }

    # --- Run button ---
    $RunButton.Add_Click({
        $m = $script:Messages

        if ([string]::IsNullOrEmpty([string]$TypeComboBox.SelectedItem)) {
            [System.Windows.MessageBox]::Show($m.selectTypePrompt, $m.selectTypeTitle, 'OK') | Out-Null
            return
        }
        $type     = [string]$TypeComboBox.SelectedItem
        $affinity = [string]$AffinityComboBox.SelectedItem
        $shared   = [string]$SharedComboBox.SelectedItem

        # If config defines affinity groups for the type, require a choice
        if ($script:AffinityMap -and $script:AffinityMap.PSObject.Properties.Name -contains $type) {
            if ([string]::IsNullOrEmpty($affinity)) {
                [System.Windows.MessageBox]::Show($m.selectAffinityPrompt, $m.selectAffinityTitle, 'OK') | Out-Null
                return
            }
        }

        # Require "shared" choice only when config defines specific options for this affinity
        if (Test-SharedSelectionRequired -Affinity $affinity) {
            if ([string]::IsNullOrEmpty($shared)) {
                [System.Windows.MessageBox]::Show($m.selectSharedPrompt, $m.selectSharedTitle, 'OK') | Out-Null
                return
            }
        }

        $officeStr = if ($RadioButton_Yes.IsChecked) { "With Microsoft 365 Apps" }
                     elseif ($RadioButton_No.IsChecked) { "Without Microsoft 365 Apps" }
                     else { "" }
        $winIsTen  = ($Win10RadioButton.IsChecked -eq $true)
        $winStr    = if ($winIsTen) { 'Windows 10' } else { 'Windows 11' }

        # --- Confirmation summary ---
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add(("  * {0}: {1}" -f $script:UiStrings.typeLabel, $type))
        if ($affinity) { $lines.Add(("  * {0}: {1}" -f $script:UiStrings.affinityLabel, $affinity)) }
        if ($shared)   { $lines.Add(("  * {0}: {1}" -f $script:UiStrings.sharedLabel, $shared)) }

        $noticeCase = ($script:PostInstallOfficeNoticeTypes -contains $type) -and ($RadioButton_No.IsChecked -eq $true)
        if ($noticeCase)        { $lines.Add("  * " + $m.officeNotInstalledNote) }
        elseif ($officeStr)     { $lines.Add("  * " + $officeStr) }
        $lines.Add("  * " + $winStr)

        $body = $m.confirmIntro + "`n" + ($lines -join "`n") + "`n`n" + $m.confirmFooter
        $ans  = [System.Windows.MessageBox]::Show($body, $m.confirmTitle, 'OKCancel')
        if ($ans -ne 'OK') { return }

        Write-Log -Message ("Confirmed: Type={0}, BusinessUnit={1}, Shared={2}, Office={3}, Windows={4}" -f $type,$affinity,$shared,$officeStr,$winStr) -Level INFO

        try {
            # Legacy + new TS variables
            if ($type)     { Set-TSVariable -Name 'Type' -Value $type;         Set-TSVariable -Name 'OSDClientType' -Value $type }
            if ($affinity) { Set-TSVariable -Name 'Affinity' -Value $affinity; Set-TSVariable -Name 'OSDAffinity'   -Value $affinity }
            if ($shared)   { Set-TSVariable -Name 'Shared' -Value $shared;     Set-TSVariable -Name 'OSDShared'     -Value $shared }

            if ($officeStr) { Set-TSVariable -Name 'Office' -Value $officeStr }
            Set-TSVariable -Name 'OSDOfficeInclude' -Value ([bool]$RadioButton_Yes.IsChecked).ToString()

            if ($winIsTen) {
                Set-TSVariable -Name 'OSDWin11Image' -Value 'False'
                Set-TSVariable -Name 'OSDWin10Image' -Value 'True'
            } else {
                Set-TSVariable -Name 'OSDWin11Image' -Value 'True'
                Set-TSVariable -Name 'OSDWin10Image' -Value 'False'
            }

            $script:Completed = $true
        } catch {
            Write-Log -Message "Failed to write TS variables: $_" -Level ERROR
            [System.Windows.MessageBox]::Show($m.writeErrorMessage, $m.writeErrorTitle, 'OK') | Out-Null
            return   # keep the form open so the technician can retry or cancel
        }

        $Form.Close()
    })

    [void]$Form.ShowDialog()

    if ($script:Completed) {
        Set-TSVariable -Name 'OSDFormResult' -Value 'Completed'
        Write-Log -Message 'OSDForm completed (technician confirmed a selection).' -Level INFO
        $exitCode = $script:ExitSuccess
    } else {
        Set-TSVariable -Name 'OSDFormResult' -Value 'Cancelled'
        Write-Log -Message 'OSDForm closed without confirmation (cancelled).' -Level WARN
        $exitCode = $script:ExitSuccess   # step still succeeds; TS can branch on OSDFormResult
    }
}
catch {
    Write-Log -Message "Unhandled error: $_" -Level ERROR
    $exitCode = if ($script:ConfigFailed) { $script:ExitConfig } else { $script:ExitError }
}

exit $exitCode
