# Start-SequenceInsight.ps1
<#
.SYNOPSIS
    Launcher for Sequence Insight - a dependency-free WPF UI over the SequenceInsight module.

.DESCRIPTION
    Loads configuration (or runs with synthetic demo data via -DevMode), connects the data layer
    (AdminService + SQL), builds the WPF window from ui\MainWindow.xaml, and refreshes task-sequence
    execution data in the background using a runspace pool so the UI never blocks.

    Settings live in a JSON config file (see config\SequenceInsight.config.sample.json) - not the registry.
    MDT is not used; live progress comes from polling the execution data and the AdminService status feed.

.PARAMETER ConfigPath
    Path to SequenceInsight.config.json. Falls back to env SEQUENCEINSIGHT_CONFIG, then .\SequenceInsight.config.json.

.PARAMETER DevMode
    Run with synthetic demo data and no live ConfigMgr connection. Great for trying the UI anywhere.

.PARAMETER Theme
    Override the configured theme: light, dark or auto.

.PARAMETER SelfTest
    Build and populate the window headlessly (no ShowDialog) and exit 0 if controls bind and data loads.
    Used by CI / verification. Requires an STA thread (Windows PowerShell, or pwsh -STA).

.EXAMPLE
    .\Start-SequenceInsight.ps1 -ConfigPath .\SequenceInsight.config.json

.EXAMPLE
    .\Start-SequenceInsight.ps1 -DevMode

.NOTES
    Author: Love Arvidsson
    License: MIT
    Exit codes: 0 success, 1 unhandled error, 3 configuration error.
    WPF needs an STA thread. On pwsh (MTA) this script auto-relaunches under Windows PowerShell -STA
    unless -SelfTest is used.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Launcher intentionally writes user-facing console output (relaunch notice, self-test result, fatal errors).')]
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$DevMode,
    [ValidateSet('light', 'dark', 'auto')][string]$Theme,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$script:ExitSuccess = 0
$script:ExitError   = 1
$script:ExitConfig  = 3

# ------------------------------------------------------------------------------
# STA relaunch (WPF requires STA; pwsh is MTA by default). Skipped for -SelfTest.
# ------------------------------------------------------------------------------
if (-not $SelfTest -and ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') -and -not $env:TSM_STA_RELAUNCH) {
    $env:TSM_STA_RELAUNCH = '1'
    $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath)
    if ($DevMode)    { $relaunchArgs += '-DevMode' }
    if ($ConfigPath) { $relaunchArgs += @('-ConfigPath', $ConfigPath) }
    if ($Theme)      { $relaunchArgs += @('-Theme', $Theme) }
    Write-Host 'Relaunching under Windows PowerShell (STA) for WPF...' -ForegroundColor Cyan
    & powershell.exe @relaunchArgs
    exit $LASTEXITCODE
}

# ------------------------------------------------------------------------------
# UI helpers
# ------------------------------------------------------------------------------
function Initialize-Wpf {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms   # NotifyIcon (local toast)
    Add-Type -AssemblyName System.Drawing         # SystemIcons for the toast
    try { Add-Type -AssemblyName System.Xaml } catch { Write-Verbose "System.Xaml not separately loadable: $_" }
}

function Show-TSToast {
    param([string]$Title, [string]$Message)
    if (-not $script:Notify) { return }
    try {
        $script:Notify.ShowBalloonTip(7000, $Title, $Message, [System.Windows.Forms.ToolTipIcon]::Warning)
    } catch { Write-Verbose "Toast failed: $_" }
}

function New-WindowFromXaml {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory WPF window; no system/external state change.')]
    param([Parameter(Mandatory)][string]$XamlPath)
    $xaml = Get-Content -LiteralPath $XamlPath -Raw
    # Defensive sanitise (matches the Start-OSDForm pattern); our XAML is already clean.
    $xaml = $xaml -replace '\s+mc:Ignorable="[^"]*"', '' -replace '\s+x:Class="[^"]+"', ''
    return [Windows.Markup.XamlReader]::Parse($xaml)
}

