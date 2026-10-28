<#
.SYNOPSIS
    Packwright's studio, the WinGet part: the "Install it with WinGet" dialog, the WinGet card in
    the editor and the WinGet runtime package. Not a script to run on its own.

.DESCRIPTION
    Packwright.ps1 reads this file, and New-WinGetPackage.ps1 with it, the first time a session
    needs WinGet: a WinGet package opened, "Install it with WinGet" picked, Settings shown, or a
    Packwright.policy.json for the start screen to read (Import-StudioWinGet). A session that never
    touches WinGet reads neither.

    Everything here runs in Packwright.ps1's script scope, as if it were still written there. It
    uses that script's window and controls ($ui), its state ($script:LoadedFolder,
    $script:WinGetBlock and the rest) and its functions; that script calls these in turn, from the
    few places a WinGet package is different, once Import-StudioWinGet has read them. Keep the top
    level of this file to $script: variables and functions: anything else would be a local of
    Import-StudioWinGet, gone again when it returns.

.NOTES
    Author   : Love A
    Requires : PowerShell 7+, Windows; Packwright.ps1 and New-WinGetPackage.ps1 next to it.
    Versioned with Packwright.ps1 (Studio): its changes are under Studio in CHANGELOG.md.
    The self-test is Invoke-WinGetSelfTest, run by .\Packwright.ps1 -TestLoad.
#>
if ($MyInvocation.InvocationName -ne '.') {
    throw 'Packwright.WinGet.ps1 is part of Packwright, which reads it when it is needed. Start Packwright.ps1 instead.'
}

#region ---- The WinGet card in the editor ------------------------------------------
# At the top of the editor, for a package New-WinGetPackage wrote. The main window keeps a place
# for it (WinGetCardHost), and Initialize-StudioWinGet puts it there and its controls in $ui, beside
# the window's own. Parsed on its own it cannot see the window's resources, so it brings the theme.
$script:WinGetCardXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Border.Resources>
<!--THEME-->
  </Border.Resources>
  <Border x:Name="PnlWinGet" Style="{StaticResource Card}" Visibility="Collapsed">
    <StackPanel>
      <DockPanel>
        <Border x:Name="WgBadge" DockPanel.Dock="Right" CornerRadius="10" Padding="9,3" VerticalAlignment="Top"
                Background="{StaticResource AccentSoft}">
          <TextBlock x:Name="WgTxtBadge" FontSize="11" FontWeight="SemiBold" Foreground="{StaticResource Accent}"/>
        </Border>
        <StackPanel>
          <TextBlock Style="{StaticResource H2}" Text="Installed with WinGet"/>
          <TextBlock x:Name="WgTxtIdLine" Style="{StaticResource Tiny}" Margin="0,2,0,0"/>
        </StackPanel>
      </DockPanel>
      <TextBlock x:Name="WgTxtSummary" Style="{StaticResource Body}" Margin="0,10,0,0"/>
      <StackPanel x:Name="WgPnlVersion" Margin="0,4,0,0">
        <TextBlock Style="{StaticResource FieldLabel}" Text="VERSION DEVICES GET"/>
        <DockPanel>
          <Button x:Name="WgBtnVersion" DockPanel.Dock="Right" Style="{StaticResource BtnDefault}"
                  Content="Use this version" Margin="8,0,0,0"/>
          <ComboBox x:Name="WgCmbVersion"/>
        </DockPanel>
      </StackPanel>
      <TextBlock x:Name="WgTxtVersionNote" Style="{StaticResource Tiny}" Margin="0,6,0,0"/>
      <WrapPanel Margin="0,10,0,0">
        <Button x:Name="WgBtnRefresh" Style="{StaticResource BtnDefault}" Content="Refresh the scripts"
                Margin="0,0,8,0" Visibility="Collapsed"/>
        <Button x:Name="WgBtnChange" Style="{StaticResource BtnQuiet}" Content="Pick another app..."/>
      </WrapPanel>
      <Border x:Name="WgPnlRuntime" Style="{StaticResource Note}" Margin="0,10,0,0">
        <StackPanel>
          <TextBlock x:Name="WgTxtRuntime" Style="{StaticResource Tiny}"/>
          <Button x:Name="WgBtnRuntime" Style="{StaticResource BtnQuiet}" HorizontalAlignment="Left"
                  Content="Create the WinGet runtime package..." Margin="-8,4,0,0"/>
        </StackPanel>
      </Border>
    </StackPanel>
  </Border>
</Border>
'@

# Once, when this file is read: the card into the editor, its buttons wired, and those buttons
# among the ones a build or publish switches off while it runs
function Initialize-StudioWinGet {
    $card = [Windows.Markup.XamlReader]::Parse($script:WinGetCardXaml.Replace('<!--THEME-->', $script:Theme))
    foreach ($name in ([regex]::Matches($script:WinGetCardXaml, 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value })) {
        $control = $card.FindName($name)
        if ($null -eq $control) { throw "The WinGet card has no control named $name." }
        $ui[$name] = $control
    }
    $ui.WinGetCardHost.Child = $card

    $ui.WgBtnVersion.Add_Click({ Start-WinGetReplan })
    $ui.WgBtnRefresh.Add_Click({
        try {
            $written = @(Update-WinGetScript -Folder $script:LoadedFolder)
            Write-GuiLog "WinGet scripts written again from app.json: $($written -join ', ')"
            Set-StatusText 'The WinGet scripts are Packwright''s own again.'
        }
        catch { Write-GuiLog "ERROR: $($_.Exception.Message)" }
        Clear-PackageCache -Folder $script:LoadedFolder
        Update-WinGetScriptState
        Update-WinGetCard
        Update-Readiness | Out-Null
    })
    $ui.WgBtnChange.Add_Click({ Show-WinGetDialog })
    $ui.WgBtnRuntime.Add_Click({ Start-WinGetRuntimeBuild })
    $ui.CmbRunAs.Add_SelectionChanged({ if (-not $script:Loading -and (Test-WinGetPackage)) { Update-WinGetCard } })

    foreach ($name in 'WgBtnVersion', 'WgBtnRefresh', 'WgBtnChange', 'WgBtnRuntime') {
        $script:RunLockedButtons.Add($name)
        $ui[$name].IsEnabled = -not $script:RunPS
    }
}
#endregion

#region ---- WinGet dialog XAML --------------------------------------------------
$script:WinGetXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="New package from WinGet" Width="1010" Height="720" MinWidth="820" MinHeight="560"
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
        <TextBlock Style="{StaticResource H1}" FontSize="18" Text="Install an app with WinGet"/>
        <TextBlock Style="{StaticResource Muted}" Margin="0,4,0,0"
                   Text="Pick where the app comes from, and find it. The package is written from the app's manifest; no installer goes into it, because each device installs the app itself."/>
        <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
          <RadioButton x:Name="GRbStore" GroupName="WinGetSource" Content="Microsoft Store" Margin="0,0,22,0" VerticalAlignment="Center"/>
          <RadioButton x:Name="GRbCommunity" GroupName="WinGetSource" Content="WinGet community repository" Margin="0" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock x:Name="GTxtSourceNote" Style="{StaticResource Tiny}" Margin="0,4,0,0"/>
      </StackPanel>
    </Border>

    <Grid Grid.Row="1" Margin="22,14,22,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="11*"/><ColumnDefinition Width="9*"/>
      </Grid.ColumnDefinitions>
      <Grid Grid.Column="0" Margin="0,0,14,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <DockPanel>
          <Button x:Name="GBtnSearch" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="Search"
                  Margin="8,0,0,0" IsDefault="True"/>
          <TextBox x:Name="GTxtQuery"/>
        </DockPanel>
        <ListView x:Name="GLstResults" Grid.Row="1" Margin="0,10,0,0" BorderBrush="{StaticResource Stroke}"
                  Background="{StaticResource BgCard}">
          <ListView.View>
            <GridView>
              <GridViewColumn Header="Name" Width="180" DisplayMemberBinding="{Binding Name}"/>
              <GridViewColumn Header="Id" Width="150" DisplayMemberBinding="{Binding Id}"/>
              <GridViewColumn Header="Version" Width="72" DisplayMemberBinding="{Binding Version}"/>
              <GridViewColumn Header="Publisher / kind" Width="120" DisplayMemberBinding="{Binding Detail}"/>
            </GridView>
          </ListView.View>
        </ListView>
        <TextBlock x:Name="GTxtResults" Grid.Row="2" Style="{StaticResource Tiny}" Margin="0,6,0,0"
                   Text="Type part of the name, or the exact id if you know it."/>
      </Grid>

      <Border Grid.Column="1" Background="{StaticResource BgCard}" BorderBrush="{StaticResource Stroke}"
              BorderThickness="1" CornerRadius="8" Padding="16,14">
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel>
            <DockPanel>
              <Border DockPanel.Dock="Left" Width="56" Height="56" Background="White" CornerRadius="6"
                      BorderBrush="{StaticResource Stroke}" BorderThickness="1" Margin="0,0,12,0" VerticalAlignment="Top">
                <Image x:Name="GImgIcon" Stretch="Uniform" Margin="5"/>
              </Border>
              <StackPanel>
                <TextBlock x:Name="GTxtName" Style="{StaticResource H2}" Text="Nothing picked yet"/>
                <TextBlock x:Name="GTxtPublisher" Style="{StaticResource Muted}"/>
                <TextBlock x:Name="GTxtIdLine" Style="{StaticResource Tiny}" Margin="0,2,0,0"/>
              </StackPanel>
            </DockPanel>
            <TextBlock x:Name="GTxtDescription" Style="{StaticResource Body}" Margin="0,10,0,0" MaxHeight="72"
                       TextTrimming="WordEllipsis"/>
            <StackPanel x:Name="GPnlVersion" Visibility="Collapsed">
              <TextBlock Style="{StaticResource FieldLabel}" Text="VERSION DEVICES GET"/>
              <ComboBox x:Name="GCmbVersion"/>
            </StackPanel>
            <StackPanel x:Name="GPnlDelivery" Visibility="Collapsed">
              <TextBlock Style="{StaticResource FieldLabel}" Text="HOW INTUNE DELIVERS IT"/>
              <RadioButton x:Name="GRbWin32" GroupName="WinGetDelivery" Content="A Win32 app that installs it with WinGet"/>
              <RadioButton x:Name="GRbStoreApp" GroupName="WinGetDelivery" Content="Intune's own Microsoft Store app type"/>
              <TextBlock x:Name="GTxtDelivery" Style="{StaticResource Tiny}" Margin="20,4,0,0"/>
            </StackPanel>
            <TextBlock Style="{StaticResource FieldLabel}" Text="WHAT INTUNE WILL DO" Margin="0,14,0,3"/>
            <TextBlock x:Name="GTxtPlan" Style="{StaticResource Body}" Text="Pick an app to see how it will be installed and detected."/>
            <Border x:Name="GPnlBlock" Style="{StaticResource Note}" Margin="0,10,0,0" Visibility="Collapsed"
                    Background="{StaticResource ErrSoft}" BorderBrush="{StaticResource Err}">
              <TextBlock x:Name="GTxtBlock" Style="{StaticResource Body}" Foreground="{StaticResource Err}"/>
            </Border>
            <Border x:Name="GPnlWarn" Style="{StaticResource Note}" Margin="0,10,0,0" Visibility="Collapsed"
                    Background="{StaticResource WarnSoft}" BorderBrush="{StaticResource Warn}">
              <TextBlock x:Name="GTxtWarn" Style="{StaticResource Body}" Foreground="{StaticResource Warn}"/>
            </Border>
            <TextBlock x:Name="GTxtNotes" Style="{StaticResource Tiny}" Margin="0,10,0,0"/>
          </StackPanel>
        </ScrollViewer>
      </Border>
    </Grid>

    <Border Grid.Row="2" Background="{StaticResource BgCard}" BorderBrush="{StaticResource Stroke}" BorderThickness="0,1,0,0">
      <DockPanel Margin="22,12">
        <Button x:Name="GBtnCancel" DockPanel.Dock="Right" Style="{StaticResource BtnQuiet}" Content="Cancel"
                Margin="8,0,0,0" IsCancel="True"/>
        <Button x:Name="GBtnCreatePublish" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}"
                Content="Create and publish" Margin="8,0,0,0" IsEnabled="False"/>
        <Button x:Name="GBtnCreate" DockPanel.Dock="Right" Style="{StaticResource BtnDefault}"
                Content="Create package" IsEnabled="False"/>
        <Button x:Name="GBtnRuntime" DockPanel.Dock="Left" Style="{StaticResource BtnQuiet}"
                Content="WinGet runtime package..." Margin="-8,0,0,0"
                ToolTip="The app every device needs once, so WinGet works for SYSTEM"/>
        <TextBlock x:Name="GTxtFolder" Style="{StaticResource Tiny}" VerticalAlignment="Center" Margin="8,0,12,0"
                   TextTrimming="CharacterEllipsis"/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@
#endregion

#region ---- WinGet dialog logic --------------------------------------------------
function Get-WinGetSourceLabel {
    param([string]$Source)
    switch ($Source) { 'msstore' { 'Microsoft Store' } 'winget' { 'WinGet community repository' } default { $Source } }
}

# What each source is, said where the choice is made. The Store's own description is a short
# one on purpose: what an organisation that allows only the Store needs to know is that the
# Store vets the app and serves the installer itself — Win32 apps from the Store included.
function Get-WinGetSourceNote {
    param([string]$Source, $Policy)
    $note = switch ($Source) {
        'msstore' { 'Curated by Microsoft: every app is certified, and installers come from the Store''s own servers, checked against their hash.' }
        'winget'  { 'Kept by the WinGet community on GitHub. Each installer downloads from its publisher''s own site and is checked against the hash in the manifest.' }
    }
    if ($Policy.Restricted) {
        $allowed = if ($Policy.AllowedSources.Count) { ($Policy.AllowedSources | ForEach-Object { Get-WinGetSourceLabel $_ }) -join ' and ' } else { 'nothing' }
        $note += "  Your organisation allows $allowed only ($(Split-Path -Leaf $Policy.Path))."
    }
    $note
}

function Set-WgSource {
    param([Parameter(Mandatory)][string]$Source)
    $wg = $script:Wg
    $wg.Source = $Source
    $wg.C.GTxtSourceNote.Text = Get-WinGetSourceNote -Source $Source -Policy $wg.Policy
    $wg.C.GLstResults.ItemsSource = $null
    $wg.C.GTxtResults.Text = if ($Source -eq 'winget' -and -not (Find-LocalWinGet)) {
        'WinGet is not available on this computer, so the community repository cannot be searched from here.'
    } else { 'Type part of the name, or the exact id if you know it.' }
    Clear-WgDetail
}

function Clear-WgDetail {
    $c = $script:Wg.C
    $script:Wg.Info = $null; $script:Wg.Plan = $null
    $c.GImgIcon.Source = $null
    $c.GTxtName.Text = 'Nothing picked yet'; $c.GTxtPublisher.Text = ''; $c.GTxtIdLine.Text = ''; $c.GTxtDescription.Text = ''
    $c.GPnlVersion.Visibility = 'Collapsed'; $c.GPnlDelivery.Visibility = 'Collapsed'
    $c.GTxtPlan.Text = 'Pick an app to see how it will be installed and detected.'
    $c.GPnlBlock.Visibility = 'Collapsed'; $c.GPnlWarn.Visibility = 'Collapsed'; $c.GTxtNotes.Text = ''
    $c.GBtnCreate.IsEnabled = $false; $c.GBtnCreatePublish.IsEnabled = $false
}

function Start-WgSearch {
    $wg = $script:Wg
    $query = $wg.C.GTxtQuery.Text.Trim()
    if (-not $query) { return }
    $wg.C.GTxtResults.Text = "Searching the $(Get-WinGetSourceLabel $wg.Source) for '$query'..."
    $wg.C.GLstResults.ItemsSource = $null
    Start-StudioLookup -Engine $script:EngineWinGet -Name 'wgsearch' -OnDone 'Complete-WgSearch' -Context @{ Source = $wg.Source; Query = $query } -Arguments @{
        Query = $query; Source = $wg.Source } -Script 'param($Query, $Source) Search-WinGetCatalog -Query $Query -Source $Source -Limit 40'
}

