<#
.SYNOPSIS
    Package an application and publish it to Intune — a guided GUI on top of
    Build-IntuneWinApp + Publish-IntuneWinApp.

.DESCRIPTION
    Opens on a start screen with two choices: create a new package from a vendor
    installer (guided wizard), or open a package folder you already have. Everything
    the Intune app will contain is shown as an editable, live preview with a per-field
    tag telling you where each value came from (app.json / PSADT / MSI / installer /
    default / manual). Corrections are written back to app.json in the package folder,
    so the GUI and the command line stay interchangeable.

    Designed so an occasional packager can succeed without knowing the tooling:
      - Start screen with recent packages; drop a folder or an installer on the window
      - Guided wizard from a bare vendor .exe/.msi: installer engine detection
        (MSI/Inno Setup/NSIS/InstallShield/WiX Burn) prefills silent switches
      - Detection without registry knowledge: pick the app from this computer's
        Apps & features list and the uninstall-key rule is generated
      - Advanced settings (commands, run-as, restart, architecture) stay collapsed
      - A live readiness checklist instead of one-at-a-time error dialogs
      - Company Portal preview, icon picker and icon extraction from the installer
      - Duplicate app names in Intune are refused before anything is created
      - Build/upload runs in the background with a live log, progress and Cancel
      - Built-in help (Help button or F1) covering just what the tool needs from you

.PARAMETER SourceFolder
    Optional: open this package folder at startup instead of the start screen.

.PARAMETER Installer
    Optional: open the guided wizard at startup with this vendor .exe/.msi preloaded.

.PARAMETER Wizard
    Open the guided wizard at startup.

.PARAMETER TestLoad
    Diagnostics: build every window, run headless self-tests and print a PASS/FAIL
    summary, then exit without showing the UI.

.EXAMPLE
    .\Packwright.ps1

.EXAMPLE
    .\Packwright.ps1 -SourceFolder "C:\psadt\7-zip"

.EXAMPLE
    .\Packwright.ps1 -Installer "C:\Downloads\SetupApp.exe"

.NOTES
    Author   : Love A
    Requires : PowerShell 7+, Windows. Uses only WPF/WinForms + the two engine scripts.
.VERSION
    2026-09-04 - 2.4 - Settings dialog (header button, and asked once on first run) for the
                       package folder and the output folder, both defaulting to a local disk
                       instead of a Documents folder redirected to a network home directory.
                       Resolved paths use .ProviderPath, so a UNC path no longer reaches
                       IntuneWinAppUtil.exe provider-qualified and unopenable.
    2026-09-04 - 2.3 - Delegated sign-in is asked for with -SignIn Browser: the default
                       WAM prompt parents itself to the console window of the process,
                       and a GUI has none, so it failed without a message and the
                       publish carried on unauthenticated. Windows PowerShell 5.1 is
                       turned away in a dialog instead of a wall of parse errors; the
                       scripts are saved UTF-8 with BOM so 5.1 can read that far, and
                       the self-test keeps the BOM from going missing again
    2026-09-04 - 2.2 - Picking another installer in the wizard refreshes everything that
                       came from the previous file (commands, hint, MSI product code,
                       extracted logo, suggested folder name); hand-edited text is kept
                       and pointed out. A hidden "use the MSI product code" option can
                       no longer stay selected and write an empty product code.
    2026-09-03 - 2.1 - Built-in help: Help button in the header and F1, showing a short
                       usage guide written for the person packaging the app (the README
                       stays the reference for setup, sign-in and the command line)
    2026-09-03 - 2.0 - Redesigned for low-threshold use: start screen with recent
                       packages and drag-and-drop, restyled single-window editor with
                       live Company Portal preview and readiness checklist, detection
                       reduced to one "find the app on this computer" button with the
                       raw fields behind an expander, advanced settings collapsed,
                       icon extraction from installer/installed app, Cancel for a
                       running build, duplicate-name check before publishing.
                       Fixes: changing the setup file now refreshes commands and
                       detection; absolute detection-script paths validate correctly;
                       MSI COM handles released; MSI/installed-app lookups cached;
                       engine arguments passed as parameters instead of string
                       concatenation; window fits small screens (scrolls).
    2026-07-10 - 1.4 - Guided wizard from a vendor installer, installed-apps picker,
                       engine detection, remembered package root
    2026-07-07 - 1.3 - English UI, neutral publisher default
    2026-07-07 - 1.2 - Correct minimumWindowsRelease values
    2026-07-07 - 1.1 - "From MSI..." product code fetch, manual source tags
    2026-07-06 - 1.0 - Initial version
#>
[CmdletBinding()]
param(
    [string]$SourceFolder,
    [string]$Installer,
    [switch]$Wizard,
    [switch]$TestLoad
)

# Windows PowerShell 5.1 gets further than is good for anyone: the file parses, the window
# opens, and then icon extraction quietly falls back to 32x32 instead of 256x256. Stop here
# instead, and say it in a dialog too — the usual way to end up in 5.1 is double-clicking
# the .ps1 in Explorer, where there is no console to read the error in.
# (This check is only reachable because the script is saved as UTF-8 with a BOM. Without
# one, 5.1 reads the em dashes as ANSI, every string after the first one breaks, and you
# get the wall of parse errors instead. Self-test 'Scripts are saved UTF-8 with BOM' guards that.)
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $wrongVersion = @"
Packwright needs PowerShell 7.

This is Windows PowerShell $($PSVersionTable.PSVersion) — what Explorer uses when you
double-click a .ps1 file. Start Packwright from PowerShell 7 instead:

    pwsh -STA -File "$PSCommandPath"

No PowerShell 7 on this machine? Install it with:  winget install Microsoft.PowerShell
"@
    # Console first: the dialog blocks until someone clicks it, and a run from a terminal
    # (or with no desktop at all) should not have to wait for that to read the reason.
    Write-Host $wrongVersion -ForegroundColor Red
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [void][Windows.MessageBox]::Show($wrongVersion, 'Packwright needs PowerShell 7', 'OK', 'Error')
    }
    catch { }   # no WPF to show it in — the console text above is then all there is
    exit 1
}

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$script:EngineBuild   = Join-Path $PSScriptRoot 'Build-IntuneWinApp.ps1'
$script:EnginePublish = Join-Path $PSScriptRoot 'Publish-IntuneWinApp.ps1'
foreach ($engine in $EngineBuild, $EnginePublish) {
    if (-not (Test-Path -LiteralPath $engine)) { throw "Engine script missing: $engine" }
}

#region ---- Theme ---------------------------------------------------------------
# One resource block shared by every window. Each window XAML carries a <!--THEME-->
# placeholder inside <Window.Resources>; New-StudioWindow injects this before parsing.
$script:Theme = @'
  <SolidColorBrush x:Key="BgApp" Color="#F2F3F5"/>
  <SolidColorBrush x:Key="BgCard" Color="#FFFFFF"/>
  <SolidColorBrush x:Key="BgSubtle" Color="#F6F8FA"/>
  <SolidColorBrush x:Key="Stroke" Color="#E1E4E8"/>
  <SolidColorBrush x:Key="Ink" Color="#1A1C20"/>
  <SolidColorBrush x:Key="InkMuted" Color="#5B6169"/>
  <SolidColorBrush x:Key="InkFaint" Color="#868C95"/>
  <SolidColorBrush x:Key="Accent" Color="#0F6CBD"/>
  <SolidColorBrush x:Key="AccentDark" Color="#0C5391"/>
  <SolidColorBrush x:Key="AccentSoft" Color="#EBF3FC"/>
  <SolidColorBrush x:Key="Ok" Color="#0E7A33"/>
  <SolidColorBrush x:Key="OkSoft" Color="#E9F6EC"/>
  <SolidColorBrush x:Key="Warn" Color="#8A5300"/>
  <SolidColorBrush x:Key="WarnSoft" Color="#FDF3E2"/>
  <SolidColorBrush x:Key="Err" Color="#B3261E"/>
  <SolidColorBrush x:Key="ErrSoft" Color="#FCEFEE"/>

  <Style x:Key="H1" TargetType="TextBlock">
    <Setter Property="FontSize" Value="21"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
  </Style>
  <Style x:Key="H2" TargetType="TextBlock">
    <Setter Property="FontSize" Value="14"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
  </Style>
  <Style x:Key="Body" TargetType="TextBlock">
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
  </Style>
  <Style x:Key="Muted" TargetType="TextBlock">
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="Foreground" Value="{StaticResource InkMuted}"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
  </Style>
  <Style x:Key="Tiny" TargetType="TextBlock">
    <Setter Property="FontSize" Value="11"/>
    <Setter Property="Foreground" Value="{StaticResource InkFaint}"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
  </Style>
  <Style x:Key="FieldLabel" TargetType="TextBlock">
    <Setter Property="FontSize" Value="11"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Foreground" Value="{StaticResource InkMuted}"/>
    <Setter Property="Margin" Value="0,10,0,3"/>
  </Style>
  <Style x:Key="Card" TargetType="Border">
    <Setter Property="Background" Value="{StaticResource BgCard}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="8"/>
    <Setter Property="Padding" Value="16"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <Style x:Key="Note" TargetType="Border">
    <Setter Property="CornerRadius" Value="6"/>
    <Setter Property="Padding" Value="10,8"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Background" Value="{StaticResource BgSubtle}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
  </Style>

  <Style TargetType="TextBox">
    <Setter Property="Background" Value="{StaticResource BgCard}"/>
    <Setter Property="BorderBrush" Value="#CDD3D9"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="Padding" Value="8,6"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="PART_Frame" Background="{TemplateBinding Background}"
                  BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                  CornerRadius="5" SnapsToDevicePixels="True">
            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" BorderThickness="0"
                          VerticalScrollBarVisibility="{TemplateBinding VerticalScrollBarVisibility}"
                          HorizontalScrollBarVisibility="{TemplateBinding HorizontalScrollBarVisibility}"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocusWithin" Value="True">
              <Setter TargetName="PART_Frame" Property="BorderBrush" Value="{StaticResource Accent}"/>
            </Trigger>
            <Trigger Property="Tag" Value="invalid">
              <Setter TargetName="PART_Frame" Property="BorderBrush" Value="{StaticResource Err}"/>
              <Setter TargetName="PART_Frame" Property="Background" Value="{StaticResource ErrSoft}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ComboBox">
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Height" Value="30"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
  </Style>
  <Style TargetType="CheckBox">
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="Margin" Value="0,6,0,2"/>
  </Style>
  <Style TargetType="RadioButton">
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="Margin" Value="0,8,0,2"/>
  </Style>
  <Style TargetType="Expander">
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Foreground" Value="{StaticResource InkMuted}"/>
  </Style>
  <Style TargetType="ProgressBar">
    <Setter Property="Height" Value="6"/>
    <Setter Property="Foreground" Value="{StaticResource Accent}"/>
    <Setter Property="Background" Value="{StaticResource Stroke}"/>
    <Setter Property="BorderThickness" Value="0"/>
  </Style>

  <ControlTemplate x:Key="BtnTemplate" TargetType="Button">
    <Border x:Name="PART_Fill" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
            BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}"
            SnapsToDevicePixels="True">
      <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                        VerticalAlignment="Center" TextBlock.TextAlignment="Left"/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter TargetName="PART_Fill" Property="Opacity" Value="0.88"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter TargetName="PART_Fill" Property="Opacity" Value="0.45"/>
      </Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate>
  <Style x:Key="BtnPrimary" TargetType="Button">
    <Setter Property="Background" Value="{StaticResource Accent}"/>
    <Setter Property="Foreground" Value="White"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Padding" Value="18,9"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="HorizontalContentAlignment" Value="Center"/>
    <Setter Property="Template" Value="{StaticResource BtnTemplate}"/>
  </Style>
  <Style x:Key="BtnDefault" TargetType="Button">
    <Setter Property="Background" Value="{StaticResource BgCard}"/>
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="BorderBrush" Value="#CDD3D9"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="Padding" Value="12,7"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="HorizontalContentAlignment" Value="Center"/>
    <Setter Property="Template" Value="{StaticResource BtnTemplate}"/>
  </Style>
  <Style x:Key="BtnQuiet" TargetType="Button">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Foreground" Value="{StaticResource Accent}"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="Padding" Value="8,6"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="HorizontalContentAlignment" Value="Center"/>
    <Setter Property="Template" Value="{StaticResource BtnTemplate}"/>
  </Style>
  <Style x:Key="BtnCard" TargetType="Button">
    <Setter Property="Background" Value="{StaticResource BgCard}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="18"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="Template" Value="{StaticResource BtnTemplate}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{StaticResource AccentSoft}"/>
        <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
'@

