<#
.SYNOPSIS
    Deconstructs a .intunewin file: shows metadata, lists or extracts the content.
    Run without parameters to open the GUI.

.DESCRIPTION
    A .intunewin file (created with IntuneWinAppUtil/Content Prep Tool) is a ZIP with two parts:

      IntuneWinPackage/Metadata/Detection.xml           - metadata + encryption keys (in clear text!)
      IntuneWinPackage/Contents/IntunePackage.intunewin - the encrypted content

    The encrypted content has this layout:
      byte 0-31   HMAC-SHA256 over the rest of the file (key: MacKey from Detection.xml)
      byte 32-47  IV
      byte 48-    AES-256-CBC encrypted ZIP of the original source folder

    The script decrypts in a streaming fashion (handles large packages without loading
    everything into memory), verifies the HMAC and SHA256 digest against Detection.xml,
    and extracts the source files. Useful for troubleshooting and package review - e.g.
    to see exactly which files and scripts a third-party package contains, or to recover
    a lost source folder.

    Modes:
      (no args)   Open the GUI (browse or drag-and-drop a package).
      (default)   Extract all content to -Destination and show a summary.
      -Info       Show metadata from Detection.xml only (no decryption).
      -List       Decrypt and list the files in the package without extracting them.
      -Gui        Open the GUI, optionally preloaded with -Path.

.PARAMETER Path
    Path to the .intunewin file. If omitted, the GUI opens.

.PARAMETER Destination
    Folder to extract into. Default: "<file name without extension>-extracted" next to
    the file. The folder must not already exist (use -Force to overwrite).

.PARAMETER Info
    Show metadata only (app name, setup file, sizes, MSI info; keys are masked).
    Returns an object.

.PARAMETER List
    Decrypt and list the content (relative path, size) without writing any files.
    Returns one object per file.

.PARAMETER Force
    Overwrite -Destination if the folder already exists.

.PARAMETER ShowKeys
    Show the encryption key and MAC key in clear text in -Info mode
    (they are readable by anyone who opens the file anyway, but are masked by default).

.PARAMETER PassThru
    Return a result object in extract mode as well.

.PARAMETER Gui
    Open the GUI. Combine with -Path to preload a package.

.EXAMPLE
    .\Expand-IntuneWin.ps1
    Opens the GUI. Browse or drop an .intunewin file to inspect and extract it.

.EXAMPLE
    .\Expand-IntuneWin.ps1 .\Invoke-AppDeployToolkit.intunewin
    Extracts the package to .\Invoke-AppDeployToolkit-extracted\ and shows a summary.

.EXAMPLE
    .\Expand-IntuneWin.ps1 .\app.intunewin -Info
    Shows app name, setup file, sizes and any MSI metadata without decrypting.

.EXAMPLE
    .\Expand-IntuneWin.ps1 .\app.intunewin -List | Sort-Object Size -Descending | Select-Object -First 10
    Lists the ten largest files in the package.

.EXAMPLE
    .\Expand-IntuneWin.ps1 .\app.intunewin -Destination C:\Temp\review -Force
    Extracts to the given folder, overwriting previous content.

.NOTES
    Version: 1.1
    Author: Love Arvidsson
    Date: 2026-07-10
    Changelog
        - v1.0: Initial script creation.
        - v1.1: Added WPF GUI (default when run without parameters), translated to English.

    Works in Windows PowerShell 5.1 and PowerShell 7+.
    Integrity: an HMAC mismatch always aborts (corrupt or tampered file).