function Complete-WgSearch {
    param($Result, $Failure, $Context)
    $wg = $script:Wg
    if (-not $wg -or $Context.Source -ne $wg.Source) { return }
    if ($Failure) { $wg.C.GTxtResults.Text = "The search failed: $(Format-RunError $Failure)"; return }
    $rows = @($Result | Where-Object { $_ } | ForEach-Object {
        [pscustomobject]@{
            Id = $_.Id; Name = $_.Name; Version = $_.Version; Source = $_.Source
            Detail = $(if ($_.Publisher -and $_.Kind) { "$($_.Publisher) · $($_.Kind)" } elseif ($_.Publisher) { $_.Publisher } else { $_.Kind })
        }
    })
    $wg.C.GLstResults.ItemsSource = $rows
    $wg.C.GTxtResults.Text = if ($rows.Count) { "$($rows.Count) found in the $(Get-WinGetSourceLabel $Context.Source). Pick one to see the details." }
                             else { "Nothing in the $(Get-WinGetSourceLabel $Context.Source) matches '$($Context.Query)'." }
}

function Start-WgDetail {
    param([Parameter(Mandatory)][string]$Id, [string]$Version)
    $wg = $script:Wg
    $wg.C.GTxtPlan.Text = "Reading the manifest of $Id..."
    $wg.C.GBtnCreate.IsEnabled = $false; $wg.C.GBtnCreatePublish.IsEnabled = $false
    Start-StudioLookup -Engine $script:EngineWinGet -Name 'wgdetail' -OnDone 'Complete-WgDetail' -Context @{ Source = $wg.Source; Id = $Id; Version = $Version } -Arguments @{
        Id = $Id; Source = $wg.Source; Version = $Version } -Script 'param($Id, $Source, $Version) Get-WinGetCatalogEntry -Id $Id -Source $Source -Version $Version'
}

function Complete-WgDetail {
    param($Result, $Failure, $Context)
    $wg = $script:Wg
    if (-not $wg -or $Context.Source -ne $wg.Source) { return }
    $c = $wg.C
    if ($Failure) {
        Clear-WgDetail
        $c.GTxtName.Text = $Context.Id
        $c.GPnlBlock.Visibility = 'Visible'
        $c.GTxtBlock.Text = Format-RunError $Failure
        return
    }
    $info = @($Result)[-1]
    $wg.Info = $info
    $c.GTxtName.Text = $info.Name
    $c.GTxtPublisher.Text = $info.Publisher
    $c.GTxtIdLine.Text = "$($info.Id) · $(Get-WinGetSourceLabel $info.Source)" +
        $(if ($info.Pricing) { " · $($info.Pricing)" } else { '' }) + $(if ($info.License -and "$($info.License)" -notmatch '^https?://') { " · $($info.License)" } else { '' })
    $c.GTxtDescription.Text = Format-WinGetDescription $info.Description
    $c.GImgIcon.Source = $null
    if ($info.IconUrl) {
        try {
            $bitmap = New-Object Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit(); $bitmap.UriSource = [Uri]$info.IconUrl; $bitmap.DecodePixelWidth = 112; $bitmap.EndInit()
            $c.GImgIcon.Source = $bitmap
        }
        catch { }
    }

    # The versions a community package can be pinned to, newest first; a Store app has only one
    $wg.Filling = $true
    try {
        $c.GCmbVersion.Items.Clear()
        if ($info.Source -eq 'winget' -and @($info.Versions).Count) {
            [void]$c.GCmbVersion.Items.Add('Latest: whatever is newest when a device installs it')
            foreach ($available in $info.Versions) { [void]$c.GCmbVersion.Items.Add($available) }
            $c.GCmbVersion.SelectedItem = if ($wg.Latest) { $c.GCmbVersion.Items[0] } else { $info.Version }
            $c.GPnlVersion.Visibility = 'Visible'
        }
        else { $c.GPnlVersion.Visibility = 'Collapsed' }
        $c.GPnlDelivery.Visibility = if ($info.Source -eq 'msstore') { 'Visible' } else { 'Collapsed' }
        if ($info.Source -eq 'msstore') {
            $c.GRbStoreApp.IsChecked = $wg.Delivery -eq 'store'
            $c.GRbWin32.IsChecked = $wg.Delivery -ne 'store'
        }
    }
    finally { $wg.Filling = $false }
    Update-WgPlan
}

# The plan is worked out on the spot from what is already known — only another version of a
# community package needs its own manifest, and that one is fetched.
function Update-WgPlan {
    $wg = $script:Wg
    if (-not $wg.Info) { return }
    $c = $wg.C
    $delivery = if ($wg.Info.Source -eq 'msstore' -and $wg.Delivery -eq 'store') { 'store' } else { 'win32' }
    $plan = New-WinGetInstallPlan -Info $wg.Info -Latest:$wg.Latest -Delivery $delivery -Policy $wg.Policy
    $wg.Plan = $plan
    $c.GTxtDelivery.Text = if ($delivery -eq 'store') {
        'Nothing to build or upload. Intune installs, detects and updates it itself, and it keeps working where the Microsoft Store app is blocked.'
    } else {
        'Packwright''s scripts run WinGet on the device: logs, retries and the detection rule are yours to see and test. WinGet''s command line refuses Store installs on devices where the Microsoft Store app is blocked.'
    }
    $lines = @()
    if ($delivery -eq 'store') {
        $lines += "Intune's Microsoft Store app type installs $($wg.Info.Name) $(if ($plan.RunAs -eq 'user') { 'for the signed-in user' } else { 'for every user on the device' })."
    }
    else {
        $command = "winget install --id $($plan.Id) --source $($plan.Source)" +
            $(if ($plan.Version) { " --version $($plan.Version)" } else { '' }) +
            $(if ($plan.Scope) { " --scope $($plan.Scope)" } else { '' }) +
            $(if ($plan.Architecture) { " --architecture $($plan.Architecture)" } else { '' }) +
            $(if ($plan.InstallerType) { " --installer-type $($plan.InstallerType)" } else { '' })
        $lines += "Runs $(if ($plan.RunAs -eq 'user') { 'as the signed-in user' } else { 'as SYSTEM' }): $command"
        if ($plan.DetectionText) { $lines += "Detection: $($plan.DetectionText)" }
        $lines += "Only on devices where WinGet $($script:WinGetMinimumVersion) or later is ready - " +
                  $(if ($wg.Policy.RuntimeLink -eq 'dependency') { "the '$($wg.Policy.RuntimeAppName)' app is installed first as a dependency." }
                    else { 'the WinGet runtime app sees to that.' })
    }
    $c.GTxtPlan.Text = $lines -join [Environment]::NewLine
    $c.GPnlBlock.Visibility = if ($plan.Blockers.Count) { 'Visible' } else { 'Collapsed' }
    $c.GTxtBlock.Text = ($plan.Blockers | ForEach-Object { [string][char]0x2715 + '  ' + $_ }) -join [Environment]::NewLine
    $c.GPnlWarn.Visibility = if ($plan.Warnings.Count) { 'Visible' } else { 'Collapsed' }
    $c.GTxtWarn.Text = ($plan.Warnings | ForEach-Object { [string][char]0x26A0 + '  ' + $_ }) -join [Environment]::NewLine
    $c.GTxtNotes.Text = ($plan.Notes | ForEach-Object { [string][char]0x2022 + '  ' + $_ }) -join [Environment]::NewLine
    $ok = -not $plan.Blockers.Count
    $c.GBtnCreate.IsEnabled = $ok
    $c.GBtnCreatePublish.IsEnabled = $ok
}

function Select-WgVersion {
    $wg = $script:Wg
    if ($wg.Filling -or -not $wg.Info) { return }
    $picked = "$($wg.C.GCmbVersion.SelectedItem)"
    if (-not $picked) { return }
    if ($picked -like 'Latest*') {
        $wg.Latest = $true
        # The plan for "latest" is made from the newest manifest
        if ($wg.Info.Version -ne @($wg.Info.Versions)[0]) { Start-WgDetail -Id $wg.Info.Id -Version @($wg.Info.Versions)[0]; return }
        Update-WgPlan
        return
    }
    $wg.Latest = $false
    if ($picked -eq $wg.Info.Version) { Update-WgPlan; return }
    Start-WgDetail -Id $wg.Info.Id -Version $picked
}

function Start-WgCreate {
    param([bool]$Publish)
    $wg = $script:Wg
    if (-not $wg.Plan -or $wg.Plan.Blockers.Count) { return }
    $c = $wg.C
    foreach ($button in $c.GBtnCreate, $c.GBtnCreatePublish, $c.GBtnSearch) { $button.IsEnabled = $false }
    $c.GTxtPlan.Text = "Writing the package for $($wg.Info.Name)..."
    $root = Get-StudioPackageRoot
    $folderName = Get-WinGetFolderName -Plan $wg.Plan
    $target = Join-Path $root $folderName
    $force = $false
    if ((Test-Path -LiteralPath $target) -and @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue).Count) {
        $answer = [Windows.MessageBox]::Show(
            "The folder already exists and is not empty:`n$target`n`nWrite the package into it anyway? Files with the same names are overwritten.",
            'New package from WinGet', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { Update-WgPlan; $c.GBtnSearch.IsEnabled = $true; return }
        $force = $true
    }
    Start-StudioLookup -Engine $script:EngineWinGet -Name 'wgcreate' -OnDone 'Complete-WgCreate' -OnProgress 'Show-WgCreateProgress' -Context @{ Publish = $Publish } -Arguments @{
        Info = $wg.Info; Latest = [bool]$wg.Latest; Delivery = $wg.Plan.Delivery; Root = $root; Folder = $folderName; Force = $force
    } -Script ('param($Info, $Latest, $Delivery, $Root, $Folder, $Force) ' +
               'New-WinGetPackage -Id $Info.Id -Source $Info.Source -Version $Info.Version -Latest:$Latest -Delivery $Delivery ' +
               '-PackageRoot $Root -FolderName $Folder -Info $Info -Force:$Force')
}

# The installer being downloaded for its icon, which can take a while for a large one
function Show-WgCreateProgress {
    param($Record, $Context)
    $wg = $script:Wg
    if (-not $wg -or $Record.RecordType -eq 'Completed' -or -not $Record.StatusDescription) { return }
    $wg.C.GTxtPlan.Text = "Writing the package for $($wg.Info.Name)...`n$($Record.Activity): $($Record.StatusDescription)"
}

function Complete-WgCreate {
    param($Result, $Failure, $Context)
    $wg = $script:Wg
    if (-not $wg) { return }
    $wg.C.GBtnSearch.IsEnabled = $true
    if ($Failure) {
        Update-WgPlan
        [Windows.MessageBox]::Show("Could not create the package:`n$(Format-RunError $Failure)", 'New package from WinGet', 'OK', 'Error') | Out-Null
        return
    }
    $created = @($Result)[-1]
    Set-StudioSetting -Name 'PackageRoot' -Value (Split-Path -Parent $created.Folder)
    $wg.Result = @{ Folder = $created.Folder; Setup = $created.Setup; Publish = [bool]$Context.Publish; Warnings = @($created.Plan.Warnings); Icon = $created.Icon }
    $wg.Window.DialogResult = $true
}

# A WinGet package's own icon, found the way a new one gets it: the catalog, the app installed on
# this computer, the installer. That last one is a download, so it runs in the background.
function Start-WinGetIconLookup {
    $block = $script:WinGetBlock
    if (-not $block) { return }
    $ui.BtnIconAuto.IsEnabled = $false
    Set-StatusText "Looking for the icon of $($block['id'])..."
    Start-StudioLookup -Engine $script:EngineWinGet -Name 'wgicon' -OnDone 'Complete-WinGetIconLookup' -OnProgress 'Show-WinGetIconProgress' -Context @{ Folder = $script:LoadedFolder } -Arguments @{
        Id = "$($block['id'])"; Source = "$($block['source'])"; Version = "$($block['version'])"; Delivery = "$($block['delivery'])"; Folder = $script:LoadedFolder
    } -Script ('param($Id, $Source, $Version, $Delivery, $Folder) ' +
               '$info = Get-WinGetCatalogEntry -Id $Id -Source $Source -Version $Version; ' +
               '$plan = New-WinGetInstallPlan -Info $info -Latest:(-not $Version) -Delivery $(if ($Delivery) { $Delivery } else { ''win32'' }); ' +
               'Save-WinGetPackageIcon -Info $info -Plan $plan -Folder $Folder')
}

function Show-WinGetIconProgress {
    param($Record, $Context)
    if ($Context.Folder -ne $script:LoadedFolder -or $Record.RecordType -eq 'Completed' -or -not $Record.StatusDescription) { return }
    Set-StatusText "$($Record.Activity): $($Record.StatusDescription)"
}

function Complete-WinGetIconLookup {
    param($Result, $Failure, $Context)
    $ui.BtnIconAuto.IsEnabled = $true
    if ($Context.Folder -ne $script:LoadedFolder) { return }
    if ($Failure) {
        Write-GuiLog "WARNING: The app's icon could not be looked for: $(Format-RunError $Failure)"
        Set-StatusText 'No icon found - see the log.'
        return
    }
    $found = @($Result)[-1]
    if (-not $found.File) {
        Write-GuiLog "No icon found for $($script:WinGetBlock['id']): $($found.From). Choose an image instead."
        Set-StatusText 'No icon found - choose an image instead.'
        return
    }
    Set-IconPreview -Path (Join-Path $script:LoadedFolder $found.File) -Note "icon.png — $($found.Size)x$($found.Size), taken from $($found.From)"
    Write-GuiLog "Icon taken from $($found.From) ($($found.Size)x$($found.Size)) to icon.png"
    if ($found.Size -lt 64) { Write-GuiLog 'Only a small icon was available; a larger png looks sharper in the Company Portal.' }
    try { Save-AppManifest | Out-Null } catch { Write-GuiLog "ERROR: $($_.Exception.Message)" }
    Set-StatusText 'Icon taken.'
    Update-Readiness | Out-Null
}