# Parse a window XAML (with the theme injected) and return the window plus a name->control
# map. Names that fail to resolve are reported so a XAML typo fails loudly, not at click time.
function New-StudioWindow {
    param([Parameter(Mandatory)][string]$Xaml)
    $full = $Xaml.Replace('<!--THEME-->', $script:Theme)
    $studioWindow = [Windows.Markup.XamlReader]::Parse($full)
    $controls = @{}
    $unresolved = @()
    foreach ($name in ([regex]::Matches($full, 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)) {
        if ($name -like 'PART_*') { continue }   # names inside control templates
        $control = $studioWindow.FindName($name)
        if ($null -eq $control) { $unresolved += $name } else { $controls[$name] = $control }
    }
    @{ Window = $studioWindow; C = $controls; Unresolved = $unresolved }
}
#endregion

#region ---- Main window XAML ---------------------------------------------------
$script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Packwright" Width="1120" Height="800" MinWidth="900" MinHeight="560"
        WindowStartupLocation="CenterScreen" Background="#F2F3F5"
        FontFamily="Segoe UI" FontSize="12" AllowDrop="True">
  <Window.Resources>
<!--THEME-->
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="{StaticResource BgCard}" BorderBrush="{StaticResource Stroke}" BorderThickness="0,0,0,1">
      <Grid Margin="20,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="Packwright" FontSize="14" FontWeight="SemiBold"
                   Foreground="{StaticResource Ink}" VerticalAlignment="Center"/>
        <StackPanel x:Name="PnlHeaderPkg" Grid.Column="1" Orientation="Horizontal" Margin="12,0,0,0"
                    VerticalAlignment="Center" Visibility="Collapsed">
          <TextBlock Text="—" Style="{StaticResource Tiny}" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <TextBlock x:Name="TxtHeaderPkg" Style="{StaticResource Muted}" VerticalAlignment="Center"
                     TextTrimming="CharacterEllipsis" MaxWidth="430" TextWrapping="NoWrap"/>
          <Button x:Name="BtnChangePkg" Style="{StaticResource BtnQuiet}" Content="Change package" Margin="4,0,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal">
          <Border Style="{StaticResource Note}" Padding="9,4" VerticalAlignment="Center">
            <TextBlock x:Name="TxtAuthStatus" Style="{StaticResource Tiny}" MaxWidth="330" TextWrapping="NoWrap"
                       TextTrimming="CharacterEllipsis"/>
          </Border>
          <Button x:Name="BtnSettings" Style="{StaticResource BtnDefault}" Content="Settings" Margin="8,0,0,0"
                  ToolTip="Where packages and .intunewin files are kept"/>
          <Button x:Name="BtnHelp" Style="{StaticResource BtnDefault}" Content="Help" Margin="8,0,0,0"
                  ToolTip="How to use this tool (F1)"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Content -->
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                  Padding="20,16,20,4">
      <Grid>

        <!-- Start view -->
        <Grid x:Name="ViewStart" MaxWidth="840" HorizontalAlignment="Center">
          <StackPanel Margin="0,16,0,0">
            <TextBlock Style="{StaticResource H1}" Text="Package an app for Intune"/>
            <TextBlock Style="{StaticResource Muted}" Margin="0,6,0,18"
                       Text="Pick where you want to start. Nothing is sent to Intune until you review it and press Publish."/>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="BtnStartWizard" Grid.Column="0" Style="{StaticResource BtnCard}" Margin="0,0,8,0">
                <StackPanel>
                  <TextBlock Text="I have an installer file" FontSize="15" FontWeight="SemiBold"
                             Foreground="#1A1C20" TextWrapping="Wrap"/>
                  <TextBlock Margin="0,6,0,0" FontSize="12" Foreground="#5B6169" TextWrapping="Wrap"
                             Text="Start from the .exe or .msi you got from the vendor. Five short steps: the tool identifies the installer, fills in the silent switches and builds the package for you."/>
                  <TextBlock Margin="0,10,0,0" FontSize="12" FontWeight="SemiBold" Foreground="#0F6CBD"
                             Text="Create a new package"/>
                </StackPanel>
              </Button>
              <Button x:Name="BtnStartOpen" Grid.Column="1" Style="{StaticResource BtnCard}" Margin="8,0,0,0">
                <StackPanel>
                  <TextBlock Text="I have a package folder" FontSize="15" FontWeight="SemiBold"
                             Foreground="#1A1C20" TextWrapping="Wrap"/>
                  <TextBlock Margin="0,6,0,0" FontSize="12" Foreground="#5B6169" TextWrapping="Wrap"
                             Text="Open a folder that already holds the installation files — a PSADT package, an MSI or a plain installer. Existing app.json settings are loaded."/>
                  <TextBlock Margin="0,10,0,0" FontSize="12" FontWeight="SemiBold" Foreground="#0F6CBD"
                             Text="Open a folder..."/>
                </StackPanel>
              </Button>
            </Grid>

            <TextBlock Style="{StaticResource H2}" Text="Recent packages" Margin="0,22,0,6"/>
            <ListBox x:Name="LstRecent" MaxHeight="180" BorderBrush="{StaticResource Stroke}"
                     Background="{StaticResource BgCard}" Visibility="Collapsed">
              <ListBox.ItemTemplate>
                <DataTemplate>
                  <StackPanel Margin="2,4">
                    <TextBlock Text="{Binding Title}" FontSize="12" FontWeight="SemiBold" Foreground="#1A1C20"/>
                    <TextBlock Text="{Binding Folder}" FontSize="11" Foreground="#868C95"/>
                  </StackPanel>
                </DataTemplate>
              </ListBox.ItemTemplate>
            </ListBox>
            <TextBlock x:Name="TxtRecentEmpty" Style="{StaticResource Tiny}"
                       Text="Nothing here yet — packages you open show up in this list."/>
            <Border Style="{StaticResource Note}" Margin="0,16,0,0">
              <TextBlock Style="{StaticResource Tiny}"
                         Text="Tip: you can also drag a package folder or an installer file straight onto this window."/>
            </Border>
          </StackPanel>
        </Grid>

        <!-- Editor view -->
        <Grid x:Name="ViewEditor" Visibility="Collapsed">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*" MinWidth="400"/><ColumnDefinition Width="370"/>
          </Grid.ColumnDefinitions>

          <StackPanel Grid.Column="0" Margin="0,0,16,0">
            <!-- App information -->
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="App information"/>
                <TextBlock Style="{StaticResource Tiny}" Text="What the app is called in Intune and the Company Portal."/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource FieldLabel}" Text="NAME"/>
                  <TextBlock x:Name="TagName" Grid.Column="1" Style="{StaticResource Tiny}" Margin="0,10,0,3"/>
                </Grid>
                <TextBox x:Name="TxtName"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource FieldLabel}" Text="PUBLISHER"/>
                  <TextBlock x:Name="TagPublisher" Grid.Column="1" Style="{StaticResource Tiny}" Margin="0,10,0,3"/>
                </Grid>
                <TextBox x:Name="TxtPublisher"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource FieldLabel}" Text="VERSION"/>
                  <TextBlock x:Name="TagVersion" Grid.Column="1" Style="{StaticResource Tiny}" Margin="0,10,0,3"/>
                </Grid>
                <TextBox x:Name="TxtVersion"/>
                <TextBlock Style="{StaticResource FieldLabel}" Text="DESCRIPTION (OPTIONAL)"/>
                <TextBox x:Name="TxtDescription" AcceptsReturn="True" Height="52" TextWrapping="Wrap"
                         VerticalScrollBarVisibility="Auto"/>
              </StackPanel>
            </Border>

            <!-- Detection -->
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Detection"/>
                <TextBlock Style="{StaticResource Tiny}"
                           Text="How Intune checks whether the app is already installed on a device. Intune requires this."/>
                <Border x:Name="PnlDetSummary" Style="{StaticResource Note}" Margin="0,10,0,0">
                  <TextBlock x:Name="TxtDetSummary" Style="{StaticResource Body}"/>
                </Border>
                <Button x:Name="BtnRegPick" Style="{StaticResource BtnDefault}" Margin="0,10,0,0"
                        HorizontalAlignment="Left" Content="Find the app on this computer..."/>
                <TextBlock Style="{StaticResource Tiny}" Margin="0,6,0,0"
                           Text="Recommended: install the app on this computer first, then pick it here — the registry rule is written for you. You can uninstall it again afterwards."/>
                <Expander x:Name="ExpDetection" Header="Change detection method" Margin="0,12,0,0">
                  <StackPanel Margin="0,8,0,0">
                    <TextBlock Style="{StaticResource FieldLabel}" Text="METHOD"/>
                    <ComboBox x:Name="CmbDetType">
                      <ComboBoxItem Content="Registry key (works for most installers)" Tag="registry"/>
                      <ComboBoxItem Content="MSI product code" Tag="msi"/>
                      <ComboBoxItem Content="File or folder" Tag="file"/>
                      <ComboBoxItem Content="PowerShell script" Tag="script"/>
                    </ComboBox>

                    <StackPanel x:Name="PnlDetMsi">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="PRODUCT CODE"/>
                      <DockPanel>
                        <Button x:Name="BtnMsiPick" DockPanel.Dock="Right" Style="{StaticResource BtnDefault}"
                                Content="From MSI..." Margin="6,0,0,0"/>
                        <TextBox x:Name="TxtProductCode"/>
                      </DockPanel>
                    </StackPanel>

                    <StackPanel x:Name="PnlDetFile">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="FOLDER PATH"/>
                      <TextBox x:Name="TxtDetPath"/>
                      <TextBlock Style="{StaticResource FieldLabel}" Text="FILE OR FOLDER NAME"/>
                      <TextBox x:Name="TxtDetFile"/>
                    </StackPanel>

                    <StackPanel x:Name="PnlDetRegistry">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="REGISTRY KEY"/>
                      <TextBox x:Name="TxtKeyPath"/>
                      <TextBlock Style="{StaticResource FieldLabel}" Text="VALUE NAME (EMPTY = KEY MUST EXIST)"/>
                      <TextBox x:Name="TxtValueName"/>
                    </StackPanel>

                    <StackPanel x:Name="PnlDetScript">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="SCRIPT FILE"/>
                      <DockPanel>
                        <Button x:Name="BtnBrowseScript" DockPanel.Dock="Right" Style="{StaticResource BtnDefault}"
                                Content="Browse..." Margin="6,0,0,0"/>
                        <TextBox x:Name="TxtScript"/>
                      </DockPanel>
                      <TextBlock Style="{StaticResource Tiny}" Margin="0,6,0,0"
                                 Text="The script must write something to stdout and exit with code 0 when the app is installed."/>
                    </StackPanel>

                    <StackPanel x:Name="PnlDetCompare">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="COMPARE"/>
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <ComboBox x:Name="CmbDetCheck" Margin="0,0,4,0">
                          <ComboBoxItem Content="exists" IsSelected="True"/><ComboBoxItem Content="version"/>
                          <ComboBoxItem Content="string"/><ComboBoxItem Content="integer"/>
                        </ComboBox>
                        <ComboBox x:Name="CmbDetOperator" Grid.Column="1" Margin="4,0,0,0">
                          <ComboBoxItem Content="notConfigured" IsSelected="True"/><ComboBoxItem Content="equal"/>
                          <ComboBoxItem Content="notEqual"/><ComboBoxItem Content="greaterThan"/>
                          <ComboBoxItem Content="greaterThanOrEqual"/><ComboBoxItem Content="lessThan"/>
                          <ComboBoxItem Content="lessThanOrEqual"/>
                        </ComboBox>
                      </Grid>
                      <TextBlock x:Name="LblDetValue" Style="{StaticResource FieldLabel}" Text="COMPARISON VALUE"/>
                      <TextBox x:Name="TxtDetValue"/>
                      <CheckBox x:Name="ChkDet32" Content="32-bit app on 64-bit Windows (WOW6432Node)"/>
                    </StackPanel>
                  </StackPanel>
                </Expander>
              </StackPanel>
            </Border>

            <!-- Advanced -->
            <Border Style="{StaticResource Card}">
              <Expander x:Name="ExpAdvanced" Header="Advanced: commands, run-as, restart, architecture">
                <StackPanel Margin="0,10,0,0">
                  <TextBlock Style="{StaticResource FieldLabel}" Text="INSTALL COMMAND"/>
                  <TextBox x:Name="TxtInstall"/>
                  <TextBlock Style="{StaticResource FieldLabel}" Text="UNINSTALL COMMAND"/>
                  <TextBox x:Name="TxtUninstall"/>
                  <TextBlock x:Name="TxtCmdHint" Style="{StaticResource Tiny}" Margin="0,6,0,0"/>
                  <Grid Margin="0,4,0,0">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Margin="0,0,6,0">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="RUN AS"/>
                      <ComboBox x:Name="CmbRunAs">
                        <ComboBoxItem Content="system" IsSelected="True"/><ComboBoxItem Content="user"/>
                      </ComboBox>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Margin="6,0,0,0">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="RESTART BEHAVIOUR"/>
                      <ComboBox x:Name="CmbRestart">
                        <ComboBoxItem Content="suppress" IsSelected="True"/><ComboBoxItem Content="basedOnReturnCode"/>
                        <ComboBoxItem Content="allow"/><ComboBoxItem Content="force"/>
                      </ComboBox>
                    </StackPanel>
                  </Grid>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Margin="0,0,6,0">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="ARCHITECTURE"/>
                      <ComboBox x:Name="CmbArch">
                        <ComboBoxItem Content="x64" IsSelected="True"/><ComboBoxItem Content="x86"/>
                        <ComboBoxItem Content="x86,x64"/><ComboBoxItem Content="arm64"/>
                      </ComboBox>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Margin="6,0,0,0">
                      <TextBlock Style="{StaticResource FieldLabel}" Text="MINIMUM WINDOWS"/>
                      <ComboBox x:Name="CmbMinOs" IsEditable="True" Text="1607">
                        <ComboBoxItem Content="1607"/><ComboBoxItem Content="1809"/>
                        <ComboBoxItem Content="Windows10_21H2"/><ComboBoxItem Content="Windows10_22H2"/>
                        <ComboBoxItem Content="Windows11_21H2"/><ComboBoxItem Content="Windows11_22H2"/>
                      </ComboBox>
                    </StackPanel>
                  </Grid>
                  <TextBlock Style="{StaticResource FieldLabel}" Text="SETUP FILE"/>
                  <ComboBox x:Name="CmbSetup"/>
                  <TextBlock Style="{StaticResource FieldLabel}" Text="IF THE APP ALREADY EXISTS IN INTUNE"/>
                  <TextBlock Style="{StaticResource Tiny}"
                             Text="By default publishing stops, so a re-publish cannot create a duplicate by mistake."/>
                  <CheckBox x:Name="ChkUpdateExisting"
                            Content="Update it: upload this package as a new version of that app"/>
                  <CheckBox x:Name="ChkAllowDuplicate"
                            Content="Create a second app with the same name anyway"/>
                </StackPanel>
              </Expander>
            </Border>
          </StackPanel>

          <StackPanel Grid.Column="1">
            <!-- Preview -->
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Preview"/>
                <TextBlock Style="{StaticResource Tiny}" Text="How the app will look in the Company Portal."/>
                <Border Background="{StaticResource BgSubtle}" BorderBrush="{StaticResource Stroke}"
                        BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,10,0,0">
                  <DockPanel>
                    <Border DockPanel.Dock="Left" Width="64" Height="64" Background="White" CornerRadius="6"
                            BorderBrush="{StaticResource Stroke}" BorderThickness="1" Margin="0,0,12,0"
                            VerticalAlignment="Top">
                      <Image x:Name="ImgPreview" Stretch="Uniform" Margin="6"/>
                    </Border>
                    <StackPanel>
                      <TextBlock x:Name="PvName" FontSize="14" FontWeight="SemiBold" Foreground="#1A1C20"
                                 TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"/>
                      <TextBlock x:Name="PvPublisher" Style="{StaticResource Muted}" TextWrapping="NoWrap"
                                 TextTrimming="CharacterEllipsis"/>
                      <TextBlock x:Name="PvVersion" Style="{StaticResource Tiny}" Margin="0,2,0,0"/>
                      <TextBlock x:Name="PvDescription" Style="{StaticResource Tiny}" MaxHeight="46" Margin="0,6,0,0"/>
                    </StackPanel>
                  </DockPanel>
                </Border>
              </StackPanel>
            </Border>

            <!-- Logo -->
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="Logo"/>
                <DockPanel Margin="0,10,0,0">
                  <Border DockPanel.Dock="Left" Width="56" Height="56" Background="White" CornerRadius="6"
                          BorderBrush="{StaticResource Stroke}" BorderThickness="1" Margin="0,0,12,0">
                    <Image x:Name="ImgIcon" Stretch="Uniform" Margin="5"/>
                  </Border>
                  <StackPanel>
                    <Button x:Name="BtnIconAuto" Style="{StaticResource BtnDefault}" HorizontalAlignment="Left"
                            Content="Use the app's own icon"/>
                    <Button x:Name="BtnBrowseIcon" Style="{StaticResource BtnQuiet}" HorizontalAlignment="Left"
                            Content="Choose an image instead..." Margin="0,4,0,0"/>
                  </StackPanel>
                </DockPanel>
                <TextBlock x:Name="TxtIconPath" Style="{StaticResource Tiny}" Margin="0,8,0,0"
                           Text="No logo yet — the app gets a generic icon in the Company Portal."/>
              </StackPanel>
            </Border>

            <!-- Readiness -->
            <Border x:Name="PnlReady" Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock x:Name="TxtReadyTitle" Style="{StaticResource H2}" Text="Almost ready"/>
                <StackPanel Margin="0,8,0,0">
                  <TextBlock x:Name="ChkSetup" Style="{StaticResource Body}" Margin="0,2"/>
                  <TextBlock x:Name="ChkName" Style="{StaticResource Body}" Margin="0,2"/>
                  <TextBlock x:Name="ChkPublisher" Style="{StaticResource Body}" Margin="0,2"/>
                  <TextBlock x:Name="ChkDetection" Style="{StaticResource Body}" Margin="0,2"/>
                </StackPanel>
                <TextBlock x:Name="TxtReadyNote" Style="{StaticResource Tiny}" Margin="0,10,0,0"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </Grid>
      </Grid>
    </ScrollViewer>

    <!-- Action bar -->
    <Border x:Name="PnlActions" Grid.Row="2" Background="{StaticResource BgCard}" BorderBrush="{StaticResource Stroke}"
            BorderThickness="0,1,0,0" Visibility="Collapsed">
      <DockPanel Margin="20,10">
        <Button x:Name="BtnPublish" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}"
                Content="Publish to Intune"/>
        <Button x:Name="BtnBuild" DockPanel.Dock="Right" Style="{StaticResource BtnDefault}"
                Content="Build only" Margin="0,0,8,0"/>
        <Button x:Name="BtnSave" DockPanel.Dock="Right" Style="{StaticResource BtnQuiet}"
                Content="Save settings" Margin="0,0,4,0"/>
        <Button x:Name="BtnCancelRun" DockPanel.Dock="Right" Style="{StaticResource BtnDefault}"
                Content="Cancel" Margin="0,0,8,0" Visibility="Collapsed"/>
        <Button x:Name="BtnOpenPortal" DockPanel.Dock="Left" Style="{StaticResource BtnQuiet}"
                Content="Open in the Intune portal" Visibility="Collapsed"/>
        <TextBlock x:Name="TxtActionHint" Style="{StaticResource Tiny}" VerticalAlignment="Center" Margin="8,0,12,0"/>
      </DockPanel>
    </Border>

    <!-- Log -->
    <Expander x:Name="ExpLog" Grid.Row="3" Header="Log" Margin="20,8,20,4">
      <Border CornerRadius="6" Background="#1E2126" Padding="2" Margin="0,6,0,0">
        <TextBox x:Name="TxtLog" Height="170" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                 Background="#1E2126" Foreground="#DDE1E6" BorderThickness="0" TextWrapping="NoWrap"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
      </Border>
    </Expander>

    <!-- Status -->
    <Border Grid.Row="4" Background="{StaticResource BgCard}" BorderBrush="{StaticResource Stroke}" BorderThickness="0,1,0,0">
      <Grid Margin="20,7">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="TxtStatus" Style="{StaticResource Muted}" VerticalAlignment="Center"
                   TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
        <ProgressBar x:Name="Prog" Grid.Column="1" Width="180" VerticalAlignment="Center"
                     Margin="12,0,0,0" Visibility="Collapsed"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@
#endregion

$script:MainWindow = New-StudioWindow -Xaml $script:MainXaml
if ($script:MainWindow.Unresolved.Count) {
    throw "Main window XAML defines names that cannot be resolved: $($script:MainWindow.Unresolved -join ', ')"
}
$window = $script:MainWindow.Window
$ui     = $script:MainWindow.C

#region ---- State and logging ---------------------------------------------------
$script:LoadedFolder  = $null    # package folder currently open
$script:IconAbsPath   = $null    # absolute path of the logo shown in the UI
$script:InitialValues = $null    # snapshot used to tag hand-edited fields
$script:Loading       = $false   # suppresses change handlers while filling the UI
$script:PickedApp     = $null    # installed app picked for detection (icon source)
$script:PortalUrl     = $null
$script:MsiPropCache  = @{}
$script:MsiListCache  = @{}
$script:InstalledApps = $null
$script:IconApiReady  = $null
$script:PsadtSkip     = '^(Invoke-AppDeployToolkit|Deploy-Application|PSADT|AppDeployToolkit|ServiceUI|IntuneWinAppUtil)'

function Write-GuiLog {
    param([string]$Message)
    $ui.TxtLog.AppendText($Message + [Environment]::NewLine)
    $ui.TxtLog.ScrollToEnd()
}

function Set-StatusText {
    param([string]$Text)
    $ui.TxtStatus.Text = $Text
}
#endregion

#region ---- Persisted settings and recent packages ------------------------------
$script:SettingsFile = Join-Path $env:APPDATA 'Packwright\settings.json'

function Get-StudioSetting {
    param([string]$Name)
    try { (Get-Content -LiteralPath $script:SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable)[$Name] }
    catch { $null }
}

function Set-StudioSetting {
    param([string]$Name, $Value)
    $all = @{}
    try { $all = Get-Content -LiteralPath $script:SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch {}
    $all[$Name] = $Value
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $script:SettingsFile) -Force
    ($all | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
}

# On a managed machine Documents is usually redirected to a network home directory, and a
# package folder there breaks the build in ways that read as something else entirely: the
# WindowsInstaller COM object refuses to open the MSI, IntuneWinAppUtil.exe answers "the
# setup file cannot be accessed", and 150 MB crosses the wire twice on the way to Intune.
# Everything Packwright writes therefore defaults to a local disk, and the settings dialog
# says so out loud if you point it somewhere else anyway.
function Test-LocalPath {
    param([string]$Path)
    if (-not "$Path".Trim()) { return $false }
    if ("$Path".StartsWith('\\')) { return $false }          # UNC — no drive to ask about
    try {
        $root = [IO.Path]::GetPathRoot($Path)
        if (-not $root) { return $false }                    # relative path, nothing to judge
        return ([IO.DriveInfo]::new($root).DriveType -eq 'Fixed')
    }
    catch { return $false }                                  # unparseable or a drive that is gone
}

# USERPROFILE stays on the local disk even when Documents is redirected, which is the whole
# point; LOCALAPPDATA is the fallback for the odd machine where even that is not local.
function Get-DefaultPackageRoot {
    $preferred = Join-Path $env:USERPROFILE 'IntunePackages'
    if (Test-LocalPath $preferred) { return $preferred }
    Join-Path $env:LOCALAPPDATA 'Packwright\Packages'
}

function Get-DefaultOutputRoot { Join-Path $PSScriptRoot 'Output' }

function Get-StudioPackageRoot {
    $saved = "$(Get-StudioSetting 'PackageRoot')".Trim()
    if ($saved) { $saved } else { Get-DefaultPackageRoot }
}

function Get-StudioOutputRoot {
    $saved = "$(Get-StudioSetting 'OutputRoot')".Trim()
    if ($saved) { $saved } else { Get-DefaultOutputRoot }
}

# True until the settings file exists, so the first run can ask where things should go
# instead of leaving it to be discovered in %APPDATA% after something has already failed.
function Test-FirstRun { -not (Test-Path -LiteralPath $script:SettingsFile) }

# Anyone who ran an earlier version already has a settings.json and so never sees the
# first-run dialog. If what it holds is the old MyDocuments default, that is not a choice
# anyone made — move it to the local default. A share someone typed in on purpose is left
# exactly where it is and only warned about. Returns what to log, or '' if nothing moved.
# LegacyRoot is a parameter so the self-test can exercise the move on a machine where
# Documents happens to be local and there would otherwise be nothing to move.
function Repair-LegacyPackageRoot {
    param([string]$LegacyRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'IntunePackages'))
    $savedRoot = "$(Get-StudioSetting 'PackageRoot')".Trim()
    if (-not $savedRoot -or $savedRoot -ine $LegacyRoot -or (Test-LocalPath $savedRoot)) { return '' }
    $local = Get-DefaultPackageRoot
    Set-StudioSetting -Name 'PackageRoot' -Value $local
    "Package folder moved off the network home directory to $local — change it under Settings if you want it somewhere else."
}

# Most recently opened packages, newest first, folders that no longer exist dropped
function Get-RecentPackage {
    $recent = @(Get-StudioSetting 'Recent')
    @($recent | Where-Object { $_ -and (Test-Path -LiteralPath "$_" -PathType Container) } |
        ForEach-Object { [pscustomobject]@{ Title = Split-Path -Leaf "$_"; Folder = "$_" } })
}

function Add-RecentPackage {
    param([Parameter(Mandatory)][string]$Folder)
    $list = @(@($Folder) + @(Get-StudioSetting 'Recent' | Where-Object { "$_" -and "$_" -ine $Folder }) |
              Select-Object -First 8)
    Set-StudioSetting -Name 'Recent' -Value $list
}
#endregion

#region ---- Package metadata readers --------------------------------------------
# AppVendor/AppName/AppVersion from the $adtSession block of a PSADT package —
# the same values Publish-IntuneWinApp reads, so the preview matches what gets published.
function Get-PsadtMetadata {
    param([Parameter(Mandatory)][string]$Folder)
    $result = @{}
    $deployScript = Join-Path $Folder 'Invoke-AppDeployToolkit.ps1'
    if (Test-Path -LiteralPath $deployScript) {
        $content = Get-Content -LiteralPath $deployScript -Raw
        foreach ($key in 'AppVendor', 'AppName', 'AppVersion') {
            $pattern = '(?m)^\s*' + $key + '\s*=\s*([''"])(.*?)\1'
            if ($content -match $pattern -and $Matches[2].Trim()) { $result[$key] = $Matches[2].Trim() }
        }
    }
    $result
}

# MSI Property table via COM. Results are cached and every COM handle is released —
# the GUI may read the same MSI repeatedly while the user edits fields.
function Get-MsiProperty {
    param([Parameter(Mandatory)][string]$MsiPath)
    $cacheKey = $MsiPath.ToLowerInvariant()
    if ($script:MsiPropCache.ContainsKey($cacheKey)) { return $script:MsiPropCache[$cacheKey] }

    $result = @{}
    $installer = $null; $database = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($MsiPath, 0))
        foreach ($property in 'ProductName', 'Manufacturer', 'ProductVersion', 'ProductCode') {
            $view = $null; $record = $null
            try {
                $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database,
                            "SELECT Value FROM Property WHERE Property='$property'")
                $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
                $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
                if ($record) {
                    $value = "$($record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, 1))".Trim()
                    if ($value) { $result[$property] = $value }
                }
                $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
            }
            finally {
                foreach ($comObject in $record, $view) {
                    if ($comObject) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) }
                }
            }
        }
    }
    catch { Write-GuiLog "WARNING: Could not read MSI properties from $([IO.Path]::GetFileName($MsiPath)): $($_.Exception.Message)" }
    finally {
        foreach ($comObject in $database, $installer) {
            if ($comObject) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) }
        }
    }
    $script:MsiPropCache[$cacheKey] = $result
    $result
}

# Every .msi in the open package (PSADT keeps the payload under Files\); cached per folder
function Find-PackageMsi {
    param([switch]$Refresh)
    if (-not $script:LoadedFolder) { return @() }
    $cacheKey = $script:LoadedFolder.ToLowerInvariant()
    if ($Refresh) { $script:MsiListCache.Remove($cacheKey) }
    if (-not $script:MsiListCache.ContainsKey($cacheKey)) {
        $script:MsiListCache[$cacheKey] = @(Get-ChildItem -LiteralPath $script:LoadedFolder -Filter *.msi -File -Recurse -ErrorAction SilentlyContinue)
    }
    $script:MsiListCache[$cacheKey]
}

# The vendor payload inside a package, ignoring PSADT's own binaries and our tooling.
# Files under Files\ win, then the largest — that is the app installer in practice.
function Find-PayloadFile {
    param([Parameter(Mandatory)][string]$Folder, [string[]]$Extension = @('.exe', '.msi'))
    @(Get-ChildItem -LiteralPath $Folder -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in $Extension -and $_.BaseName -notmatch $script:PsadtSkip } |
        Sort-Object @{ Expression = { if ($_.FullName -match '\\Files\\') { 0 } else { 1 } } },
                    @{ Expression = { $_.Length }; Descending = $true })
}