function Set-TSTheme {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Swaps in-memory WPF theme brushes; no system/external state change.')]
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][ValidateSet('light', 'dark', 'auto')][string]$Mode
    )
    $effective = $Mode
    if ($Mode -eq 'auto') { $effective = if (Test-SystemDarkTheme) { 'dark' } else { 'light' } }

    $palette = if ($effective -eq 'dark') {
        @{ BgBrush='#0F1117'; PanelBrush='#171A21'; InkBrush='#E6E8EE'; MutedBrush='#9AA3B2';
           LineBrush='#262B36'; AccentBrush='#6EA8FE'; AltRowBrush='#1B1F28'; ErrRowBrush='#241417'; ChipBrush='#1E2533' }
    } else {
        @{ BgBrush='#F6F7F9'; PanelBrush='#FFFFFF'; InkBrush='#1F2430'; MutedBrush='#6B7280';
           LineBrush='#E5E7EB'; AccentBrush='#2563EB'; AltRowBrush='#F2F4F7'; ErrRowBrush='#FEF2F2'; ChipBrush='#EEF2FF' }
    }
    foreach ($key in $palette.Keys) {
        $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($palette[$key]))
        $brush.Freeze()
        # The ResourceDictionary indexer/Add takes [object]; pass the unwrapped .NET object so WPF
        # does not store a PSObject wrapper. Replace (Remove+Add) rather than mutate (XAML brushes
        # consumed by implicit styles get auto-frozen and cannot be mutated).
        $raw = $brush.PSObject.BaseObject
        [void]$Window.Resources.Remove($key)
        $Window.Resources.Add($key, $raw)
    }
    $script:CurrentTheme = $effective
}

function Test-SystemDarkTheme {
    try {
        $v = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        return ($v.AppsUseLightTheme -eq 0)
    } catch { return $false }
}

function Format-UiTime {
    param([AllowNull()][object]$Utc, [string]$DateDisplay = 'local', [string]$Format = 'yyyy-MM-dd HH:mm:ss')
    if (-not $Utc) { return '' }
    $dt = [datetime]::SpecifyKind([datetime]$Utc, [System.DateTimeKind]::Utc)
    if ($DateDisplay -eq 'utc') { return $dt.ToString($Format) + ' UTC' }
    return $dt.ToLocalTime().ToString($Format)
}

function Format-UiDuration {
    param([AllowNull()][object]$Seconds)
    if ($null -eq $Seconds -or "$Seconds" -eq '') { return '' }
    $s = [int]$Seconds; if ($s -lt 0) { return '' }
    $ts = [timespan]::FromSeconds($s)
    if ($ts.TotalHours -ge 1)   { return ('{0}h {1}m' -f [int]$ts.TotalHours, $ts.Minutes) }
    if ($ts.TotalMinutes -ge 1) { return ('{0}m {1}s' -f [int]$ts.TotalMinutes, $ts.Seconds) }
    return ('{0}s' -f $ts.Seconds)
}

function Set-AutoInterval {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Adjusts an in-memory DispatcherTimer interval; no system/external state change.')]
    [CmdletBinding()]
    param()
    if (-not $script:AutoTimer) { return }
    $secs = 60
    if ($script:UI.IntervalCombo.SelectedItem -and $script:UI.IntervalCombo.SelectedItem.Seconds) {
        $secs = [int]$script:UI.IntervalCombo.SelectedItem.Seconds
    }
    $script:AutoTimer.Stop()
    $script:AutoTimer.Interval = [timespan]::FromSeconds([math]::Max(5, $secs))
    $script:AutoTimer.Start()
}