#>
[CmdletBinding(DefaultParameterSetName = 'Extract')]
param (
    [Parameter(Position = 0)]
    [string]$Path,

    [Parameter(ParameterSetName = 'Extract', Position = 1)]
    [string]$Destination,

    [Parameter(ParameterSetName = 'Info', Mandatory)]
    [switch]$Info,

    [Parameter(ParameterSetName = 'List', Mandatory)]
    [switch]$List,

    [Parameter(ParameterSetName = 'Extract')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Info')]
    [switch]$ShowKeys,

    [Parameter(ParameterSetName = 'Extract')]
    [switch]$PassThru,

    [Parameter(ParameterSetName = 'Extract')]
    [switch]$Gui
)

$ErrorActionPreference = 'Stop'

#region Core (shared by CLI and GUI; also injected into background runspaces)

$core = {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

    function Format-Size {
        param ([long]$Bytes)
        if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
        if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
        if ($Bytes -ge 1KB) { return '{0:N1} kB' -f ($Bytes / 1KB) }
        return "$Bytes B"
    }

    # Parses the outer ZIP and Detection.xml. Cheap - no decryption.
    function Get-IntuneWinMetadata {
        param ([Parameter(Mandatory)][string]$FilePath)

        $file = Get-Item -LiteralPath $FilePath
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
        } catch {
            throw "Could not open '$($file.Name)' as a ZIP archive. Is it a real .intunewin created by IntuneWinAppUtil? (Files downloaded straight from Intune storage are only the encrypted payload and have no metadata.)"
        }
        try {
            $detectionEntry = $zip.Entries | Where-Object { $_.FullName -match 'Metadata/Detection\.xml$' } | Select-Object -First 1
            if (-not $detectionEntry) {
                throw "No IntuneWinPackage/Metadata/Detection.xml found in '$($file.Name)' - not a valid .intunewin package."
            }
            $reader = New-Object System.IO.StreamReader($detectionEntry.Open())
            [xml]$detection = $reader.ReadToEnd()
            $reader.Close()

            $app = $detection.ApplicationInfo
            $enc = $app.EncryptionInfo
            if (-not $enc -or -not $enc.EncryptionKey) {
                throw 'Detection.xml has no EncryptionInfo - cannot decrypt the package.'
            }

            $unencryptedSize = [long]0
            if ($app.UnencryptedContentSize) { $unencryptedSize = [long]$app.UnencryptedContentSize }
            $innerName = 'IntunePackage.intunewin'
            if ($app.FileName) { $innerName = $app.FileName }

            $msi = $null
            if ($app.MsiInfo) {
                $msi = [pscustomobject]@{
                    ProductCode      = $app.MsiInfo.MsiProductCode
                    ProductVersion   = $app.MsiInfo.MsiProductVersion
                    UpgradeCode      = $app.MsiInfo.MsiUpgradeCode
                    ExecutionContext = $app.MsiInfo.MsiExecutionContext
                    Publisher        = $app.MsiInfo.MsiPublisher
                }
            }

            return [pscustomobject]@{
                File                = $file.FullName
                Name                = $app.Name
                SetupFile           = $app.SetupFile
                ToolVersion         = $app.ToolVersion
                PackedSize          = [long]$file.Length
                UnpackedSize        = $unencryptedSize
                EncryptionKey       = $enc.EncryptionKey
                MacKey              = $enc.MacKey
                IV                  = $enc.InitializationVector
                Mac                 = $enc.Mac
                FileDigest          = $enc.FileDigest
                FileDigestAlgorithm = $enc.FileDigestAlgorithm
                InnerFileName       = $innerName
                MsiInfo             = $msi
            }
        } finally {
            $zip.Dispose()
        }
    }

    # Decrypts the inner package (streaming) to a temporary ZIP file.
    # Verifies the HMAC (throws on mismatch) and the SHA256 digest against Detection.xml.
    # Returns TempZip + Warnings - the caller is responsible for deleting the temp file.
    function ConvertFrom-EncryptedPackage {
        param (
            [Parameter(Mandatory)][string]$FilePath,
            [scriptblock]$OnProgress
        )

        $meta = Get-IntuneWinMetadata -FilePath $FilePath
        $warnings = New-Object System.Collections.Generic.List[string]
        $zip = [System.IO.Compression.ZipFile]::OpenRead($meta.File)
        $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) ("intunewin-{0}.zip" -f [guid]::NewGuid())
        $inStream = $null; $decStream = $null; $hmac = $null; $sha = $null; $aes = $null
        try {
            $packageEntry = $zip.Entries | Where-Object { $_.FullName -match 'Contents/.+$' -and $_.Name -eq $meta.InnerFileName } | Select-Object -First 1
            if (-not $packageEntry) {
                $packageEntry = $zip.Entries | Where-Object { $_.FullName -match 'Contents/.+$' } | Select-Object -First 1
            }
            if (-not $packageEntry) {
                throw "No content found under IntuneWinPackage/Contents/ in '$([System.IO.Path]::GetFileName($meta.File))'."
            }

            $inStream = $packageEntry.Open()

            # Header: 32 byte HMAC + 16 byte IV
            $header = New-Object byte[] 48
            $read = 0
            while ($read -lt 48) {
                $n = $inStream.Read($header, $read, 48 - $read)
                if ($n -le 0) { throw 'The file is too short to be a valid encrypted package.' }
                $read += $n
            }
            $storedHmac = $header[0..31]
            $iv = $header[32..47]

            $aes = [System.Security.Cryptography.Aes]::Create()
            $aes.Key = [Convert]::FromBase64String($meta.EncryptionKey)
            $aes.IV = $iv

            $hmac = New-Object System.Security.Cryptography.HMACSHA256(, [Convert]::FromBase64String($meta.MacKey))
            $sha = [System.Security.Cryptography.SHA256]::Create()

            # The HMAC covers IV + ciphertext
            [void]$hmac.TransformBlock($iv, 0, 16, $null, 0)

            # Chain: ciphertext -> AES decryption -> SHA256 of the plaintext -> temp ZIP
            $fileStream = [System.IO.File]::Create($tempZip)
            $shaStream = New-Object System.Security.Cryptography.CryptoStream($fileStream, $sha, [System.Security.Cryptography.CryptoStreamMode]::Write)
            $decStream = New-Object System.Security.Cryptography.CryptoStream($shaStream, $aes.CreateDecryptor(), [System.Security.Cryptography.CryptoStreamMode]::Write)

            $buffer = New-Object byte[] 1MB
            $totalRead = [long]48
            $totalLength = $packageEntry.Length
            while (($n = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                [void]$hmac.TransformBlock($buffer, 0, $n, $null, 0)
                $decStream.Write($buffer, 0, $n)
                $totalRead += $n
                if ($OnProgress) { & $OnProgress $totalRead $totalLength }
            }
            [void]$hmac.TransformFinalBlock([byte[]]@(), 0, 0)
            $decStream.FlushFinalBlock()
            $decStream.Close(); $decStream = $null

            if ([Convert]::ToBase64String($hmac.Hash) -ne [Convert]::ToBase64String($storedHmac)) {
                throw 'HMAC verification failed - the file is corrupt, incomplete or has been tampered with.'
            }
            if ($meta.Mac -and [Convert]::ToBase64String($hmac.Hash) -ne $meta.Mac) {
                $warnings.Add('The HMAC in the file header is valid, but <Mac> in Detection.xml differs.')
            }
            if ($meta.FileDigest -and [Convert]::ToBase64String($sha.Hash) -ne $meta.FileDigest) {
                $warnings.Add('SHA256 of the decrypted content does not match <FileDigest> in Detection.xml.')
            }
            $actualSize = (Get-Item -LiteralPath $tempZip).Length
            if ($meta.UnpackedSize -gt 0 -and $actualSize -ne $meta.UnpackedSize) {
                $warnings.Add("Decrypted size ($actualSize) differs from <UnencryptedContentSize> ($($meta.UnpackedSize)).")
            }
            return [pscustomobject]@{
                TempZip  = $tempZip
                Warnings = $warnings.ToArray()
                Metadata = $meta
            }
        } catch {
            if ($decStream) { try { $decStream.Close() } catch {} ; $decStream = $null }
            Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
            throw
        } finally {
            if ($decStream) { try { $decStream.Close() } catch {} }
            if ($inStream) { $inStream.Close() }
            if ($hmac) { $hmac.Dispose() }
            if ($sha) { $sha.Dispose() }
            if ($aes) { $aes.Dispose() }
            $zip.Dispose()
        }
    }

    # Lists the files inside a decrypted (inner) ZIP.
    function Get-InnerFileList {
        param ([Parameter(Mandatory)][string]$ZipPath)
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            foreach ($entry in $zip.Entries) {
                if (-not $entry.Name) { continue }  # skip pure directory entries
                [pscustomobject]@{
                    Path       = $entry.FullName
                    Size       = [long]$entry.Length
                    Compressed = [long]$entry.CompressedLength
                }
            }
        } finally {
            $zip.Dispose()
        }
    }

    # Extracts a decrypted (inner) ZIP to a folder, with a path traversal guard.
    function Expand-InnerZip {
        param (
            [Parameter(Mandatory)][string]$ZipPath,
            [Parameter(Mandatory)][string]$Destination,
            [scriptblock]$OnProgress
        )
        $destRoot = (New-Item -ItemType Directory -Path $Destination -Force).FullName
        $rootPrefix = $destRoot.TrimEnd('\') + '\'
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            $fileEntries = @($zip.Entries | Where-Object { $_.Name })
            $count = 0
            foreach ($entry in $fileEntries) {
                $targetPath = [System.IO.Path]::GetFullPath((Join-Path $destRoot $entry.FullName))
                if (-not $targetPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Invalid path in package (path traversal attempt?): $($entry.FullName)"
                }
                $targetDir = Split-Path $targetPath -Parent
                if (-not (Test-Path -LiteralPath $targetDir)) { [void](New-Item -ItemType Directory -Path $targetDir -Force) }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
                $count++
                if ($OnProgress) { & $OnProgress $count $fileEntries.Count $entry.FullName }
            }
            return [pscustomobject]@{
                FileCount   = $count
                Destination = $destRoot
            }
        } finally {
            $zip.Dispose()
        }
    }

    # Saves the raw Detection.xml from a package to a file.
    function Export-DetectionXml {
        param (
            [Parameter(Mandatory)][string]$FilePath,
            [Parameter(Mandatory)][string]$OutFile
        )
        $zip = [System.IO.Compression.ZipFile]::OpenRead((Get-Item -LiteralPath $FilePath).FullName)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -match 'Metadata/Detection\.xml$' } | Select-Object -First 1
            if (-not $entry) { throw 'No Detection.xml found in the package.' }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $OutFile, $true)
        } finally {
            $zip.Dispose()
        }
    }
}
. $core
$script:CoreText = $core.ToString()