# Identify the installer engine of a vendor .exe/.msi and suggest silent commands.
# Version-info strings give name/publisher/version; the engine is found by scanning the
# first 8 MB for known signatures — a heuristic, so every suggested command stays editable.
function Get-InstallerInfo {
    param([Parameter(Mandatory)][string]$Path)
    $file = Get-Item -LiteralPath $Path
    $quoted = '"' + $file.Name + '"'
    $info = [ordered]@{
        FilePath = $file.FullName; FileName = $file.Name
        Engine = 'unknown'; Name = $null; Publisher = $null; Version = $null; ProductCode = $null
        InstallCommand = $quoted; UninstallCommand = ''
        Hint = "Unknown installer type — look up the vendor's silent switches and complete the install command."
    }
    if ($file.Extension -ieq '.msi') {
        $msi = Get-MsiProperty -MsiPath $file.FullName
        $info.Engine = 'MSI'
        $info.Name = $msi.ProductName; $info.Publisher = $msi.Manufacturer
        $info.Version = $msi.ProductVersion; $info.ProductCode = $msi.ProductCode
        $info.InstallCommand = "msiexec /i $quoted /qn /norestart"
        if ($msi.ProductCode) { $info.UninstallCommand = "msiexec /x `"$($msi.ProductCode)`" /qn /norestart" }
        $info.Hint = 'MSI package — installs silently with msiexec /qn; detection can use the MSI product code.'
        return [pscustomobject]$info
    }

    try {
        $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($file.FullName)
        if ("$($versionInfo.ProductName)".Trim()) { $info.Name = "$($versionInfo.ProductName)".Trim() }
        if ("$($versionInfo.CompanyName)".Trim()) { $info.Publisher = "$($versionInfo.CompanyName)".Trim() }
        $rawVersion = "$($versionInfo.ProductVersion)".Trim()
        if (-not $rawVersion) { $rawVersion = "$($versionInfo.FileVersion)".Trim() }
        if ($rawVersion) { $info.Version = ($rawVersion -split '\s')[0] }
    } catch {}

    $length = [int][Math]::Min($file.Length, 8MB)
    $bytes = [byte[]]::new($length)
    $stream = [IO.File]::OpenRead($file.FullName)
    try { [void]$stream.Read($bytes, 0, $length) } finally { $stream.Dispose() }
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    $wide  = [Text.Encoding]::Unicode.GetString($bytes)

    $engines = @(
        @{ Engine = 'Inno Setup'; Signature = 'Inno Setup'
           Install = "$quoted /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-"
           Hint = "Inno Setup installer — /VERYSILENT installs without UI. The uninstaller (unins000.exe) only exists after install, so use 'Find the app on this computer' to get the exact uninstall command." }
        @{ Engine = 'NSIS'; Signature = 'Nullsoft'
           Install = "$quoted /S"
           Hint = 'NSIS installer — /S (capital S) installs silently. The uninstaller is usually uninstall.exe /S in the install folder.' }
        @{ Engine = 'WiX Burn'; Signature = '.wixburn'
           Install = "$quoted /quiet /norestart"; Uninstall = "$quoted /uninstall /quiet /norestart"
           Hint = 'WiX Burn bundle — /quiet installs silently, /uninstall /quiet removes it.' }
        @{ Engine = 'InstallShield'; Signature = 'InstallShield'
           Install = "$quoted /s /v`"/qn /norestart`""
           Hint = 'InstallShield installer — /s /v"/qn" works for MSI-based setups; suite installers may need /silent instead.' }
    )
    foreach ($engine in $engines) {
        if ($ascii.IndexOf($engine.Signature, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $wide.IndexOf($engine.Signature, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $info.Engine = $engine.Engine
            $info.InstallCommand = $engine.Install
            if ($engine.Uninstall) { $info.UninstallCommand = $engine.Uninstall }
            $info.Hint = $engine.Hint
            break
        }
    }
    [pscustomobject]$info
}
#endregion

#region ---- Installed applications and icons ------------------------------------
# Apps & features as seen in the registry (HKLM 64- and 32-bit uninstall keys), cached
function Get-InstalledApp {
    param([switch]$Refresh)
    if ($script:InstalledApps -and -not $Refresh) { return $script:InstalledApps }
    $hives = @(
        @{ Root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Is32Bit = $false }
        @{ Root = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Is32Bit = $true }
    )
    $apps = foreach ($hive in $hives) {
        foreach ($key in @(Get-ChildItem -Path $hive.Root -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            $name = "$($properties.DisplayName)".Trim()
            if (-not $name) { continue }
            if ($properties.SystemComponent -eq 1) { continue }
            # Intune expects the key path without WOW6432Node; check32BitOn64System redirects instead
            [pscustomobject]@{
                DisplayName    = $name
                DisplayVersion = "$($properties.DisplayVersion)".Trim()
                Publisher      = "$($properties.Publisher)".Trim()
                Bitness        = if ($hive.Is32Bit) { 'x86' } else { 'x64' }
                Is32Bit        = $hive.Is32Bit
                KeyPath        = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' + $key.PSChildName
                QuietUninstall = "$($properties.QuietUninstallString)".Trim()
                Uninstall      = "$($properties.UninstallString)".Trim()
                DisplayIcon    = "$($properties.DisplayIcon)".Trim()
            }
        }
    }
    $script:InstalledApps = @($apps | Sort-Object DisplayName, Bitness)
    $script:InstalledApps
}

# Registry detection block (app.json schema) from a picked installed app
function ConvertTo-RegistryDetection {
    param([Parameter(Mandatory)]$App)
    $detection = [ordered]@{ type = 'registry'; keyPath = $App.KeyPath; valueName = 'DisplayVersion' }
    if ($App.DisplayVersion) {
        $detection.detectionType  = 'version'
        $detection.operator       = 'greaterThanOrEqual'
        $detection.detectionValue = $App.DisplayVersion
    }
    else {
        $detection.valueName     = ''
        $detection.detectionType = 'exists'
        $detection.operator      = 'notConfigured'
    }
    $detection.check32BitOn64System = [bool]$App.Is32Bit
    $detection
}

# Silent uninstall command from an installed app's registry entry, if one can be derived
function Get-AppUninstallCommand {
    param([Parameter(Mandatory)]$App)
    if ($App.QuietUninstall) { return $App.QuietUninstall }
    if ($App.Uninstall -match '(?i)msiexec.*?/[ix]\s*(\{[0-9a-f-]+\})') {
        return "msiexec /x `"$($Matches[1])`" /qn /norestart"
    }
    ''
}

# A DisplayIcon value is "C:\path\app.exe,0" or a bare path — split it into file + index
function Resolve-IconReference {
    param([string]$Reference)
    if (-not $Reference) { return $null }
    $path = $Reference.Trim().Trim('"')
    $index = 0
    if ($path -match '^(?<file>.*?),\s*(?<index>-?\d+)\s*$') {
        $path = $Matches.file.Trim().Trim('"')
        $index = [Math]::Max(0, [int]$Matches.index)
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) { return @{ Path = $path; Index = $index } }
    $null
}

# PrivateExtractIcons gives the largest icon in an exe/dll (up to 256 px); the BCL only
# exposes the 32 px one. Compiled on first use so startup stays fast.
function Initialize-IconApi {
    if ($null -ne $script:IconApiReady) { return $script:IconApiReady }
    try {
        if (-not ('StudioIconApi' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class StudioIconApi {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int PrivateExtractIcons(string file, int index, int cx, int cy,
                                                 IntPtr[] icons, int[] ids, int count, int flags);
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr icon);
}
'@
        }
        $script:IconApiReady = $true
    }
    catch { $script:IconApiReady = $false }
    $script:IconApiReady
}

# Write the icon of an .ico/.exe/.dll to Destination as PNG; returns the pixel size or $null
function Export-IconFile {
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [int]$IconIndex = 0,
        [Parameter(Mandatory)][string]$Destination
    )
    try {
        if ([IO.Path]::GetExtension($SourceFile) -ieq '.ico') {
            $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create(
                [Uri]$SourceFile, 'None', [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $frame = $decoder.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1
            $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
            $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($frame))
            $stream = [IO.File]::Create($Destination)
            try { $encoder.Save($stream) } finally { $stream.Dispose() }
            return $frame.PixelWidth
        }

        if (Initialize-IconApi) {
            foreach ($size in 256, 128, 64, 48) {
                $handles = New-Object IntPtr[] 1
                $ids = New-Object int[] 1
                $found = [StudioIconApi]::PrivateExtractIcons($SourceFile, $IconIndex, $size, $size, $handles, $ids, 1, 0)
                if ($found -gt 0 -and $handles[0] -ne [IntPtr]::Zero) {
                    $icon = $null; $bitmap = $null
                    try {
                        $icon = [System.Drawing.Icon]::FromHandle($handles[0])
                        $bitmap = $icon.ToBitmap()
                        $bitmap.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
                        return $bitmap.Width
                    }
                    finally {
                        if ($bitmap) { $bitmap.Dispose() }
                        if ($icon) { $icon.Dispose() }
                        [void][StudioIconApi]::DestroyIcon($handles[0])
                    }
                }
            }
        }

        $associated = [System.Drawing.Icon]::ExtractAssociatedIcon($SourceFile)
        if ($associated) {
            $bitmap = $associated.ToBitmap()
            try {
                $bitmap.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
                return $bitmap.Width
            }
            finally { $bitmap.Dispose(); $associated.Dispose() }
        }
    }
    catch { Write-GuiLog "WARNING: Could not extract an icon from $([IO.Path]::GetFileName($SourceFile)): $($_.Exception.Message)" }
    $null
}
#endregion

#region ---- Small UI helpers ----------------------------------------------------
function Get-ComboValue {
    param($Combo)
    if ($Combo.SelectedItem -is [Windows.Controls.ComboBoxItem]) { "$($Combo.SelectedItem.Content)" } else { "$($Combo.Text)" }
}

function Set-ComboValue {
    param($Combo, [string]$Value)
    if (-not $Value) { return }
    foreach ($item in $Combo.Items) {
        if ($item -is [Windows.Controls.ComboBoxItem] -and "$($item.Content)" -eq $Value) { $Combo.SelectedItem = $item; return }
    }
    if ($Combo.IsEditable) { $Combo.Text = $Value }
}

function Get-DetTypeValue { "$($ui.CmbDetType.SelectedItem.Tag)" }

function Set-DetTypeValue {
    param([string]$Value)
    foreach ($item in $ui.CmbDetType.Items) { if ("$($item.Tag)" -eq $Value) { $ui.CmbDetType.SelectedItem = $item; return } }
}

function Get-ThemeBrush {
    param([string]$Key)
    $window.FindResource($Key)
}

# Intune's service only accepts specific release ids: '1607'-style build numbers or
# 'Windows10_22H2'/'Windows11_22H2'. Bare '22H2' gives 400 Unknown MinimumSupportedWindowsRelease.
function ConvertTo-MinOsValue {
    param([string]$Value)
    $trimmed = "$Value".Trim()
    if ($trimmed -match '^\d{2}H\d$') {
        $mapped = if ($trimmed -in '23H2', '24H2', '25H2') { "Windows11_$trimmed" } else { "Windows10_$trimmed" }
        Write-GuiLog "WARNING: '$trimmed' is not a valid Intune minimum Windows value — changed to '$mapped'."
        return $mapped
    }
    $trimmed
}

function Get-SetupKind {
    param([string]$Setup)
    if (-not $Setup) { 'none' }
    elseif ($Setup -ieq 'Invoke-AppDeployToolkit.exe') { 'psadt' }
    elseif ($Setup -like '*.msi') { 'msi' }
    else { 'exe' }
}

# What Intune should run for this setup file, plus any metadata the file itself carries
function Get-SetupDefault {
    param([Parameter(Mandatory)][string]$Folder, [string]$Setup)
    $result = @{
        Kind = Get-SetupKind $Setup; Install = ''; Uninstall = ''; Hint = ''
        Name = $null; Publisher = $null; Version = $null; ProductCode = $null
    }
    switch ($result.Kind) {
        'psadt' {
            $result.Install   = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent'
            $result.Uninstall = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent'
            $result.Hint      = 'PSADT package — the toolkit handles the silent install; these commands are the standard ones.'
        }
        'msi' {
            $msi = Get-MsiProperty -MsiPath (Join-Path $Folder $Setup)
            $result.Install     = "msiexec /i `"$Setup`" /qn /norestart"
            $result.Name        = $msi.ProductName
            $result.Publisher   = $msi.Manufacturer
            $result.Version     = $msi.ProductVersion
            $result.ProductCode = $msi.ProductCode
            if ($msi.ProductCode) { $result.Uninstall = "msiexec /x `"$($msi.ProductCode)`" /qn /norestart" }
            $result.Hint = 'MSI package — installs silently with msiexec /qn.'
        }
        'exe' {
            try {
                $info = Get-InstallerInfo -Path (Join-Path $Folder $Setup)
                $result.Install   = $info.InstallCommand
                $result.Uninstall = $info.UninstallCommand
                $result.Hint      = $info.Hint
                $result.Name      = $info.Name
                $result.Publisher = $info.Publisher
                $result.Version   = $info.Version
            }
            catch { $result.Install = '"' + $Setup + '"' }
        }
    }
    $result
}
#endregion

#region ---- Detection UI --------------------------------------------------------
function Update-DetectionUi {
    $type = Get-DetTypeValue
    $ui.PnlDetMsi.Visibility      = if ($type -eq 'msi') { 'Visible' } else { 'Collapsed' }
    $ui.PnlDetFile.Visibility     = if ($type -eq 'file') { 'Visible' } else { 'Collapsed' }
    $ui.PnlDetRegistry.Visibility = if ($type -eq 'registry') { 'Visible' } else { 'Collapsed' }
    $ui.PnlDetScript.Visibility   = if ($type -eq 'script') { 'Visible' } else { 'Collapsed' }
    $ui.PnlDetCompare.Visibility  = if ($type -in 'file', 'registry') { 'Visible' } else { 'Collapsed' }
    # The comparison value only means something when the check is not "exists"
    $showValue = ($type -in 'file', 'registry') -and (Get-ComboValue $ui.CmbDetCheck) -ne 'exists'
    $ui.LblDetValue.Visibility = if ($showValue) { 'Visible' } else { 'Collapsed' }
    $ui.TxtDetValue.Visibility = $ui.LblDetValue.Visibility
    $ui.CmbDetOperator.Visibility = if ($showValue) { 'Visible' } else { 'Hidden' }
    # The "find the app" shortcut only produces registry rules
    $ui.BtnRegPick.Visibility = if ($type -eq 'registry') { 'Visible' } else { 'Collapsed' }
}

# Plain-language description of the rule, so nobody has to read Intune jargon
function Get-DetectionSummary {
    $type = Get-DetTypeValue
    $check = Get-ComboValue $ui.CmbDetCheck
    $operatorWord = switch (Get-ComboValue $ui.CmbDetOperator) {
        'equal'              { 'is' }
        'notEqual'           { 'is not' }
        'greaterThan'        { 'is newer than' }
        'greaterThanOrEqual' { 'is at least' }
        'lessThan'           { 'is older than' }
        'lessThanOrEqual'    { 'is at most' }
        default              { 'is' }
    }
    switch ($type) {
        'msi' {
            $code = $ui.TxtProductCode.Text.Trim()
            if ($code) { @{ Ok = $true; Text = "Intune checks that the MSI product $code is installed." } }
            else { @{ Ok = $false; Text = 'No MSI product code yet. Open "Change detection method" and click "From MSI...".' } }
        }
        'registry' {
            $key = $ui.TxtKeyPath.Text.Trim()
            if (-not $key -or $key -match '\\Uninstall\\?$') {
                @{ Ok = $false; Text = 'No detection rule yet. Click "Find the app on this computer..." and pick the app — the rule is written for you.' }
            }
            else {
                $leaf = Split-Path -Leaf $key
                $value = $ui.TxtValueName.Text.Trim()
                if (-not $value -or $check -eq 'exists') {
                    @{ Ok = $true; Text = "Intune checks that the registry key $leaf exists." }
                }
                else {
                    @{ Ok = $true; Text = "Intune reads $value under the registry key $leaf and treats the app as installed when it $operatorWord $($ui.TxtDetValue.Text.Trim())." }
                }
            }
        }
        'file' {
            $path = $ui.TxtDetPath.Text.Trim(); $name = $ui.TxtDetFile.Text.Trim()
            if (-not $path -or -not $name) { @{ Ok = $false; Text = 'Fill in the folder path and the file or folder name to look for.' } }
            elseif ($check -eq 'exists') { @{ Ok = $true; Text = "Intune checks that $path\$name exists." } }
            else { @{ Ok = $true; Text = "Intune checks that $path\$name $operatorWord $($ui.TxtDetValue.Text.Trim())." } }
        }
        'script' {
            $file = $ui.TxtScript.Text.Trim()
            if ($file) { @{ Ok = $true; Text = "A PowerShell script ($([IO.Path]::GetFileName($file))) decides whether the app is installed." } }
            else { @{ Ok = $false; Text = 'Pick the PowerShell script that checks whether the app is installed.' } }
        }
        default { @{ Ok = $false; Text = 'Pick a detection method.' } }
    }
}

function Update-DetectionSummary {
    $summary = Get-DetectionSummary
    $ui.TxtDetSummary.Text = $summary.Text
    if ($summary.Ok) {
        $ui.PnlDetSummary.Background  = Get-ThemeBrush 'OkSoft'
        $ui.PnlDetSummary.BorderBrush = Get-ThemeBrush 'Ok'
        $ui.TxtDetSummary.Foreground  = Get-ThemeBrush 'Ok'
    }
    else {
        $ui.PnlDetSummary.Background  = Get-ThemeBrush 'WarnSoft'
        $ui.PnlDetSummary.BorderBrush = Get-ThemeBrush 'Warn'
        $ui.TxtDetSummary.Foreground  = Get-ThemeBrush 'Warn'
    }
    $summary.Ok
}
#endregion

#region ---- Preview, icon and view switching ------------------------------------
function Update-PreviewCard {
    $name = $ui.TxtName.Text.Trim()
    $ui.PvName.Text        = if ($name) { $name } else { '(no name yet)' }
    $ui.PvPublisher.Text   = if ($ui.TxtPublisher.Text.Trim()) { $ui.TxtPublisher.Text.Trim() } else { '(no publisher yet)' }
    $ui.PvVersion.Text     = if ($ui.TxtVersion.Text.Trim()) { "Version $($ui.TxtVersion.Text.Trim())" } else { '' }
    $ui.PvDescription.Text = $ui.TxtDescription.Text.Trim()
    $ui.TxtHeaderPkg.Text  = if ($script:LoadedFolder) { $script:LoadedFolder } else { '' }
}

function Set-IconPreview {
    param([string]$Path, [string]$Note)
    try {
        $bitmap = New-Object Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.UriSource = [Uri]$Path
        $bitmap.CacheOption = 'OnLoad'
        $bitmap.DecodePixelWidth = 128
        $bitmap.EndInit()
        $ui.ImgIcon.Source = $bitmap
        $ui.ImgPreview.Source = $bitmap
        $script:IconAbsPath = $Path
        $ui.TxtIconPath.Text = if ($Note) { $Note } else { [IO.Path]::GetFileName($Path) }
    }
    catch { Write-GuiLog "WARNING: Could not read the image: $($_.Exception.Message)" }
}

function Clear-IconPreview {
    $script:IconAbsPath = $null
    $ui.ImgIcon.Source = $null
    $ui.ImgPreview.Source = $null
    $ui.TxtIconPath.Text = 'No logo yet — the app gets a generic icon in the Company Portal.'
}

# Take the app's real icon: from the installed app the user picked for detection, else
# from the vendor payload inside the package, else from the setup file itself.
function Import-PackageIcon {
    if (-not $script:LoadedFolder) { return }
    $destination = Join-Path $script:LoadedFolder 'icon.png'
    $attempts = @()
    if ($script:PickedApp) {
        $reference = Resolve-IconReference -Reference $script:PickedApp.DisplayIcon
        if ($reference) { $attempts += @{ Source = $reference.Path; Index = $reference.Index; From = "the installed app $($script:PickedApp.DisplayName)" } }
    }
    foreach ($candidate in (Find-PayloadFile -Folder $script:LoadedFolder -Extension '.exe')) {
        $attempts += @{ Source = $candidate.FullName; Index = 0; From = $candidate.Name }
    }
    $setup = "$($ui.CmbSetup.SelectedItem)"
    if ((Get-SetupKind $setup) -eq 'exe') {
        $attempts += @{ Source = Join-Path $script:LoadedFolder $setup; Index = 0; From = $setup }
    }
    if (-not $attempts) {
        Write-GuiLog 'No program file to take an icon from — the package only holds an MSI. Install the app and use "Find the app on this computer...", or choose an image.'
        Set-StatusText 'No icon source found in the package.'
        return
    }
    foreach ($attempt in $attempts) {
        $size = Export-IconFile -SourceFile $attempt.Source -IconIndex $attempt.Index -Destination $destination
        if ($size) {
            Set-IconPreview -Path $destination -Note "icon.png — ${size}x${size}, taken from $($attempt.From)"
            Write-GuiLog "Icon extracted from $($attempt.From) (${size}x${size}) to icon.png"
            if ($size -lt 64) { Write-GuiLog 'Only a small icon was available; a larger png looks sharper in the Company Portal.' }
            Update-Readiness | Out-Null
            return
        }
    }
    Write-GuiLog 'None of the program files in the package contained an icon. Choose an image instead.'
}

function Show-StartView {
    $script:LoadedFolder = $null
    $ui.ViewEditor.Visibility = 'Collapsed'
    $ui.ViewStart.Visibility  = 'Visible'
    $ui.PnlActions.Visibility = 'Collapsed'
    $ui.PnlHeaderPkg.Visibility = 'Collapsed'
    $recent = @(Get-RecentPackage)
    $ui.LstRecent.ItemsSource = $recent
    $ui.LstRecent.Visibility    = if ($recent.Count) { 'Visible' } else { 'Collapsed' }
    $ui.TxtRecentEmpty.Visibility = if ($recent.Count) { 'Collapsed' } else { 'Visible' }
    Set-StatusText 'Choose how you want to start.'
}

function Show-EditorView {
    $ui.ViewStart.Visibility  = 'Collapsed'
    $ui.ViewEditor.Visibility = 'Visible'
    $ui.PnlActions.Visibility = 'Visible'
    $ui.PnlHeaderPkg.Visibility = 'Visible'
}
#endregion

#region ---- Opening a package ---------------------------------------------------
# Fill the whole editor from a package folder. Precedence matches Publish-IntuneWinApp:
# app.json > PSADT $adtSession > the setup file's own metadata > empty.
function Open-PackageFolder {
    param([Parameter(Mandatory)][string]$Folder, [string]$PreferSetup)

    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        Set-StatusText "Folder not found: $Folder"
        Write-GuiLog "ERROR: Folder not found: $Folder"
        return $false
    }
    # .ProviderPath, never .Path: for a UNC path PathInfo.Path is provider-qualified
    # ("Microsoft.PowerShell.Core\FileSystem::\\server\share\..."), Join-Path keeps the
    # prefix, and everything outside PowerShell — IntuneWinAppUtil.exe, the WindowsInstaller
    # COM object — then fails to open a path that looks perfectly fine in the log.
    $Folder = (Resolve-Path -LiteralPath $Folder).ProviderPath
    $script:LoadedFolder  = $Folder
    $script:InitialValues = $null
    $script:PickedApp     = $null
    $script:MsiListCache.Remove($Folder.ToLowerInvariant())
    $script:Loading = $true

    try {
        # Setup file candidates
        $ui.CmbSetup.Items.Clear()
        $candidates = @(Get-ChildItem -LiteralPath $Folder -File |
                        Where-Object { $_.Extension -in '.exe', '.msi' } | Select-Object -ExpandProperty Name)
        foreach ($candidate in $candidates) { [void]$ui.CmbSetup.Items.Add($candidate) }
        $msiCandidates = @($candidates | Where-Object { $_ -like '*.msi' })
        if ($PreferSetup -and $candidates -contains $PreferSetup)          { $ui.CmbSetup.SelectedItem = $PreferSetup }
        elseif ($candidates -contains 'Invoke-AppDeployToolkit.exe')       { $ui.CmbSetup.SelectedItem = 'Invoke-AppDeployToolkit.exe' }
        elseif ($msiCandidates.Count -eq 1)                                { $ui.CmbSetup.SelectedItem = $msiCandidates[0] }
        elseif ($candidates.Count -gt 0)                                   { $ui.CmbSetup.SelectedIndex = 0 }

        $setup = "$($ui.CmbSetup.SelectedItem)"
        $defaults = if ($setup) { Get-SetupDefault -Folder $Folder -Setup $setup } else { @{ Kind = 'none' } }
        $psadt = if ($defaults.Kind -eq 'psadt') { Get-PsadtMetadata -Folder $Folder } else { @{} }

        $manifestPath = Join-Path $Folder 'app.json'
        $manifest = $null
        if (Test-Path -LiteralPath $manifestPath) {
            try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
            catch { Write-GuiLog "WARNING: app.json could not be read: $($_.Exception.Message)" }
        }

        # Where each value may come from, best source first
        $fileTag = switch ($defaults.Kind) { 'msi' { 'MSI' } 'exe' { 'installer' } default { 'setup file' } }
        $layers = @(
            @{ Tag = 'app.json'; Name = "$($manifest.displayName)"; Publisher = "$($manifest.publisher)"; Version = "$($manifest.version)" }
            @{ Tag = 'PSADT';    Name = "$($psadt.AppName)";        Publisher = "$($psadt.AppVendor)";    Version = "$($psadt.AppVersion)" }
            @{ Tag = $fileTag;   Name = "$($defaults.Name)";        Publisher = "$($defaults.Publisher)"; Version = "$($defaults.Version)" }
        )
        foreach ($field in 'Name', 'Publisher', 'Version') {
            $value = ''; $tag = 'default'
            foreach ($layer in $layers) {
                if ("$($layer[$field])".Trim()) { $value = "$($layer[$field])".Trim(); $tag = $layer.Tag; break }
            }
            $ui."Txt$field".Text = $value
            $ui."Tag$field".Text = "from $tag"
        }
        $ui.TxtDescription.Text = "$($manifest.description)"

        $ui.TxtInstall.Text   = if ("$($manifest.installCommandLine)".Trim())   { $manifest.installCommandLine }   else { $defaults.Install }
        $ui.TxtUninstall.Text = if ("$($manifest.uninstallCommandLine)".Trim()) { $manifest.uninstallCommandLine } else { $defaults.Uninstall }
        $ui.TxtCmdHint.Text   = "$($defaults.Hint)"
        $script:DerivedInstall   = $defaults.Install
        $script:DerivedUninstall = $defaults.Uninstall

        Set-ComboValue $ui.CmbRunAs   $(if ($manifest.runAsAccount)    { $manifest.runAsAccount }    else { 'system' })
        Set-ComboValue $ui.CmbRestart $(if ($manifest.restartBehavior) { $manifest.restartBehavior } else { 'suppress' })
        Set-ComboValue $ui.CmbArch    $(if ($manifest.architecture)    { $manifest.architecture }    else { 'x64' })
        Set-ComboValue $ui.CmbMinOs   (ConvertTo-MinOsValue $(if ($manifest.minimumWindowsRelease) { $manifest.minimumWindowsRelease } else { '1607' }))
        $ui.ChkUpdateExisting.IsChecked = $false
        $ui.ChkAllowDuplicate.IsChecked = $false

        # Detection: saved rule wins; otherwise MSI packages get the product code rule and
        # everything else starts on the registry method the "find the app" button fills in.
        $detection = $manifest.detection
        $ui.TxtProductCode.Text = ''; $ui.TxtDetPath.Text = ''; $ui.TxtDetFile.Text = ''
        $ui.TxtKeyPath.Text = ''; $ui.TxtValueName.Text = ''; $ui.TxtDetValue.Text = ''; $ui.TxtScript.Text = ''
        if ($detection) {
            Set-DetTypeValue "$($detection.type)"
            $ui.TxtProductCode.Text = "$($detection.productCode)"
            $ui.TxtDetPath.Text     = "$($detection.path)"
            $ui.TxtDetFile.Text     = "$($detection.fileOrFolderName)"
            $ui.TxtKeyPath.Text     = "$($detection.keyPath)"
            $ui.TxtValueName.Text   = "$($detection.valueName)"
            Set-ComboValue $ui.CmbDetCheck    $(if ($detection.detectionType) { $detection.detectionType } else { 'exists' })
            Set-ComboValue $ui.CmbDetOperator $(if ($detection.operator)      { $detection.operator }      else { 'notConfigured' })
            $ui.TxtDetValue.Text   = "$($detection.detectionValue)"
            $ui.ChkDet32.IsChecked = [bool]$detection.check32BitOn64System
            $ui.TxtScript.Text     = "$($detection.scriptFile)"
        }
        elseif ($defaults.ProductCode) {
            Set-DetTypeValue 'msi'
            $ui.TxtProductCode.Text = $defaults.ProductCode
        }
        else {
            Set-DetTypeValue 'registry'
            Set-ComboValue $ui.CmbDetCheck 'version'
            Set-ComboValue $ui.CmbDetOperator 'greaterThanOrEqual'
            $ui.TxtDetValue.Text = $ui.TxtVersion.Text
            $ui.ChkDet32.IsChecked = $false
        }

        # Logo: the manifest reference, else an icon.png/logo.png lying in the folder
        Clear-IconPreview
        $iconReference = "$($manifest.icon)"
        if (-not $iconReference) {
            $guess = Get-ChildItem -LiteralPath $Folder -File |
                     Where-Object { $_.Name -match '^(icon|logo)\.(png|jpe?g)$' } | Select-Object -First 1
            if ($guess) { $iconReference = $guess.Name }
        }
        if ($iconReference) {
            $iconFull = if ([IO.Path]::IsPathRooted($iconReference)) { $iconReference } else { Join-Path $Folder $iconReference }
            if (Test-Path -LiteralPath $iconFull) { Set-IconPreview -Path $iconFull }
        }
    }
    finally { $script:Loading = $false }

    # Snapshot after loading so hand edits can be tagged "manual"
    $script:InitialValues = @{
        Name = $ui.TxtName.Text; NameTag = $ui.TagName.Text
        Publisher = $ui.TxtPublisher.Text; PublisherTag = $ui.TagPublisher.Text
        Version = $ui.TxtVersion.Text; VersionTag = $ui.TagVersion.Text
    }

    # MSI rule saved without a code (or picked before the MSI was known): fill it in
    if ((Get-DetTypeValue) -eq 'msi' -and -not $ui.TxtProductCode.Text.Trim()) {
        $found = @(Find-PackageMsi)
        if ($found.Count -eq 1) { Import-MsiProductCode -MsiPath $found[0].FullName }
        elseif ($found.Count -gt 1) { Write-GuiLog "The package holds $($found.Count) MSI files — use 'From MSI...' to pick the right one." }
    }

    Show-EditorView
    Update-DetectionUi
    Update-PreviewCard
    Update-Readiness
    Add-RecentPackage -Folder $Folder
    $kindText = switch ($defaults.Kind) {
        'psadt' { 'PSADT package' } 'msi' { 'MSI package' }
        'exe'   { "installer ($($defaults.Hint -replace ' —.*',''))" } default { 'no setup file found' }
    }
    Write-GuiLog "Opened $Folder ($kindText)"
    Set-StatusText "Opened '$(Split-Path -Leaf $Folder)'. Review the fields, then publish."
    $true
}

# Re-derive the commands when the setup file changes, without discarding hand edits
function Update-SetupSelection {
    if ($script:Loading -or -not $script:LoadedFolder) { return }
    $setup = "$($ui.CmbSetup.SelectedItem)"
    if (-not $setup) { return }
    $defaults = Get-SetupDefault -Folder $script:LoadedFolder -Setup $setup
    foreach ($pair in @(
        @{ Box = $ui.TxtInstall;   New = $defaults.Install;   Old = $script:DerivedInstall }
        @{ Box = $ui.TxtUninstall; New = $defaults.Uninstall; Old = $script:DerivedUninstall })) {
        $current = $pair.Box.Text.Trim()
        if (-not $current -or $current -eq "$($pair.Old)".Trim()) { $pair.Box.Text = "$($pair.New)" }
        elseif ("$($pair.New)".Trim() -and $current -ne "$($pair.New)".Trim()) {
            Write-GuiLog "Setup file changed — '$($pair.Box.Name)' was edited by hand and was left as it is. Suggested: $($pair.New)"
        }
    }
    $script:DerivedInstall   = $defaults.Install
    $script:DerivedUninstall = $defaults.Uninstall
    $ui.TxtCmdHint.Text = "$($defaults.Hint)"
    if ($defaults.ProductCode -and (Get-DetTypeValue) -eq 'msi' -and -not $ui.TxtProductCode.Text.Trim()) {
        $ui.TxtProductCode.Text = $defaults.ProductCode
    }
    Write-GuiLog "Setup file set to $setup"
    Update-DetectionSummary | Out-Null
    Update-Readiness | Out-Null
}

function Import-MsiProductCode {
    param([Parameter(Mandatory)][string]$MsiPath)
    $msi = Get-MsiProperty -MsiPath $MsiPath
    if (-not $msi.Count) { Write-GuiLog "WARNING: No properties could be read from $([IO.Path]::GetFileName($MsiPath))"; return }
    if ($msi.ProductCode) { $ui.TxtProductCode.Text = $msi.ProductCode }
    Write-GuiLog ("Read {0}: {1} {2} {3}" -f [IO.Path]::GetFileName($MsiPath), $msi.ProductName, $msi.ProductVersion, $msi.ProductCode)
    foreach ($pair in @(
        @{ Box = $ui.TxtName; Value = $msi.ProductName; Key = 'Name' }
        @{ Box = $ui.TxtVersion; Value = $msi.ProductVersion; Key = 'Version' })) {
        if (-not $pair.Box.Text.Trim() -and $pair.Value) {
            $pair.Box.Text = $pair.Value
            $ui."Tag$($pair.Key)".Text = 'from MSI'
            if ($script:InitialValues) {
                $script:InitialValues[$pair.Key] = $pair.Value
                $script:InitialValues["$($pair.Key)Tag"] = 'from MSI'
            }
        }
    }
    Update-DetectionSummary | Out-Null
    Update-Readiness | Out-Null
}
#endregion

#region ---- Saving app.json -----------------------------------------------------
# Absolute or package-relative detection script -> full path, or $null when missing
function Resolve-DetectionScript {
    $file = $ui.TxtScript.Text.Trim()
    if (-not $file) { return $null }
    $full = if ([IO.Path]::IsPathRooted($file)) { $file } else { Join-Path "$script:LoadedFolder" $file }
    if (Test-Path -LiteralPath $full -PathType Leaf) { $full } else { $null }
}

function Save-AppManifest {
    if (-not $script:LoadedFolder) { throw 'No package folder is open.' }
    $manifestPath = Join-Path $script:LoadedFolder 'app.json'
    $existing = @{}
    if (Test-Path -LiteralPath $manifestPath) {
        try { $existing = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable } catch { $existing = @{} }
    }

    $type = Get-DetTypeValue
    $detection = [ordered]@{ type = $type }
    switch ($type) {
        'msi' { if ($ui.TxtProductCode.Text.Trim()) { $detection.productCode = $ui.TxtProductCode.Text.Trim() } }
        'file' {
            $detection.path             = $ui.TxtDetPath.Text.Trim()
            $detection.fileOrFolderName = $ui.TxtDetFile.Text.Trim()
            $detection.detectionType    = Get-ComboValue $ui.CmbDetCheck
            $detection.operator         = Get-ComboValue $ui.CmbDetOperator
            if ($ui.TxtDetValue.Text.Trim()) { $detection.detectionValue = $ui.TxtDetValue.Text.Trim() }
            $detection.check32BitOn64System = [bool]$ui.ChkDet32.IsChecked
        }
        'registry' {
            $detection.keyPath       = $ui.TxtKeyPath.Text.Trim()
            $detection.valueName     = $ui.TxtValueName.Text.Trim()
            $detection.detectionType = Get-ComboValue $ui.CmbDetCheck
            $detection.operator      = Get-ComboValue $ui.CmbDetOperator
            if ($ui.TxtDetValue.Text.Trim()) { $detection.detectionValue = $ui.TxtDetValue.Text.Trim() }
            $detection.check32BitOn64System = [bool]$ui.ChkDet32.IsChecked
        }
        'script' {
            # Keep it relative when the script lives in the package, so the folder stays portable
            $resolved = Resolve-DetectionScript
            $detection.scriptFile = if ($resolved -and (Split-Path -Parent $resolved) -ieq $script:LoadedFolder) {
                [IO.Path]::GetFileName($resolved)
            } else { $ui.TxtScript.Text.Trim() }
        }
    }

    # Logo: copy into the package folder when picked from elsewhere, store the file name
    $iconReference = $null
    if ($script:IconAbsPath) {
        if ((Split-Path -Parent $script:IconAbsPath) -ieq $script:LoadedFolder) {
            $iconReference = [IO.Path]::GetFileName($script:IconAbsPath)
        }
        else {
            $iconReference = 'icon' + [IO.Path]::GetExtension($script:IconAbsPath)
            Copy-Item -LiteralPath $script:IconAbsPath -Destination (Join-Path $script:LoadedFolder $iconReference) -Force
            $script:IconAbsPath = Join-Path $script:LoadedFolder $iconReference
            Write-GuiLog "Copied the logo into the package folder as $iconReference"
        }
    }

    $merged = [ordered]@{}
    foreach ($key in $existing.Keys) { $merged[$key] = $existing[$key] }   # keep fields we do not edit (owner, notes...)
    $merged.displayName = $ui.TxtName.Text.Trim()
    $merged.publisher   = $ui.TxtPublisher.Text.Trim()
    if ($ui.TxtVersion.Text.Trim())     { $merged.version = $ui.TxtVersion.Text.Trim() }         else { $merged.Remove('version') }
    if ($ui.TxtDescription.Text.Trim()) { $merged.description = $ui.TxtDescription.Text.Trim() } else { $merged.Remove('description') }
    $merged.installCommandLine    = $ui.TxtInstall.Text.Trim()
    $merged.uninstallCommandLine  = $ui.TxtUninstall.Text.Trim()
    $merged.runAsAccount          = Get-ComboValue $ui.CmbRunAs
    $merged.restartBehavior       = Get-ComboValue $ui.CmbRestart
    $merged.architecture          = Get-ComboValue $ui.CmbArch
    $merged.minimumWindowsRelease = ConvertTo-MinOsValue "$($ui.CmbMinOs.Text)"
    $merged.detection             = $detection
    if ($iconReference) { $merged.icon = $iconReference } else { $merged.Remove('icon') }

    ($merged | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-GuiLog "Settings saved to $manifestPath"
    $manifestPath
}
#endregion

#region ---- Readiness and validation --------------------------------------------
function Set-CheckLine {
    param($Block, [bool]$Ok, [string]$Text)
    $Block.Text = ([string][char]0x2713, [string][char]0x2715)[[int](-not $Ok)] + '   ' + $Text
    $Block.Foreground = Get-ThemeBrush $(if ($Ok) { 'Ok' } else { 'Warn' })
}

# Everything Intune insists on, as a live checklist instead of one dialog at a time
function Update-Readiness {
    $hasSetup     = [bool]"$($ui.CmbSetup.SelectedItem)"
    $hasName      = [bool]$ui.TxtName.Text.Trim()
    $hasPublisher = [bool]$ui.TxtPublisher.Text.Trim()
    $detectionOk  = Update-DetectionSummary
    if ((Get-DetTypeValue) -eq 'script') { $detectionOk = [bool](Resolve-DetectionScript) }

    Set-CheckLine $ui.ChkSetup     $hasSetup     $(if ($hasSetup) { "Setup file: $($ui.CmbSetup.SelectedItem)" } else { 'No setup file in this folder' })
    Set-CheckLine $ui.ChkName      $hasName      $(if ($hasName) { 'Name' } else { 'Name is missing' })
    Set-CheckLine $ui.ChkPublisher $hasPublisher $(if ($hasPublisher) { 'Publisher' } else { 'Publisher is missing' })
    Set-CheckLine $ui.ChkDetection $detectionOk  $(if ($detectionOk) { 'Detection rule' } else { 'Detection rule is not set' })

    $ready = $hasSetup -and $hasName -and $hasPublisher -and $detectionOk
    $ui.TxtReadyTitle.Text = if ($ready) { 'Ready to publish' } else { 'Not ready yet' }
    $ui.TxtReadyTitle.Foreground = Get-ThemeBrush $(if ($ready) { 'Ok' } else { 'Ink' })
    $ui.PnlReady.BorderBrush = Get-ThemeBrush $(if ($ready) { 'Ok' } else { 'Stroke' })
    $ui.TxtReadyNote.Text = if ($ready) {
        'Publishing builds the .intunewin and creates the app in Intune. No groups are assigned — do that in the portal.'
    } else { 'Fill in the items marked above. "Build only" works without them.' }
    $ui.TxtActionHint.Text = if ($ready) { '' } else { 'Some required information is still missing.' }
    $ready
}

# Mark the offending fields and take the user there, instead of a modal dialog
function Test-ReadyToRun {
    param([switch]$ForPublish)
    foreach ($box in $ui.TxtName, $ui.TxtPublisher, $ui.TxtProductCode, $ui.TxtDetPath,
                     $ui.TxtDetFile, $ui.TxtKeyPath, $ui.TxtScript) { $box.Tag = $null }

    if (-not $script:LoadedFolder) { Set-StatusText 'Open a package folder first.'; return $false }
    if (-not "$($ui.CmbSetup.SelectedItem)") {
        $ui.ExpAdvanced.IsExpanded = $true
        Set-StatusText 'This folder has no .exe or .msi to package. Pick another folder.'
        return $false
    }
    if (-not $ForPublish) { return $true }

    $issues = @()
    if (-not $ui.TxtName.Text.Trim())      { $issues += @{ Box = $ui.TxtName;      Message = 'The app needs a name.' } }
    if (-not $ui.TxtPublisher.Text.Trim()) { $issues += @{ Box = $ui.TxtPublisher; Message = 'The app needs a publisher.' } }

    $type = Get-DetTypeValue
    $detectionBox = switch ($type) {
        'msi'      { if (-not $ui.TxtProductCode.Text.Trim()) { $ui.TxtProductCode } }
        'file'     { if (-not $ui.TxtDetPath.Text.Trim()) { $ui.TxtDetPath } elseif (-not $ui.TxtDetFile.Text.Trim()) { $ui.TxtDetFile } }
        'registry' { if (-not (Get-DetectionSummary).Ok) { $ui.TxtKeyPath } }
        'script'   { if (-not (Resolve-DetectionScript)) { $ui.TxtScript } }
    }
    if ($detectionBox) {
        $issues += @{ Box = $detectionBox; Message = 'Intune needs a detection rule. Use "Find the app on this computer..." or fill in the fields.' }
        $ui.ExpDetection.IsExpanded = $true
    }

    if (-not $issues) { return $true }
    foreach ($issue in $issues) { $issue.Box.Tag = 'invalid' }
    Set-StatusText $issues[0].Message
    Write-GuiLog "Cannot publish yet: $($issues[0].Message)"
    $issues[0].Box.Focus() | Out-Null
    $false
}
#endregion

#region ---- Installed-app picker dialog -----------------------------------------
$script:PickerXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Find the app on this computer" Width="740" Height="540" MinWidth="580" MinHeight="380"
        WindowStartupLocation="CenterOwner" Background="#F2F3F5" FontFamily="Segoe UI" FontSize="12"
        ShowInTaskbar="False">
  <Window.Resources>
<!--THEME-->
  </Window.Resources>
  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel>
      <TextBlock Style="{StaticResource H2}" Text="Pick the application"/>
      <TextBlock Style="{StaticResource Muted}" Margin="0,4,0,0"
                 Text="This is the list from Apps and features on this computer. Picking the app writes the detection rule from its uninstall entry. If the app is missing, install it here first and then reopen this list."/>
    </StackPanel>
    <TextBox x:Name="PTxtFilter" Grid.Row="1" Margin="0,12,0,8"/>
    <ListView x:Name="PLstApps" Grid.Row="2" BorderBrush="{StaticResource Stroke}" Background="{StaticResource BgCard}">
      <ListView.View>
        <GridView>
          <GridViewColumn Header="Name" Width="300" DisplayMemberBinding="{Binding DisplayName}"/>
          <GridViewColumn Header="Version" Width="110" DisplayMemberBinding="{Binding DisplayVersion}"/>
          <GridViewColumn Header="Publisher" Width="190" DisplayMemberBinding="{Binding Publisher}"/>
          <GridViewColumn Header="Bits" Width="50" DisplayMemberBinding="{Binding Bitness}"/>
        </GridView>
      </ListView.View>
    </ListView>
    <DockPanel Grid.Row="3" Margin="0,12,0,0">
      <Button x:Name="PBtnCancel" DockPanel.Dock="Right" Style="{StaticResource BtnDefault}" Content="Cancel"
              Margin="8,0,0,0" IsCancel="True"/>
      <Button x:Name="PBtnOk" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="Use this app"
              IsDefault="True" IsEnabled="False"/>
      <TextBlock x:Name="PTxtCount" Style="{StaticResource Tiny}" VerticalAlignment="Center"/>
    </DockPanel>
  </Grid>
</Window>
'@

# Searchable Apps & features picker; returns the selected app object or $null
function Show-InstalledAppPicker {
    param($Owner)
    $dialog = New-StudioWindow -Xaml $script:PickerXaml
    if ($Owner) { $dialog.Window.Owner = $Owner }
    $script:Pick = @{ Window = $dialog.Window; C = $dialog.C; All = @(Get-InstalledApp); Result = $null }
    $dialog.C.PTxtFilter.Text = ''
    $dialog.C.PLstApps.ItemsSource = $script:Pick.All
    $dialog.C.PTxtCount.Text = "$($script:Pick.All.Count) programs installed"
    $dialog.C.PTxtFilter.Add_TextChanged({
        $filter = $script:Pick.C.PTxtFilter.Text.Trim()
        $shown = if ($filter) {
            @($script:Pick.All | Where-Object { $_.DisplayName -like "*$filter*" -or $_.Publisher -like "*$filter*" })
        } else { $script:Pick.All }
        $script:Pick.C.PLstApps.ItemsSource = $shown
        $script:Pick.C.PTxtCount.Text = "$(@($shown).Count) of $($script:Pick.All.Count) programs"
    })
    $dialog.C.PLstApps.Add_SelectionChanged({
        $script:Pick.C.PBtnOk.IsEnabled = ($null -ne $script:Pick.C.PLstApps.SelectedItem)
    })
    $acceptSelection = {
        if ($script:Pick.C.PLstApps.SelectedItem) {
            $script:Pick.Result = $script:Pick.C.PLstApps.SelectedItem
            $script:Pick.Window.DialogResult = $true
        }
    }
    $dialog.C.PBtnOk.Add_Click($acceptSelection)
    $dialog.C.PLstApps.Add_MouseDoubleClick($acceptSelection)
    $dialog.C.PBtnCancel.Add_Click({ $script:Pick.Window.DialogResult = $false })
    $dialog.Window.Add_Loaded({ $script:Pick.C.PTxtFilter.Focus() })
    [void]$dialog.Window.ShowDialog()
    $result = $script:Pick.Result
    $script:Pick = $null
    if ($result) { $script:PickedApp = $result }
    $result
}

# Scaffold a package folder: copy the installer in, optionally the logo, write app.json
function New-InstallerPackage {
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$TargetFolder,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Manifest,
        [string]$IconSource
    )
    $null = New-Item -ItemType Directory -Path $TargetFolder -Force
    $TargetFolder = (Resolve-Path -LiteralPath $TargetFolder).ProviderPath
    $destination = Join-Path $TargetFolder ([IO.Path]::GetFileName($InstallerPath))
    if ((Resolve-Path -LiteralPath $InstallerPath).ProviderPath -ine $destination) {
        Copy-Item -LiteralPath $InstallerPath -Destination $destination -Force
    }
    if ($IconSource -and (Test-Path -LiteralPath $IconSource)) {
        $iconName = 'icon' + [IO.Path]::GetExtension($IconSource)
        Copy-Item -LiteralPath $IconSource -Destination (Join-Path $TargetFolder $iconName) -Force
        $Manifest.icon = $iconName
    }
    ($Manifest | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $TargetFolder 'app.json') -Encoding UTF8
    $TargetFolder
}
#endregion

#region ---- In-app help ----------------------------------------------------------
# Written for the person using the tool, not the person who installed it — the README
# covers setup, auth and the command line. Paragraphs are split on blank lines.
$script:HelpTopics = @(
    @{ Title = 'What this does'
       Body  = @'
It turns a folder holding an installation file into a Win32 app in Intune.

Publishing does two things: the folder is packed into an .intunewin file, and an app is created in Intune with the settings shown on screen. No groups are assigned — you do that in the Intune portal afterwards.
'@ }
    @{ Title = 'Two ways to start'
       Body  = @'
I have an installer file — pick the .exe or .msi you got from the vendor. A five-step wizard creates the package folder and fills in the silent install switches for the installer type it recognises (MSI, Inno Setup, NSIS, InstallShield, WiX Burn).

I have a package folder — open a folder that already holds the installation files: a PSADT package, an MSI, or a plain installer. Anything previously saved in the folder is loaded.

You can also drag a package folder or an installer straight onto the window.
'@ }
    @{ Title = 'What Intune insists on'
       Body  = @'
A name, a publisher and a detection rule. The checklist on the right turns green when all three are set, and the Publish button tells you which field is missing if you try too early.

Everything else already has a sensible default.
'@ }
    @{ Title = 'Detection — the one thing worth understanding'
       Body  = @'
Intune has to answer "is this app already on the device?" without running the installer. That is what a detection rule is for, and Intune refuses an app without one.

The easy way: install the app on this computer as a normal double-click install, then press "Find the app on this computer..." and pick it from the list. The rule is written from the app's own uninstall entry — the same information Apps and features shows — and a silent uninstall command is picked up when the app provides one. You can uninstall the app again afterwards.

MSI packages need nothing: the product code is read straight from the MSI.

If you would rather write the rule yourself, open "Change detection method": a registry key, a file or folder, or a PowerShell script.
'@ }
    @{ Title = 'Where your settings are kept'
       Body  = @'
Everything you change is written to app.json in the package folder when you save, build or publish.

That is the same file the command-line tools read, so a package prepared here works identically without this window, and a colleague who opens the folder sees your settings.
'@ }
    @{ Title = 'Publishing'
       Body  = @'
Publish to Intune builds the package and creates the app. A confirmation dialog repeats the name, version and detection rule first.

If Intune already has an app with the same name, publishing stops before anything is created — that is usually the sign that the same thing is being published twice. If a second app with that name is genuinely what you want, tick the box under Advanced.

A long upload can be cancelled. If the upload had already started, check Intune for a half-created app and remove it before trying again.

Build only produces the .intunewin file in the Output folder without touching Intune.
'@ }
    @{ Title = 'Where things are kept'
       Body  = @'
Settings in the header holds the two folders Packwright writes to: the package folder, where the wizard creates a folder per package, and the output folder, where the built .intunewin files land. You are asked once, the first time the tool starts.

Both default to a local disk on purpose. Documents is usually redirected to a network home directory on a managed machine, and packaging from there fails in ways that point at the wrong thing — the MSI properties come back empty, or the build stops with "the setup file cannot be accessed". Pick a folder on C:. The dialog says so if you pick something else, and the log repeats it when a build starts from a network path.
'@ }
    @{ Title = 'If something goes wrong'
       Body  = @'
Open the Log at the bottom of the window. It holds everything the build and the upload did, including the full error text.

The usual causes: the detection rule is not set; an app with the same name already exists (add the version to the name); or Minimum Windows was typed by hand — Intune only accepts values such as 1607 or Windows10_22H2, and the tool corrects the obvious mistakes for you.
'@ }
    @{ Title = 'Signing in'
       Body  = @'
The top right corner shows how publishing authenticates.

With a .secret file next to the script, the tool signs in as an app registration and never prompts. Without one, a browser sign-in opens and your own Intune permissions decide what you are allowed to do.

That browser window can open behind this one — if a publish seems to stall right after it starts, look for it in the taskbar. Publishing stops if the sign-in fails, so nothing is half-created in Intune.
'@ }
)

$script:HelpXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="How to use Packwright" Width="720" Height="640" MinWidth="520" MinHeight="400"
        WindowStartupLocation="CenterOwner" Background="#F2F3F5" FontFamily="Segoe UI" FontSize="12"
        ShowInTaskbar="False">
  <Window.Resources>
<!--THEME-->
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Border Grid.Row="0" Background="{StaticResource BgCard}" BorderBrush="{StaticResource Stroke}" BorderThickness="0,0,0,1">
      <StackPanel Margin="22,16,22,14">
        <TextBlock Style="{StaticResource H1}" FontSize="18" Text="How to use this tool"/>
        <TextBlock Style="{StaticResource Muted}" Margin="0,4,0,0"
                   Text="The short version. The README next to the script covers setup, sign-in and the command line."/>
      </StackPanel>
    </Border>
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="22,16,22,8">
      <StackPanel x:Name="HStack"/>
    </ScrollViewer>
    <Border Grid.Row="2" Background="{StaticResource BgCard}" BorderBrush="{StaticResource Stroke}" BorderThickness="0,1,0,0">
      <DockPanel Margin="22,12">
        <Button x:Name="HBtnClose" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="Close"
                IsDefault="True" IsCancel="True"/>
        <Button x:Name="HBtnReadme" DockPanel.Dock="Right" Style="{StaticResource BtnQuiet}"
                Content="Open the full README" Margin="0,0,8,0"/>
        <TextBlock Style="{StaticResource Tiny}" VerticalAlignment="Center" Text="Press F1 in the main window to open this again."/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@

# Render the topics into the dialog; separate from Show-StudioHelp so it can be tested
function Add-HelpContent {
    param([Parameter(Mandatory)]$Dialog)
    foreach ($topic in $script:HelpTopics) {
        $heading = New-Object Windows.Controls.TextBlock
        $heading.Text = $topic.Title
        $heading.Style = $Dialog.Window.FindResource('H2')
        $heading.Margin = New-Object Windows.Thickness 0, 14, 0, 4
        [void]$Dialog.C.HStack.Children.Add($heading)
        foreach ($paragraph in @($topic.Body -split '\r?\n\s*\r?\n' | Where-Object { $_.Trim() })) {
            $block = New-Object Windows.Controls.TextBlock
            $block.Text = $paragraph.Trim()
            $block.Style = $Dialog.Window.FindResource('Body')
            $block.Margin = New-Object Windows.Thickness 0, 0, 0, 6
            $block.LineHeight = 17
            [void]$Dialog.C.HStack.Children.Add($block)
        }
    }
    $Dialog.C.HStack.Children.Count
}

function Show-StudioHelp {
    $dialog = New-StudioWindow -Xaml $script:HelpXaml
    if ($window.IsVisible) { $dialog.Window.Owner = $window }
    [void](Add-HelpContent -Dialog $dialog)
    $readmePath = Join-Path $PSScriptRoot 'README.md'
    if (Test-Path -LiteralPath $readmePath) {
        $dialog.C.HBtnReadme.Add_Click({ Start-Process -FilePath $readmePath }.GetNewClosure())
    }
    else { $dialog.C.HBtnReadme.Visibility = 'Collapsed' }
    $dialog.C.HBtnClose.Add_Click({ $dialog.Window.Close() }.GetNewClosure())
    [void]$dialog.Window.ShowDialog()
}
#endregion

#region ---- Settings dialog ------------------------------------------------------
$script:SettingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Settings" Width="700" SizeToContent="Height" MinWidth="560"
        WindowStartupLocation="CenterOwner" Background="#F2F3F5" FontFamily="Segoe UI" FontSize="12"
        ShowInTaskbar="False" ResizeMode="NoResize">
  <Window.Resources>
<!--THEME-->
  </Window.Resources>
  <StackPanel>
    <Border Background="{StaticResource BgCard}" BorderBrush="{StaticResource Stroke}" BorderThickness="0,0,0,1">
      <StackPanel Margin="22,16,22,14">
        <TextBlock x:Name="SetTitle" Style="{StaticResource H1}" FontSize="18" Text="Settings"/>
        <TextBlock x:Name="SetSubtitle" Style="{StaticResource Muted}" Margin="0,4,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

    <StackPanel Margin="22,18,22,8">
      <TextBlock Style="{StaticResource FieldLabel}" Text="PACKAGE FOLDER"/>
      <TextBlock Style="{StaticResource Tiny}" Margin="0,0,0,4" TextWrapping="Wrap"
                 Text="Where the wizard creates a folder per package, with the installer and app.json in it."/>
      <DockPanel>
        <Button x:Name="SetBtnPackages" DockPanel.Dock="Right" Style="{StaticResource BtnDefault}"
                Content="Browse..." Margin="8,0,0,0"/>
        <TextBox x:Name="SetTxtPackages"/>
      </DockPanel>

      <TextBlock Style="{StaticResource FieldLabel}" Text="OUTPUT FOLDER" Margin="0,16,0,0"/>
      <TextBlock Style="{StaticResource Tiny}" Margin="0,0,0,4" TextWrapping="Wrap"
                 Text="Where the built .intunewin files are written before they are uploaded."/>
      <DockPanel>
        <Button x:Name="SetBtnOutput" DockPanel.Dock="Right" Style="{StaticResource BtnDefault}"
                Content="Browse..." Margin="8,0,0,0"/>
        <TextBox x:Name="SetTxtOutput"/>
      </DockPanel>

      <Border x:Name="SetPnlWarn" Background="{StaticResource WarnSoft}" BorderBrush="{StaticResource Warn}"
              BorderThickness="1" CornerRadius="4" Padding="10,8" Margin="0,16,0,0" Visibility="Collapsed">
        <TextBlock x:Name="SetTxtWarn" Foreground="{StaticResource Warn}" TextWrapping="Wrap"/>
      </Border>

      <Button x:Name="SetBtnDefaults" Style="{StaticResource BtnQuiet}" HorizontalAlignment="Left"
              Content="Reset to the defaults" Margin="0,14,0,0"/>
      <TextBlock x:Name="SetTxtFile" Style="{StaticResource Tiny}" Margin="0,10,0,0" TextWrapping="Wrap"/>
    </StackPanel>

    <Border Background="{StaticResource BgCard}" BorderBrush="{StaticResource Stroke}" BorderThickness="0,1,0,0" Margin="0,10,0,0">
      <DockPanel Margin="22,12">
        <Button x:Name="SetBtnSave" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}"
                Content="Save" IsDefault="True"/>
        <Button x:Name="SetBtnCancel" DockPanel.Dock="Right" Style="{StaticResource BtnQuiet}"
                Content="Cancel" Margin="0,0,8,0" IsCancel="True"/>
        <TextBlock Style="{StaticResource Tiny}" VerticalAlignment="Center"
                   Text="Folders are created when they are first used."/>
      </DockPanel>
    </Border>
  </StackPanel>
</Window>
'@

# Warning text for the two folders, or '' when both are on a local disk. Kept separate from
# the dialog so the self-test can exercise the rule without opening a window.
function Get-PathWarning {
    param([string]$PackageRoot, [string]$OutputRoot)
    $remote = @()
    if (-not (Test-LocalPath $PackageRoot)) { $remote += 'The package folder' }
    if (-not (Test-LocalPath $OutputRoot))  { $remote += 'The output folder' }
    if (-not $remote) { return '' }
    ($remote -join ' and ') + ' is not on a local disk. A redirected Documents folder or a mapped ' +
        'drive is the usual reason a build fails with "the setup file cannot be accessed", or the MSI ' +
        'properties come back empty. Pick a folder on C: unless you know this share works.'
}

function Show-StudioSettings {
    param([switch]$FirstRun)
    $dialog = New-StudioWindow -Xaml $script:SettingsXaml
    if ($window.IsVisible) { $dialog.Window.Owner = $window }
    $c = $dialog.C

    if ($FirstRun) {
        $dialog.Window.Title = 'Welcome to Packwright'
        $c.SetTitle.Text     = 'Where should Packwright keep things?'
        $c.SetSubtitle.Text  = 'Two folders, both on a local disk by default. You can change them later from ' +
                               'Settings in the header — this is only asked once.'
        $c.SetBtnSave.Content = 'Get started'
        $c.SetBtnCancel.Visibility = 'Collapsed'
    }
    else {
        $c.SetSubtitle.Text = 'Where Packwright puts the packages it creates and the packages it builds.'
    }
    $c.SetTxtFile.Text = "Saved in $($script:SettingsFile)"

    $c.SetTxtPackages.Text = Get-StudioPackageRoot
    $c.SetTxtOutput.Text   = Get-StudioOutputRoot

    $refresh = {
        $warning = Get-PathWarning -PackageRoot $c.SetTxtPackages.Text.Trim() -OutputRoot $c.SetTxtOutput.Text.Trim()
        $c.SetTxtWarn.Text     = $warning
        $c.SetPnlWarn.Visibility = if ($warning) { 'Visible' } else { 'Collapsed' }
    }.GetNewClosure()

    $browse = {
        param($box, $description)
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $description
        if ($box.Text.Trim()) { $dlg.SelectedPath = $box.Text.Trim() }
        if ($dlg.ShowDialog() -eq 'OK') { $box.Text = $dlg.SelectedPath }
    }

    $c.SetTxtPackages.Add_TextChanged($refresh)
    $c.SetTxtOutput.Add_TextChanged($refresh)
    $c.SetBtnPackages.Add_Click({ & $browse $c.SetTxtPackages 'Pick the folder where package folders are created' }.GetNewClosure())
    $c.SetBtnOutput.Add_Click({ & $browse $c.SetTxtOutput 'Pick the folder where .intunewin files are written' }.GetNewClosure())
    $c.SetBtnDefaults.Add_Click({
        $c.SetTxtPackages.Text = Get-DefaultPackageRoot
        $c.SetTxtOutput.Text   = Get-DefaultOutputRoot
    }.GetNewClosure())

    # Script scope, not a local: the click handler is a closure and has to write somewhere
    # the caller can still read after ShowDialog returns.
    $c.SetBtnSave.Add_Click({
        $packages = $c.SetTxtPackages.Text.Trim()
        $output   = $c.SetTxtOutput.Text.Trim()
        foreach ($pair in @{ Name = 'Package'; Value = $packages }, @{ Name = 'Output'; Value = $output }) {
            if (-not $pair.Value) {
                [void][Windows.MessageBox]::Show("The $($pair.Name.ToLower()) folder cannot be empty.",
                    'Settings', 'OK', 'Warning')
                return
            }
            if (-not [IO.Path]::IsPathRooted($pair.Value)) {
                [void][Windows.MessageBox]::Show("$($pair.Name) folder must be a full path, for example C:\IntunePackages.",
                    'Settings', 'OK', 'Warning')
                return
            }
        }
        Set-StudioSetting -Name 'PackageRoot' -Value $packages
        Set-StudioSetting -Name 'OutputRoot'  -Value $output
        $script:SettingsSaved = $true
        $dialog.Window.Close()
    }.GetNewClosure())
    $c.SetBtnCancel.Add_Click({ $dialog.Window.Close() }.GetNewClosure())

    # A first run has no Cancel, so closing the window with the X still has to leave
    # something on disk — otherwise the dialog comes back on every start.
    $dialog.Window.Add_Closed({
        if ($FirstRun -and -not $script:SettingsSaved) {
            Set-StudioSetting -Name 'PackageRoot' -Value (Get-DefaultPackageRoot)
            Set-StudioSetting -Name 'OutputRoot'  -Value (Get-DefaultOutputRoot)
        }
    }.GetNewClosure())

    & $refresh
    $script:SettingsSaved = $false
    [void]$dialog.Window.ShowDialog()
    $script:SettingsSaved
}
#endregion

#region ---- Guided wizard XAML ---------------------------------------------------
$script:WizardXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="New package from an installer" Width="820" Height="660" MinWidth="700" MinHeight="560"
        WindowStartupLocation="CenterOwner" Background="#F2F3F5" FontFamily="Segoe UI" FontSize="12"
        ShowInTaskbar="False">
  <Window.Resources>
<!--THEME-->
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="{StaticResource BgCard}" BorderBrush="{StaticResource Stroke}" BorderThickness="0,0,0,1">
      <StackPanel Margin="22,16,22,14">
        <TextBlock x:Name="WTxtStepNumbers" Style="{StaticResource Tiny}" Margin="0,0,0,4"/>
        <TextBlock x:Name="WTxtStepTitle" Style="{StaticResource H1}" FontSize="18"/>
        <TextBlock x:Name="WTxtStepSub" Style="{StaticResource Muted}" Margin="0,4,0,0"/>
      </StackPanel>
    </Border>

    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="22,16,22,8">
      <Grid>
        <!-- Step 1: installer file -->
        <StackPanel x:Name="WStep1">
          <TextBlock Style="{StaticResource FieldLabel}" Text="INSTALLATION FILE FROM THE VENDOR (.EXE OR .MSI)"/>
          <DockPanel>
            <Button x:Name="WBtnInstaller" DockPanel.Dock="Right" Style="{StaticResource BtnDefault}"
                    Content="Browse..." Margin="6,0,0,0"/>
            <TextBox x:Name="WTxtInstaller"/>
          </DockPanel>
          <Border x:Name="WPnlEngine" Style="{StaticResource Note}" Margin="0,12,0,0" Visibility="Collapsed"
                  Background="{StaticResource OkSoft}" BorderBrush="{StaticResource Ok}">
            <TextBlock x:Name="WTxtEngine" Style="{StaticResource Body}" Foreground="{StaticResource Ok}"/>
          </Border>
          <TextBlock Style="{StaticResource FieldLabel}" Text="WHERE PACKAGE FOLDERS ARE CREATED" Margin="0,20,0,3"/>
          <DockPanel>
            <Button x:Name="WBtnRoot" DockPanel.Dock="Right" Style="{StaticResource BtnDefault}"
                    Content="Browse..." Margin="6,0,0,0"/>
            <TextBox x:Name="WTxtRoot"/>
          </DockPanel>
          <TextBlock Style="{StaticResource Tiny}" Margin="0,6,0,0"
                     Text="A folder for this app is created here, holding the installer and an app.json with the settings. The location is remembered for next time."/>
        </StackPanel>

        <!-- Step 2: app information -->
        <StackPanel x:Name="WStep2" Visibility="Collapsed">
          <TextBlock Style="{StaticResource FieldLabel}" Text="NAME" Margin="0,0,0,3"/>
          <TextBox x:Name="WTxtName"/>
          <TextBlock Style="{StaticResource FieldLabel}" Text="PUBLISHER"/>
          <TextBox x:Name="WTxtPublisher"/>
          <TextBlock Style="{StaticResource FieldLabel}" Text="VERSION"/>
          <TextBox x:Name="WTxtVersion"/>
          <TextBlock Style="{StaticResource FieldLabel}" Text="DESCRIPTION (OPTIONAL)"/>
          <TextBox x:Name="WTxtDescription" AcceptsReturn="True" Height="52" TextWrapping="Wrap"
                   VerticalScrollBarVisibility="Auto"/>
          <TextBlock Style="{StaticResource FieldLabel}" Text="INSTALL COMMAND"/>
          <TextBox x:Name="WTxtInstall"/>
          <TextBlock Style="{StaticResource FieldLabel}" Text="UNINSTALL COMMAND"/>
          <TextBox x:Name="WTxtUninstall"/>
          <Border Style="{StaticResource Note}" Margin="0,12,0,0">
            <TextBlock x:Name="WTxtCmdHint" Style="{StaticResource Muted}"/>
          </Border>
        </StackPanel>

        <!-- Step 3: detection -->
        <StackPanel x:Name="WStep3" Visibility="Collapsed">
          <RadioButton x:Name="WRbDetPick" Content="Pick the app from the programs installed on this computer (recommended)"/>
          <StackPanel Margin="22,6,0,4">
            <Button x:Name="WBtnPickApp" Style="{StaticResource BtnDefault}" HorizontalAlignment="Left"
                    Content="Choose installed program..."/>
            <TextBlock x:Name="WTxtPicked" Style="{StaticResource Muted}" Margin="0,6,0,0" Text="Nothing selected yet."/>
          </StackPanel>
          <RadioButton x:Name="WRbDetMsi" Content="Use the MSI product code (read from the MSI automatically)"/>
          <TextBlock x:Name="WTxtWizMsi" Style="{StaticResource Muted}" Margin="22,2,0,4"/>
          <RadioButton x:Name="WRbDetLater" Content="Skip for now — set Detection in the studio before publishing"/>
          <Border Style="{StaticResource Note}" Margin="0,16,0,0" Background="{StaticResource WarnSoft}"
                  BorderBrush="{StaticResource Warn}">
            <TextBlock Style="{StaticResource Body}" Foreground="{StaticResource Warn}"
                       Text="If the app is not installed on this computer yet: run the installer now as a normal double-click install, then click Choose installed program. That teaches the tool exactly what Intune should look for, and you can uninstall the app again afterwards."/>
          </Border>
        </StackPanel>

        <!-- Step 4: logo -->
        <StackPanel x:Name="WStep4" Visibility="Collapsed">
          <DockPanel>
            <Border DockPanel.Dock="Left" Width="72" Height="72" Background="White" CornerRadius="6"
                    BorderBrush="{StaticResource Stroke}" BorderThickness="1" Margin="0,0,14,0">
              <Image x:Name="WImgIcon" Stretch="Uniform" Margin="6"/>
            </Border>
            <StackPanel>
              <Button x:Name="WBtnIconAuto" Style="{StaticResource BtnDefault}" HorizontalAlignment="Left"
                      Content="Take the icon from the installer"/>
              <Button x:Name="WBtnIcon" Style="{StaticResource BtnQuiet}" HorizontalAlignment="Left"
                      Content="Choose an image instead..." Margin="0,4,0,0"/>
            </StackPanel>
          </DockPanel>
          <TextBlock x:Name="WTxtIcon" Style="{StaticResource Tiny}" Margin="0,10,0,0"
                     Text="No logo yet — the app gets a generic icon in the Company Portal."/>
        </StackPanel>

        <!-- Step 5: summary -->
        <StackPanel x:Name="WStep5" Visibility="Collapsed">
          <TextBlock Style="{StaticResource FieldLabel}" Text="PACKAGE FOLDER NAME" Margin="0,0,0,3"/>
          <TextBox x:Name="WTxtFolder"/>
          <TextBlock Style="{StaticResource FieldLabel}" Text="THIS IS WHAT WILL BE CREATED"/>
          <Border Style="{StaticResource Note}" Background="{StaticResource BgCard}">
            <TextBox x:Name="WTxtSummary" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                     BorderThickness="0" Background="Transparent" TextWrapping="NoWrap"
                     VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Height="190"/>
          </Border>
          <Border x:Name="WPnlSummaryNote" Style="{StaticResource Note}" Margin="0,10,0,0" Visibility="Collapsed"
                  Background="{StaticResource WarnSoft}" BorderBrush="{StaticResource Warn}">
            <TextBlock x:Name="WTxtSummaryNote" Style="{StaticResource Body}" Foreground="{StaticResource Warn}"
                       Text="Detection is not set, so publishing is disabled. Create the package and set Detection in the studio — the app opens there right away."/>
          </Border>
        </StackPanel>
      </Grid>
    </ScrollViewer>

    <Border Grid.Row="2" Background="{StaticResource BgCard}" BorderBrush="{StaticResource Stroke}" BorderThickness="0,1,0,0">
      <DockPanel Margin="22,12">
        <Button x:Name="WBtnCancel" DockPanel.Dock="Right" Style="{StaticResource BtnQuiet}" Content="Cancel"
                Margin="8,0,0,0" IsCancel="True"/>
        <Button x:Name="WBtnCreatePublish" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}"
                Content="Create and publish" Margin="8,0,0,0" Visibility="Collapsed"/>
        <Button x:Name="WBtnCreate" DockPanel.Dock="Right" Style="{StaticResource BtnDefault}"
                Content="Create package" Margin="8,0,0,0" Visibility="Collapsed"/>
        <Button x:Name="WBtnNext" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="Next"
                Margin="8,0,0,0" IsDefault="True"/>
        <Button x:Name="WBtnBack" DockPanel.Dock="Right" Style="{StaticResource BtnDefault}" Content="Back"
                IsEnabled="False"/>
        <TextBlock Style="{StaticResource Tiny}" VerticalAlignment="Center"
                   Text="Everything can still be changed in the studio afterwards."/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@
#endregion

#region ---- Guided wizard logic --------------------------------------------------
function Show-WizMessage {
    param([string]$Message)
    [Windows.MessageBox]::Show($Message, 'New package from an installer', 'OK', 'Warning') | Out-Null
}

# Fresh wizard state. Auto remembers what the wizard itself wrote into each box, so picking
# another installer can refresh those fields while leaving hand-typed text alone.
function New-WizState {
    param([Parameter(Mandatory)]$Dialog)
    @{
        Window = $Dialog.Window; C = $Dialog.C; Step = 1
        Info = $null; Detection = $null; IconPath = $null; IconSource = $null
        Auto = @{}; Result = $null
    }
}

# Write an installer-derived value into a wizard field. Empty fields and fields still holding
# the wizard's own suggestion follow the new installer; hand edits win. Returns $true if written.
function Set-WizField {
    param([Parameter(Mandatory)][string]$Name, [string]$Value)
    $wizard = $script:Wz
    $box = $wizard.C[$Name]
    $current = "$($box.Text)".Trim()
    $handEdited = $current -and $current -ne "$($wizard.Auto[$Name])".Trim()
    if (-not $handEdited) { $box.Text = "$Value" }
    $wizard.Auto[$Name] = "$Value"
    return (-not $handEdited)
}

# Drop a logo that was read out of an installer we no longer use
function Clear-WizIcon {
    $wizard = $script:Wz
    $wizard.IconPath = $null; $wizard.IconSource = $null
    $wizard.C.WImgIcon.Source = $null
    $wizard.C.WTxtIcon.Text = 'No logo yet — the app gets a generic icon in the Company Portal.'
}

# Analyze the chosen installer, surface the result in step 1 and re-derive everything the
# installer decides. Runs again for every new file, so changing your mind in step 1 reaches
# the commands, the logo and the MSI detection in the later steps.
function Read-WizInstaller {
    $wizard = $script:Wz
    $path = (Resolve-Path -LiteralPath $wizard.C.WTxtInstaller.Text.Trim()).ProviderPath
    $previous = $wizard.Info
    $wizard.Info = Get-InstallerInfo -Path $path
    $product = @($wizard.Info.Name, $wizard.Info.Version | Where-Object { $_ }) -join ' '
    $wizard.C.WPnlEngine.Visibility = 'Visible'
    $wizard.C.WTxtEngine.Text = "Installer type: $($wizard.Info.Engine)." +
        $(if ($product) { " Product: $product." } else { '' }) + " $($wizard.Info.Hint)"

    [void](Set-WizField 'WTxtName'      $wizard.Info.Name)
    [void](Set-WizField 'WTxtPublisher' $wizard.Info.Publisher)
    [void](Set-WizField 'WTxtVersion'   $wizard.Info.Version)
    $kept = @()
    if (-not (Set-WizField 'WTxtInstall'   $wizard.Info.InstallCommand))   { $kept += 'install command' }
    if (-not (Set-WizField 'WTxtUninstall' $wizard.Info.UninstallCommand)) { $kept += 'uninstall command' }
    $wizard.C.WTxtCmdHint.Text = "$($wizard.Info.Hint)" + $(if ($kept) {
        "  You edited the $($kept -join ' and ') by hand, so it was left as it is — check that it matches $($wizard.Info.FileName)."
    } else { '' })

    if ($previous -and $previous.FilePath -ine $wizard.Info.FilePath) {
        Write-GuiLog "Wizard: installer set to $($wizard.Info.FileName) ($($wizard.Info.Engine))"
        # The product code and the extracted logo belonged to the file that was replaced
        if ($wizard.Detection -and $wizard.Detection.type -eq 'msi') { $wizard.Detection = $null }
        if ($wizard.IconSource -and $wizard.IconSource -ieq "$($previous.FilePath)") { Clear-WizIcon }
    }
}

# Validate the current step and perform its exit actions; $true lets Next proceed
function Test-WizStep {
    $wizard = $script:Wz; $c = $wizard.C
    switch ($wizard.Step) {
        1 {
            $path = $c.WTxtInstaller.Text.Trim()
            if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { Show-WizMessage 'Pick an installation file first.'; return $false }
            if ([IO.Path]::GetExtension($path) -notin '.exe', '.msi') { Show-WizMessage 'The installation file must be an .exe or .msi.'; return $false }
            if (-not $c.WTxtRoot.Text.Trim()) { Show-WizMessage 'Pick a folder where the package should be created.'; return $false }
            # Read-WizInstaller fills in step 2 from the file; it runs for every new path
            if (-not $wizard.Info -or $wizard.Info.FilePath -ine (Resolve-Path -LiteralPath $path).ProviderPath) { Read-WizInstaller }
            return $true
        }
        2 {
            if (-not $c.WTxtName.Text.Trim())      { Show-WizMessage 'The app needs a name.'; return $false }
            if (-not $c.WTxtPublisher.Text.Trim()) { Show-WizMessage 'The app needs a publisher.'; return $false }
            if (-not $c.WTxtInstall.Text.Trim())   { Show-WizMessage 'The app needs an install command.'; return $false }
            return $true
        }
        3 {
            if ($c.WRbDetPick.IsChecked) {
                if (-not $wizard.Detection -or $wizard.Detection.type -ne 'registry') {
                    Show-WizMessage "Click 'Choose installed program...' and pick the app — or choose another option."; return $false
                }
            }
            elseif ($c.WRbDetMsi.IsChecked) {
                $wizard.Detection = [ordered]@{ type = 'msi'; productCode = $wizard.Info.ProductCode }
            }
            else { $wizard.Detection = $null }
            return $true
        }
        default { return $true }
    }
}

# Switch panels, titles and buttons to the current step
function Update-WizStep {
    $wizard = $script:Wz; $c = $wizard.C; $step = $wizard.Step
    $titles = @{
        1 = @('Installation file', 'Pick the file you got from the vendor. The tool identifies the installer type and prefills the silent switches.')
        2 = @('App information', 'This is how the app appears in Intune and the Company Portal. The commands are what Intune runs on the devices.')
        3 = @('Detection', 'Intune needs a way to check whether the app is already on a device. Without it, publishing is blocked.')
        4 = @('Logo (optional)', 'Shown next to the app in the Company Portal.')
        5 = @('Summary', 'Review what will be created. The package then opens in the studio, where everything can still be adjusted.')
    }
    $c.WTxtStepNumbers.Text = "STEP $step OF 5"
    $c.WTxtStepTitle.Text   = $titles[$step][0]
    $c.WTxtStepSub.Text     = $titles[$step][1]
    foreach ($index in 1..5) { $c["WStep$index"].Visibility = if ($index -eq $step) { 'Visible' } else { 'Collapsed' } }
    $c.WBtnBack.IsEnabled = ($step -gt 1)
    $c.WBtnNext.Visibility          = if ($step -lt 5) { 'Visible' } else { 'Collapsed' }
    $c.WBtnCreate.Visibility        = if ($step -eq 5) { 'Visible' } else { 'Collapsed' }
    $c.WBtnCreatePublish.Visibility = if ($step -eq 5) { 'Visible' } else { 'Collapsed' }

    if ($step -eq 3) {
        $hasMsiCode = $wizard.Info -and $wizard.Info.ProductCode
        $c.WRbDetMsi.Visibility  = if ($hasMsiCode) { 'Visible' } else { 'Collapsed' }
        $c.WTxtWizMsi.Visibility = $c.WRbDetMsi.Visibility
        if ($hasMsiCode) { $c.WTxtWizMsi.Text = "Product code $($wizard.Info.ProductCode) was read from the MSI — nothing more to do." }
        # A hidden option must not stay selected: the code came from an installer we dropped
        elseif ($c.WRbDetMsi.IsChecked) { $c.WRbDetPick.IsChecked = $true }
        if (-not ($c.WRbDetPick.IsChecked -or $c.WRbDetMsi.IsChecked -or $c.WRbDetLater.IsChecked)) {
            if ($hasMsiCode) { $c.WRbDetMsi.IsChecked = $true } else { $c.WRbDetPick.IsChecked = $true }
        }
    }
    if ($step -eq 4) {
        $c.WBtnIconAuto.IsEnabled = [bool]($wizard.Info -and $wizard.Info.FilePath -and
                                           [IO.Path]::GetExtension($wizard.Info.FilePath) -ieq '.exe') -or [bool]$script:PickedApp
    }
    if ($step -eq 5) {
        # Suggested from the current name and version, and re-suggested when those change
        [void](Set-WizField 'WTxtFolder' `
            ((('{0} {1}' -f $c.WTxtName.Text.Trim(), $c.WTxtVersion.Text.Trim()).Trim() -replace '[\\/:*?"<>|]', '')))
        $detectionText = if (-not $wizard.Detection) { 'NOT SET — set it in the studio before publishing' }
                         elseif ($wizard.Detection.type -eq 'msi') { "MSI product code $($wizard.Detection.productCode)" }
                         else {
                             "Registry: $($wizard.Detection.keyPath)" +
                             $(if ($wizard.Detection.detectionValue) { ", DisplayVersion >= $($wizard.Detection.detectionValue)" } else { ' (key exists)' })
                         }
        $c.WTxtSummary.Text = @(
            "Created in:  $($c.WTxtRoot.Text.Trim())"
            "Setup file:  $($wizard.Info.FileName) ($($wizard.Info.Engine))"
            ''
            "App name:    $($c.WTxtName.Text.Trim())"
            "Publisher:   $($c.WTxtPublisher.Text.Trim())"
            "Version:     $($c.WTxtVersion.Text.Trim())"
            "Install:     $($c.WTxtInstall.Text.Trim())"
            "Uninstall:   $(if ($c.WTxtUninstall.Text.Trim()) { $c.WTxtUninstall.Text.Trim() } else { '(empty — can be added later)' })"
            "Detection:   $detectionText"
            "Logo:        $(if ($wizard.IconPath) { [IO.Path]::GetFileName($wizard.IconPath) } else { 'none' })"
        ) -join [Environment]::NewLine
        $c.WBtnCreatePublish.IsEnabled = [bool]$wizard.Detection
        $c.WPnlSummaryNote.Visibility = if ($wizard.Detection) { 'Collapsed' } else { 'Visible' }
    }
}

# Create the package folder from the wizard state; close the wizard on success
function Invoke-WizCreate {
    param([bool]$Publish)
    $wizard = $script:Wz; $c = $wizard.C
    try {
        $folderName = ($c.WTxtFolder.Text.Trim() -replace '[\\/:*?"<>|]', '')
        if (-not $folderName) { Show-WizMessage 'Give the package folder a name.'; return }
        $root = $c.WTxtRoot.Text.Trim()
        $target = Join-Path $root $folderName
        if ((Test-Path -LiteralPath $target) -and @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            $answer = [Windows.MessageBox]::Show(
                "The folder already exists and is not empty:`n$target`n`nUse it anyway? Files with the same names are overwritten.",
                'New package from an installer', 'YesNo', 'Question')
            if ($answer -ne 'Yes') { return }
        }
        $manifest = [ordered]@{
            displayName = $c.WTxtName.Text.Trim()
            publisher   = $c.WTxtPublisher.Text.Trim()
        }
        if ($c.WTxtVersion.Text.Trim())     { $manifest.version = $c.WTxtVersion.Text.Trim() }
        if ($c.WTxtDescription.Text.Trim()) { $manifest.description = $c.WTxtDescription.Text.Trim() }
        $manifest.installCommandLine    = $c.WTxtInstall.Text.Trim()
        $manifest.uninstallCommandLine  = $c.WTxtUninstall.Text.Trim()
        $manifest.runAsAccount          = 'system'
        $manifest.restartBehavior       = 'suppress'
        $manifest.architecture          = 'x64'
        $manifest.minimumWindowsRelease = '1607'
        if ($wizard.Detection) { $manifest.detection = $wizard.Detection }

        $created = New-InstallerPackage -InstallerPath $wizard.Info.FilePath -TargetFolder $target `
                                        -Manifest $manifest -IconSource $wizard.IconPath
        Set-StudioSetting -Name 'PackageRoot' -Value $root
        $wizard.Result = @{ Folder = $created; Setup = $wizard.Info.FileName; Publish = $Publish }
        $wizard.Window.DialogResult = $true
    }
    catch {
        [Windows.MessageBox]::Show("Could not create the package:`n$($_.Exception.Message)",
            'New package from an installer', 'OK', 'Error') | Out-Null
    }
}

function Show-PackageWizard {
    param([string]$InstallerPath)
    $dialog = New-StudioWindow -Xaml $script:WizardXaml
    $dialog.Window.Owner = $window
    $script:Wz = New-WizState -Dialog $dialog
    $c = $dialog.C

    # Not MyDocuments: that is the folder redirection points at a network home directory on a
    # managed machine, and a package built from there fails in ways that name the wrong culprit.
    $c.WTxtRoot.Text = Get-StudioPackageRoot

    $c.WBtnInstaller.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'Installers (*.exe;*.msi)|*.exe;*.msi'
        if ($dlg.ShowDialog()) {
            $script:Wz.C.WTxtInstaller.Text = $dlg.FileName
            try { Read-WizInstaller } catch { Show-WizMessage "Could not read the file: $($_.Exception.Message)" }
        }
    })
    $c.WBtnRoot.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Pick the folder where package folders are created'
        if ($script:Wz.C.WTxtRoot.Text.Trim()) { $dlg.SelectedPath = $script:Wz.C.WTxtRoot.Text.Trim() }
        if ($dlg.ShowDialog() -eq 'OK') { $script:Wz.C.WTxtRoot.Text = $dlg.SelectedPath }
    })
    $c.WBtnPickApp.Add_Click({
        $app = Show-InstalledAppPicker -Owner $script:Wz.Window
        if (-not $app) { return }
        $script:Wz.Detection = ConvertTo-RegistryDetection -App $app
        $script:Wz.C.WRbDetPick.IsChecked = $true
        $script:Wz.C.WTxtPicked.Text = "Selected: $($app.DisplayName) $($app.DisplayVersion) — rule on the app's uninstall key" +
            $(if ($app.DisplayVersion) { " (DisplayVersion at least $($app.DisplayVersion))" } else { ' (key exists)' })
        if (-not $script:Wz.C.WTxtUninstall.Text.Trim()) {
            $uninstall = Get-AppUninstallCommand -App $app
            if ($uninstall) { $script:Wz.C.WTxtUninstall.Text = $uninstall }
        }
    })
    $c.WBtnIconAuto.Add_Click({
        $wizard = $script:Wz
        $attempts = @()
        if ($script:PickedApp) {
            $reference = Resolve-IconReference -Reference $script:PickedApp.DisplayIcon
            if ($reference) { $attempts += @{ Source = $reference.Path; Index = $reference.Index; From = $script:PickedApp.DisplayName } }
        }
        if ($wizard.Info -and [IO.Path]::GetExtension($wizard.Info.FilePath) -ieq '.exe') {
            $attempts += @{ Source = $wizard.Info.FilePath; Index = 0; From = $wizard.Info.FileName }
        }
        foreach ($attempt in $attempts) {
            $temporary = Join-Path ([IO.Path]::GetTempPath()) ('Packwright-icon-{0}.png' -f [guid]::NewGuid())
            $size = Export-IconFile -SourceFile $attempt.Source -IconIndex $attempt.Index -Destination $temporary
            if ($size) {
                $bitmap = New-Object Windows.Media.Imaging.BitmapImage
                $bitmap.BeginInit(); $bitmap.UriSource = [Uri]$temporary
                $bitmap.CacheOption = 'OnLoad'; $bitmap.DecodePixelWidth = 128; $bitmap.EndInit()
                $wizard.C.WImgIcon.Source = $bitmap
                $wizard.IconPath = $temporary; $wizard.IconSource = $attempt.Source
                $wizard.C.WTxtIcon.Text = "Icon taken from $($attempt.From) (${size}x${size})."
                return
            }
        }
        $wizard.C.WTxtIcon.Text = 'No icon could be read from the installer — choose an image instead.'
    })
    $c.WBtnIcon.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'Images (*.png;*.jpg;*.jpeg)|*.png;*.jpg;*.jpeg'
        if ($dlg.ShowDialog()) {
            try {
                $bitmap = New-Object Windows.Media.Imaging.BitmapImage
                $bitmap.BeginInit(); $bitmap.UriSource = [Uri]$dlg.FileName
                $bitmap.CacheOption = 'OnLoad'; $bitmap.DecodePixelWidth = 128; $bitmap.EndInit()
                $script:Wz.C.WImgIcon.Source = $bitmap
                $script:Wz.IconPath = $dlg.FileName; $script:Wz.IconSource = $dlg.FileName
                $script:Wz.C.WTxtIcon.Text = $dlg.FileName
            }
            catch { Show-WizMessage "Could not read the image: $($_.Exception.Message)" }
        }
    })
    $c.WBtnBack.Add_Click({ if ($script:Wz.Step -gt 1) { $script:Wz.Step--; Update-WizStep } })
    $c.WBtnNext.Add_Click({ if (Test-WizStep) { $script:Wz.Step++; Update-WizStep } })
    $c.WBtnCreate.Add_Click({ Invoke-WizCreate -Publish $false })
    $c.WBtnCreatePublish.Add_Click({ Invoke-WizCreate -Publish $true })
    $c.WBtnCancel.Add_Click({ $script:Wz.Window.DialogResult = $false })

    if ($InstallerPath -and (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        $c.WTxtInstaller.Text = (Resolve-Path -LiteralPath $InstallerPath).ProviderPath
        try { Read-WizInstaller } catch { Write-GuiLog "WARNING: Could not read $InstallerPath : $($_.Exception.Message)" }
    }

    Update-WizStep
    [void]$dialog.Window.ShowDialog()
    $result = $script:Wz.Result
    $script:Wz = $null
    if ($result) {
        Write-GuiLog "Wizard created the package: $($result.Folder)"
        if (Open-PackageFolder -Folder $result.Folder -PreferSetup $result.Setup) {
            if ($result.Publish) { Start-EngineRun -Publish $true }
        }
    }
}
#endregion