# ------------------------------------------------------------------------------
# Data binding
# ------------------------------------------------------------------------------
function Update-RunsGrid {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates in-memory WPF grid bindings; no system/external state change.')]
    param([object[]]$Runs)
    $runs = @($Runs)

    # Annotate with live status using the baseline from this fetch and the current time.
    $baseline = Get-TSStepBaseline -Runs $runs -MinRuns ([int]$script:Ctx.Config.analytics.baselineMinSuccessRuns)
    $null = Add-TSLiveInfo -Runs $runs -Baseline $baseline -AsOf (Get-Date) -LiveWindowMinutes ([int]$script:Ctx.Config.liveWindowMinutes)

    # In-progress runs on top, then most-recent activity.
    $script:Runs = @($runs | Sort-Object @{ Expression = { [bool]$_.IsInProgress }; Descending = $true }, @{ Expression = { $_.EndedUtc }; Descending = $true })

    $display = foreach ($r in $script:Runs) {
        $live = ''
        if ($r.IsInProgress) { $live = if ($null -ne $r.PercentComplete) { 'running ~{0}%' -f $r.PercentComplete } else { 'running' } }
        [pscustomobject]@{
            Live         = $live
            Computer     = $r.Computer
            TaskSequence = $r.TaskSequence
            Status       = if ($r.IsInProgress) { 'Running' } elseif ($r.Superseded) { 'Superseded' } else { $r.Status }
            Errors       = $r.ErrorCount
            Steps        = $r.StepCount
            Started      = Format-UiTime -Utc $r.StartedUtc -DateDisplay $script:Ctx.DateDisplay
            _Run         = $r
        }
    }
    $script:UI.RunsGrid.ItemsSource = @($display)

    $errRuns  = @($script:Runs | Where-Object { $_.ErrorCount -gt 0 }).Count
    $liveRuns = @($script:Runs | Where-Object { $_.IsInProgress }).Count

    # If the number of step rows hit the cap, the window was truncated to the most recent rows -
    # warn so "older data missing" isn't mistaken for a broken date filter.
    $capNote = ''
    if (-not $script:Ctx.DevMode) {
        $totalSteps = [int](@($script:Runs | Measure-Object StepCount -Sum).Sum)
        if ($totalSteps -ge [int]$script:Ctx.MaxRows) {
            $capNote = ' | NOTE: hit the {0}-row cap - raise maxRows or narrow the window/computer to see older runs' -f $script:Ctx.MaxRows
        }
    }
    $script:UI.StatusText.Text = ('{0} runs | {1} in progress | {2} with errors | refreshed {3}{4}' -f $script:Runs.Count, $liveRuns, $errRuns, (Get-Date -Format 'HH:mm:ss'), $capNote)
}

function Show-RunStep {
    param($Run)
    if (-not $Run) { $script:UI.StepsGrid.ItemsSource = @(); $script:UI.OutputBox.Text = ''; return }
    # Run.Steps is already in canonical execution order (timestamp, then step) from ConvertTo-TSRun.
    $steps = foreach ($s in @($Run.Steps)) {
        [pscustomobject]@{
            Step     = $s.Step
            Action   = $s.ActionName
            Status   = $s.Status
            ExitCode = $s.ExitCode
            Duration = Format-UiDuration -Seconds $s.DurationSeconds
            Time     = Format-UiTime -Utc $s.ExecutionTimeUtc -DateDisplay $script:Ctx.DateDisplay -Format 'yyyy-MM-dd HH:mm:ss.fff'
            _Output  = $s.ActionOutput
            _Step    = $s   # underlying normalized step, for lazy output load
        }
    }
    $script:UI.StepsGrid.ItemsSource = @($steps)
    $script:UI.OutputBox.Text = ''
}

# ------------------------------------------------------------------------------
# Background refresh (runspace pool keeps the UI responsive)
# ------------------------------------------------------------------------------
function Test-TSSelected {
    # True only when a specific task sequence (not "All") is selected.
    return ($script:UI.TsCombo.SelectedItem -and $script:UI.TsCombo.SelectedItem.PackageID)
}

function Get-CurrentFilter {
    $pkg = $null
    if (Test-TSSelected) { $pkg = [string]$script:UI.TsCombo.SelectedItem.PackageID }

    # Free-form "last N hours" (default 24). Tolerates a trailing unit, e.g. "120h".
    $hours = 24
    if ([string]$script:UI.HoursBox.Text -match '(\d+)') { $h = [int]$Matches[1]; if ($h -ge 1) { $hours = $h } }

    return @{
        PackageID  = $pkg
        Computer   = [string]$script:UI.ComputerBox.Text
        SinceHours = $hours
        ErrorsOnly = [bool]$script:UI.ErrorsOnlyCheck.IsChecked
    }
}