#endregion

#region GUI

$script:DecryptWork = @'
$ErrorActionPreference = 'Stop'
try {
    $sync.State = 'decrypting'
    $sync.Progress = 0
    $res = ConvertFrom-EncryptedPackage -FilePath $sync.FilePath -OnProgress {
        param($done, $total)
        if ($total -gt 0) { $sync.Progress = [math]::Min(100, 100 * $done / $total) }
        $sync.StatusText = "Decrypting... $(Format-Size $done) / $(Format-Size $total)"
    }
    $sync.TempZip = $res.TempZip
    $sync.Warnings = $res.Warnings
    $sync.Files = @(Get-InnerFileList -ZipPath $res.TempZip)
    $sync.State = 'listed'
} catch {
    $sync.Error = $_.Exception.Message
    $sync.ErrorPhase = 'decrypt'
    $sync.State = 'error'
}
'@

$script:ExtractWork = @'
$ErrorActionPreference = 'Stop'
try {
    $sync.State = 'extracting'
    $sync.Progress = 0
    $res = Expand-InnerZip -ZipPath $sync.TempZip -Destination $sync.Destination -OnProgress {
        param($i, $n, $name)
        $sync.Progress = 100 * $i / $n
        $sync.StatusText = "Extracting ($i/$n): $name"
    }
    $sync.ExtractCount = $res.FileCount
    $sync.ExtractPath = $res.Destination
    $sync.State = 'extracted'
} catch {
    $sync.Error = $_.Exception.Message
    $sync.ErrorPhase = 'extract'
    $sync.State = 'error'
}
'@