#region ---- Background run (build/publish in a runspace) -----------------------
$script:RunPS = $null
$script:RunHandle = $null
$script:RunCancelled = $false
$script:StreamIdx = @{ Info = 0; Warn = 0; Err = 0 }

# Graph errors arrive as a whole HTTP dump; dig out the sentence a human can act on
function Format-RunError {
    param([string]$Text)
    foreach ($pattern in '\\"Message\\"\s*:\s*\\"(?<m>[^\\"]{5,400})',
                         '"Message"\s*:\s*"(?<m>[^"]{5,400})"',
                         '"message"\s*:\s*"(?<m>[^"]{5,400})"') {
        if ($Text -match $pattern) { return ($Matches.m -split ' - Operation ID')[0].Trim() }
    }
    @($Text -split '\r?\n' | Where-Object { $_.Trim() })[0]
}

function Set-RunUiState {
    param([bool]$Busy)
    foreach ($name in 'BtnSave', 'BtnBuild', 'BtnPublish', 'BtnChangePkg', 'BtnRegPick', 'BtnIconAuto', 'BtnBrowseIcon') {
        $ui[$name].IsEnabled = -not $Busy
    }
    $ui.BtnCancelRun.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $ui.Prog.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    if ($Busy) { $ui.ExpLog.IsExpanded = $true } else { $ui.Prog.IsIndeterminate = $false; $ui.Prog.Value = 0 }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
    $runspaceShell = $script:RunPS
    if (-not $runspaceShell) { $timer.Stop(); return }

    while ($runspaceShell.Streams.Information.Count -gt $script:StreamIdx.Info) {
        Write-GuiLog "$($runspaceShell.Streams.Information[$script:StreamIdx.Info].MessageData)"
        $script:StreamIdx.Info++
    }
    while ($runspaceShell.Streams.Warning.Count -gt $script:StreamIdx.Warn) {
        Write-GuiLog "WARNING: $($runspaceShell.Streams.Warning[$script:StreamIdx.Warn].Message)"
        $script:StreamIdx.Warn++
    }
    while ($runspaceShell.Streams.Error.Count -gt $script:StreamIdx.Err) {
        $raw = "$($runspaceShell.Streams.Error[$script:StreamIdx.Err])"
        Write-GuiLog "ERROR: $(Format-RunError $raw)"
        Write-GuiLog "  details: $raw"
        Set-StatusText (Format-RunError $raw)
        $script:StreamIdx.Err++
    }
    if ($runspaceShell.Streams.Progress.Count -gt 0) {
        $last = $runspaceShell.Streams.Progress[$runspaceShell.Streams.Progress.Count - 1]
        if ($last.PercentComplete -ge 0) {
            $ui.Prog.IsIndeterminate = $false
            $ui.Prog.Value = $last.PercentComplete
            if ("$($last.StatusDescription)".Trim()) { Set-StatusText "Uploading — $($last.StatusDescription)" }
        }
    }

    if (-not $script:RunHandle.IsCompleted) { return }
    $timer.Stop()
    $results = @()
    try { $results = @($runspaceShell.EndInvoke($script:RunHandle)) }
    catch {
        if (-not $script:RunCancelled) {
            $message = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            Write-GuiLog "ERROR: $(Format-RunError $message)"
            Set-StatusText (Format-RunError $message)
        }
    }
    foreach ($result in $results) {
        if ($result.PSObject.Properties['IntuneWinFile']) {
            Write-GuiLog "Built $($result.IntuneWinFile) ($($result.SizeMB) MB)"
            Set-StatusText "Package built: $($result.IntuneWinFile)"
        }
        if ($result.PSObject.Properties['AppId']) {
            Write-GuiLog "Published '$($result.DisplayName)' — app id $($result.AppId)"
            Set-StatusText "'$($result.DisplayName)' is published in Intune. Assign groups in the portal."
            $script:PortalUrl = $result.PortalUrl
            $ui.BtnOpenPortal.Visibility = 'Visible'
        }
    }
    if ($script:RunCancelled) {
        Write-GuiLog 'Cancelled. If the upload had already started, check Intune for a half-created app.'
        Set-StatusText 'Cancelled.'
    }
    $runspaceShell.Runspace.Dispose(); $runspaceShell.Dispose()
    $script:RunPS = $null
    Set-RunUiState -Busy $false
})