function Show-WinGetDialog {
    $policy = Get-PackwrightPolicy
    foreach ($problem in $policy.Problems) { Write-GuiLog "WARNING: $problem" }
    if (-not $policy.AllowedSources.Count) {
        [Windows.MessageBox]::Show(("Packwright.policy.json allows no WinGet source, so there is nothing to package from.`n`n" + ($policy.Problems -join "`n")),
            'New package from WinGet', 'OK', 'Warning') | Out-Null
        return
    }
    $dialog = New-StudioWindow -Xaml $script:WinGetXaml
    if ($window.IsVisible) { $dialog.Window.Owner = $window }
    $script:Wg = @{
        Window = $dialog.Window; C = $dialog.C; Policy = $policy; Source = $policy.DefaultSource
        Info = $null; Plan = $null; Latest = $false; Delivery = $policy.StoreDelivery; Filling = $false; Result = $null
    }
    $c = $dialog.C
    foreach ($pair in @(@{ Box = $c.GRbStore; Source = 'msstore' }, @{ Box = $c.GRbCommunity; Source = 'winget' })) {
        $refusal = Get-WinGetSourceRefusal -Source $pair.Source -Policy $policy
        $pair.Box.IsEnabled = -not $refusal
        if ($refusal) { $pair.Box.ToolTip = $refusal }
    }
    $c.GRbStore.IsChecked = $policy.DefaultSource -eq 'msstore'
    $c.GRbCommunity.IsChecked = $policy.DefaultSource -eq 'winget'
    Set-WgSource -Source $policy.DefaultSource
    $c.GTxtFolder.Text = "Packages are created in $(Get-StudioPackageRoot)"

    $c.GRbStore.Add_Checked({ Set-WgSource -Source 'msstore' })
    $c.GRbCommunity.Add_Checked({ Set-WgSource -Source 'winget' })
    $c.GBtnSearch.Add_Click({ Start-WgSearch })
    $c.GLstResults.Add_SelectionChanged({
        $picked = $script:Wg.C.GLstResults.SelectedItem
        if ($picked) { $script:Wg.Latest = $false; Start-WgDetail -Id $picked.Id }
    })
    $c.GCmbVersion.Add_SelectionChanged({ Select-WgVersion })
    $c.GRbWin32.Add_Checked({ if (-not $script:Wg.Filling) { $script:Wg.Delivery = 'win32'; Update-WgPlan } })
    $c.GRbStoreApp.Add_Checked({ if (-not $script:Wg.Filling) { $script:Wg.Delivery = 'store'; Update-WgPlan } })
    $c.GBtnCreate.Add_Click({ Start-WgCreate -Publish $false })
    $c.GBtnCreatePublish.Add_Click({ Start-WgCreate -Publish $true })
    $c.GBtnRuntime.Add_Click({ $script:Wg.Result = @{ Runtime = $true }; $script:Wg.Window.DialogResult = $true })
    $c.GBtnCancel.Add_Click({ $script:Wg.Window.DialogResult = $false })
    $dialog.Window.Add_Loaded({ $script:Wg.C.GTxtQuery.Focus() })

    [void]$dialog.Window.ShowDialog()
    $result = $script:Wg.Result
    $script:Wg = $null
    if (-not $result) { return }
    if ($result.Runtime) { Start-WinGetRuntimeBuild; return }
    Write-GuiLog "WinGet package created: $($result.Folder)"
    foreach ($warning in $result.Warnings) { Write-GuiLog "WARNING: $warning" }
    if ($result.Icon) {
        Write-GuiLog $(if ($result.Icon.File) { "Icon taken from $($result.Icon.From) ($($result.Icon.Size)x$($result.Icon.Size))." }
                       else { "No icon found: $($result.Icon.From). Choose an image under Logo." })
    }
    if (Open-PackageFolder -Folder $result.Folder -PreferSetup $result.Setup) {
        if ($result.Publish) { Start-EngineRun -Publish $true }
    }
}
#endregion

#region ---- What the start screen and Settings say about WinGet --------------------
# "Install it with WinGet" on the start screen, as Packwright.policy.json has it
function Get-WinGetStartText {
    $policy = Get-PackwrightPolicy
    if (-not $policy.AllowedSources.Count) {
        'Packwright.policy.json allows no WinGet source here, so there is nothing to pick from until it is fixed.'
    } elseif ($policy.Restricted) {
        "Pick an app from the $(($policy.AllowedSources | ForEach-Object { Get-WinGetSourceLabel $_ }) -join ' and ') - the source your organisation allows. No installer to provide: each device installs it with WinGet."
    } else {
        'Pick an app from the Microsoft Store or the WinGet repository. No installer to provide: each device installs it with WinGet, and the detection rule is written from the app''s manifest.'
    }
}

# What Packwright.policy.json says, for the Settings dialog. Not a setting anyone changes here:
# the policy belongs to the organisation and travels with the scripts.
function Get-WinGetPolicySummary {
    $policy = Get-PackwrightPolicy
    $sources = if ($policy.AllowedSources.Count) { ($policy.AllowedSources | ForEach-Object { Get-WinGetSourceLabel $_ }) -join ' and ' } else { 'no source at all' }
    $origin = if ($policy.Exists) { "as set in $($policy.Path)" } else { 'both, because there is no Packwright.policy.json next to the scripts' }
    $delivery = if ($policy.StoreDelivery -eq 'store') { "Intune's own Store app type" } else { 'Win32 apps that run WinGet' }
    $link = if ($policy.RuntimeLink -eq 'dependency') { "a dependency on '$($policy.RuntimeAppName)'" } else { 'a requirement rule' }
    $market = "$(Format-StoreMarket $policy.StoreMarket) market (" +
              $(if ($policy.StoreMarketFrom -eq 'policy') { 'set by the policy' } else { "this computer's country or region in Windows" }) + ')'
    "Packages may come from the $sources, $origin. Store apps are looked up in the $market and are delivered as $delivery " +
        "unless you pick otherwise; each WinGet app waits for the WinGet runtime through $link." +
        $(if ($policy.Problems) { ' ' + ($policy.Problems -join ' ') } else { '' })
}
#endregion

#region ---- WinGet in the editor -------------------------------------------------
# A package New-WinGetPackage wrote carries a winget block in app.json, and everything about how
# it installs is written from that block: the commands, the scripts and the detection rule. The
# editor shows it as one card and keeps those in step when the block changes. The block itself,
# and what the rest of the studio asks of it (Test-WinGetPackage, Test-WinGetStoreApp), stay in
# Packwright.ps1: opening a package reads it, before anything here has been read.

# Shows or hides what an Intune Store app does not have: there is nothing to build, no command,
# and Intune detects the app itself
function Set-EditorMode {
    $store = Test-WinGetStoreApp
    $visible = if ($store) { 'Collapsed' } else { 'Visible' }
    foreach ($panel in 'PnlDetectionCard', 'PnlCommands', 'PnlSetupFile', 'PnlRestart', 'PnlArchOs') { $ui[$panel].Visibility = $visible }
    $ui.BtnBuild.Visibility = $visible
    $ui.BtnTest.Visibility = $visible
    $ui.ExpAdvanced.Header = if ($store) { 'Advanced: run-as, and what to do if the app already exists' } else { 'Advanced: commands, run-as, restart, architecture' }
}

$script:DetHintDefault = $null
function Update-WinGetCard {
    $block = $script:WinGetBlock
    $ui.PnlWinGet.Visibility = if ($block) { 'Visible' } else { 'Collapsed' }
    Set-EditorMode
    if ($null -eq $script:DetHintDefault) { $script:DetHintDefault = $ui.TxtDetHint.Text }
    $ui.TxtDetHint.Text = if ($block) {
        'Written from the app''s manifest. "Test on this computer" shows whether it finds the app - and offers a rule written from what the install added if it does not.'
    } else { $script:DetHintDefault }
    if (-not $block) { return }
    $source = "$($block['source'])"
    $store = Test-WinGetStoreApp
    $ui.WgTxtBadge.Text = Get-WinGetSourceLabel $source
    $ui.WgTxtIdLine.Text = "$($block['id'])" + $(if ($block['packageName']) { " · $($block['packageName'])" } else { '' })
    $runs = if ((Get-ComboValue $ui.CmbRunAs) -eq 'user') { 'as the signed-in user, for that user only' } else { 'as SYSTEM, for every user on the device' }
    $ui.WgTxtSummary.Text = if ($store) {
        "Delivered as an Intune Store app: Intune installs it, detects it and keeps it up to date itself. Nothing is built or uploaded."
    } elseif ($block['version']) {
        "Intune runs WinGet on each device $runs, and installs version $($block['version']) from the $(Get-WinGetSourceLabel $source)."
    } else {
        "Intune runs WinGet on each device $runs, and installs whatever version the $(Get-WinGetSourceLabel $source) has that day."
    }
    $ui.WgPnlVersion.Visibility = if ($source -eq 'winget' -and -not $store) { 'Visible' } else { 'Collapsed' }
    Update-WinGetVersionNote
    $attention = @($script:WinGetScripts | Where-Object { $_.State -ne 'current' })
    $ui.WgBtnRefresh.Visibility = if ($attention.Count) { 'Visible' } else { 'Collapsed' }
    $ui.WgPnlRuntime.Visibility = if ($store) { 'Collapsed' } else { 'Visible' }
    $policy = Get-PackwrightPolicy
    $ui.WgTxtRuntime.Text = if ($policy.RuntimeLink -eq 'dependency') {
        "Devices need WinGet $($script:WinGetMinimumVersion) or later. Publishing makes this app depend on '$($policy.RuntimeAppName)', which Intune then installs first - publish that once before this one."
    } else {
        "Devices need WinGet $($script:WinGetMinimumVersion) or later. A requirement rule keeps this app waiting until they have it; the WinGet runtime package provides it. Publish that once and assign it to all devices."
    }
}

function Update-WinGetVersionNote {
    $block = $script:WinGetBlock
    if (-not $block) { return }
    $note = ''
    if ("$($block['source'])" -eq 'winget' -and -not (Test-WinGetStoreApp)) {
        $versions = @($script:WinGetVersions)
        if ($null -eq $script:WinGetVersions) { $note = 'Looking up the versions in the repository...' }
        elseif (-not $versions.Count) { $note = 'The repository could not be asked for its versions.' }
        elseif ($block['version']) {
            if ($versions -notcontains $block['version']) { $note = "Version $($block['version']) is no longer in the repository, so new devices cannot install it. Pick a version that is there." }
            elseif ($versions[0] -ne $block['version']) { $note = "Version $($versions[0]) is in the repository; this package installs $($block['version'])." }
            else { $note = "$($block['version']) is the newest version in the repository." }
        }
        else { $note = "Not pinned: devices get the newest version ($($versions[0]) today) when they install, and Intune does not upgrade it after that." }
    }
    $ui.WgTxtVersionNote.Text = $note
    $ui.WgTxtVersionNote.Visibility = if ($note) { 'Visible' } else { 'Collapsed' }
}