function Stop-GuiBackground {
    if ($script:bgPS) {
        try { $script:bgPS.Stop() } catch {}
        try { $script:bgPS.Dispose() } catch {}
    }
    if ($script:bgRS) {
        try { $script:bgRS.Dispose() } catch {}
    }
    $script:bgPS = $null
    $script:bgRS = $null
}

function Start-GuiBackground {
    param ([Parameter(Mandatory)][string]$WorkScript)
    Stop-GuiBackground
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $script:sync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:CoreText + "`n" + $WorkScript)
    [void]$ps.BeginInvoke()
    $script:bgPS = $ps
    $script:bgRS = $rs
}

function Set-GuiBadge {
    param ([string]$Mode)
    $bc = New-Object Windows.Media.BrushConverter
    switch ($Mode) {
        'ok'      { $bg = '#DCFCE7'; $fg = '#166534'; $text = 'HMAC OK' }
        'fail'    { $bg = '#FEE2E2'; $fg = '#991B1B'; $text = 'FAILED' }
        'pending' { $bg = '#FEF9C3'; $fg = '#854D0E'; $text = 'Verifying...' }
        default   { $bg = '#E5E7EB'; $fg = '#374151'; $text = '-' }
    }
    $script:ui.HmacBadge.Background = $bc.ConvertFromString($bg)
    $script:ui.HmacText.Foreground = $bc.ConvertFromString($fg)
    $script:ui.HmacText.Text = $text
}

function Update-GuiFilter {
    if (-not $script:dataTable) { return }
    $text = $script:ui.FilterBox.Text
    if ([string]::IsNullOrWhiteSpace($text)) {
        $script:dataTable.DefaultView.RowFilter = ''
    } else {
        $escaped = ($text -replace '([\[\]%*])', '[$1]') -replace "'", "''"
        $script:dataTable.DefaultView.RowFilter = "Path LIKE '%$escaped%'"
    }
    $visible = $script:dataTable.DefaultView.Count
    $total = $script:dataTable.Rows.Count
    if ($visible -ne $total) {
        $script:ui.CountText.Text = '{0} of {1} files' -f $visible, $total
    } else {
        $script:ui.CountText.Text = $script:countAllText
    }
}