# Build (and optionally publish) through the engine scripts, in a background runspace so
# the window stays responsive. Arguments are passed as parameters, never string-concatenated.
function Start-EngineRun {
    param([bool]$Publish)
    if ($script:RunPS) { Set-StatusText 'A build is already running.'; return }
    if (-not (Test-ReadyToRun -ForPublish:$Publish)) { return }
    try { Save-AppManifest | Out-Null }
    catch { Write-GuiLog "ERROR: $($_.Exception.Message)"; Set-StatusText 'Could not save app.json.'; return }

    # A package opened by hand can still sit on a share, whatever the settings say. Name it
    # in the log now, so the failure that follows is not read as a broken installer.
    $pathWarning = Get-PathWarning -PackageRoot $script:LoadedFolder -OutputRoot (Get-StudioOutputRoot)
    if ($pathWarning) { Write-GuiLog "WARNING: $pathWarning" }

    if ($Publish) {
        $detection = (Get-DetectionSummary).Text
        $duplicateNote = if ($ui.ChkUpdateExisting.IsChecked) {
            'If Intune already has an app with this name, it is updated with this package as a new version (assignments are kept).'
        } elseif ($ui.ChkAllowDuplicate.IsChecked) {
            'A second app with this name will be created if one already exists.'
        } else {
            'If Intune already has an app with this name, publishing stops before anything is created.'
        }
        $answer = [Windows.MessageBox]::Show(
            ("Create this app in Intune?`n`n" +
             "Name:       $($ui.TxtName.Text.Trim())`n" +
             "Publisher:  $($ui.TxtPublisher.Text.Trim())`n" +
             "Version:    $($ui.TxtVersion.Text.Trim())`n" +
             "Package:    $($ui.CmbSetup.SelectedItem)`n`n" +
             "Detection:  $detection`n`n" +
             "$duplicateNote`nNo groups are assigned — do that in the portal."),
            'Publish to Intune', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { Set-StatusText 'Publishing cancelled.'; return }
    }

    $runBody = {
        param(
            [string]$BuildScript, [string]$PublishScript,
            [string]$Source, [string]$Setup, [string]$OutputRoot,
            [bool]$DoPublish, [bool]$UpdateExisting, [bool]$AllowDuplicate
        )
        . $BuildScript
        . $PublishScript
        $built = Build-IntuneWinApp -SourceFolder $Source -SetupFile $Setup -OutputRoot $OutputRoot -PassThru
        $built
        if ($DoPublish -and $built) {
            # -SignIn Browser: the default WAM prompt parents itself to the console window
            # of the process, and a GUI has none to give it, so it fails with an empty
            # message. The plain browser flow needs no window of ours.
            $built | Publish-IntuneWinApp -Confirm:$false -Update:$UpdateExisting `
                         -AllowDuplicateName:$AllowDuplicate -SignIn Browser
        }
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $runspaceShell = [powershell]::Create()
    $runspaceShell.Runspace = $runspace
    [void]$runspaceShell.AddScript($runBody.ToString()).AddParameters(@{
        BuildScript    = $script:EngineBuild
        PublishScript  = $script:EnginePublish
        Source         = $script:LoadedFolder
        Setup          = "$($ui.CmbSetup.SelectedItem)"
        OutputRoot     = Get-StudioOutputRoot
        DoPublish      = $Publish
        UpdateExisting = [bool]$ui.ChkUpdateExisting.IsChecked
        AllowDuplicate = [bool]$ui.ChkAllowDuplicate.IsChecked
    })

    $script:RunPS = $runspaceShell
    $script:RunCancelled = $false
    $script:StreamIdx = @{ Info = 0; Warn = 0; Err = 0 }
    $script:RunHandle = $runspaceShell.BeginInvoke()

    $ui.BtnOpenPortal.Visibility = 'Collapsed'
    Set-RunUiState -Busy $true
    $ui.Prog.IsIndeterminate = $true
    Set-StatusText $(if ($Publish) { 'Building the package and publishing to Intune...' } else { 'Building the package...' })
    Write-GuiLog ('==== ' + $(if ($Publish) { 'Build and publish' } else { 'Build' }) + " — $(Get-Date -Format 'HH:mm:ss') ====")
    $timer.Start()
}
#endregion

#region ---- Event wiring -------------------------------------------------------
# Start view
$ui.BtnStartWizard.Add_Click({ Show-PackageWizard })
$ui.BtnStartOpen.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick the package folder (the folder holding the installation files)'
    if ($dlg.ShowDialog() -eq 'OK') { [void](Open-PackageFolder -Folder $dlg.SelectedPath) }
})
$ui.LstRecent.Add_MouseDoubleClick({
    if ($ui.LstRecent.SelectedItem) { [void](Open-PackageFolder -Folder $ui.LstRecent.SelectedItem.Folder) }
})
$ui.LstRecent.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq 'Return' -and $ui.LstRecent.SelectedItem) {
        [void](Open-PackageFolder -Folder $ui.LstRecent.SelectedItem.Folder)
    }
})
$ui.BtnChangePkg.Add_Click({ Show-StartView })

$ui.BtnSettings.Add_Click({ [void](Show-StudioSettings) })

# Help: header button and F1 anywhere in the window
$ui.BtnHelp.Add_Click({ Show-StudioHelp })
$window.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq 'F1') { Show-StudioHelp; $eventArgs.Handled = $true }
})

# App information -> preview, source tags, readiness
foreach ($fieldName in 'Name', 'Publisher', 'Version') {
    $ui."Txt$fieldName".Add_TextChanged({
        if ($script:Loading) { return }
        foreach ($key in 'Name', 'Publisher', 'Version') {
            if ($script:InitialValues) {
                $ui."Tag$key".Text = if ($ui."Txt$key".Text -eq $script:InitialValues[$key]) {
                    $script:InitialValues["${key}Tag"]
                } else { 'edited by hand' }
            }
        }
        Update-PreviewCard
        Update-Readiness
    })
}
$ui.TxtDescription.Add_TextChanged({ if (-not $script:Loading) { Update-PreviewCard } })

# Detection
$ui.CmbDetType.Add_SelectionChanged({
    Update-DetectionUi
    if ($script:Loading -or -not $script:LoadedFolder) { return }
    if ((Get-DetTypeValue) -eq 'msi' -and -not $ui.TxtProductCode.Text.Trim()) {
        $found = @(Find-PackageMsi)
        if ($found.Count -eq 1) { Import-MsiProductCode -MsiPath $found[0].FullName }
        elseif ($found.Count -gt 1) { Write-GuiLog "The package holds $($found.Count) MSI files — use 'From MSI...' to pick the right one." }
        else { Write-GuiLog "No MSI in this package — use 'From MSI...' to pick one, or enter the product code by hand." }
    }
    Update-Readiness
})
$ui.CmbDetCheck.Add_SelectionChanged({ Update-DetectionUi; if (-not $script:Loading) { Update-Readiness } })
$ui.CmbDetOperator.Add_SelectionChanged({ if (-not $script:Loading) { Update-Readiness } })
$ui.ChkDet32.Add_Click({ if (-not $script:Loading) { Update-Readiness } })
foreach ($detectionBox in 'TxtProductCode', 'TxtDetPath', 'TxtDetFile', 'TxtKeyPath', 'TxtValueName', 'TxtDetValue', 'TxtScript') {
    $ui[$detectionBox].Add_TextChanged({ if (-not $script:Loading) { Update-Readiness } })
}
$ui.BtnRegPick.Add_Click({
    $app = Show-InstalledAppPicker -Owner $window
    if (-not $app) { return }
    $detection = ConvertTo-RegistryDetection -App $app
    Set-DetTypeValue 'registry'
    $ui.TxtKeyPath.Text    = $detection.keyPath
    $ui.TxtValueName.Text  = "$($detection.valueName)"
    Set-ComboValue $ui.CmbDetCheck $detection.detectionType
    Set-ComboValue $ui.CmbDetOperator $detection.operator
    $ui.TxtDetValue.Text   = "$($detection.detectionValue)"
    $ui.ChkDet32.IsChecked = [bool]$detection.check32BitOn64System
    $ui.TxtKeyPath.Tag = $null
    Write-GuiLog "Detection rule written from the installed app: $($app.DisplayName) $($app.DisplayVersion)"
    if (-not $ui.TxtUninstall.Text.Trim()) {
        $uninstall = Get-AppUninstallCommand -App $app
        if ($uninstall) {
            $ui.TxtUninstall.Text = $uninstall
            Write-GuiLog "Uninstall command taken from the app's registry entry."
        }
    }
    if (-not $ui.TxtVersion.Text.Trim() -and $app.DisplayVersion) { $ui.TxtVersion.Text = $app.DisplayVersion }
    Update-DetectionUi
    Update-Readiness
})
$ui.BtnMsiPick.Add_Click({
    $found = @(Find-PackageMsi)
    if ($found.Count -eq 1) { Import-MsiProductCode -MsiPath $found[0].FullName; return }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'MSI packages (*.msi)|*.msi'
    if ($script:LoadedFolder) {
        $filesFolder = Join-Path $script:LoadedFolder 'Files'
        $dlg.InitialDirectory = if (Test-Path -LiteralPath $filesFolder) { $filesFolder } else { $script:LoadedFolder }
    }
    if ($dlg.ShowDialog()) { Import-MsiProductCode -MsiPath $dlg.FileName }
})
$ui.BtnBrowseScript.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'PowerShell (*.ps1)|*.ps1'
    if ($script:LoadedFolder) { $dlg.InitialDirectory = $script:LoadedFolder }
    if ($dlg.ShowDialog()) { $ui.TxtScript.Text = $dlg.FileName; Update-Readiness }
})

# Advanced
$ui.CmbSetup.Add_SelectionChanged({ Update-SetupSelection })
# Updating the existing app and creating a second one are opposites; keep them exclusive
# so the engine's contradiction check can never be reached from the GUI
$ui.ChkUpdateExisting.Add_Click({ if ($ui.ChkUpdateExisting.IsChecked) { $ui.ChkAllowDuplicate.IsChecked = $false } })
$ui.ChkAllowDuplicate.Add_Click({ if ($ui.ChkAllowDuplicate.IsChecked) { $ui.ChkUpdateExisting.IsChecked = $false } })
$ui.CmbMinOs.Add_LostFocus({ if (-not $script:Loading) { Set-ComboValue $ui.CmbMinOs (ConvertTo-MinOsValue "$($ui.CmbMinOs.Text)") } })

# Logo
$ui.BtnIconAuto.Add_Click({ Import-PackageIcon })
$ui.BtnBrowseIcon.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Images (*.png;*.jpg;*.jpeg)|*.png;*.jpg;*.jpeg'
    if ($dlg.ShowDialog()) { Set-IconPreview -Path $dlg.FileName }
})

# Actions
$ui.BtnSave.Add_Click({
    try { Save-AppManifest | Out-Null; Set-StatusText 'Settings saved to app.json.' }
    catch { Write-GuiLog "ERROR: $($_.Exception.Message)"; Set-StatusText 'Could not save app.json.' }
})
$ui.BtnBuild.Add_Click({ Start-EngineRun -Publish $false })
$ui.BtnPublish.Add_Click({ Start-EngineRun -Publish $true })
$ui.BtnCancelRun.Add_Click({
    if (-not $script:RunPS) { return }
    $script:RunCancelled = $true
    Set-StatusText 'Cancelling...'
    try { $script:RunPS.Stop() } catch {}
})
$ui.BtnOpenPortal.Add_Click({ if ($script:PortalUrl) { Start-Process $script:PortalUrl } })

# Drag a package folder or an installer onto the window
$window.Add_DragOver({
    param($sender, $eventArgs)
    $eventArgs.Effects = if ($eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { 'Copy' } else { 'None' }
    $eventArgs.Handled = $true
})
$window.Add_Drop({
    param($sender, $eventArgs)
    $dropped = @($eventArgs.Data.GetData([Windows.DataFormats]::FileDrop))
    if (-not $dropped) { return }
    $first = $dropped[0]
    if (Test-Path -LiteralPath $first -PathType Container) { [void](Open-PackageFolder -Folder $first) }
    elseif ([IO.Path]::GetExtension($first) -in '.exe', '.msi') { Show-PackageWizard -InstallerPath $first }
    else { Set-StatusText 'Drop a package folder, or an .exe/.msi installer.' }
})
#endregion

#region ---- Startup ------------------------------------------------------------
$secretPath = Join-Path $PSScriptRoot '.secret'
$ui.TxtAuthStatus.Text = if (Test-Path -LiteralPath $secretPath) {
    'Signed in as an app — publishing needs no sign-in prompt'
} else {
    'No .secret — publishing opens a browser sign-in'
}
Update-DetectionUi
Show-StartView

if (-not $TestLoad) {
    # Ask where things go before anything is created, rather than leaving it to be found in
    # %APPDATA% after a build has already failed. On ContentRendered so the main window is up
    # behind the dialog; handlers run in the order they are added, so this comes before the wizard.
    if (Test-FirstRun) { $window.Add_ContentRendered({ [void](Show-StudioSettings -FirstRun) }) }

    $moved = Repair-LegacyPackageRoot
    if ($moved) { Write-GuiLog $moved }
    $startupWarning = Get-PathWarning -PackageRoot (Get-StudioPackageRoot) -OutputRoot (Get-StudioOutputRoot)
    if ($startupWarning) {
        Write-GuiLog "WARNING: $startupWarning"
        Set-StatusText 'A folder under Settings is not on a local disk — see the log.'
    }

    if ($SourceFolder) { [void](Open-PackageFolder -Folder $SourceFolder) }
    if ($Installer)    { $window.Add_ContentRendered({ Show-PackageWizard -InstallerPath $Installer }.GetNewClosure()) }
    elseif ($Wizard)   { $window.Add_ContentRendered({ Show-PackageWizard }) }
}
#endregion

#region ---- Headless self-test -------------------------------------------------
if ($TestLoad) {
    $script:TestPass = 0
    $script:TestFail = 0
    function Assert-Test {
        param([string]$Name, $Condition, [string]$Detail)
        if ($Condition) {
            $script:TestPass++
            Write-Host ("  PASS  {0}{1}" -f $Name, $(if ($Detail) { " — $Detail" } else { '' }))
        }
        else {
            $script:TestFail++
            Write-Host ("  FAIL  {0}{1}" -f $Name, $(if ($Detail) { " — $Detail" } else { '' })) -ForegroundColor Red
        }
    }

    Write-Host "Packwright self-test"

    # The PowerShell 7 guard at the top of each script is only reachable if 5.1 can read the
    # file. Saved without a BOM, 5.1 decodes the em dashes as ANSI, the stray quote byte ends
    # the string it sits in, and the run dies in 41 parse errors before any guard is reached.
    $noBom = @(foreach ($engine in $PSCommandPath, $script:EngineBuild, $script:EnginePublish) {
        $head = [byte[]]::new(3)
        $reader = [IO.File]::OpenRead($engine)
        try { [void]$reader.Read($head, 0, 3) } finally { $reader.Dispose() }
        if ($head[0] -ne 0xEF -or $head[1] -ne 0xBB -or $head[2] -ne 0xBF) { Split-Path -Leaf $engine }
    })
    Assert-Test 'Scripts are saved UTF-8 with BOM' ($noBom.Count -eq 0) $(
        if ($noBom.Count) { "no BOM: $($noBom -join ', ') — PowerShell 5.1 cannot parse these, so the version guard never runs" }
        else { 'all three readable by PowerShell 5.1' })

    # PathInfo.Path is provider-qualified on a UNC path; only .ProviderPath is something
    # IntuneWinAppUtil.exe or the WindowsInstaller COM object can open.
    $providerQualified = @(foreach ($engine in $PSCommandPath, $script:EngineBuild, $script:EnginePublish) {
        if ((Get-Content -LiteralPath $engine -Raw) -match 'Resolve-Path[^\r\n]*\)\.Path\b') { Split-Path -Leaf $engine }
    })
    # The detail strings deliberately avoid spelling out the pattern being searched for —
    # this test reads its own source, and did fail on its own failure message once.
    Assert-Test 'Resolved paths are plain filesystem paths' ($providerQualified.Count -eq 0) $(
        if ($providerQualified.Count) { "a Resolve-Path result is read as .Path in $($providerQualified -join ', ') — use .ProviderPath" }
        else { 'every Resolve-Path result uses .ProviderPath' })

    Assert-Test 'Local disk detection' (
        (Test-LocalPath 'C:\IntunePackages') -and
        -not (Test-LocalPath '\\server\share\IntunePackages') -and
        -not (Test-LocalPath 'IntunePackages') -and
        -not (Test-LocalPath ''))
    $defaultRoot = Get-DefaultPackageRoot
    Assert-Test 'Default package folder is on a local disk' (Test-LocalPath $defaultRoot) $defaultRoot
    Assert-Test 'Network package folder is called out' (
        (Get-PathWarning -PackageRoot '\\server\share\pkg' -OutputRoot 'C:\Out') -match 'package folder')
    Assert-Test 'Network output folder is called out' (
        (Get-PathWarning -PackageRoot 'C:\Pkg' -OutputRoot '\\server\share\out') -match 'output folder')
    Assert-Test 'Two local folders warn about nothing' (
        -not (Get-PathWarning -PackageRoot 'C:\Pkg' -OutputRoot 'C:\Out'))

    # Settings behaviour, against a throwaway file so the real settings.json is untouched
    $realSettingsFile = $script:SettingsFile
    try {
        $script:SettingsFile = Join-Path ([IO.Path]::GetTempPath()) 'Packwright-selftest-settings.json'
        Remove-Item -LiteralPath $script:SettingsFile -Force -ErrorAction SilentlyContinue
        Assert-Test 'First run is detected while no settings exist' (Test-FirstRun)

        $legacy = '\\server\home$\user\IntunePackages'
        Set-StudioSetting -Name 'PackageRoot' -Value $legacy
        Assert-Test 'Saved settings end the first run' (-not (Test-FirstRun))
        $movedMessage = Repair-LegacyPackageRoot -LegacyRoot $legacy
        Assert-Test 'Old network default is moved to a local folder' (
            $movedMessage -and (Test-LocalPath (Get-StudioPackageRoot))) (Get-StudioPackageRoot)

        $chosen = '\\server\share\ChosenOnPurpose'
        Set-StudioSetting -Name 'PackageRoot' -Value $chosen
        Assert-Test 'A share chosen on purpose is left alone' (
            -not (Repair-LegacyPackageRoot -LegacyRoot $legacy) -and (Get-StudioPackageRoot) -eq $chosen)
    }
    finally {
        Remove-Item -LiteralPath $script:SettingsFile -Force -ErrorAction SilentlyContinue
        $script:SettingsFile = $realSettingsFile
    }

    Assert-Test 'Main window builds' ($ui.Count -ge 70) "$($ui.Count) named controls"
    Assert-Test 'Theme applied to main window' ($null -ne $window.FindResource('Accent')) 'Accent brush resolves'
    Assert-Test 'Start view is the landing screen' ($ui.ViewStart.Visibility -eq 'Visible' -and $ui.ViewEditor.Visibility -eq 'Collapsed')
    Assert-Test 'Action bar hidden until a package is open' ($ui.PnlActions.Visibility -eq 'Collapsed')

    $pickerDialog = New-StudioWindow -Xaml $script:PickerXaml
    Assert-Test 'Picker window builds' ($pickerDialog.Unresolved.Count -eq 0) "$($pickerDialog.C.Count) controls"
    $wizardDialog = New-StudioWindow -Xaml $script:WizardXaml
    Assert-Test 'Wizard window builds' ($wizardDialog.Unresolved.Count -eq 0) "$($wizardDialog.C.Count) controls"

    $helpDialog = New-StudioWindow -Xaml $script:HelpXaml
    Assert-Test 'Help window builds' ($helpDialog.Unresolved.Count -eq 0) "$($helpDialog.C.Count) controls"
    $settingsDialog = New-StudioWindow -Xaml $script:SettingsXaml
    Assert-Test 'Settings window builds' ($settingsDialog.Unresolved.Count -eq 0) "$($settingsDialog.C.Count) controls"
    Assert-Test 'Settings is reachable from the header' ($null -ne $ui.BtnSettings)
    $emptyTopics = @($script:HelpTopics | Where-Object { -not "$($_.Title)".Trim() -or -not "$($_.Body)".Trim() })
    Assert-Test 'Every help topic has a title and body' ($emptyTopics.Count -eq 0) "$($script:HelpTopics.Count) topics"
    $helpBlocks = Add-HelpContent -Dialog $helpDialog
    Assert-Test 'Help content renders' ($helpBlocks -ge (2 * $script:HelpTopics.Count)) "$helpBlocks text blocks"
    Assert-Test 'Help button and F1 are wired' ($null -ne $ui.BtnHelp)
    Assert-Test 'README is available to open from help' (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'README.md'))

    $installed = @(Get-InstalledApp)
    Assert-Test 'Installed apps enumerated' ($installed.Count -gt 0) "$($installed.Count) programs"
    if ($installed.Count) {
        $sample = ConvertTo-RegistryDetection -App $installed[0]
        Assert-Test 'Detection rule from installed app' ($sample.keyPath -and $sample.keyPath -notmatch 'WOW6432Node') 'key path without WOW6432Node'
        $withIcon = @($installed | Where-Object { Resolve-IconReference -Reference $_.DisplayIcon })
        Assert-Test 'DisplayIcon parsing' ($withIcon.Count -gt 0) "$($withIcon.Count) of $($installed.Count) apps expose a usable icon"
    }

    Assert-Test 'minOS normalization 22H2'  ((ConvertTo-MinOsValue '22H2') -eq 'Windows10_22H2')
    Assert-Test 'minOS normalization 24H2'  ((ConvertTo-MinOsValue '24H2') -eq 'Windows11_24H2')
    Assert-Test 'minOS passthrough 1607'    ((ConvertTo-MinOsValue '1607') -eq '1607')
    $graphDump = '{"error":{"code":"BadRequest","message":"{\r\n  \"_version\": 3,\r\n  \"Message\": \"Unknown MinimumSupportedWindowsRelease: 22H2 - Operation ID (for customer support): 0000\",\r\n}"}}'
    Assert-Test 'Graph error is humanized' ((Format-RunError $graphDump) -eq 'Unknown MinimumSupportedWindowsRelease: 22H2') (Format-RunError $graphDump)
    $ui.TxtLog.Clear()   # the normalization tests above log warnings on purpose

    # --- Installer engine detection on synthetic signatures ----------------------
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) 'Packwright-selftest'
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Path $testRoot -Force
    $signatures = [ordered]@{
        'inno.exe' = 'xx Inno Setup Setup Data xx'; 'nsis.exe' = 'xx NullsoftInst xx'
        'burn.exe' = 'xx .wixburn xx'; 'ishield.exe' = 'xx InstallShield xx'; 'plain.exe' = 'nothing to see here'
    }
    foreach ($name in $signatures.Keys) { [IO.File]::WriteAllText((Join-Path $testRoot $name), $signatures[$name]) }
    $expectedEngines = @{ 'inno.exe' = 'Inno Setup'; 'nsis.exe' = 'NSIS'; 'burn.exe' = 'WiX Burn'; 'ishield.exe' = 'InstallShield'; 'plain.exe' = 'unknown' }
    foreach ($name in $signatures.Keys) {
        $engineInfo = Get-InstallerInfo -Path (Join-Path $testRoot $name)
        Assert-Test "Engine detection $name" ($engineInfo.Engine -eq $expectedEngines[$name]) "$($engineInfo.Engine) / $($engineInfo.InstallCommand)"
    }

    # --- Scaffold, open, readiness ----------------------------------------------
    $scaffoldManifest = [ordered]@{
        displayName = 'Self Test App'; publisher = 'IT'; version = '1.0'
        installCommandLine = '"nsis.exe" /S'; uninstallCommandLine = ''
        runAsAccount = 'system'; restartBehavior = 'suppress'
        architecture = 'x64'; minimumWindowsRelease = '1607'
        detection = [ordered]@{
            type = 'registry'; keyPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\SelfTest'
            valueName = 'DisplayVersion'; detectionType = 'version'; operator = 'greaterThanOrEqual'
            detectionValue = '1.0'; check32BitOn64System = $false
        }
    }
    $scaffolded = New-InstallerPackage -InstallerPath (Join-Path $testRoot 'nsis.exe') `
        -TargetFolder (Join-Path $testRoot 'pkg\Self Test App 1.0') -Manifest $scaffoldManifest
    Assert-Test 'Scaffold copies the installer' (Test-Path (Join-Path $scaffolded 'nsis.exe'))

    Assert-Test 'Scaffolded package opens' (Open-PackageFolder -Folder $scaffolded)
    Assert-Test 'Editor view shown after open' ($ui.ViewEditor.Visibility -eq 'Visible' -and $ui.PnlActions.Visibility -eq 'Visible')
    Assert-Test 'Name read from app.json' ($ui.TxtName.Text -eq 'Self Test App') "tag: $($ui.TagName.Text)"
    Assert-Test 'Detection type from app.json' ((Get-DetTypeValue) -eq 'registry')
    Assert-Test 'Registry fields visible, MSI hidden' ($ui.PnlDetRegistry.Visibility -eq 'Visible' -and $ui.PnlDetMsi.Visibility -eq 'Collapsed')
    Assert-Test 'Package is publish-ready' (Update-Readiness) $ui.TxtReadyTitle.Text
    Assert-Test 'Detection summary is plain language' ($ui.TxtDetSummary.Text -match 'at least 1\.0') $ui.TxtDetSummary.Text
    Assert-Test 'Preview card filled' ($ui.PvName.Text -eq 'Self Test App' -and $ui.PvVersion.Text -eq 'Version 1.0')

    # Existing-app options are opposites and must stay mutually exclusive
    $ui.ChkUpdateExisting.IsChecked = $true
    $ui.ChkAllowDuplicate.IsChecked = $true
    $ui.ChkAllowDuplicate.RaiseEvent(
        (New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Assert-Test 'Update and allow-duplicate stay mutually exclusive' `
        ($ui.ChkAllowDuplicate.IsChecked -and -not $ui.ChkUpdateExisting.IsChecked)
    $ui.ChkAllowDuplicate.IsChecked = $false

    $ui.TxtName.Text = ''
    Assert-Test 'Readiness drops when the name is cleared' (-not (Update-Readiness)) $ui.TxtReadyTitle.Text
    Assert-Test 'Publish blocked and field marked' ((-not (Test-ReadyToRun -ForPublish)) -and $ui.TxtName.Tag -eq 'invalid')
    Assert-Test 'Build only is still allowed' (Test-ReadyToRun)
    $ui.TxtName.Text = 'Self Test App'

    # --- Changing the setup file refreshes the commands (regression) -------------
    [IO.File]::WriteAllText((Join-Path $scaffolded 'other.exe'), 'xx Inno Setup Setup Data xx')
    Assert-Test 'Package reopens with the new file present' (Open-PackageFolder -Folder $scaffolded -PreferSetup 'nsis.exe')
    $installBefore = $ui.TxtInstall.Text
    $ui.CmbSetup.SelectedItem = 'other.exe'
    Assert-Test 'Setup change rewrites the install command' ($ui.TxtInstall.Text -ne $installBefore -and $ui.TxtInstall.Text -match 'other\.exe') "'$installBefore' -> '$($ui.TxtInstall.Text)'"
    $ui.TxtInstall.Text = 'custom.exe /verysilent'
    $ui.CmbSetup.SelectedItem = 'nsis.exe'
    Assert-Test 'Hand-edited command is not overwritten' ($ui.TxtInstall.Text -eq 'custom.exe /verysilent')

    # --- Detection script path handling (regression) ------------------------------
    $externalScript = Join-Path $testRoot 'Detect-App.ps1'
    [IO.File]::WriteAllText($externalScript, 'Write-Output "installed"; exit 0')
    Set-DetTypeValue 'script'
    $ui.TxtScript.Text = $externalScript
    Assert-Test 'Absolute detection script resolves' ((Resolve-DetectionScript) -eq $externalScript)
    Assert-Test 'Script detection counts as complete' (Update-Readiness)
    $ui.TxtScript.Text = 'nope.ps1'
    Assert-Test 'Missing detection script is caught' (-not (Update-Readiness))

    # --- Detection summaries per method -------------------------------------------
    Set-DetTypeValue 'msi'; $ui.TxtProductCode.Text = '{11111111-2222-3333-4444-555555555555}'
    Assert-Test 'MSI summary' ((Get-DetectionSummary).Ok -and $ui.TxtDetSummary.Text -match 'MSI product')
    Set-DetTypeValue 'file'; $ui.TxtDetPath.Text = 'C:\Program Files\App'; $ui.TxtDetFile.Text = 'app.exe'
    Set-ComboValue $ui.CmbDetCheck 'exists'
    Assert-Test 'File summary' ((Get-DetectionSummary).Ok -and $ui.TxtDetSummary.Text -match 'app\.exe exists')
    Assert-Test 'Comparison value hidden when check is exists' ($ui.TxtDetValue.Visibility -eq 'Collapsed')

    # --- Icon extraction ----------------------------------------------------------
    $iconPackage = Join-Path $testRoot 'iconpkg'
    $null = New-Item -ItemType Directory -Path $iconPackage -Force
    # pwsh.exe keeps its icon resources when copied, so this proves the high-resolution path
    Copy-Item (Get-Process -Id $PID).Path (Join-Path $iconPackage 'payload.exe') -Force
    '{ "displayName": "Icon Test", "publisher": "IT", "detection": { "type": "registry", "keyPath": "HKEY_LOCAL_MACHINE\\SOFTWARE\\X" } }' |
        Set-Content -LiteralPath (Join-Path $iconPackage 'app.json') -Encoding UTF8
    [void](Open-PackageFolder -Folder $iconPackage)
    Import-PackageIcon
    Assert-Test 'Icon extracted from the package payload' (Test-Path (Join-Path $iconPackage 'icon.png')) $ui.TxtIconPath.Text
    Assert-Test 'Icon extracted at high resolution' ($ui.TxtIconPath.Text -match '(\d+)x\1' -and [int]$Matches[1] -ge 64) $ui.TxtIconPath.Text
    Assert-Test 'Extracted icon is shown in the preview' ($null -ne $ui.ImgPreview.Source)
    $savedManifest = Save-AppManifest
    $iconRoundtrip = Get-Content -LiteralPath $savedManifest -Raw | ConvertFrom-Json
    Assert-Test 'Icon reference saved to app.json' ($iconRoundtrip.icon -eq 'icon.png') "icon=$($iconRoundtrip.icon)"

    # --- Your own packages, if you point at some ---------------------------------
    # Set PACKWRIGHT_TESTPACKAGES to a semicolon-separated list of package folders to
    # have the suite open each of them, e.g.
    #   $env:PACKWRIGHT_TESTPACKAGES = 'C:\psadt\7-zip;D:\packages\Acme 1.2'
    $ownPackages = @("$env:PACKWRIGHT_TESTPACKAGES" -split ';' | Where-Object { $_.Trim() })
    if (-not $ownPackages) {
        Write-Host '  SKIP  Real packages (set PACKWRIGHT_TESTPACKAGES to a semicolon-separated list of folders)'
    }
    foreach ($ownPackage in $ownPackages) {
        $folder = $ownPackage.Trim()
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            Assert-Test "Real package exists: $folder" $false 'folder not found'
            continue
        }
        [void](Open-PackageFolder -Folder $folder)
        Assert-Test "Real package opens: $(Split-Path -Leaf $folder)" ($ui.TxtName.Text.Length -gt 0) `
            ("name='{0}' ({1}), detection={2}, ready={3}" -f $ui.TxtName.Text, $ui.TagName.Text, (Get-DetTypeValue), (Update-Readiness))
    }

    # --- Wizard walkthrough -------------------------------------------------------
    $walk = New-StudioWindow -Xaml $script:WizardXaml
    $script:Wz = New-WizState -Dialog $walk
    $walk.C.WTxtInstaller.Text = Join-Path $testRoot 'inno.exe'
    $walk.C.WTxtRoot.Text = Join-Path $testRoot 'pkgroot'
    Update-WizStep
    $stepResults = @()
    $stepResults += Test-WizStep; $script:Wz.Step = 2; Update-WizStep
    Assert-Test 'Wizard prefills the silent switches' ($walk.C.WTxtInstall.Text -match '/VERYSILENT') $walk.C.WTxtInstall.Text
    $walk.C.WTxtName.Text = 'Walkthrough App'; $walk.C.WTxtPublisher.Text = 'IT'
    $stepResults += Test-WizStep; $script:Wz.Step = 3; Update-WizStep
    Assert-Test 'Wizard defaults to picking an installed app' ([bool]$walk.C.WRbDetPick.IsChecked)
    $script:Wz.Detection = [ordered]@{
        type = 'registry'; keyPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Walk'
        valueName = 'DisplayVersion'; detectionType = 'version'; operator = 'greaterThanOrEqual'
        detectionValue = '2.0'; check32BitOn64System = $false
    }
    $stepResults += Test-WizStep; $script:Wz.Step = 4; Update-WizStep
    $stepResults += Test-WizStep; $script:Wz.Step = 5; Update-WizStep
    Assert-Test 'Wizard steps validate' ($stepResults -notcontains $false) "engine=$($script:Wz.Info.Engine)"
    Assert-Test 'Wizard folder name suggested' ($walk.C.WTxtFolder.Text -eq 'Walkthrough App') $walk.C.WTxtFolder.Text
    Assert-Test 'Wizard summary shows the detection rule' ($walk.C.WTxtSummary.Text -match 'DisplayVersion >= 2\.0')
    Assert-Test 'Wizard allows publishing with detection set' ($walk.C.WBtnCreatePublish.IsEnabled)
    $script:Wz.Detection = $null; Update-WizStep
    Assert-Test 'Wizard blocks publishing without detection' ((-not $walk.C.WBtnCreatePublish.IsEnabled) -and $walk.C.WPnlSummaryNote.Visibility -eq 'Visible')

    # --- Back to step 1 and another installer refreshes the rest (regression) ------
    $script:Wz.Step = 1; Update-WizStep
    $walk.C.WTxtInstaller.Text = Join-Path $testRoot 'nsis.exe'
    $walk.C.WTxtUninstall.Text = 'custom-uninstall.exe /S'    # a hand edit that must survive
    $script:Wz.Detection = [ordered]@{ type = 'msi'; productCode = '{11111111-2222-3333-4444-555555555555}' }
    $walk.C.WRbDetMsi.IsChecked = $true
    Assert-Test 'Wizard step 1 accepts the new installer' ([bool](Test-WizStep))
    Assert-Test 'Wizard rewrites the install command for the new installer' `
        ($walk.C.WTxtInstall.Text -match 'nsis\.exe" /S$') $walk.C.WTxtInstall.Text
    Assert-Test 'Wizard keeps a hand-edited command' ($walk.C.WTxtUninstall.Text -eq 'custom-uninstall.exe /S')
    Assert-Test 'Wizard says which edit it kept' ($walk.C.WTxtCmdHint.Text -match 'uninstall command') $walk.C.WTxtCmdHint.Text
    Assert-Test "Wizard drops the old installer's product code" ($null -eq $script:Wz.Detection)
    $script:Wz.Step = 3; Update-WizStep
    Assert-Test 'Wizard clears the MSI option it just hid' ((-not $walk.C.WRbDetMsi.IsChecked) -and [bool]$walk.C.WRbDetPick.IsChecked)
    $script:Wz.Step = 5; Update-WizStep
    Assert-Test 'Wizard summary names the new installer' ($walk.C.WTxtSummary.Text -match 'nsis\.exe \(NSIS\)')
    $script:Wz = $null

    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue

    # The GUI log is invisible in headless mode; surface warnings so they cannot hide
    $logLines = @($ui.TxtLog.Text -split '\r?\n' | Where-Object { $_ -match 'WARNING|ERROR' })
    Assert-Test 'No warnings or errors in the run log' ($logLines.Count -eq 0) $(if ($logLines) { $logLines[0] } else { 'log clean' })
    if ($logLines) {
        Write-Host '  --- log warnings/errors ---'
        $logLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    }

    Write-Host ''
    Write-Host ("SELF-TEST: {0} passed, {1} failed" -f $script:TestPass, $script:TestFail) `
        -ForegroundColor $(if ($script:TestFail) { 'Red' } else { 'Green' })
    if ($script:TestFail) { exit 1 }
    return
}
#endregion

[void]$window.ShowDialog()