function Invoke-RefreshSync {
    # Synchronous fetch + populate (used by -SelfTest and as the simple path).
    $f = Get-CurrentFilter
    $runs = Get-TSRun -Context $script:Ctx -PackageID $f.PackageID -Computer $f.Computer -SinceHours $f.SinceHours -ErrorsOnly:$f.ErrorsOnly
    Update-RunsGrid -Runs $runs
    if (@($runs).Count) { $script:UI.RunsGrid.SelectedIndex = 0 }
}

function Start-RefreshJob {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts an in-memory background runspace refresh; no system/external state change.')]
    [CmdletBinding()]
    param()
    # One refresh in flight at a time. If a filter changes while busy, remember to re-run when it
    # finishes so the latest filter is always applied (fixes "filter ignored until manual refresh").
    if ($script:CurrentJob) { $script:RefreshPending = $true; return }
    $script:UI.StatusText.Text = 'Refreshing...'
    $f = Get-CurrentFilter
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript({
        param($ctx, $pkg, $comp, $hours, $errorsOnly)
        Get-TSRun -Context $ctx -PackageID $pkg -Computer $comp -SinceHours $hours -ErrorsOnly:$errorsOnly
    }).AddArgument($script:Ctx).AddArgument($f.PackageID).AddArgument($f.Computer).AddArgument($f.SinceHours).AddArgument($f.ErrorsOnly)
    $handle = $ps.BeginInvoke()
    $script:CurrentJob = @{ PS = $ps; Handle = $handle }
}