function Invoke-GuiLoadFile {
    param ([Parameter(Mandatory)][string]$FilePath)

    Stop-GuiBackground
    if ($script:sync.TempZip -and (Test-Path -LiteralPath $script:sync.TempZip)) {
        Remove-Item -LiteralPath $script:sync.TempZip -Force -ErrorAction SilentlyContinue
    }
    try {
        $meta = Get-IntuneWinMetadata -FilePath $FilePath
    } catch {
        [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'Expand-IntuneWin', 'OK', 'Warning')
        return
    }
    $script:meta = $meta
    $ui = $script:ui
    $ui.FileBox.Text = $meta.File
    $ui.AppName.Text = $meta.Name
    $ui.SetupText.Text = '' + $meta.SetupFile
    $ui.ToolText.Text = '' + $meta.ToolVersion
    $ui.PackedText.Text = Format-Size $meta.PackedSize
    $ui.UnpackedText.Text = Format-Size $meta.UnpackedSize
    if ($meta.MsiInfo) {
        $ui.MsiProductText.Text = '' + $meta.MsiInfo.ProductCode
        $ui.MsiVersionText.Text = '' + $meta.MsiInfo.ProductVersion
        $ui.MsiPublisherText.Text = '' + $meta.MsiInfo.Publisher
        $ui.MsiPanel.Visibility = 'Visible'
    } else {
        $ui.MsiPanel.Visibility = 'Collapsed'
    }
    $ui.SaveXmlBtn.IsEnabled = $true
    $ui.ExtractBtn.IsEnabled = $false
    $ui.OpenBtn.IsEnabled = $false
    $ui.DestBtn.IsEnabled = $false
    $ui.FilterBox.Text = ''
    $ui.FilterBox.IsEnabled = $false
    $ui.FilesGrid.ItemsSource = $null
    $script:dataTable = $null
    $script:countAllText = ''
    $ui.CountText.Text = ''
    $ui.Progress.Value = 0
    Set-GuiBadge pending
    $base = [System.IO.Path]::GetFileNameWithoutExtension($meta.File)
    $ui.DestBox.Text = Join-Path (Split-Path -Parent $meta.File) ($base + '-extracted')
    $ui.StatusText.Foreground = [Windows.Media.Brushes]::DimGray
    $ui.StatusText.Text = 'Decrypting and verifying...'

    $script:sync.Clear()
    $script:sync.State = 'starting'
    $script:sync.FilePath = $meta.File
    Start-GuiBackground -WorkScript $script:DecryptWork
}