function Start-WinGetVersionLookup {
    $block = $script:WinGetBlock
    $script:WinGetVersions = $null
    $ui.WgCmbVersion.Items.Clear()
    if (-not $block -or "$($block['source'])" -ne 'winget' -or (Test-WinGetStoreApp)) { return }
    # The self-test runs offline, and its packages are made up
    if ($TestLoad -or -not (Find-LocalWinGet)) { $script:WinGetVersions = @(); Update-WinGetVersionNote; return }
    Start-StudioLookup -Engine $script:EngineWinGet -Name 'wgversions' -OnDone 'Complete-WinGetVersionLookup' -Context @{ Folder = $script:LoadedFolder } `
        -Arguments @{ Id = "$($block['id'])" } -Script 'param($Id) Get-CommunityCatalogVersion -Id $Id'
}

function Complete-WinGetVersionLookup {
    param($Result, $Failure, $Context)
    if ($Context.Folder -ne $script:LoadedFolder -or -not $script:WinGetBlock) { return }
    $script:WinGetVersions = if ($Failure) { @() } else { @($Result | Where-Object { $_ }) }
    if ($Failure) { Write-GuiLog "WARNING: The WinGet repository could not be asked for the versions of $($script:WinGetBlock['id']): $(Format-RunError $Failure)" }
    $ui.WgCmbVersion.Items.Clear()
    if ($script:WinGetVersions.Count) {
        [void]$ui.WgCmbVersion.Items.Add('Latest: whatever is newest when a device installs it')
        foreach ($available in $script:WinGetVersions) { [void]$ui.WgCmbVersion.Items.Add($available) }
        $ui.WgCmbVersion.SelectedItem = if ($script:WinGetBlock['version']) { $script:WinGetBlock['version'] } else { $ui.WgCmbVersion.Items[0] }
    }
    Update-WinGetVersionNote
    Update-Readiness | Out-Null
}

# Another version (or "latest"): read that version's manifest, plan it again, and carry the
# result into everything the block decides - commands, scripts, detection, the version label.
function Start-WinGetReplan {
    $block = $script:WinGetBlock
    $picked = "$($ui.WgCmbVersion.SelectedItem)"
    if (-not $block -or -not $picked) { return }
    $latest = $picked -like 'Latest*'
    $version = if ($latest) { '' } else { $picked }
    if (-not $latest -and $version -eq "$($block['version'])") { Set-StatusText "The package already installs $version."; return }
    if ($latest -and -not "$($block['version'])") { Set-StatusText 'The package already installs the latest version.'; return }
    Set-StatusText "Reading the manifest of $($block['id']) $(if ($version) { $version } else { '(newest)' })..."
    $ui.WgBtnVersion.IsEnabled = $false
    Start-StudioLookup -Engine $script:EngineWinGet -Name 'wgreplan' -OnDone 'Complete-WinGetReplan' -Context @{ Folder = $script:LoadedFolder; Latest = $latest } -Arguments @{
        Id = "$($block['id'])"; Version = $version; Latest = $latest; Delivery = "$($block['delivery'])"
    } -Script ('param($Id, $Version, $Latest, $Delivery) $info = Get-WinGetCatalogEntry -Id $Id -Source winget -Version $Version; ' +
               '[pscustomobject]@{ Info = $info; Plan = (New-WinGetInstallPlan -Info $info -Latest:$Latest -Delivery $Delivery) }')
}

function Complete-WinGetReplan {
    param($Result, $Failure, $Context)
    $ui.WgBtnVersion.IsEnabled = $true
    if ($Context.Folder -ne $script:LoadedFolder -or -not $script:WinGetBlock) { return }
    if ($Failure) { Write-GuiLog "ERROR: $(Format-RunError $Failure)"; Set-StatusText (Format-RunError $Failure); return }
    $answer = @($Result)[-1]
    if ($answer.Plan.Blockers.Count) { Write-GuiLog "ERROR: $($answer.Plan.Blockers -join ' ')"; Set-StatusText 'That version cannot be packaged - see the log.'; return }
    Set-WinGetPlan -Plan $answer.Plan -Info $answer.Info
    foreach ($warning in $answer.Plan.Warnings) { Write-GuiLog "WARNING: $warning" }
}

# Carry a plan into the editor and the package folder, and save, so app.json, the scripts and
# the screen never disagree about what this package installs
function Set-WinGetPlan {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Info)
    $block = $script:WinGetBlock
    $previous = "$($block['version'])"
    $block['version'] = $Plan.Version; $block['scope'] = $Plan.Scope; $block['architecture'] = $Plan.Architecture; $block['installerType'] = $Plan.InstallerType
    $block['packageFamilyName'] = $Plan.PackageFamilyName
    $block['productCode'] = if ($Plan.Detect -and $Plan.Detect.kind -eq 'appx') { '' } else { $Plan.ProductCode }
    $block['detect'] = if ($Plan.Detect) { ConvertTo-StudioHashtable $Plan.Detect } else { $null }
    $block['runner'] = $script:WinGetRunnerVersion

    $script:Loading = $true
    try {
        $commands = Get-WinGetCommandLine -WinGet $block
        $ui.TxtInstall.Text = $commands.Install
        $ui.TxtUninstall.Text = $commands.Uninstall
        $script:DerivedInstall = $commands.Install
        $script:DerivedUninstall = $commands.Uninstall
        Set-ComboValue $ui.CmbRunAs $Plan.RunAs
        Set-ComboValue $ui.CmbArch $Plan.IntuneArchitecture
        $ui.TxtVersion.Text = $Plan.Label
        $ui.TagVersion.Text = 'from WinGet'
        if ($script:InitialValues) { $script:InitialValues.Version = $Plan.Label; $script:InitialValues.VersionTag = 'from WinGet' }
        Set-StudioDetection -Detection $Plan.Detection
    }
    finally { $script:Loading = $false }
    Set-DetValueTracking
    try {
        [void](Write-WinGetScripts -Folder $script:LoadedFolder -WinGet $block)
        Save-AppManifest | Out-Null
    }
    catch { Write-GuiLog "ERROR: $($_.Exception.Message)" }
    Write-GuiLog ("WinGet: {0} now installs {1}. Commands, scripts and the detection rule were written for it and saved." -f
        $block['id'], $(if ($Plan.Version) { "version $($Plan.Version)" } else { 'the newest version' }) + $(if ($previous -and $previous -ne $Plan.Version) { " (was $previous)" } else { '' }))
    # Another version of an app that was published before is an update of that app, not a
    # second one beside it - which is what publishing would otherwise stop at
    if ($previous -ne $Plan.Version -and -not $ui.ChkUpdateExisting.IsChecked) {
        $ui.ChkUpdateExisting.IsChecked = $true
        $ui.ChkAllowDuplicate.IsChecked = $false
        Write-GuiLog 'Publishing will update the app Intune already has with this version (assignments are kept) - see Advanced.'
    }
    Update-WinGetScriptState
    Update-DetectionUi
    Update-PreviewCard
    Update-WinGetCard
    Update-Readiness | Out-Null
}

# What the WinGet settings give for the commands, so changing the setup file never "re-derives"
# them, and the hint under the commands - for a WinGet package and for the runtime package
function Set-WinGetDerivedCommand {
    if ($script:WinGetBlock -and "$($script:WinGetBlock['delivery'])" -ne 'store') {
        $wingetCommands = Get-WinGetCommandLine -WinGet $script:WinGetBlock
        $script:DerivedInstall   = $wingetCommands.Install
        $script:DerivedUninstall = $wingetCommands.Uninstall
        $ui.TxtCmdHint.Text = 'Written from the WinGet settings: the source and the id are on the command line, so the Intune portal shows where the app comes from.'
    }
    elseif ($script:WinGetRuntimeBlock) {
        $ui.TxtCmdHint.Text = 'The WinGet runtime package: it installs App Installer and the Visual C++ runtime where they are missing or older.'
    }
}

# What the log calls the package just opened
function Get-WinGetPackageKind {
    if (Test-WinGetStoreApp) { "Intune Store app — $($script:WinGetBlock['id']) from the Microsoft Store" }
    elseif (Test-WinGetPackage) { "WinGet package — $($script:WinGetBlock['id']) from the $(Get-WinGetSourceLabel "$($script:WinGetBlock['source'])")" }
    elseif (Test-WinGetRuntimePackage) { "WinGet runtime package — App Installer $($script:WinGetRuntimeBlock['appInstaller'])" }
}

function Update-WinGetScriptState {
    $script:WinGetScripts = @()
    if ((Test-WinGetPackage) -or (Test-WinGetRuntimePackage)) {
        try { $script:WinGetScripts = @(Get-WinGetScriptState -Folder $script:LoadedFolder) } catch { }
    }
}

# The commands app.json would have if nobody had touched them
function Get-WinGetCommandMismatch {
    if (-not (Test-WinGetPackage) -or (Test-WinGetStoreApp)) { return @() }
    $expected = Get-WinGetCommandLine -WinGet $script:WinGetBlock
    @(foreach ($pair in @(@{ Name = 'install'; Box = $ui.TxtInstall; Expected = $expected.Install },
                         @{ Name = 'uninstall'; Box = $ui.TxtUninstall; Expected = $expected.Uninstall })) {
        if (($pair.Box.Text -replace '\s+', ' ').Trim() -ne ($pair.Expected -replace '\s+', ' ').Trim()) { $pair.Name }
    })
}

# What stops a WinGet package from being published: a source the organisation does not allow,
# scripts that are missing, and - where the organisation restricts its sources - scripts or
# commands changed by hand, since those decide where the app is really installed from.
function Get-WinGetBlocker {
    if (-not (Test-WinGetPackage)) { return @() }
    $policy = Get-PackwrightPolicy
    $blockers = @()
    $refusal = Get-WinGetSourceRefusal -Source "$($script:WinGetBlock['source'])" -Policy $policy
    if ($refusal) { $blockers += $refusal }
    foreach ($state in $script:WinGetScripts) {
        if ($state.State -eq 'missing') { $blockers += "$($state.Detail) Refresh the scripts." }
        elseif ($state.State -eq 'edited' -and $policy.Restricted) {
            $blockers += "$($state.Detail) Your organisation restricts the WinGet sources, so only Packwright's own scripts are published. Refresh the scripts."
        }
    }
    if ($policy.Restricted) {
        foreach ($name in (Get-WinGetCommandMismatch)) {
            $blockers += "The $name command was changed by hand. Your organisation restricts the WinGet sources, so only the commands Packwright writes are published."
        }
    }
    $blockers
}

function Get-WinGetWarning {
    if (Test-WinGetRuntimePackage) {
        # The runtime package's scripts are written from runtime.json; an older or edited one is
        # worth building again rather than repairing here
        return @($script:WinGetScripts | Where-Object { $_.State -ne 'current' } | ForEach-Object {
            "$($_.Detail) Build the WinGet runtime package again to get current scripts." })
    }
    if (-not (Test-WinGetPackage)) { return @() }
    $policy = Get-PackwrightPolicy
    $warnings = @()
    foreach ($state in $script:WinGetScripts) {
        if ($state.State -eq 'outdated') { $warnings += "$($state.Detail) Refresh the scripts to get the current ones." }
        elseif ($state.State -eq 'edited' -and -not $policy.Restricted) { $warnings += "$($state.Detail) Refresh the scripts to undo that." }
    }
    if (-not $policy.Restricted) {
        foreach ($name in (Get-WinGetCommandMismatch)) { $warnings += "The $name command was changed by hand, so it no longer says exactly what the WinGet settings say." }
    }
    $block = $script:WinGetBlock
    $versions = @($script:WinGetVersions)
    if ($block['version'] -and $null -ne $script:WinGetVersions -and $versions.Count) {
        if ($versions -notcontains $block['version']) { $warnings += "Version $($block['version']) is no longer in the WinGet repository: new devices cannot install it." }
        elseif ($versions[0] -ne $block['version']) { $warnings += "WinGet has version $($versions[0]); this package installs $($block['version'])." }
    }
    if ("$($block['source'])" -eq 'msstore' -and -not (Test-WinGetStoreApp) -and (Test-StoreBlockedHere)) {
        $warnings += "The Microsoft Store app is turned off by policy on this computer. If the devices are the same, WinGet refuses Store installs there - publish the app as an Intune Store app instead."
    }
    $warnings
}
#endregion

#region ---- WinGet runtime package -----------------------------------------------
function Start-WinGetRuntimeBuild {
    if (Test-StudioLookupRunning -Name 'wgruntime') { Set-StatusText 'The WinGet runtime package is already being built.'; return }
    $answer = [Windows.MessageBox]::Show(
        ("The WinGet runtime package makes WinGet usable for SYSTEM on every device: App Installer from the latest winget-cli release on GitHub, " +
         "with its framework packages, and the Visual C++ runtime from Microsoft.`n`nAbout 330 MB is downloaded and checked here (SHA-256 and Microsoft's " +
         "signature), then the package opens in the studio. Publish it once and assign it to all devices.`n`nBuild it now?"),
        'WinGet runtime package', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    Write-GuiLog '==== WinGet runtime package ===='
    Set-StatusText 'Downloading App Installer and the Visual C++ runtime...'
    $ui.Prog.Visibility = 'Visible'; $ui.Prog.IsIndeterminate = $true
    $ui.ExpLog.IsExpanded = $true
    Start-StudioLookup -Engine $script:EngineWinGet -Name 'wgruntime' -OnDone 'Complete-WinGetRuntimeBuild' -OnProgress 'Show-WinGetRuntimeProgress' -Arguments @{
        Root = Get-StudioPackageRoot } -Script 'param($Root) New-WinGetRuntimePackage -PackageRoot $Root -Force'
}

function Show-WinGetRuntimeProgress {
    param($Record, $Context)
    if ("$($Record.StatusDescription)".Trim()) { Set-StatusText "WinGet runtime package: $($Record.StatusDescription)" }
}

function Complete-WinGetRuntimeBuild {
    param($Result, $Failure, $Context)
    $ui.Prog.Visibility = if ($script:RunPS) { 'Visible' } else { 'Collapsed' }
    $ui.Prog.IsIndeterminate = $false
    if ($Failure) {
        Write-GuiLog "ERROR: $(Format-RunError $Failure)"
        Set-StatusText 'The WinGet runtime package could not be built - see the log.'
        return
    }
    $created = @($Result)[-1]
    Write-GuiLog "WinGet runtime package: App Installer $($created.AppInstaller) from $($created.Release), in $($created.Folder)"
    if (Open-PackageFolder -Folder $created.Folder -PreferSetup $created.Setup) {
        Set-StatusText 'WinGet runtime package ready. Publish it, then assign it to all devices in the Intune portal.'
    }
}
#endregion

#region ---- Self-test --------------------------------------------------------------
# Run by .\Packwright.ps1 -TestLoad once it has read this file, with the suite's own tools:
# Assert-Test, Invoke-PublishProbe and the scaffolded package are Packwright.ps1's. A function
# rather than more of the suite's top level, so its variables are its own: up there, a test's
# $iconWork was the engine's $script:IconWork - names differ in case only - and broke it.
function Invoke-WinGetSelfTest {
    param([Parameter(Mandatory)][string]$TestRoot, [Parameter(Mandatory)][string]$Scaffolded)

    # --- WinGet: organisation policy -----------------------------------------------
    # Packwright.policy.json decides which sources may be used at all. Missing, it allows both;
    # broken, it allows nothing - "msstore only" with a stray comma did not mean "everything".
    $wgRoot = Join-Path $testRoot 'winget'
    $null = New-Item -ItemType Directory -Path $wgRoot -Force
    $openPolicy = Get-PackwrightPolicy -Path (Join-Path $wgRoot 'no-such-policy.json')
    Assert-Test 'Without a policy file both WinGet sources are allowed' (
        -not $openPolicy.Restricted -and $openPolicy.AllowedSources.Count -eq 2) ($openPolicy.AllowedSources -join ', ')
    $storeOnlyPath = Join-Path $wgRoot 'storeonly.policy.json'
    '{ "winget": { "allowedSources": [ "msstore" ], "runtimeAppName": "Self Test Runtime" } }' | Set-Content -LiteralPath $storeOnlyPath -Encoding UTF8
    $storeOnly = Get-PackwrightPolicy -Path $storeOnlyPath
    Assert-Test 'A Store-only policy allows the Store and nothing else' (
        $storeOnly.Restricted -and ($storeOnly.AllowedSources -join ',') -eq 'msstore' -and $storeOnly.RuntimeAppName -eq 'Self Test Runtime') `
        ($storeOnly.AllowedSources -join ', ')
    $refusal = Get-WinGetSourceRefusal -Source 'winget' -Policy $storeOnly
    Assert-Test 'The community repository is refused, naming the policy file' ($refusal -match 'Microsoft Store only' -and $refusal -match 'storeonly\.policy\.json') $refusal
    Assert-Test 'The Store is not refused' ($null -eq (Get-WinGetSourceRefusal -Source 'msstore' -Policy $storeOnly))
    $brokenPath = Join-Path $wgRoot 'broken.policy.json'
    '{ "winget": { "allowedSources": [ "msstore" ], }' | Set-Content -LiteralPath $brokenPath -Encoding UTF8
    $broken = Get-PackwrightPolicy -Path $brokenPath
    Assert-Test 'A policy file that cannot be read allows nothing' (
        $broken.AllowedSources.Count -eq 0 -and $broken.Problems.Count -and (Get-WinGetSourceRefusal -Source 'msstore' -Policy $broken)) ($broken.Problems -join ' ')
    $oddPath = Join-Path $wgRoot 'odd.policy.json'
    '{ "winget": { "allowedSources": [ "msstore", "chocolatey" ] } }' | Set-Content -LiteralPath $oddPath -Encoding UTF8
    $odd = Get-PackwrightPolicy -Path $oddPath
    Assert-Test 'An unknown source in the policy is named, not quietly allowed' (
        ($odd.AllowedSources -join ',') -eq 'msstore' -and ($odd.Problems -join ' ') -match 'chocolatey') ($odd.Problems -join ' ')
    $casedPath = Join-Path $wgRoot 'cased.policy.json'
    '{ "WinGet": { "AllowedSources": [ "MSStore" ], "StoreMarket": "de", "_note": "a comment" } }' | Set-Content -LiteralPath $casedPath -Encoding UTF8
    $cased = Get-PackwrightPolicy -Path $casedPath
    Assert-Test 'Policy keys are read whatever their case, and _ keys are comments' (
        ($cased.AllowedSources -join ',') -eq 'msstore' -and $cased.Restricted -and $cased.StoreMarket -eq 'DE' -and
        $cased.StoreMarketFrom -eq 'policy' -and -not $cased.Problems.Count) "$($cased.AllowedSources -join ',') $($cased.StoreMarket) $($cased.Problems -join ' ')"
    $silentPath = Join-Path $wgRoot 'silent.policy.json'
    '{ "winget": { "allowedSource": [ "msstore" ] } }' | Set-Content -LiteralPath $silentPath -Encoding UTF8
    $silent = Get-PackwrightPolicy -Path $silentPath
    Assert-Test 'A policy that does not name its sources - here misspelled - allows nothing, and says why' (
        $silent.AllowedSources.Count -eq 0 -and ($silent.Problems -join ' ') -match 'allowedSource"' -and
        ($silent.Problems -join ' ') -match 'does not say which sources') ($silent.Problems -join ' | ')
    Assert-Test "Without a policy, Store apps are looked up in this computer's own country or region" (
        $openPolicy.StoreMarketFrom -eq 'windows' -and $openPolicy.StoreMarket -cmatch '^[A-Z]{2}$') $openPolicy.StoreMarket

    # --- WinGet: reading manifests ------------------------------------------------
    # winget's cached manifests are the only place the per-installer scope and product code can
    # be read without installing anything. Compact sequences under a key, "- key: value" items,
    # a root key after a list, escapes and block scalars are what its YAML writer produces.
    $yaml = @"
# Created by a tool
PackageIdentifier: Contoso.Tool
PackageVersion: 2.1.0
PackageName: Contoso Tool
Copyright: "Copyright \xA9 Contoso \"Tools\""
ReleaseNotes: '- It''s better.'
Description: |-
  First line
  Second line
Tags: [one, "two, three"]
ShortDescription: 'First part
  second part

  and it''s a new paragraph' # a comment
Moniker: "a\x41b
  c \
  d"
Installers:
- Architecture: x64
  InstallModes:
  - silent
  - interactive
  InstallerSwitches:
    Silent: /S
  ProductCode: '{11111111-2222-3333-4444-555555555555}'
  AppsAndFeaturesEntries:
  - DisplayName: Contoso Tool
    DisplayVersion: 2.1.0
- Architecture: x86
  InstallerType: wix
Scope: machine
InstallerType: exe
ManifestType: merged
"@
    $parsed = ConvertFrom-WinGetManifestYaml -Text $yaml
    Assert-Test 'Manifest YAML: plain, quoted and escaped values' (
        $parsed['PackageIdentifier'] -eq 'Contoso.Tool' -and $parsed['PackageVersion'] -eq '2.1.0' -and
        $parsed['Copyright'] -eq ('Copyright ' + [char]0xA9 + ' Contoso "Tools"') -and $parsed['ReleaseNotes'] -eq "- It's better.") `
        "$($parsed['Copyright']) / $($parsed['ReleaseNotes'])"
    Assert-Test 'Manifest YAML: block scalar and flow list' (
        $parsed['Description'] -eq "First line`nSecond line" -and @($parsed['Tags']).Count -eq 2 -and @($parsed['Tags'])[1] -eq 'two, three') `
        "$(@($parsed['Tags']) -join '|')"
    Assert-Test 'Manifest YAML: quoted values wrapped over several lines are folded, not cut off' (
        $parsed['ShortDescription'] -eq "First part second part`nand it's a new paragraph" -and $parsed['Moniker'] -eq 'aAb c d') `
        "'$($parsed['ShortDescription'])' / '$($parsed['Moniker'])'"
    $parsedInstallers = @($parsed['Installers'])
    Assert-Test 'Manifest YAML: a list of installers, with lists and maps inside' (
        $parsedInstallers.Count -eq 2 -and @($parsedInstallers[0]['InstallModes']).Count -eq 2 -and
        $parsedInstallers[0]['InstallerSwitches']['Silent'] -eq '/S' -and
        @($parsedInstallers[0]['AppsAndFeaturesEntries'])[0]['DisplayVersion'] -eq '2.1.0' -and $parsedInstallers[1]['InstallerType'] -eq 'wix') `
        "$($parsedInstallers.Count) installers"
    Assert-Test 'Manifest YAML: keys after a list are the root''s again' ($parsed['Scope'] -eq 'machine' -and $parsed['ManifestType'] -eq 'merged') "Scope=$($parsed['Scope'])"
    $effective = New-WinGetInstallerInfo -Installer $parsedInstallers[0] -Root $parsed
    Assert-Test 'An installer takes the fields the manifest gives once for all' (
        $effective.Scope -eq 'machine' -and $effective.InstallerType -eq 'exe' -and
        $effective.ProductCode -eq '{11111111-2222-3333-4444-555555555555}' -and $effective.Arp[0].DisplayName -eq 'Contoso Tool') `
        "$($effective.Scope) $($effective.InstallerType) $($effective.ProductCode)"

    # winget's table, by column position. An id cut short with '…' is useless and is dropped.
    $table = @(
        'Name              Id                  Version  Match'
        '-----------------------------------------------------'
        'Contoso Tool      Contoso.Tool        2.1.0    Tag: tool'
        'Contoso Tool Beta Contoso.Tool.Beta   2.2.0-b'
        ('Very long name    Contoso.VeryLongId' + [char]0x2026 + ' 1.0')
    )
    $rows = @(ConvertFrom-WinGetTable -Lines $table)
    Assert-Test 'winget search table is read by column, cut-off ids dropped' (
        $rows.Count -eq 2 -and $rows[0].Id -eq 'Contoso.Tool' -and $rows[1].Name -eq 'Contoso Tool Beta' -and $rows[1].Version -eq '2.2.0-b') `
        (($rows | ForEach-Object { "$($_.Id)=$($_.Version)" }) -join ', ')

    # --- WinGet: the plan ------------------------------------------------------------
    $newInstaller = {
        param([string]$Architecture, [string]$Type, [string]$Scope, [string]$ProductCode, [string]$Family, $Arp)
        [pscustomobject]@{ Architecture = $Architecture; InstallerType = $Type; RequestType = $Type; Scope = $Scope; Locale = ''
                           ProductCode = $ProductCode; PackageFamilyName = $Family; Arp = @($Arp | Where-Object { $_ }); Url = ''
                           UrlHost = 'downloads.contoso.example'; Sha256 = ''; Markets = @() }
    }
    $storeInfo = [pscustomobject]@{
        Id = '9NSELFTEST01'; Source = 'msstore'; Name = 'Self Test Store App'; Publisher = 'Contoso'; Version = ''; Versions = @()
        Description = "  First line.`n`n`n   Second line.  "; Homepage = 'https://contoso.example/'; PrivacyUrl = 'https://contoso.example/privacy'
        License = 'https://contoso.example/license'; LicenseUrl = ''; Author = ''; Pricing = 'Free'; Market = 'SE'; Markets = @('SE')
        Installers = @((& $newInstaller 'x64' 'msstore' 'user' '' 'Contoso.SelfTest_8wekyb3d8bbwe'), (& $newInstaller 'x86' 'msstore' 'user' '' 'Contoso.SelfTest_8wekyb3d8bbwe'))
        IconUrl = ''; ManifestComplete = $true
    }
    $msiEntry = [pscustomobject]@{ DisplayName = 'Contoso Tool 2.1'; DisplayVersion = '2.1.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}'
                                   UpgradeCode = '{AAAAAAAA-2222-3333-4444-555555555555}'; Publisher = 'Contoso'; InstallerType = 'wix' }
    $communityInfo = [pscustomobject]@{
        Id = 'Contoso.Tool'; Source = 'winget'; Name = 'Contoso Tool'; Publisher = 'Contoso'; Version = '2.1.0'; Versions = @('2.1.0', '2.0.0')
        Description = 'A tool.'; Homepage = 'https://contoso.example/tool'; PrivacyUrl = ''; License = 'MIT'; LicenseUrl = ''; Author = 'Contoso Dev'
        Pricing = ''; Market = ''; Markets = @()
        Installers = @((& $newInstaller 'arm64' 'exe' 'machine' 'ContosoTool' ''), (& $newInstaller 'x64' 'exe' 'machine' 'ContosoTool' ''),
                       (& $newInstaller 'x64' 'wix' 'machine' '{11111111-2222-3333-4444-555555555555}' '' $msiEntry))
        IconUrl = ''; ManifestComplete = $true
    }

    $storePlan = New-WinGetInstallPlan -Info $storeInfo -Policy $openPolicy
    Assert-Test 'A Store app installs as SYSTEM for every user, detected by its package family' (
        $storePlan.RunAs -eq 'system' -and $storePlan.Scope -eq 'machine' -and $storePlan.Detect.kind -eq 'appx' -and
        $storePlan.Detect.packageFamilyName -eq 'Contoso.SelfTest_8wekyb3d8bbwe' -and -not $storePlan.Architecture -and
        $storePlan.IntuneArchitecture -eq 'neutral' -and -not $storePlan.Blockers.Count) "$($storePlan.RunAs) $($storePlan.Scope) $($storePlan.IntuneArchitecture)"
    $paidInfo = $storeInfo.PSObject.Copy(); $paidInfo.Pricing = '79,00 kr'
    Assert-Test 'A Store app that is not free cannot be packaged' (
        (New-WinGetInstallPlan -Info $paidInfo -Policy $openPolicy).Blockers -match 'not free')
    $absentInfo = $storeInfo.PSObject.Copy(); $absentInfo.Installers = @()
    $absentBlockers = (New-WinGetInstallPlan -Info $absentInfo -Policy $openPolicy).Blockers -join ' '
    Assert-Test 'A Store app not offered in the market cannot be packaged, and the message says how to change the market' (
        $absentBlockers -match 'SE \(Sweden\) market' -and $absentBlockers -match 'set storeMarket') $absentBlockers

    # A product code belongs to one release: an app that updates itself moves off it, and a rule
    # on it would have Intune install on top. The upgrade code stays with the app.
    $pinnedPlan = New-WinGetInstallPlan -Info $communityInfo -Policy $openPolicy
    Assert-Test 'A pinned MSI is detected by its upgrade code, at that version or later' (
        $pinnedPlan.InstallerType -eq 'wix' -and $pinnedPlan.Architecture -eq 'x64' -and $pinnedPlan.Version -eq '2.1.0' -and
        $pinnedPlan.Detection.type -eq 'script' -and $pinnedPlan.Detect.kind -eq 'msi' -and
        $pinnedPlan.Detect.upgradeCode -eq '{AAAAAAAA-2222-3333-4444-555555555555}' -and $pinnedPlan.Detect.minimumVersion -eq '2.1.0' -and
        $pinnedPlan.ProductCode -eq '{11111111-2222-3333-4444-555555555555}') "$($pinnedPlan.InstallerType) $($pinnedPlan.Detect.kind) $($pinnedPlan.Detect.minimumVersion)"
    $latestPlan = New-WinGetInstallPlan -Info $communityInfo -Latest -Policy $openPolicy
    Assert-Test 'Left on latest, any version of the MSI counts' (
        $latestPlan.InstallerType -eq 'wix' -and -not $latestPlan.Version -and $latestPlan.Detect.kind -eq 'msi' -and -not $latestPlan.Detect.minimumVersion) `
        "$($latestPlan.InstallerType) $($latestPlan.Detect.kind) '$($latestPlan.Detect.minimumVersion)'"
    Assert-Test 'The architecture is chosen, not left to an ARM64 device' ($latestPlan.Architecture -eq 'x64' -and $latestPlan.IntuneArchitecture -eq 'x64')
    $exeInfo = $communityInfo.PSObject.Copy()
    $exeInfo.Installers = @((& $newInstaller 'arm64' 'exe' 'machine' 'ContosoTool' ''), (& $newInstaller 'x64' 'exe' 'machine' 'ContosoTool' ''))
    $exePinned = New-WinGetInstallPlan -Info $exeInfo -Policy $openPolicy
    $exeLatest = New-WinGetInstallPlan -Info $exeInfo -Latest -Policy $openPolicy
    Assert-Test 'An uninstall key without a version in it is the rule: at least the pinned version, or simply there' (
        $exePinned.Detection.type -eq 'registry' -and $exePinned.Detection.keyPath -like 'HKEY_LOCAL_MACHINE\*\Uninstall\ContosoTool' -and
        $exePinned.Detection.operator -eq 'greaterThanOrEqual' -and $exePinned.Detection.detectionValue -eq '2.1.0' -and
        $exeLatest.Detection.type -eq 'registry' -and $exeLatest.Detection.detectionType -eq 'exists') "$($exePinned.Detection.keyPath) / $($exeLatest.Detection.detectionType)"
    $versionedInfo = $communityInfo.PSObject.Copy()
    $versionedInfo.Installers = @(& $newInstaller 'x64' 'exe' 'machine' 'Contoso Tool 2.1.0' '')
    $versionedPlan = New-WinGetInstallPlan -Info $versionedInfo -Policy $openPolicy
    Assert-Test 'A key with the version in it is not trusted to last: WinGet is asked instead' (
        $versionedPlan.Detect.kind -eq 'winget' -and $versionedPlan.Detect.minimumVersion -eq '2.1.0' -and $versionedPlan.Detection.type -eq 'script' -and
        ($versionedPlan.Notes -join ' ') -match 'changes from one version to the next') ($versionedPlan.Notes -join ' | ')
    # A burn bundle's upgrade code is the bundle's own, which Windows Installer has never heard of
    $bundleEntry = [pscustomobject]@{ DisplayName = 'Contoso Suite'; DisplayVersion = '2.1.0'; ProductCode = '{22222222-2222-3333-4444-555555555555}'
                                      UpgradeCode = '{BBBBBBBB-2222-3333-4444-555555555555}'; Publisher = 'Contoso'; InstallerType = 'burn' }
    $bundleInfo = $communityInfo.PSObject.Copy()
    $bundleInfo.Installers = @(& $newInstaller 'x64' 'burn' 'machine' '{22222222-2222-3333-4444-555555555555}' '' $bundleEntry)
    $bundlePlan = New-WinGetInstallPlan -Info $bundleInfo -Policy $openPolicy
    Assert-Test "A bundle is not detected by its upgrade code, nor by its product code" ($bundlePlan.Detect.kind -eq 'winget') "$($bundlePlan.Detect.kind) $($bundlePlan.Detection.type)"
    Assert-Test 'Keys that last and keys that do not' (
        (Test-WinGetStableKey -Key '7-Zip' -Versions '26.04') -and (Test-WinGetStableKey -Key '{F7C3B5A1-1111-2222-3333-444444444444}_is1' -Versions '1.0') -and
        -not (Test-WinGetStableKey -Key '{F7C3B5A1-1111-2222-3333-444444444444}' -Versions '1.0') -and
        -not (Test-WinGetStableKey -Key 'Opera 136.0.6008.22' -Versions '136.0.6008.22') -and -not (Test-WinGetStableKey -Key 'Foo_2024' -Versions '2024') -and
        -not (Test-WinGetStableKey -Key '' -Versions '1.0'))

    $userInfo = $communityInfo.PSObject.Copy()
    $userInfo.Installers = @(& $newInstaller 'x86' 'exe' 'user' 'ContosoToolUser' '')
    $userPlan = New-WinGetInstallPlan -Info $userInfo -Policy $openPolicy
    Assert-Test 'A per-user installer runs as the signed-in user, detected under HKCU' (
        $userPlan.RunAs -eq 'user' -and $userPlan.Scope -eq 'user' -and $userPlan.Detection.keyPath -like 'HKEY_CURRENT_USER\*' -and
        -not $userPlan.Detection.check32BitOn64System -and $userPlan.IntuneArchitecture -eq 'x86,x64') "$($userPlan.RunAs) $($userPlan.Detection.keyPath)"
    $unknownInfo = $communityInfo.PSObject.Copy()
    $unknownInfo.Installers = @(& $newInstaller 'x64' 'exe' '' '' '')
    $unknownPlan = New-WinGetInstallPlan -Info $unknownInfo -Policy $openPolicy
    Assert-Test 'An installer of unknown scope is pointed out, and detected by asking WinGet' (
        $unknownPlan.RunAs -eq 'system' -and $unknownPlan.Detect.kind -eq 'winget' -and -not $unknownPlan.Scope -and
        ($unknownPlan.Warnings -join ' ') -match 'does not say whether' -and ($unknownPlan.Notes -join ' ') -match 'Detection asks WinGet') `
        (($unknownPlan.Warnings + $unknownPlan.Notes) -join ' | ')
    Assert-Test "Intune's Store app type takes Store apps only" (
        (New-WinGetInstallPlan -Info $communityInfo -Delivery store -Policy $openPolicy).Blockers -match 'Microsoft Store only')
    Assert-Test 'A plan for a source the policy does not allow is blocked' (
        (New-WinGetInstallPlan -Info $communityInfo -Policy $storeOnly).Blockers -match 'Microsoft Store only')

    # --- WinGet: commands and scripts ------------------------------------------------
    $commands = Get-WinGetCommandLine -WinGet @{ id = 'Contoso.Tool'; source = 'winget'; version = '2.1.0'; scope = 'machine'
                                                 architecture = 'x64'; installerType = 'wix'; override = '/S /D="C:\x y"'; productCode = 'ContosoTool' }
    Assert-Test 'The source and id are on the install command, where the portal shows them' (
        $commands.Install -eq 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install-WinGetApp.ps1" -Id Contoso.Tool -Source winget -Version 2.1.0 -Scope machine -Architecture x64 -InstallerType wix -Override "/S /D=\"C:\x y\""') $commands.Install
    Assert-Test 'The uninstall command carries the product code to fall back on' (
        $commands.Uninstall -match '-Source winget -Scope machine -ProductCode ContosoTool$') $commands.Uninstall

    $templates = 'TplRelaunch', 'TplLog', 'TplTools', 'TplRunner', 'TplInstall', 'TplUninstall', 'TplDetectAppx', 'TplDetectMsi',
                 'TplDetectWinGet', 'TplRequire', 'TplRuntimeInstall', 'TplRuntimeDetect', 'TplRuntimeUninstall'
    $nonAscii = @($templates | Where-Object { (Get-Variable -Scope Script -Name $_).Value -match '[^\x00-\x7F]' })
    Assert-Test 'The device scripts are plain ASCII' ($nonAscii.Count -eq 0) $(if ($nonAscii) { $nonAscii -join ', ' } else { "$($templates.Count) templates" })
    Assert-Test 'The templates have not changed without a new runner version' (
        (Get-WinGetTemplateHash) -eq $script:WinGetTemplateHash) $(
        if ((Get-WinGetTemplateHash) -ne $script:WinGetTemplateHash) {
            "the templates are $(Get-WinGetTemplateHash), runner $($script:WinGetRunnerVersion) says $($script:WinGetTemplateHash): raise WinGetRunnerVersion and the hash in New-WinGetPackage.ps1"
        } else { "runner $($script:WinGetRunnerVersion)" })

    # A package written from the community plan, and what becomes of its scripts
    $communityPackage = (New-WinGetPackage -Id $communityInfo.Id -Source winget -Info $communityInfo -PackageRoot $wgRoot -FolderName 'Contoso Tool').Folder
    $communityManifestPath = Join-Path $communityPackage 'app.json'
    $communityManifest = Get-Content -LiteralPath $communityManifestPath -Raw | ConvertFrom-Json
    Assert-Test 'A WinGet package folder holds the scripts and an app.json that says where it comes from' (
        (Test-Path (Join-Path $communityPackage 'Install-WinGetApp.ps1')) -and (Test-Path (Join-Path $communityPackage 'Require-WinGetRuntime.ps1')) -and
        $communityManifest.winget.source -eq 'winget' -and $communityManifest.notes -match 'WinGet community repository \(winget\): Contoso.Tool 2\.1\.0' -and
        $communityManifest.requirements[0].scriptFile -eq 'Require-WinGetRuntime.ps1' -and $communityManifest.minimumWindowsRelease -eq '1809') $communityManifest.notes
    $states = @(Get-WinGetScriptState -Folder $communityPackage)
    Assert-Test 'Freshly written scripts are current' (@($states | Where-Object { $_.State -ne 'current' }).Count -eq 0 -and $states.Count -eq 4) (($states | ForEach-Object { "$($_.File)=$($_.State)" }) -join ', ')
    Add-Content -LiteralPath (Join-Path $communityPackage 'Install-WinGetApp.ps1') -Value '# a change'
    $uninstallPath = Join-Path $communityPackage 'Uninstall-WinGetApp.ps1'
    [IO.File]::WriteAllText($uninstallPath, ([IO.File]::ReadAllText($uninstallPath) -replace 'Packwright WinGet runner \d+(\.\d+)+', 'Packwright WinGet runner 0.9'))
    Remove-Item -LiteralPath (Join-Path $communityPackage 'Require-WinGetRuntime.ps1')
    $states = @{}; foreach ($state in (Get-WinGetScriptState -Folder $communityPackage)) { $states[$state.File] = $state.State }
    Assert-Test 'A script changed by hand, an older one and a missing one are each named' (
        $states['Install-WinGetApp.ps1'] -eq 'edited' -and $states['Uninstall-WinGetApp.ps1'] -eq 'outdated' -and $states['Require-WinGetRuntime.ps1'] -eq 'missing') `
        (($states.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
    [void](Update-WinGetScript -Folder $communityPackage)
    Assert-Test 'Refreshing the scripts makes them current again' (@(Get-WinGetScriptState -Folder $communityPackage | Where-Object { $_.State -ne 'current' }).Count -eq 0)

    # --- WinGet: the app's icon --------------------------------------------------------
    # All offline: pwsh.exe stands in for a program file, an MSI is made here, and the download
    # of an installer is a copy - so the SHA-256 check and the reading are the real ones
    $iconTests = Join-Path $wgRoot 'icons'
    $null = New-Item -ItemType Directory -Path $iconTests -Force
    $programFile = (Get-Process -Id $PID).Path
    $nativeSize = Get-WinGetNativeIconSize -File $programFile
    $exportedSize = Export-WinGetFileIcon -File $programFile -Destination (Join-Path $iconTests 'program.png')
    Assert-Test 'A program file gives its icon at the size it has, not blown up to 256' (
        $nativeSize -ge 16 -and $exportedSize -eq [Math]::Min(256, $nativeSize) -and (Test-Path (Join-Path $iconTests 'program.png'))) "native $nativeSize, exported $exportedSize"
    Add-Type -AssemblyName System.Drawing
    foreach ($shape in @{ Name = 'big'; Width = 1080; Height = 1080 }, @{ Name = 'banner'; Width = 300; Height = 100 }) {
        $blank = [Drawing.Bitmap]::new($shape.Width, $shape.Height)
        try { $blank.Save((Join-Path $iconTests "$($shape.Name)-source.png"), [Drawing.Imaging.ImageFormat]::Png) } finally { $blank.Dispose() }
    }
    $bigSide = @(Invoke-StaWork -Work $script:IconWork -Arguments @((Join-Path $iconTests 'big-source.png'), (Join-Path $iconTests 'big.png'), ''))[-1]
    $bannerSide = @(Invoke-StaWork -Work $script:IconWork -Arguments @((Join-Path $iconTests 'banner-source.png'), (Join-Path $iconTests 'banner.png'), ''))[-1]
    Assert-Test 'A large picture is made 512 px, and a banner is not taken for an icon' (
        $bigSide -eq 512 -and $bannerSide -eq 0 -and -not (Test-Path (Join-Path $iconTests 'banner.png'))) "big $bigSide, banner $bannerSide"
    $webIcon = Read-StoreWebIcon -Html ('<head><meta content="https://images-eds-ssl.xboxlive.com/image?url=a1&amp;format=source" property="og:image"/></head>' +
                                        '<script>{"iconUrlBackground":"#0C34FA"}</script>')
    Assert-Test "A Win32 app from the Store gets the icon its web Store page shows" (
        $webIcon.Url -eq 'https://images-eds-ssl.xboxlive.com/image?url=a1&format=source' -and $webIcon.Background -eq '#0C34FA') "$($webIcon.Url) $($webIcon.Background)"
    Assert-Test 'An app is found in Apps and features by its name, or its name and version, and nothing that merely starts the same' (
        (Test-WinGetAppName -DisplayName '7-Zip 26.04 (x64 edition)' -Names '7-Zip') -and (Test-WinGetAppName -DisplayName 'VLC media player' -Names 'vlc media player') -and
        -not (Test-WinGetAppName -DisplayName 'Microsoft Edge WebView2 Runtime' -Names 'Microsoft Edge') -and -not (Test-WinGetAppName -DisplayName 'Gitter' -Names 'Git'))

    # An MSI with an Icon table and ARPPRODUCTICON naming a row of it, made with Windows Installer's own API
    $msiPath = Join-Path $iconTests 'icon-test.msi'
    $msiApi = New-Object -ComObject WindowsInstaller.Installer
    $msiDatabase = $msiApi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $msiApi, @([string]$msiPath, [int]3))
    $msiRun = {
        param([string]$Sql, $Record)
        $view = $msiDatabase.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $msiDatabase, @($Sql))
        [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $(if ($Record) { @($Record) } else { $null }))
        [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
    }
    & $msiRun 'CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` LONGCHAR NOT NULL PRIMARY KEY `Property`)'
    & $msiRun 'CREATE TABLE `Icon` (`Name` CHAR(72) NOT NULL, `Data` OBJECT NOT NULL PRIMARY KEY `Name`)'
    & $msiRun 'INSERT INTO `Property` (`Property`, `Value`) VALUES (''ARPPRODUCTICON'', ''app.exe'')'
    # The row ARPPRODUCTICON names, and a larger one beside it that must not be taken instead
    $largerFile = Get-ChildItem -LiteralPath (Split-Path -Parent $programFile) -File -Filter '*.dll' | Sort-Object Length |
                  Where-Object { $_.Length -gt (Get-Item -LiteralPath $programFile).Length } | Select-Object -First 1 -ExpandProperty FullName
    foreach ($row in @(@{ Name = 'app.exe'; File = $programFile }, @{ Name = 'larger.dll'; File = $largerFile })) {
        if (-not $row.File) { continue }
        $msiRecord = $msiApi.GetType().InvokeMember('CreateRecord', 'InvokeMethod', $null, $msiApi, @([int]2))
        [void]$msiRecord.GetType().InvokeMember('StringData', 'SetProperty', $null, $msiRecord, @([int]1, [string]$row.Name))
        [void]$msiRecord.GetType().InvokeMember('SetStream', 'InvokeMethod', $null, $msiRecord, @([int]2, [string]$row.File))
        & $msiRun 'INSERT INTO `Icon` (`Name`, `Data`) VALUES (?, ?)' $msiRecord
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($msiRecord)
    }
    [void]$msiDatabase.GetType().InvokeMember('Commit', 'InvokeMethod', $null, $msiDatabase, $null)
    foreach ($com in $msiDatabase, $msiApi) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) }
    $msiIcon = Export-MsiProductIcon -Path $msiPath -Folder $iconTests
    $msiSize = if ($msiIcon) { Export-WinGetFileIcon -File $msiIcon -Destination (Join-Path $iconTests 'msi.png') }
    Assert-Test "An MSI's icon is read from its Icon table: the row ARPPRODUCTICON names, not merely the largest" (
        $msiIcon -and (Split-Path -Leaf $msiIcon) -eq 'app.exe.ibd' -and $msiSize -ge 16 -and $largerFile) "$msiIcon, $msiSize px"

    # The installer as the manifest names it, "downloaded" as a copy of the program file
    $iconInstaller = [pscustomobject]@{ Architecture = 'x64'; InstallerType = 'exe'; RequestType = 'exe'; Url = 'https://downloads.contoso.example/setup.exe'
                                        UrlHost = 'downloads.contoso.example'; Sha256 = (Get-FileHash -LiteralPath $programFile -Algorithm SHA256).Hash; ProductCode = ''; Arp = @() }
    $realDownload = ${function:Save-LimitedDownload}
    $realCatalogIcon = ${function:Save-WinGetIcon}
    try {
        ${function:Save-LimitedDownload} = { param($Url, $Destination, $LimitMB, $Activity) Copy-Item -LiteralPath $programFile -Destination $Destination }
        $goodInstaller = Save-WinGetInstallerIcon -Installer $iconInstaller -Destination (Join-Path $iconTests 'installer.png')
        $tamperedInstaller = $iconInstaller.PSObject.Copy()
        $tamperedInstaller.Sha256 = '0' * 64
        $badInstaller = Save-WinGetInstallerIcon -Installer $tamperedInstaller -Destination (Join-Path $iconTests 'tampered.png')
        Assert-Test "An installer's icon is taken only when the download matches the manifest's SHA-256" (
            $goodInstaller.Size -ge 16 -and -not $badInstaller.Size -and $badInstaller.Note -match 'SHA-256' -and -not (Test-Path (Join-Path $iconTests 'tampered.png'))) `
            "$($goodInstaller.Size) px / $($badInstaller.Note)"
        # A catalog's 48 px icon gives way to the installer's larger one - unless nothing is to be downloaded
        ${function:Save-WinGetIcon} = { param($Url, $Destination, $Background) Copy-Item -LiteralPath (Join-Path $iconTests 'program.png') -Destination $Destination; 48 }
        $smallInfo = [pscustomobject]@{ Id = 'Contoso.IconTest'; Source = 'winget'; Name = 'Contoso Icon Test'; IconUrl = 'https://contoso.example/icon.png'
                                        IconBackground = ''; Installers = @($iconInstaller) }
        $smallPlan = [pscustomobject]@{ ProductCode = ''; Installer = $iconInstaller }
        $iconFolders = foreach ($name in 'icon-download', 'icon-nodownload') { $folder = Join-Path $iconTests $name; $null = New-Item -ItemType Directory -Path $folder -Force; $folder }
        $sharper = Save-WinGetPackageIcon -Info $smallInfo -Plan $smallPlan -Folder $iconFolders[0]
        $kept = Save-WinGetPackageIcon -Info $smallInfo -Plan $smallPlan -Folder $iconFolders[1] -NoDownload
        Assert-Test "A catalog's small icon gives way to the installer's larger one, and stays when nothing is to be downloaded" (
            $sharper.Size -gt 48 -and $sharper.From -match 'downloads\.contoso\.example' -and $kept.Size -eq 48 -and $kept.From -eq 'the manifest' -and
            (Test-Path (Join-Path $iconFolders[0] 'icon.png')) -and (Test-Path (Join-Path $iconFolders[1] 'icon.png'))) "$($sharper.Size) from $($sharper.From) / $($kept.Size) from $($kept.From)"
    }
    finally {
        ${function:Save-LimitedDownload} = $realDownload
        ${function:Save-WinGetIcon} = $realCatalogIcon
    }

    # Identity read out of an app package, the way the runtime package lists its frameworks
    $appxStage = Join-Path $wgRoot 'appxstage'
    $null = New-Item -ItemType Directory -Path $appxStage -Force
    '<?xml version="1.0"?><Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="Microsoft.VCLibs.140.00.UWPDesktop" Version="14.0.33728.0" ProcessorArchitecture="x64" Publisher="CN=Microsoft"/></Package>' |
        Set-Content -LiteralPath (Join-Path $appxStage 'AppxManifest.xml') -Encoding UTF8
    $appxFile = Join-Path $wgRoot 'framework.appx'
    [IO.Compression.ZipFile]::CreateFromDirectory($appxStage, $appxFile)
    $identity = Get-AppPackageIdentity -Path $appxFile
    Assert-Test 'A package identity is read from its manifest' (
        $identity.Name -eq 'Microsoft.VCLibs.140.00.UWPDesktop' -and $identity.Version -eq '14.0.33728.0' -and $identity.Architecture -eq 'x64') "$($identity.Name) $($identity.Version) $($identity.Architecture)"
    # App Installer's bundle is versioned by date; what installs, and what a device reports, is
    # the application package inside it. Read as the bundle's, every device would look out of
    # date for ever and the runtime would reinstall on each evaluation.
    $bundleStage = Join-Path $wgRoot 'bundlestage'
    $null = New-Item -ItemType Directory -Path (Join-Path $bundleStage 'AppxMetadata') -Force
    ('<?xml version="1.0"?><Bundle xmlns="http://schemas.microsoft.com/appx/2013/bundle"><Identity Name="Microsoft.DesktopAppInstaller" Version="2026.917.151.0" Publisher="CN=Microsoft"/>' +
     '<Packages><Package Type="resource" Version="1.29.380.0" FileName="AppInstaller_language-sv.msix"/>' +
     '<Package Type="application" Version="1.29.380.0" Architecture="x64" FileName="AppInstaller_x64.msix"/>' +
     '<Package Type="application" Version="1.29.379.0" Architecture="x64" FileName="AppxMetadata\Stub\AppInstaller_x64_stub.msix"/>' +
     '<Package Type="application" Version="1.29.380.0" Architecture="arm64" FileName="AppInstaller_arm64.msix"/></Packages></Bundle>') |
        Set-Content -LiteralPath (Join-Path $bundleStage 'AppxMetadata\AppxBundleManifest.xml') -Encoding UTF8
    $bundleFile = Join-Path $wgRoot 'appinstaller.msixbundle'
    [IO.Compression.ZipFile]::CreateFromDirectory($bundleStage, $bundleFile)
    $bundleIdentity = Get-AppPackageIdentity -Path $bundleFile
    Assert-Test "A bundle's version is the application's inside it, not the bundle's own" (
        $bundleIdentity.Version -eq '1.29.380.0' -and $bundleIdentity.BundleVersion -eq '2026.917.151.0') "$($bundleIdentity.Version) (bundle $($bundleIdentity.BundleVersion))"

    # --- WinGet: the device scripts under Windows PowerShell 5.1 ---------------------
    # What runs on the devices is 5.1, started 32-bit, and nothing else can tell whether it
    # parses there and answers the way Intune reads it. Only the finding of winget.exe is
    # swapped, in a copy - the scripts have no switch that points them elsewhere.
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
        Write-Host '  SKIP  Device scripts under Windows PowerShell 5.1 (powershell.exe is not here)'
    }
    else {
        $deviceDir = Join-Path $wgRoot 'device'
        $null = New-Item -ItemType Directory -Path $deviceDir -Force
        $allScripts = [ordered]@{}
        # A typographic quote in a value is a quote to PowerShell too, and must not end the string
        $curlyId = "O$([char]0x2019)Brien.Tool"
        foreach ($set in (Get-WinGetScriptSet -WinGet @{ id = "O'Brien.Tool"; source = 'winget'; runtime = 'requirement'
                                                         detect = @{ kind = 'msi'; upgradeCode = '{0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0}'; minimumVersion = '1.0' } }),
                         (Get-WinGetScriptSet -WinGet @{ id = 'Fake.App'; source = 'msstore'; runtime = 'requirement'
                                                         detect = @{ kind = 'appx'; packageFamilyName = 'Packwright.NoSuchApp_8wekyb3d8bbwe' } }),
                         (Get-WinGetScriptSet -WinGet @{ id = $curlyId; source = 'winget'; runtime = 'requirement'
                                                         detect = @{ kind = 'winget'; minimumVersion = '2.0' } }),
                         (Get-WinGetRuntimeScriptSet -Runtime @{ appInstaller = '1.29.380.0' })) {
            foreach ($name in $set.Keys) { $allScripts["$($allScripts.Count)-$name"] = $set[$name] }
        }
        foreach ($name in $allScripts.Keys) { Write-WinGetScriptFile -Path (Join-Path $deviceDir $name) -Content $allScripts[$name] }
        $parseCheck = Join-Path $deviceDir 'parse.ps1'
        'param($Folder) foreach ($f in Get-ChildItem -LiteralPath $Folder -Filter "*-*.ps1") { $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e); if ($e) { "$($f.Name): $($e[0].Message)" } }' |
            Set-Content -LiteralPath $parseCheck -Encoding ASCII
        $parseErrors = @(& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $parseCheck -Folder $deviceDir)
        Assert-Test 'Every device script parses in Windows PowerShell 5.1' ($parseErrors.Count -eq 0) $(if ($parseErrors) { $parseErrors[0] } else { "$($allScripts.Count) scripts" })

        # Detection and requirement scripts: an answer on the output, nothing on the error stream
        $runQuiet = {
            param([string]$Path)
            $start = [Diagnostics.ProcessStartInfo]::new($windowsPowerShell)
            foreach ($argument in '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path) { $start.ArgumentList.Add($argument) }
            $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true; $start.UseShellExecute = $false
            $process = [Diagnostics.Process]::Start($start)
            $output = $process.StandardOutput.ReadToEnd(); $errorText = $process.StandardError.ReadToEnd(); $process.WaitForExit()
            [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.Trim(); Error = $errorText.Trim() }
        }
        $absent = & $runQuiet (Join-Path $deviceDir (@($allScripts.Keys | Where-Object { $_ -like '*Detect-WinGetApp.ps1' })[0]))
        Assert-Test 'Detection of an MSI upgrade code nothing has finds nothing and says nothing' (
            $absent.ExitCode -eq 0 -and -not $absent.Output -and -not $absent.Error) "exit $($absent.ExitCode), out '$($absent.Output)', err '$($absent.Error)'"
        # And one this computer has: the first upgrade code Windows Installer knows products for
        $installedUpgradeCode = $null
        try {
            $msi = New-Object -ComObject WindowsInstaller.Installer
            foreach ($packed in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes' -ErrorAction SilentlyContinue | Select-Object -First 10)) {
                $p = $packed.PSChildName
                if ($p -notmatch '^[0-9A-Fa-f]{32}$') { continue }
                $s = -join (@(7, 6, 5, 4, 3, 2, 1, 0, 11, 10, 9, 8, 15, 14, 13, 12, 17, 16, 19, 18, 21, 20, 23, 22, 25, 24, 27, 26, 29, 28, 31, 30) | ForEach-Object { $p[$_] })
                $candidate = '{{{0}-{1}-{2}-{3}-{4}}}' -f $s.Substring(0, 8), $s.Substring(8, 4), $s.Substring(12, 4), $s.Substring(16, 4), $s.Substring(20, 12)
                if (@($msi.GetType().InvokeMember('RelatedProducts', 'GetProperty', $null, $msi, @($candidate))).Count) { $installedUpgradeCode = $candidate; break }
            }
        }
        catch { $installedUpgradeCode = $null }
        if (-not $installedUpgradeCode) { Write-Host '  SKIP  MSI detection of an installed product (no MSI product found on this computer)' }
        else {
            $msiFound = @{}
            foreach ($minimum in '', '99999.0') {
                $msiScript = Join-Path $deviceDir "Detect-Msi-$($minimum -replace '\.', '_').ps1"
                Write-WinGetScriptFile -Path $msiScript -Content (Get-WinGetScriptSet -WinGet @{ id = 'Fake.App'; source = 'winget'; runtime = 'requirement'
                    detect = @{ kind = 'msi'; upgradeCode = $installedUpgradeCode; minimumVersion = $minimum } })['Detect-WinGetApp.ps1']
                $msiFound[$minimum] = & $runQuiet $msiScript
            }
            Assert-Test 'MSI detection finds an installed product by its upgrade code, and not when it is older than asked' (
                $msiFound[''].Output -like 'Installed: {*' -and -not $msiFound[''].Error -and -not $msiFound['99999.0'].Output -and -not $msiFound['99999.0'].Error) `
                "any: '$($msiFound[''].Output)' $($msiFound[''].Error) / 99999: '$($msiFound['99999.0'].Output)'"
        }
        $appxAbsent = & $runQuiet (Join-Path $deviceDir (@($allScripts.Keys | Where-Object { $_ -like '*Detect-WinGetApp.ps1' })[1]))
        Assert-Test 'Detection of an app package that is not there says nothing' (
            $appxAbsent.ExitCode -eq 0 -and -not $appxAbsent.Output -and -not $appxAbsent.Error) "exit $($appxAbsent.ExitCode), err '$($appxAbsent.Error)'"
        $requirement = & $runQuiet (Join-Path $deviceDir (@($allScripts.Keys | Where-Object { $_ -like '*Require-WinGetRuntime.ps1' })[0]))
        Assert-Test 'The requirement answers True or False and nothing else' (
            $requirement.ExitCode -eq 0 -and $requirement.Output -in 'True', 'False' -and -not $requirement.Error) "'$($requirement.Output)'"

        # The install script against a stand-in for winget: what Intune is told back
        # An install writes a log of its own where --info says, and with hang.txt there it prints
        # one line and then never finishes - in a loop of cmd's own, with no child process to hold
        # its output open once it is stopped
        $fake = Join-Path $deviceDir 'fakewinget.cmd'
        $null = New-Item -ItemType Directory -Path (Join-Path $deviceDir 'DiagOutputDir') -Force
        @('@echo off', 'setlocal', 'set "HERE=%~dp0"', 'echo %*>>"%HERE%calls.txt"', 'if "%~1"=="--version" goto version',
          'if "%~1"=="--info" goto info', 'if "%~1"=="list" goto list', 'echo fake winget log>"%HERE%DiagOutputDir\WinGet-fake.log"',
          'if exist "%HERE%hang.txt" goto hang',
          'set CODE=0', 'if exist "%HERE%code.txt" set /p CODE=<"%HERE%code.txt"', 'exit /b %CODE%',
          ':hang', 'echo Found Fake App [Fake.App]', 'for /l %%i in (1,1,2147483647) do rem', 'exit /b 0',
          ':version', 'if exist "%HERE%version.txt" (type "%HERE%version.txt") else (echo v1.29.380)', 'exit /b 0',
          ':info', 'echo Logs  %HERE%DiagOutputDir', 'exit /b 0',
          ':list', 'if exist "%HERE%list.txt" type "%HERE%list.txt"', 'set LISTCODE=0', 'if exist "%HERE%listcode.txt" set /p LISTCODE=<"%HERE%listcode.txt"',
          'exit /b %LISTCODE%') | Set-Content -LiteralPath $fake -Encoding ASCII
        $stub = "function Find-WinGet { [pscustomobject]@{ Path = '$fake'; Version = [version]'1.29.380.0' } }`r`n"
        $runner = (Get-WinGetScriptSet -WinGet @{ id = 'Fake.App'; source = 'msstore'; runtime = 'requirement' })['Install-WinGetApp.ps1']
        Write-WinGetScriptFile -Path (Join-Path $deviceDir 'Install-WinGetApp.ps1') -Content $runner.Replace('# --- Install ---', $stub + '# --- Install ---')
        $mapped = @(foreach ($case in @(@{ Code = 0; Expect = 0; Name = 'installed' }, @{ Code = -1978335135; Expect = 0; Name = 'already installed' },
                                       @{ Code = -1978334974; Expect = 1618; Name = 'another install running' }, @{ Code = -1978334967; Expect = 3010; Name = 'restart to finish' },
                                       @{ Code = -1978335215; Expect = -1978335215; Name = 'hash mismatch' },
                                       @{ Code = 0; Version = 'v1.21.3482'; Expect = 1618; Name = 'winget too old' })) {
            foreach ($leftover in 'calls.txt', 'version.txt') { Remove-Item -LiteralPath (Join-Path $deviceDir $leftover) -ErrorAction SilentlyContinue }
            [IO.File]::WriteAllText((Join-Path $deviceDir 'code.txt'), "$($case.Code)")
            if ($case.Version) { [IO.File]::WriteAllText((Join-Path $deviceDir 'version.txt'), $case.Version) }
            Push-Location -LiteralPath $deviceDir
            try { $null = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File '.\Install-WinGetApp.ps1' -Id Fake.App -Source msstore -Scope machine; $exit = $LASTEXITCODE }
            finally { Pop-Location }
            if ($exit -ne $case.Expect) { "$($case.Name): $exit, expected $($case.Expect)" }
        })
        Assert-Test "WinGet's results reach Intune as the return codes it acts on" ($mapped.Count -eq 0) $(if ($mapped) { $mapped -join '; ' } else { '6 outcomes' })

        # Detection by asking WinGet, against the same stand-in: its table read by column, the
        # version compared when one is pinned, and nothing ever on the error stream
        Remove-Item -LiteralPath (Join-Path $deviceDir 'version.txt') -ErrorAction SilentlyContinue   # the "too old" case above
        $listScripts = @{}
        foreach ($minimum in '', '2.0') {
            $listScripts[$minimum] = Join-Path $deviceDir "Detect-List-$($minimum -replace '\.', '_').ps1"
            $listed = (Get-WinGetScriptSet -WinGet @{ id = 'Fake.App'; source = 'winget'; runtime = 'requirement'
                                                       detect = @{ kind = 'winget'; minimumVersion = $minimum } })['Detect-WinGetApp.ps1']
            Write-WinGetScriptFile -Path $listScripts[$minimum] -Content $listed.Replace("`$id = 'Fake.App'", $stub + "`$id = 'Fake.App'")
        }
        $listRow = { param([string]$Version) '{0,-14}{1,-10}{2,-9}{3,-10}{4}' -f 'Fake App', 'Fake.App', $Version, '', 'winget' }
        $listFailures = @(foreach ($case in @(
            @{ Name = 'latest, installed'; Minimum = ''; Rows = @('2.1.0'); Expect = $true }
            @{ Name = 'pinned 2.0, has 2.1.0'; Minimum = '2.0'; Rows = @('2.1.0'); Expect = $true }
            @{ Name = 'pinned 2.0, has 1.5'; Minimum = '2.0'; Rows = @('1.5'); Expect = $false }
            @{ Name = 'pinned 2.0, older than winget knows'; Minimum = '2.0'; Rows = @('< 2.0'); Expect = $false }
            @{ Name = 'pinned 2.0, version unknown'; Minimum = '2.0'; Rows = @('Unknown'); Expect = $true }
            @{ Name = 'pinned 2.0, per machine 1.5 and per user 2.1.0'; Minimum = '2.0'; Rows = @('1.5', '2.1.0'); Expect = $true }
            @{ Name = 'not installed'; Minimum = '2.0'; Rows = @(); Code = -1978335212; Expect = $false })) {
            $table = if ($case.Rows.Count) {
                @(('{0,-14}{1,-10}{2,-9}{3,-10}{4}' -f 'Name', 'Id', 'Version', 'Available', 'Source'), ('-' * 50)) + @($case.Rows | ForEach-Object { & $listRow $_ })
            } else { @('No installed package found matching input criteria.') }
            Set-Content -LiteralPath (Join-Path $deviceDir 'list.txt') -Value $table -Encoding ASCII
            [IO.File]::WriteAllText((Join-Path $deviceDir 'listcode.txt'), "$(if ($case.Code) { $case.Code } else { 0 })")
            Remove-Item -LiteralPath (Join-Path $deviceDir 'calls.txt') -ErrorAction SilentlyContinue
            $answer = & $runQuiet $listScripts[$case.Minimum]
            $found = $answer.Output -like 'Installed: Fake.App*'
            if ($found -ne $case.Expect -or $answer.Error -or $answer.ExitCode -ne 0) { "$($case.Name): out '$($answer.Output)', err '$($answer.Error)'" }
        })
        $listCall = @(Get-Content -LiteralPath (Join-Path $deviceDir 'calls.txt') -ErrorAction SilentlyContinue) | Where-Object { $_ -like 'list *' } | Select-Object -First 1
        Assert-Test 'Detection by WinGet reads its table, compares a pinned version, and stays silent' (
            $listFailures.Count -eq 0 -and $listCall -eq 'list --id Fake.App --exact --source winget --accept-source-agreements --disable-interactivity') `
            $(if ($listFailures) { $listFailures -join '; ' } else { $listCall })
        foreach ($leftover in 'list.txt', 'listcode.txt') { Remove-Item -LiteralPath (Join-Path $deviceDir $leftover) -ErrorAction SilentlyContinue }
        $calls = Get-Content -LiteralPath (Join-Path $deviceDir 'calls.txt') -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $deviceDir 'version.txt') -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText((Join-Path $deviceDir 'code.txt'), '0')
        Remove-Item -LiteralPath (Join-Path $deviceDir 'calls.txt') -ErrorAction SilentlyContinue
        $wow = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $wow) {
            Push-Location -LiteralPath $deviceDir
            try { $relaunchOutput = & $wow -NoProfile -ExecutionPolicy Bypass -File '.\Install-WinGetApp.ps1' -Id Fake.App -Source winget -Version 1.0 -Override 'a "quoted" value'; $exit = $LASTEXITCODE }
            finally { Pop-Location }
            $installCall = @(Get-Content -LiteralPath (Join-Path $deviceDir 'calls.txt')) | Where-Object { $_ -like 'install *' } | Select-Object -First 1
            Assert-Test 'Started 32-bit as Intune does, it carries on 64-bit with the arguments intact' (
                $exit -eq 0 -and ($relaunchOutput -join ' ') -match '64-bit' -and
                $installCall -match '--source winget --dependency-source winget' -and $installCall -match '--override "a \\"quoted\\" value"') $installCall
        }

        # A winget that never finishes is stopped at the time limit - a few seconds in this copy,
        # the one change in it besides the stand-in - what it printed is kept, its own log is
        # copied, and Intune is told to try again
        $limited = (Get-WinGetScriptSet -WinGet @{ id = 'Fake.App'; source = 'winget'; runtime = 'requirement' })['Install-WinGetApp.ps1']
        Write-WinGetScriptFile -Path (Join-Path $deviceDir 'Install-Limited.ps1') -Content (
            $limited.Replace('# --- Install ---', $stub + "`$script:Deadline = (Get-Date).AddSeconds(4)`r`n# --- Install ---"))
        [IO.File]::WriteAllText((Join-Path $deviceDir 'hang.txt'), 'x')
        Push-Location -LiteralPath $deviceDir
        try { $limitedText = @(& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File '.\Install-Limited.ps1' -Id Fake.App -Source winget) -join "`n"; $exit = $LASTEXITCODE }
        finally { Pop-Location; Remove-Item -LiteralPath (Join-Path $deviceDir 'hang.txt') -ErrorAction SilentlyContinue }
        Assert-Test 'A winget still running at the time limit is stopped, what it printed and its log are kept, and Intune tries again' (
            $exit -eq 1618 -and $limitedText -match 'was still running after' -and $limitedText -match '\| Found Fake App \[Fake\.App\]' -and
            $limitedText -match "WinGet's own log of this run") "exit $exit"

        # Another installation holding WinGet's install lock - held here, in this session, the way
        # a winget holds it - is waited for, a few seconds in this copy, and then left to Intune to
        # try again later, without winget being started to wait behind it
        $lockCreated = $false
        $heldLock = [Threading.Mutex]::new($true, 'WinGetCrossProcessInstallLock', [ref]$lockCreated)
        try {
            if (-not $lockCreated) { Write-Host '  SKIP  Waiting for WinGet''s install lock (a winget on this computer holds it right now)' }
            else {
                Write-WinGetScriptFile -Path (Join-Path $deviceDir 'Install-Waiting.ps1') -Content (
                    $limited.Replace('# --- Install ---', $stub + "`$script:LockWaitMinutes = 0.05`r`n# --- Install ---"))
                Remove-Item -LiteralPath (Join-Path $deviceDir 'calls.txt') -ErrorAction SilentlyContinue
                Push-Location -LiteralPath $deviceDir
                try { $waitedText = @(& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File '.\Install-Waiting.ps1' -Id Fake.App -Source winget) -join "`n"; $exit = $LASTEXITCODE }
                finally { Pop-Location }
                $installCalls = @(Get-Content -LiteralPath (Join-Path $deviceDir 'calls.txt') -ErrorAction SilentlyContinue | Where-Object { $_ -like 'install *' })
                Assert-Test "Another installation holding WinGet's install lock is waited for, then left for Intune to try again, and winget is not started" (
                    $exit -eq 1618 -and $waitedText -match "holds WinGet's install lock" -and $waitedText -match "has held WinGet's install lock" -and
                    $installCalls.Count -eq 0) "exit $exit, $($installCalls.Count) install call(s)"
            }
        }
        finally {
            if ($lockCreated) { $heldLock.ReleaseMutex() }
            $heldLock.Dispose()
        }
    }

    # --- WinGet: publishing -------------------------------------------------------------
    $storePackage = (New-WinGetPackage -Id $storeInfo.Id -Source msstore -Info $storeInfo -Delivery store -PackageRoot $wgRoot -FolderName 'Store App').Folder
    $storePublish = Invoke-PublishProbe -NoPath -Arguments @{ ManifestPath = (Join-Path $storePackage 'app.json') }
    $storeBody = @($storePublish.Bodies | Where-Object { $_ -like 'POST *' })
    Assert-Test 'An Intune Store app is created from app.json alone, with nothing uploaded' (
        $storePublish.Outcome -eq 'RETURNED:Created:stub-app-0001' -and $storeBody.Count -eq 1 -and
        $storeBody[0] -match '"@odata.type":"#microsoft.graph.winGetApp"' -and $storeBody[0] -match '"packageIdentifier":"9NSELFTEST01"' -and
        $storeBody[0] -match '"runAsAccount":"system"' -and $storePublish.Calls -notmatch 'contentVersions') "$($storePublish.Outcome) — $($storeBody[0])"
    Assert-Test 'Its description arrives tidied up' ($storeBody[0] -match '"description":"First line\.\\n\\nSecond line\."') ($storeBody[0] -replace '^.*"description":("[^"]*").*$', '$1')
    $storeWithFile = Invoke-PublishProbe -Arguments @{ ManifestPath = (Join-Path $storePackage 'app.json') }
    Assert-Test 'A .intunewin handed in with an Intune Store app is refused' ($storeWithFile.Outcome -match 'no content to upload') $storeWithFile.Outcome

    $wingetPublish = Invoke-PublishProbe -Arguments @{ ManifestPath = $communityManifestPath; AllowDuplicateName = $true }
    $wingetBody = @($wingetPublish.Bodies | Where-Object { $_ -like 'POST *' })
    Assert-Test 'A WinGet package is published with its requirement rule and detection' (
        $wingetPublish.Outcome -like 'RETURNED:Created:*' -and $wingetBody[0] -match 'win32LobAppPowerShellScriptRequirement' -and
        $wingetBody[0] -match '"detectionType":"boolean"' -and $wingetBody[0] -match 'win32LobAppPowerShellScriptDetection' -and
        $wingetBody[0] -match '-Source winget' -and $wingetBody[0] -match '"privacyInformationUrl"|"developer":"Contoso Dev"') $wingetPublish.Outcome

    # The publish engine checks the policy itself - next to a Store-only policy file, a copy of it
    # refuses the community package before anything reaches Intune
    $restrictedTools = Join-Path $wgRoot 'restricted'
    $null = New-Item -ItemType Directory -Path $restrictedTools -Force
    Copy-Item -LiteralPath $script:EnginePublish, $script:EngineWinGet -Destination $restrictedTools
    Copy-Item -LiteralPath $storeOnlyPath -Destination (Join-Path $restrictedTools 'Packwright.policy.json')
    $refused = Invoke-PublishProbe -PublishScript (Join-Path $restrictedTools 'Publish-IntuneWinApp.ps1') `
                   -Arguments @{ ManifestPath = $communityManifestPath; AllowDuplicateName = $true }
    Assert-Test 'Publishing refuses a source the policy does not allow, before anything is created' (
        $refused.Outcome -match 'Microsoft Store only' -and $refused.Outcome -match 'Nothing was created' -and $refused.Calls -notmatch 'POST') $refused.Outcome
    $storeWin32 = (New-WinGetPackage -Id $storeInfo.Id -Source msstore -Info $storeInfo -Delivery win32 -PackageRoot $wgRoot -FolderName 'Store App Win32').Folder
    Add-Content -LiteralPath (Join-Path $storeWin32 'Install-WinGetApp.ps1') -Value '# installs from somewhere else now'
    $tampered = Invoke-PublishProbe -PublishScript (Join-Path $restrictedTools 'Publish-IntuneWinApp.ps1') `
                    -Arguments @{ ManifestPath = (Join-Path $storeWin32 'app.json'); AllowDuplicateName = $true }
    Assert-Test 'Where sources are restricted, a script changed by hand is not published' (
        $tampered.Outcome -match 'changed by hand' -and $tampered.Calls -notmatch 'POST') $tampered.Outcome
    $openTampered = Invoke-PublishProbe -Arguments @{ ManifestPath = (Join-Path $storeWin32 'app.json'); AllowDuplicateName = $true }
    Assert-Test 'Where they are not, it is published with a warning' ($openTampered.Outcome -like 'RETURNED:Created:*') $openTampered.Outcome

    # Dependencies: found before anything is created, and set without dropping what the app
    # already supersedes - updateRelationships replaces every relationship it has
    $dependent = Get-Content -LiteralPath $communityManifestPath -Raw | ConvertFrom-Json
    $dependent | Add-Member -NotePropertyName dependencies -NotePropertyValue @([pscustomobject]@{ displayName = 'WinGet runtime'; autoInstall = $true }) -Force
    $dependentPath = Join-Path $communityPackage 'app-dependent.json'
    $dependent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $dependentPath -Encoding UTF8
    $runtimeApp = @{ id = 'stub-runtime'; '@odata.type' = '#microsoft.graph.win32LobApp'; displayName = 'WinGet runtime' }
    $related = Invoke-PublishProbe -Arguments @{ ManifestPath = $dependentPath; AllowDuplicateName = $true } -DependencyApp $runtimeApp -Relationships @(
        @{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = 'stub-old-app'; targetType = 'child'; supersedenceType = 'update' }
        @{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetId = 'stub-someone-else'; targetType = 'parent'; dependencyType = 'autoInstall' })
    $relationships = @($related.Bodies | Where-Object { $_ -like 'RELATIONSHIPS *' })
    Assert-Test 'A dependency is set, and what the app supersedes is kept' (
        $related.Outcome -like 'RETURNED:Created:*' -and $relationships.Count -eq 1 -and
        $relationships[0] -match '"targetId":"stub-runtime","dependencyType":"autoInstall"|"dependencyType":"autoInstall".*"targetId":"stub-runtime"' -and
        $relationships[0] -match 'stub-old-app' -and $relationships[0] -match '"supersedenceType":"update"' -and $relationships[0] -notmatch 'stub-someone-else') `
        "$($related.Outcome) — $($relationships -join ' ')"
    $orphan = Invoke-PublishProbe -Arguments @{ ManifestPath = $dependentPath; AllowDuplicateName = $true }
    Assert-Test 'A dependency Intune does not have stops the publish before anything is created' (
        $orphan.Outcome -match "no Win32 app of that name" -and $orphan.Calls -notmatch 'POST') $orphan.Outcome
    Remove-Item -LiteralPath $dependentPath -Force

    # --- WinGet: in the studio ------------------------------------------------------------
    $wingetDialog = New-StudioWindow -Xaml $script:WinGetXaml
    Assert-Test 'WinGet dialog builds' ($wingetDialog.Unresolved.Count -eq 0) "$($wingetDialog.C.Count) controls"
    $script:Wg = @{ Window = $wingetDialog.Window; C = $wingetDialog.C; Policy = $openPolicy; Source = 'winget'; Info = $null; Plan = $null
                    Latest = $false; Delivery = 'win32'; Filling = $false; Result = $null }
    Complete-WgDetail -Result @($communityInfo) -Failure $null -Context @{ Source = 'winget'; Id = 'Contoso.Tool' }
    Assert-Test 'Picking a community app shows its versions and the plan' (
        $wingetDialog.C.GPnlVersion.Visibility -eq 'Visible' -and $wingetDialog.C.GCmbVersion.Items.Count -eq 3 -and
        $wingetDialog.C.GTxtPlan.Text -match 'winget install --id Contoso.Tool --source winget --version 2\.1\.0' -and $wingetDialog.C.GBtnCreate.IsEnabled) `
        $wingetDialog.C.GTxtPlan.Text
    $wingetDialog.C.GCmbVersion.SelectedIndex = 0
    Select-WgVersion   # the dialog's own handler, which Show-WinGetDialog wires up
    Assert-Test 'Choosing "latest" plans for no version' ($script:Wg.Latest -and $wingetDialog.C.GTxtPlan.Text -notmatch '--version') $wingetDialog.C.GTxtPlan.Text
    $script:Wg.Source = 'msstore'; $script:Wg.Latest = $false
    Complete-WgDetail -Result @($storeInfo) -Failure $null -Context @{ Source = 'msstore'; Id = $storeInfo.Id }
    $wingetDialog.C.GRbStoreApp.IsChecked = $true
    $script:Wg.Delivery = 'store'; Update-WgPlan
    Assert-Test "A Store app can be delivered as Intune's Store app type" (
        $wingetDialog.C.GPnlDelivery.Visibility -eq 'Visible' -and $script:Wg.Plan.Delivery -eq 'store' -and
        $wingetDialog.C.GTxtPlan.Text -match "Intune's Microsoft Store app type installs") $wingetDialog.C.GTxtPlan.Text
    $script:Wg = $null

    Assert-Test 'A WinGet package opens with its card' (
        (Open-PackageFolder -Folder $communityPackage) -and $ui.PnlWinGet.Visibility -eq 'Visible' -and (Test-WinGetPackage) -and
        $ui.ChkWinGet.Visibility -eq 'Visible' -and $ui.WgTxtBadge.Text -eq 'WinGet community repository') $ui.WgTxtSummary.Text
    Assert-Test 'Its install script is the setup file, and it is ready to publish' (
        "$($ui.CmbSetup.SelectedItem)" -eq 'Install-WinGetApp.ps1' -and (Update-Readiness)) "$($ui.TxtReadyTitle.Text) — $($ui.ChkWinGet.Text)"
    Assert-Test "A WinGet id after the script is the script's argument, not a missing file" (
        $null -eq (Get-CommandFileIssue 'powershell.exe -File ".\Install-WinGetApp.ps1" -Id Foo.Bar.exe -Source winget'))
    $savedWinGet = (Get-Content -LiteralPath (Save-AppManifest) -Raw | ConvertFrom-Json).winget
    Assert-Test 'Saving keeps the WinGet settings' ($savedWinGet.id -eq 'Contoso.Tool' -and $savedWinGet.version -eq '2.1.0' -and $savedWinGet.installerType -eq 'wix')
    # What "Use the app's own icon" does with the icon the background lookup found
    Copy-Item -LiteralPath (Join-Path $iconTests 'program.png') -Destination (Join-Path $communityPackage 'icon.png') -Force
    Complete-WinGetIconLookup -Result @([pscustomobject]@{ File = 'icon.png'; From = 'the installer from downloads.contoso.example'; Size = 256 }) `
        -Failure $null -Context @{ Folder = $script:LoadedFolder }
    Assert-Test "A WinGet package takes the icon found for it, and app.json keeps it" (
        (Get-Content -LiteralPath $communityManifestPath -Raw | ConvertFrom-Json).icon -eq 'icon.png' -and
        $ui.TxtIconPath.Text -match 'downloads\.contoso\.example' -and $null -ne $ui.ImgIcon.Source) $ui.TxtIconPath.Text
    $ui.TxtInstall.Text = $ui.TxtInstall.Text + ' -Locale sv-SE'
    Assert-Test 'A command changed by hand is pointed out' ((Update-Readiness) -and $ui.TxtReadyWarn.Text -match 'install command was changed by hand') $ui.TxtReadyWarn.Text
    $realPolicy = ${function:Get-PackwrightPolicy}
    try {
        ${function:Get-PackwrightPolicy} = { param([string]$Path) [pscustomobject]@{ Path = 'Packwright.policy.json'; Exists = $true; AllowedSources = @('msstore')
            DefaultSource = 'msstore'; StoreMarket = 'SE'; StoreLocale = 'sv-SE'; StoreDelivery = 'win32'; RuntimeLink = 'requirement'
            RuntimeAppName = 'WinGet runtime'; Restricted = $true; Problems = @() } }
        $blocked = @(Get-WinGetBlocker)
        Assert-Test 'Under a Store-only policy the community package and its edited command are blocked' (
            -not (Update-Readiness) -and ($blocked -join ' ') -match 'Microsoft Store only' -and ($blocked -join ' ') -match 'changed by hand' -and
            -not (Test-ReadyToRun -ForPublish)) $ui.ChkWinGet.Text
    }
    finally { ${function:Get-PackwrightPolicy} = $realPolicy }
    $ui.TxtInstall.Text = (Get-WinGetCommandLine -WinGet $script:WinGetBlock).Install

    # Another version: the plan is carried into commands, scripts, detection and the label
    $olderInfo = $communityInfo.PSObject.Copy()
    $olderInfo.Version = '2.0.0'
    $olderEntry = [pscustomobject]@{ DisplayName = 'Contoso Tool 2.0'; DisplayVersion = '2.0.0'; ProductCode = '{99999999-2222-3333-4444-555555555555}'
                                     UpgradeCode = '{AAAAAAAA-2222-3333-4444-555555555555}'; Publisher = 'Contoso'; InstallerType = 'wix' }
    $olderInfo.Installers = @((& $newInstaller 'x64' 'wix' 'machine' '{99999999-2222-3333-4444-555555555555}' '' $olderEntry))
    Set-WinGetPlan -Plan (New-WinGetInstallPlan -Info $olderInfo -Policy $openPolicy) -Info $olderInfo
    $moved = Get-Content -LiteralPath $communityManifestPath -Raw | ConvertFrom-Json
    Assert-Test 'Moving to another version rewrites everything that depends on it' (
        $ui.TxtVersion.Text -eq '2.0.0' -and $ui.TxtInstall.Text -match '-Version 2\.0\.0' -and (Get-DetTypeValue) -eq 'script' -and
        $moved.winget.productCode -eq '{99999999-2222-3333-4444-555555555555}' -and $moved.winget.version -eq '2.0.0' -and
        $moved.winget.detect.kind -eq 'msi' -and $moved.winget.detect.minimumVersion -eq '2.0.0' -and
        (Get-Content -LiteralPath (Join-Path $communityPackage 'Detect-WinGetApp.ps1') -Raw) -match "minimumVersion = '2\.0\.0'" -and
        $moved.installCommandLine -match '-Version 2\.0\.0' -and @(Get-WinGetScriptState -Folder $communityPackage | Where-Object { $_.State -ne 'current' }).Count -eq 0) `
        "$($ui.TxtVersion.Text) / $($moved.installCommandLine)"
    Assert-Test 'Another version is published as an update of the app, not beside it' (
        $ui.ChkUpdateExisting.IsChecked -and -not $ui.ChkAllowDuplicate.IsChecked)

    Assert-Test 'An Intune Store app opens without a setup file, command or detection rule' (
        (Open-PackageFolder -Folder $storePackage) -and (Test-WinGetStoreApp) -and $ui.PnlDetectionCard.Visibility -eq 'Collapsed' -and
        $ui.BtnBuild.Visibility -eq 'Collapsed' -and (Update-Readiness) -and $ui.ChkSetup.Text -match 'Intune Store app: 9NSELFTEST01') $ui.TxtReadyTitle.Text
    $savedStore = Get-Content -LiteralPath (Save-AppManifest) -Raw | ConvertFrom-Json
    Assert-Test 'Saving an Intune Store app writes no command or detection rule' (
        -not $savedStore.installCommandLine -and -not $savedStore.detection -and $savedStore.winget.delivery -eq 'store' -and $savedStore.runAsAccount -eq 'system')
    [void](Open-PackageFolder -Folder $scaffolded -PreferSetup 'nsis.exe')
    Assert-Test 'An ordinary package shows no WinGet card' ($ui.PnlWinGet.Visibility -eq 'Collapsed' -and $ui.PnlDetectionCard.Visibility -eq 'Visible' -and $ui.BtnBuild.Visibility -eq 'Visible')
    $ui.TxtLog.Clear()   # the edited command and the policy above are logged on purpose
}
#endregion