function Complete-RefreshJob {
    if (-not $script:CurrentJob) { return }
    if (-not $script:CurrentJob.Handle.IsCompleted) { return }
    $ps = $script:CurrentJob.PS
    try {
        $result = $ps.EndInvoke($script:CurrentJob.Handle)
        if ($ps.HadErrors -and $ps.Streams.Error.Count) {
            $script:UI.StatusText.Text = 'Error: ' + $ps.Streams.Error[0].ToString()
        } else {
            $prevKey = $null
            if ($script:UI.RunsGrid.SelectedItem) { $prevKey = $script:UI.RunsGrid.SelectedItem.Computer + '|' + $script:UI.RunsGrid.SelectedItem.TaskSequence }
            Update-RunsGrid -Runs @($result)

            # Failure alerts: toast on runs that newly transitioned to failed during this session
            # (the first refresh only seeds the baseline so the existing backlog does not alert).
            if ($script:Ctx.Config.alerts.onFailure) {
                $fail = Get-TSNewFailure -PreviousFailedKeys $script:KnownFailedKeys -Current @($script:Runs)
                if ($script:AlertsArmed) {
                    foreach ($nf in $fail.NewFailures) {
                        Show-TSToast -Title 'Task sequence failed' -Message ('{0} - {1}' -f $nf.Computer, $nf.TaskSequence)
                    }
                }
                $script:KnownFailedKeys = $fail.AllFailedKeys
                $script:AlertsArmed = $true
            }

            if ($prevKey) {
                $match = @($script:UI.RunsGrid.ItemsSource) | Where-Object { ($_.Computer + '|' + $_.TaskSequence) -eq $prevKey } | Select-Object -First 1
                if ($match) { $script:UI.RunsGrid.SelectedItem = $match } elseif (@($script:UI.RunsGrid.ItemsSource).Count) { $script:UI.RunsGrid.SelectedIndex = 0 }
            } elseif (@($script:UI.RunsGrid.ItemsSource).Count) {
                $script:UI.RunsGrid.SelectedIndex = 0
            }
        }
    } catch {
        $script:UI.StatusText.Text = "Refresh failed: $_"
    } finally {
        $ps.Dispose()
        $script:CurrentJob = $null
    }
    # A filter change arrived while we were busy - run once more with the latest filter.
    if ($script:RefreshPending) {
        $script:RefreshPending = $false
        Start-RefreshJob
    }
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
$exitCode = $script:ExitSuccess
$script:Runs = @()
$script:CurrentJob = $null
$script:RefreshPending = $false
$script:KnownFailedKeys = @()
$script:AlertsArmed = $false
$script:Notify = $null

try {
    Initialize-Wpf

    # --- Module ---
    $modulePath = Join-Path $PSScriptRoot 'SequenceInsight\SequenceInsight.psd1'
    Import-Module $modulePath -Force

    # --- Config / connect ---
    if ($DevMode) {
        $script:Ctx = Connect-SequenceInsight -DevMode
    } else {
        $script:Ctx = Connect-SequenceInsight -ConfigPath $ConfigPath -DefaultConfigDirectory $PSScriptRoot
    }
    if ($Theme) { $script:Ctx.Config.theme = $Theme }

    # --- Window ---
    $xamlPath = Join-Path $PSScriptRoot 'ui\MainWindow.xaml'
    $window = New-WindowFromXaml -XamlPath $xamlPath
    $script:UI = @{
        Window           = $window
        TsCombo          = $window.FindName('TsCombo')
        ComputerBox      = $window.FindName('ComputerBox')
        HoursBox         = $window.FindName('HoursBox')
        ErrorsOnlyCheck  = $window.FindName('ErrorsOnlyCheck')
        RefreshButton    = $window.FindName('RefreshButton')
        AutoRefreshCheck = $window.FindName('AutoRefreshCheck')
        IntervalCombo    = $window.FindName('IntervalCombo')
        ExportButton     = $window.FindName('ExportButton')
        ThemeButton      = $window.FindName('ThemeButton')
        RunsGrid         = $window.FindName('RunsGrid')
        StepsGrid        = $window.FindName('StepsGrid')
        OutputBox        = $window.FindName('OutputBox')
        StatusText       = $window.FindName('StatusText')
        ConnText         = $window.FindName('ConnText')
    }

    # --- Populate static choices ---
    # "Last N hours" free-form box, seeded from config.
    $defaultHours = [math]::Max(1, [int]$script:Ctx.Config.defaultTimeWindowHours)
    $script:UI.HoursBox.Text = [string]$defaultHours

    # Auto-refresh interval choices (operator picks the cadence; default seeded from config).
    $intervals = @(
        [pscustomobject]@{ Label = '15 sec'; Seconds = 15 }
        [pscustomobject]@{ Label = '30 sec'; Seconds = 30 }
        [pscustomobject]@{ Label = '1 min';  Seconds = 60 }
        [pscustomobject]@{ Label = '2 min';  Seconds = 120 }
        [pscustomobject]@{ Label = '5 min';  Seconds = 300 }
        [pscustomobject]@{ Label = '10 min'; Seconds = 600 }
        [pscustomobject]@{ Label = '15 min'; Seconds = 900 }
        [pscustomobject]@{ Label = '30 min'; Seconds = 1800 }
    )
    $cfgSecs = [math]::Max(5, [int]$script:Ctx.Config.refreshIntervalSeconds)
    if (-not ($intervals | Where-Object { $_.Seconds -eq $cfgSecs })) {
        $cfgLabel = if ($cfgSecs % 60 -eq 0) { ('{0} min' -f ([int]($cfgSecs / 60))) } else { ('{0} sec' -f $cfgSecs) }
        $intervals = @(@([pscustomobject]@{ Label = $cfgLabel; Seconds = $cfgSecs }) + $intervals) | Sort-Object Seconds
    }
    $script:UI.IntervalCombo.ItemsSource = $intervals   # display via XAML ItemTemplate ({Binding Label})
    $script:UI.IntervalCombo.SelectedItem = ($intervals | Where-Object { $_.Seconds -eq $cfgSecs } | Select-Object -First 1)

    $script:UI.ErrorsOnlyCheck.IsChecked = [bool]$script:Ctx.Config.errorsOnlyDefault
    $script:UI.ConnText.Text = if ($script:Ctx.DevMode) { 'Demo mode' } else { ('Site {0} | {1}' -f $script:Ctx.SiteCode, $script:Ctx.Provider) }

    # Task sequence list (with an "All" entry).
    $tsItems = New-Object System.Collections.Generic.List[object]
    $tsItems.Add([pscustomobject]@{ Name = 'All task sequences'; PackageID = $null })
    foreach ($ts in @(Get-TSList -Context $script:Ctx)) {
        $tsItems.Add([pscustomobject]@{ Name = $ts.Name; PackageID = $ts.PackageID })
    }
    $script:UI.TsCombo.ItemsSource = $tsItems   # display via XAML ItemTemplate ({Binding Name})
    $script:UI.TsCombo.SelectedIndex = 0

    # --- Theme ---
    Set-TSTheme -Window $window -Mode $script:Ctx.Config.theme

    # --- Events ---
    # Refresh button + Computer/Enter are explicit loads (work for any selection, incl. "All").
    # Selecting a specific task sequence auto-loads; changing days/errors-only re-loads only if a
    # task sequence is already selected. Nothing loads at startup until the operator picks one.
    $script:UI.RefreshButton.Add_Click({ Start-RefreshJob })
    $script:UI.TsCombo.Add_SelectionChanged({ if ($script:UiReady -and (Test-TSSelected)) { Start-RefreshJob } })
    $script:UI.HoursBox.Add_KeyDown({ if ($_.Key -eq 'Return' -and (Test-TSSelected)) { Start-RefreshJob } })
    $script:UI.ErrorsOnlyCheck.Add_Click({ if (Test-TSSelected) { Start-RefreshJob } })
    $script:UI.IntervalCombo.Add_SelectionChanged({ if ($script:UiReady) { Set-AutoInterval } })
    $script:UI.ComputerBox.Add_KeyDown({ if ($_.Key -eq 'Return') { Start-RefreshJob } })
    $script:UI.RunsGrid.Add_SelectionChanged({ Show-RunStep -Run ($script:UI.RunsGrid.SelectedItem._Run) })
    $script:UI.StepsGrid.Add_SelectionChanged({
        $sel = $script:UI.StepsGrid.SelectedItem
        if (-not $sel) { $script:UI.OutputBox.Text = ''; return }
        $out = [string]$sel._Output
        # Output is loaded lazily for the SQL path (list views skip the large column).
        if (-not $out -and -not $script:Ctx.DevMode -and $sel._Step -and $sel._Step.ResourceID) {
            $script:UI.OutputBox.Text = '(loading output...)'
            try {
                $out = Get-TSStepOutput -Context $script:Ctx -ResourceID ([int]$sel._Step.ResourceID) -Step ([int]$sel._Step.Step) -ExecutionTimeUtc ([datetime]$sel._Step.ExecutionTimeUtc)
                $sel._Output = $out   # cache so re-selecting is instant
            } catch { $out = "Could not load output: $_" }
        }
        $script:UI.OutputBox.Text = $out
    })
    $script:UI.ThemeButton.Add_Click({
        $next = if ($script:CurrentTheme -eq 'dark') { 'light' } else { 'dark' }
        Set-TSTheme -Window $window -Mode $next
    })
    $script:UI.ExportButton.Add_Click({
        try {
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.Title = 'Export report'
            $dlg.Filter = 'HTML report (*.html)|*.html'
            $dlg.FileName = 'ts-report.html'
            if ($dlg.ShowDialog()) {
                $outDir = Split-Path -Parent $dlg.FileName
                # Re-query (with full action output) using the current filters, so the report is complete.
                $f = Get-CurrentFilter
                $ep = @{ Context = $script:Ctx; OutputDirectory = $outDir; SinceHours = $f.SinceHours; Formats = @('Html', 'Csv') }
                if ($f.PackageID)  { $ep['PackageID'] = $f.PackageID }
                if ($f.Computer)   { $ep['Computer'] = $f.Computer }
                if ($f.ErrorsOnly) { $ep['ErrorsOnly'] = $true }
                $path = Export-TSReport @ep
                $script:UI.StatusText.Text = "Report exported to $path"
                Start-Process $path
            }
        } catch {
            [System.Windows.MessageBox]::Show("Export failed: $_", 'Sequence Insight', 'OK') | Out-Null
        }
    })

    # --- Background runspace pool (module pre-imported into each runspace) ---
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModule(@($modulePath))
    $script:Pool = [runspacefactory]::CreateRunspacePool(1, 2, $iss, $Host)
    $script:Pool.ApartmentState = 'STA'
    $script:Pool.Open()
    # Share the connected context into new runspaces so background Get-TSRun has it cached too.
    # (We pass it explicitly via -Context, so this is belt-and-suspenders.)

    # --- Completion poller: applies finished background results on the UI thread ---
    $poller = New-Object System.Windows.Threading.DispatcherTimer
    $poller.Interval = [timespan]::FromMilliseconds(350)
    $poller.Add_Tick({ Complete-RefreshJob })
    $poller.Start()

    # --- Auto-refresh timer (cadence driven by IntervalCombo, seeded from config) ---
    $script:AutoTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:AutoTimer.Interval = [timespan]::FromSeconds([math]::Max(5, $cfgSecs))
    $script:AutoTimer.Add_Tick({ if ($script:UI.AutoRefreshCheck.IsChecked -and (Test-TSSelected) -and -not $script:CurrentJob) { Start-RefreshJob } })
    $script:AutoTimer.Start()

    # --- Local toast (NotifyIcon) for failure alerts; nothing leaves the machine ---
    if ($script:Ctx.Config.alerts.toast -and -not $SelfTest) {
        try {
            $script:Notify = New-Object System.Windows.Forms.NotifyIcon
            $script:Notify.Icon = [System.Drawing.SystemIcons]::Information
            $script:Notify.Text = 'Sequence Insight'
            $script:Notify.Visible = $true
        } catch {
            $script:Notify = $null
            Write-TSLog -Message "Toast init failed (continuing without toast): $_" -Level WARN
        }
    }

    $script:UiReady = $true

    if ($SelfTest) {
        # Headless verification: bind check + synchronous DevMode populate.
        $missing = @($script:UI.GetEnumerator() | Where-Object { $null -eq $_.Value } | ForEach-Object { $_.Key })
        if ($missing.Count) { throw "Controls failed to bind: $($missing -join ', ')" }
        Invoke-RefreshSync
        $runCount = @($script:UI.RunsGrid.ItemsSource).Count
        if ($runCount) { Show-RunStep -Run $script:Runs[0] }  # deterministic steps populate
        $stepCount = @($script:UI.StepsGrid.ItemsSource).Count
        Set-TSTheme -Window $window -Mode 'dark'
        Set-TSTheme -Window $window -Mode 'light'
        Write-Host ("SELFTEST OK: runs={0}, stepsForFirstRun={1}, theme toggled" -f $runCount, $stepCount) -ForegroundColor Green
        if ($runCount -lt 1) { throw 'SelfTest: no runs populated.' }
        $script:Pool.Close()
        exit $script:ExitSuccess
    }

    # No load at startup - wait until the operator picks a task sequence (or clicks Refresh).
    $script:UI.StatusText.Text = 'Select a task sequence to load runs (or click Refresh for all).'
    [void]$window.ShowDialog()
    $script:Pool.Close()
    if ($script:Notify) { $script:Notify.Visible = $false; $script:Notify.Dispose() }
}
catch {
    $msg = "Start-SequenceInsight failed: $_"
    Write-Host $msg -ForegroundColor Red
    try { [System.Windows.MessageBox]::Show($msg, 'Sequence Insight', 'OK') | Out-Null } catch { Write-Verbose "No UI for message box: $_" }
    $exitCode = if ("$_" -match 'Config') { $script:ExitConfig } else { $script:ExitError }
}

exit $exitCode