function Invoke-GuiExtract {
    $dest = $script:ui.DestBox.Text.Trim()
    if (-not $dest) {
        [void][System.Windows.MessageBox]::Show('Choose a destination folder first.', 'Expand-IntuneWin', 'OK', 'Information')
        return
    }
    if (Test-Path -LiteralPath $dest) {
        $existing = @(Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0) {
            $answer = [System.Windows.MessageBox]::Show(
                "The folder already exists and is not empty:`n$dest`n`nFiles with the same names will be overwritten. Continue?",
                'Expand-IntuneWin', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
        }
    }
    $script:sync.Destination = $dest
    $script:ui.ExtractBtn.IsEnabled = $false
    $script:ui.OpenBtn.IsEnabled = $false
    Start-GuiBackground -WorkScript $script:ExtractWork
}

function Update-GuiTick {
    $s = $script:sync
    $state = $s.State

    if ($state -eq 'decrypting' -or $state -eq 'extracting') {
        if ($s.Progress) { $script:ui.Progress.Value = $s.Progress }
        if ($s.StatusText) { $script:ui.StatusText.Text = $s.StatusText }
        return
    }
    if ($state -eq 'listed') {
        $s.State = 'ready'
        $script:ui.Progress.Value = 100
        $files = @($s.Files)
        $dt = New-Object System.Data.DataTable
        [void]$dt.Columns.Add('Path', [string])
        [void]$dt.Columns.Add('Size', [long])
        [void]$dt.Columns.Add('Compressed', [long])
        foreach ($f in $files) { [void]$dt.Rows.Add($f.Path, [long]$f.Size, [long]$f.Compressed) }
        $script:dataTable = $dt
        $script:ui.FilesGrid.ItemsSource = $dt.DefaultView
        $totalSize = ($files | Measure-Object -Property Size -Sum).Sum
        if (-not $totalSize) { $totalSize = 0 }
        $script:countAllText = '{0} files, {1}' -f $files.Count, (Format-Size $totalSize)
        $script:ui.CountText.Text = $script:countAllText
        Set-GuiBadge ok
        $script:ui.FilterBox.IsEnabled = $true
        $script:ui.ExtractBtn.IsEnabled = $true
        $script:ui.DestBtn.IsEnabled = $true
        if (@($s.Warnings).Count -gt 0) {
            $script:ui.StatusText.Foreground = [Windows.Media.Brushes]::DarkOrange
            $script:ui.StatusText.Text = 'Verified with warnings: ' + (@($s.Warnings) -join ' | ')
        } else {
            $script:ui.StatusText.Foreground = [Windows.Media.Brushes]::ForestGreen
            $script:ui.StatusText.Text = 'Content verified and decrypted - ready to extract.'
        }
        return
    }
    if ($state -eq 'extracted') {
        $s.State = 'ready'
        $script:ui.Progress.Value = 100
        $script:ui.ExtractBtn.IsEnabled = $true
        $script:ui.OpenBtn.IsEnabled = $true
        $script:ui.StatusText.Foreground = [Windows.Media.Brushes]::ForestGreen
        $script:ui.StatusText.Text = 'Done - {0} files extracted to {1}' -f $s.ExtractCount, $s.ExtractPath
        return
    }
    if ($state -eq 'error') {
        $s.State = 'idle'
        $script:ui.Progress.Value = 0
        $script:ui.StatusText.Foreground = [Windows.Media.Brushes]::Firebrick
        $script:ui.StatusText.Text = '' + $s.Error
        if ($s.ErrorPhase -eq 'decrypt') {
            Set-GuiBadge fail
        } else {
            $script:ui.ExtractBtn.IsEnabled = $true
        }
        return
    }
}

function Show-IntuneWinGui {
    param ([string]$InitialFile)

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Expand-IntuneWin" Width="980" Height="700" MinWidth="760" MinHeight="520"
        WindowStartupLocation="CenterScreen" AllowDrop="True"
        FontFamily="Segoe UI" FontSize="12" Background="#F3F4F6">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#C8CCD2"/>
    </Style>
    <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#0F6CBD"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#0F6CBD"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="MetaLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#6B7280"/>
      <Setter Property="Margin" Value="0,2,8,2"/>
    </Style>
    <Style x:Key="MetaValue" TargetType="TextBlock">
      <Setter Property="Margin" Value="0,2,24,2"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
  </Window.Resources>
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" Margin="0,0,0,10">
      <Button Name="SaveXmlBtn" DockPanel.Dock="Right" IsEnabled="False">Save Detection.xml...</Button>
      <Button Name="BrowseBtn" DockPanel.Dock="Right">Browse...</Button>
      <TextBox Name="FileBox" IsReadOnly="True" VerticalContentAlignment="Center" Padding="6,4"/>
    </DockPanel>

    <Border Grid.Row="1" Background="White" BorderBrush="#E2E5E9" BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Name="AppName" FontSize="16" FontWeight="SemiBold" Text="No package loaded" TextTrimming="CharacterEllipsis"/>
          <WrapPanel Margin="0,6,0,0">
            <TextBlock Style="{StaticResource MetaLabel}" Text="Setup file:"/>
            <TextBlock Name="SetupText" Style="{StaticResource MetaValue}"/>
            <TextBlock Style="{StaticResource MetaLabel}" Text="Tool version:"/>
            <TextBlock Name="ToolText" Style="{StaticResource MetaValue}"/>
            <TextBlock Style="{StaticResource MetaLabel}" Text="Packed:"/>
            <TextBlock Name="PackedText" Style="{StaticResource MetaValue}"/>
            <TextBlock Style="{StaticResource MetaLabel}" Text="Unpacked:"/>
            <TextBlock Name="UnpackedText" Style="{StaticResource MetaValue}"/>
          </WrapPanel>
          <WrapPanel Name="MsiPanel" Margin="0,2,0,0" Visibility="Collapsed">
            <TextBlock Style="{StaticResource MetaLabel}" Text="MSI product code:"/>
            <TextBlock Name="MsiProductText" Style="{StaticResource MetaValue}"/>
            <TextBlock Style="{StaticResource MetaLabel}" Text="MSI version:"/>
            <TextBlock Name="MsiVersionText" Style="{StaticResource MetaValue}"/>
            <TextBlock Style="{StaticResource MetaLabel}" Text="Publisher:"/>
            <TextBlock Name="MsiPublisherText" Style="{StaticResource MetaValue}"/>
          </WrapPanel>
        </StackPanel>
        <Border Grid.Column="1" Name="HmacBadge" CornerRadius="10" Padding="10,3" Background="#E5E7EB" VerticalAlignment="Top">
          <TextBlock Name="HmacText" Text="-" Foreground="#374151" FontWeight="SemiBold"/>
        </Border>
      </Grid>
    </Border>

    <DockPanel Grid.Row="2" Margin="0,0,0,6">
      <TextBlock Name="CountText" DockPanel.Dock="Right" VerticalAlignment="Center" Foreground="#6B7280"/>
      <TextBlock Text="Filter:" VerticalAlignment="Center" Margin="0,0,6,0" Foreground="#6B7280"/>
      <TextBox Name="FilterBox" Width="280" HorizontalAlignment="Left" Padding="6,3" IsEnabled="False"/>
    </DockPanel>

    <DataGrid Grid.Row="3" Name="FilesGrid" AutoGenerateColumns="False" IsReadOnly="True"
              HeadersVisibility="Column" GridLinesVisibility="None"
              AlternatingRowBackground="#F8F9FB" Background="White"
              BorderBrush="#E2E5E9" BorderThickness="1"
              CanUserAddRows="False" SelectionMode="Extended" RowHeight="22">
      <DataGrid.Columns>
        <DataGridTextColumn Header="Path" Binding="{Binding Path}" Width="*"/>
        <DataGridTextColumn Header="Size" Binding="{Binding Size, StringFormat=N0}" Width="110">
          <DataGridTextColumn.ElementStyle>
            <Style TargetType="TextBlock">
              <Setter Property="TextAlignment" Value="Right"/>
              <Setter Property="Margin" Value="0,0,8,0"/>
            </Style>
          </DataGridTextColumn.ElementStyle>
        </DataGridTextColumn>
        <DataGridTextColumn Header="Compressed" Binding="{Binding Compressed, StringFormat=N0}" Width="110">
          <DataGridTextColumn.ElementStyle>
            <Style TargetType="TextBlock">
              <Setter Property="TextAlignment" Value="Right"/>
              <Setter Property="Margin" Value="0,0,8,0"/>
            </Style>
          </DataGridTextColumn.ElementStyle>
        </DataGridTextColumn>
      </DataGrid.Columns>
    </DataGrid>

    <DockPanel Grid.Row="4" Margin="0,10,0,0">
      <Button Name="OpenBtn" DockPanel.Dock="Right" IsEnabled="False">Open folder</Button>
      <Button Name="ExtractBtn" DockPanel.Dock="Right" Style="{StaticResource Accent}" IsEnabled="False">Extract</Button>
      <Button Name="DestBtn" DockPanel.Dock="Right" IsEnabled="False">...</Button>
      <TextBlock Text="Extract to:" VerticalAlignment="Center" Margin="0,0,6,0" Foreground="#6B7280"/>
      <TextBox Name="DestBox" Padding="6,4" VerticalContentAlignment="Center"/>
    </DockPanel>

    <Grid Grid.Row="5" Margin="0,8,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="200"/>
      </Grid.ColumnDefinitions>
      <TextBlock Name="StatusText" Text="Open an .intunewin file, or drop one here." Foreground="#6B7280" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      <ProgressBar Grid.Column="1" Name="Progress" Height="8" Minimum="0" Maximum="100" VerticalAlignment="Center"/>
    </Grid>
  </Grid>
</Window>
'@

    $script:window = [Windows.Markup.XamlReader]::Parse($xaml)
    $script:ui = @{}
    foreach ($name in @('FileBox', 'BrowseBtn', 'SaveXmlBtn', 'AppName', 'SetupText', 'ToolText',
            'PackedText', 'UnpackedText', 'MsiPanel', 'MsiProductText', 'MsiVersionText', 'MsiPublisherText',
            'HmacBadge', 'HmacText', 'FilterBox', 'CountText', 'FilesGrid',
            'DestBox', 'DestBtn', 'ExtractBtn', 'OpenBtn', 'StatusText', 'Progress')) {
        $script:ui[$name] = $script:window.FindName($name)
    }

    $script:sync = [hashtable]::Synchronized(@{ State = 'idle' })
    $script:bgPS = $null
    $script:bgRS = $null
    $script:dataTable = $null
    $script:countAllText = ''
    $script:meta = $null

    $script:ui.BrowseBtn.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'IntuneWin packages (*.intunewin)|*.intunewin|All files (*.*)|*.*'
        if ($dlg.ShowDialog()) { Invoke-GuiLoadFile -FilePath $dlg.FileName }
    })
    $script:ui.SaveXmlBtn.Add_Click({
        if (-not $script:meta) { return }
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.FileName = 'Detection.xml'
        $dlg.Filter = 'XML files (*.xml)|*.xml|All files (*.*)|*.*'
        if ($dlg.ShowDialog()) {
            try {
                Export-DetectionXml -FilePath $script:meta.File -OutFile $dlg.FileName
                $script:ui.StatusText.Foreground = [Windows.Media.Brushes]::DimGray
                $script:ui.StatusText.Text = 'Detection.xml saved to ' + $dlg.FileName
            } catch {
                [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'Expand-IntuneWin', 'OK', 'Error')
            }
        }
    })
    $script:ui.DestBtn.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Choose the folder to extract into'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:ui.DestBox.Text = $dlg.SelectedPath
        }
    })
    $script:ui.ExtractBtn.Add_Click({ Invoke-GuiExtract })
    $script:ui.OpenBtn.Add_Click({
        if ($script:sync.ExtractPath -and (Test-Path -LiteralPath $script:sync.ExtractPath)) {
            Invoke-Item -LiteralPath $script:sync.ExtractPath
        }
    })
    $script:ui.FilterBox.Add_TextChanged({ Update-GuiFilter })

    $script:window.Add_PreviewDragOver({
        param($dragSender, $e)
        if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
            $e.Effects = [Windows.DragDropEffects]::Copy
            $e.Handled = $true
        }
    })
    $script:window.Add_Drop({
        param($dropSender, $e)
        if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
            $dropped = @($e.Data.GetData([Windows.DataFormats]::FileDrop))
            if ($dropped.Count -gt 0) { Invoke-GuiLoadFile -FilePath $dropped[0] }
        }
    })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [timespan]::FromMilliseconds(200)
    $timer.Add_Tick({ Update-GuiTick })
    $timer.Start()

    # Smoke test hook: EXPAND_INTUNEWIN_AUTOCLOSE=<seconds> closes the window
    # automatically and reports the internal state (used by automated tests).
    if ($env:EXPAND_INTUNEWIN_AUTOCLOSE) {
        $autoTimer = New-Object System.Windows.Threading.DispatcherTimer
        $autoTimer.Interval = [timespan]::FromSeconds([double]$env:EXPAND_INTUNEWIN_AUTOCLOSE)
        $autoTimer.Add_Tick({
            Write-Host ('AUTOCLOSE state={0} files={1}' -f $script:sync.State, @($script:sync.Files).Count)
            $script:window.Close()
        })
        $autoTimer.Start()
    }

    if ($InitialFile) { Invoke-GuiLoadFile -FilePath $InitialFile }

    [void]$script:window.ShowDialog()

    $timer.Stop()
    Stop-GuiBackground
    if ($script:sync.TempZip -and (Test-Path -LiteralPath $script:sync.TempZip)) {
        Remove-Item -LiteralPath $script:sync.TempZip -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region Main

if ($PSCmdlet.ParameterSetName -eq 'Extract' -and (-not $Path -or $Gui)) {
    $initialFile = $null
    if ($Path) { $initialFile = (Get-Item -LiteralPath $Path).FullName }
    Show-IntuneWinGui -InitialFile $initialFile
    return
}
if (-not $Path) {
    throw 'Path is required when using -Info or -List.'
}

$meta = Get-IntuneWinMetadata -FilePath (Get-Item -LiteralPath $Path).FullName

if ($Info) {
    $mask = { param($v) if ($ShowKeys) { $v } else { $v -replace '(?<=^.{6}).+(?=.{4}$)', '...' } }
    $result = [ordered]@{
        File          = $meta.File
        Name          = $meta.Name
        SetupFile     = $meta.SetupFile
        ToolVersion   = $meta.ToolVersion
        PackedSize    = $meta.PackedSize
        UnpackedSize  = $meta.UnpackedSize
        EncryptionKey = & $mask $meta.EncryptionKey
        MacKey        = & $mask $meta.MacKey
        IV            = $meta.IV
        FileDigest    = '{0}: {1}' -f $meta.FileDigestAlgorithm, $meta.FileDigest
    }
    if ($meta.MsiInfo) {
        $result.MsiProductCode      = $meta.MsiInfo.ProductCode
        $result.MsiProductVersion   = $meta.MsiInfo.ProductVersion
        $result.MsiUpgradeCode      = $meta.MsiInfo.UpgradeCode
        $result.MsiExecutionContext = $meta.MsiInfo.ExecutionContext
        $result.MsiPublisher        = $meta.MsiInfo.Publisher
    }
    return [pscustomobject]$result
}

Write-Host 'Package : ' -NoNewline; Write-Host $meta.Name -ForegroundColor Cyan
Write-Host "Setup   : $($meta.SetupFile)"
Write-Host "Size    : $(Format-Size $meta.PackedSize) packed, $(Format-Size $meta.UnpackedSize) unpacked"

$res = ConvertFrom-EncryptedPackage -FilePath $meta.File -OnProgress {
    param($done, $total)
    if ($total -gt 0) {
        Write-Progress -Activity 'Decrypting package' -Status (Format-Size $done) -PercentComplete ([math]::Min(100, 100 * $done / $total))
    }
}
Write-Progress -Activity 'Decrypting package' -Completed
foreach ($w in $res.Warnings) { Write-Warning $w }
Write-Host 'HMAC    : ' -NoNewline; Write-Host 'OK' -ForegroundColor Green -NoNewline
Write-Host ' (content is intact and matches the keys in Detection.xml)'

try {
    if ($List) {
        return Get-InnerFileList -ZipPath $res.TempZip
    }

    if (-not $Destination) {
        $srcItem = Get-Item -LiteralPath $meta.File
        $Destination = Join-Path $srcItem.DirectoryName ($srcItem.BaseName + '-extracted')
    }
    if (Test-Path -LiteralPath $Destination) {
        if (-not $Force) {
            throw "The folder '$Destination' already exists. Use -Force to overwrite."
        }
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }

    $extractResult = Expand-InnerZip -ZipPath $res.TempZip -Destination $Destination -OnProgress {
        param($i, $n, $name)
        Write-Progress -Activity 'Extracting files' -Status $name -PercentComplete (100 * $i / $n)
    }
    Write-Progress -Activity 'Extracting files' -Completed

    Write-Host "Files   : $($extractResult.FileCount) extracted to " -NoNewline
    Write-Host $extractResult.Destination -ForegroundColor Cyan

    if ($PassThru) {
        [pscustomobject]@{
            Name         = $meta.Name
            SetupFile    = $meta.SetupFile
            Destination  = $extractResult.Destination
            FileCount    = $extractResult.FileCount
            UnpackedSize = $meta.UnpackedSize
            HmacValid    = $true
        }
    }
} finally {
    Remove-Item -LiteralPath $res.TempZip -Force -ErrorAction SilentlyContinue
}

#endregion
