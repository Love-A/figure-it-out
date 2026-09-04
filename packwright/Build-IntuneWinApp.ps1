<#
.SYNOPSIS
    Build Intune .intunewin packages with automatic output folder, logging, and safe overwrite handling.

.DESCRIPTION
    Advanced function wrapper for IntuneWinAppUtil.exe that:
      - Can be run directly with parameters:  .\Build-IntuneWinApp.ps1 -SourceFolder "C:\psadt\7-zip"
        or dot-sourced to load the Build-IntuneWinApp function into the session
      - Auto-detects the setup file when -SetupFile is omitted
        (Invoke-AppDeployToolkit.exe for PSADT packages, otherwise a single .msi in the folder)
      - Creates ".\Output\<PackageName>" (relative to the script) unless -OutputRoot is specified
      - Writes a per-build log into the output folder
      - Backs up an existing .intunewin as <name>-<timestamp>.bak.intunewin and prunes old
        backups beyond -KeepBackups (default 3)
      - -OverwriteExisting deletes the existing .intunewin instead of backing it up
      - -Clean purges the package output folder before build
      - -Quiet suppresses console echo (logs still written to file)
      - -PassThru returns a result object (path, SHA256, size, duration) that can be piped
        straight to Publish-IntuneWinApp for upload to Intune
      - Supports -WhatIf / -Confirm and pipeline input for batch builds

.PARAMETER SourceFolder
    Folder containing installation files (e.g., C:\psadt\MSOLEDB 18.7.5). Accepts pipeline input.

.PARAMETER SetupFile
    Setup file located inside SourceFolder. Optional: auto-detected if the folder contains
    Invoke-AppDeployToolkit.exe or exactly one .msi file.

.PARAMETER OutputRoot
    Optional base output folder. Defaults to ".\Output" relative to the script file.

.PARAMETER OverwriteExisting
    If specified, removes an existing expected .intunewin file instead of renaming it.

.PARAMETER Clean
    If specified, removes the package output folder (OutputRoot\<PackageName>) before build.

.PARAMETER Quiet
    If specified, logs only to file (no console echo).

.PARAMETER PassThru
    If specified, outputs a result object with the produced .intunewin path, hash, size and duration.

.PARAMETER KeepBackups
    Number of *.bak.intunewin backups to keep per package folder. Older backups are removed
    after a successful build. Default: 3.

.EXAMPLE
    .\Build-IntuneWinApp.ps1 -SourceFolder "C:\psadt\MSOLEDB 18.7.5"

    Runs the script directly; the setup file (Invoke-AppDeployToolkit.exe) is auto-detected.

.EXAMPLE
    Build-IntuneWinApp -SourceFolder "D:\Apps\7zip" -SetupFile "Invoke-AppDeployToolkit.exe" -OverwriteExisting -PassThru

.EXAMPLE
    Build-IntuneWinApp -SourceFolder "C:\psadt\7-zip" -PassThru | Publish-IntuneWinApp

    Builds the package and creates/uploads the Win32 app in Intune (see Publish-IntuneWinApp.ps1).

.EXAMPLE
    Get-ChildItem "C:\psadt" -Directory | Build-IntuneWinApp -PassThru

    Batch-builds every package folder under C:\psadt.

.NOTES
    Author    : Love A
    File Name : Build-IntuneWinApp.ps1 (can be used as a module .psm1 as well)
.VERSION
    2026-07-07 - 2.1 - Auto-download IntuneWinAppUtil.exe from GitHub when missing
    2026-07-06 - 2.0 - Direct script invocation with parameters (no more editing the last line),
                       setup file auto-detection, deterministic output detection, backup pruning,
                       rich -PassThru object (SHA256/size/duration), fixed console echo and
                       output stream pollution, pipeline input for batch builds
    2025-09-24 - 1.0 - Initial advanced function version (SupportsShouldProcess, -Clean, -Quiet, -PassThru)
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [string]$SourceFolder,

    [Parameter(Position = 1)]
    [string]$SetupFile,

    [string]$OutputRoot,

    [switch]$OverwriteExisting,

    [switch]$Clean,

    [switch]$Quiet,

    [switch]$PassThru,

    [int]$KeepBackups
)

function Build-IntuneWinApp {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName', 'Path')]
        [ValidateNotNullOrEmpty()]
        [string]$SourceFolder,

        [Parameter(Position = 1, ValueFromPipelineByPropertyName = $true)]
        [string]$SetupFile,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputRoot = (Join-Path -Path $PSScriptRoot -ChildPath 'Output'),

        [Parameter(Mandatory = $false)]
        [switch]$OverwriteExisting,

        [Parameter(Mandatory = $false)]
        [switch]$Clean,

        [Parameter(Mandatory = $false)]
        [switch]$Quiet,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 100)]
        [int]$KeepBackups = 3
    )

    begin {
        # File + console logger. Console echo uses Write-Host so the output stream stays
        # clean for -PassThru; file writes are skipped until the output folder exists (-WhatIf).
        function Write-BuildLog {
            param(
                [string]$Message,
                [ValidateSet('INFO', 'WARN', 'ERROR')]
                [string]$Level = 'INFO',
                [string]$LogFile
            )
            $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
            if ($LogFile -and (Test-Path -LiteralPath (Split-Path -Path $LogFile -Parent))) {
                Add-Content -LiteralPath $LogFile -Value $line
            }
            if (-not $Quiet) {
                switch ($Level) {
                    'WARN'  { Write-Host $line -ForegroundColor Yellow }
                    'ERROR' { Write-Host $line -ForegroundColor Red }
                    default { Write-Host $line }
                }
            }
        }

        # Resolve tool path once (same folder as this script, with fallback). The exe is
        # Microsoft's and not redistributed with these scripts — download on first use.
        $toolPath = Join-Path -Path $PSScriptRoot -ChildPath 'IntuneWinAppUtil.exe'
        if (-not (Test-Path -LiteralPath $toolPath)) {
            $alt = 'C:\IntuneWinAppUtil\IntuneWinAppUtil.exe'
            if (Test-Path -LiteralPath $alt) { $toolPath = $alt }
        }
        if (-not (Test-Path -LiteralPath $toolPath)) {
            $toolUrl  = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe'
            $toolPath = Join-Path -Path $PSScriptRoot -ChildPath 'IntuneWinAppUtil.exe'
            if ($PSCmdlet.ShouldProcess($toolPath, "Download IntuneWinAppUtil.exe from $toolUrl")) {
                Write-Host 'IntuneWinAppUtil.exe not found — downloading from microsoft/Microsoft-Win32-Content-Prep-Tool...'
                try {
                    Invoke-WebRequest -Uri $toolUrl -OutFile $toolPath -UseBasicParsing
                }
                catch {
                    throw "IntuneWinAppUtil.exe is missing and the download failed ($($_.Exception.Message)). Download it manually from https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool and place it next to this script."
                }
            }
        }
        if (-not (Test-Path -LiteralPath $toolPath)) {
            throw "IntuneWinAppUtil.exe not found at '$toolPath'. Download it from https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool and place it next to this script."
        }
    }

    process {
        $started = Get-Date

        if (-not (Test-Path -LiteralPath $SourceFolder -PathType Container)) {
            throw "SourceFolder not found: $SourceFolder"
        }
        $resolvedSource = (Resolve-Path -LiteralPath $SourceFolder).Path

        # Auto-detect setup file if not specified (kept in a local so pipeline items don't inherit it)
        $setup = $SetupFile
        if (-not $setup) {
            if (Test-Path -LiteralPath (Join-Path -Path $resolvedSource -ChildPath 'Invoke-AppDeployToolkit.exe')) {
                $setup = 'Invoke-AppDeployToolkit.exe'
            }
            else {
                $msiFiles = @(Get-ChildItem -LiteralPath $resolvedSource -Filter *.msi -File)
                if ($msiFiles.Count -eq 1) {
                    $setup = $msiFiles[0].Name
                }
                else {
                    throw "Could not auto-detect setup file in '$resolvedSource' (no Invoke-AppDeployToolkit.exe, found $($msiFiles.Count) .msi files). Specify -SetupFile."
                }
            }
        }
        $setupFullPath = Join-Path -Path $resolvedSource -ChildPath $setup
        if (-not (Test-Path -LiteralPath $setupFullPath)) {
            throw "SetupFile not found under SourceFolder: $setupFullPath"
        }

        $packageName  = Split-Path -Path $resolvedSource -Leaf
        $outputFolder = Join-Path -Path $OutputRoot -ChildPath $packageName

        if ($Clean -and (Test-Path -LiteralPath $outputFolder)) {
            if ($PSCmdlet.ShouldProcess($outputFolder, 'Remove directory (Clean)')) {
                Remove-Item -LiteralPath $outputFolder -Recurse -Force
            }
        }
        if (-not (Test-Path -LiteralPath $outputFolder)) {
            if ($PSCmdlet.ShouldProcess($outputFolder, 'Create directory')) {
                New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
            }
        }

        $ts      = Get-Date -Format 'yyyyMMdd_HHmmss'
        $logFile = Join-Path -Path $outputFolder -ChildPath ('Build-{0}-{1}.log' -f $packageName, $ts)

        try {
            Write-BuildLog -LogFile $logFile -Message "==== Build start: $packageName ===="
            Write-BuildLog -LogFile $logFile -Message "ToolPath : $toolPath"
            Write-BuildLog -LogFile $logFile -Message "Source   : $resolvedSource"
            Write-BuildLog -LogFile $logFile -Message "Setup    : $setup"
            Write-BuildLog -LogFile $logFile -Message "Output   : $outputFolder"

            # IntuneWinAppUtil always names the output <SetupFileName>.intunewin
            $expectedName = '{0}.intunewin' -f [IO.Path]::GetFileNameWithoutExtension($setup)
            $expectedPath = Join-Path -Path $outputFolder -ChildPath $expectedName

            # Handle existing file before the tool runs
            if (Test-Path -LiteralPath $expectedPath) {
                if ($OverwriteExisting) {
                    if ($PSCmdlet.ShouldProcess($expectedPath, 'Remove existing .intunewin')) {
                        Remove-Item -LiteralPath $expectedPath -Force -ErrorAction Stop
                        Write-BuildLog -LogFile $logFile -Message "Removed existing file: $expectedPath"
                    }
                }
                else {
                    $bakName = '{0}-{1}.bak.intunewin' -f [IO.Path]::GetFileNameWithoutExtension($setup), $ts
                    if ($PSCmdlet.ShouldProcess($expectedPath, "Rename existing to $bakName")) {
                        Rename-Item -LiteralPath $expectedPath -NewName $bakName -ErrorAction Stop
                        Write-BuildLog -LogFile $logFile -Message "Renamed existing file to: $bakName"
                    }
                }
            }

            if (-not $PSCmdlet.ShouldProcess($setupFullPath, 'Package with IntuneWinAppUtil.exe')) {
                return
            }

            Write-BuildLog -LogFile $logFile -Message 'Invoking IntuneWinAppUtil.exe...'
            $toolOutput = & $toolPath -c $resolvedSource -s $setup -o $outputFolder -q 2>&1
            $exit = $LASTEXITCODE

            foreach ($line in $toolOutput) {
                $text = "$line".Trim()
                if ($text) { Write-BuildLog -LogFile $logFile -Message $text }
            }
            Write-BuildLog -LogFile $logFile -Message "IntuneWinAppUtil.exe finished with ExitCode: $exit"
            if ($exit -ne 0) {
                throw "Packaging failed with exit code $exit (log: $logFile)"
            }

            # The output name is deterministic; wait briefly for the file to land
            $deadline = (Get-Date).AddSeconds(10)
            while (-not (Test-Path -LiteralPath $expectedPath) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 250
            }
            $producedPath = $expectedPath
            if (-not (Test-Path -LiteralPath $producedPath)) {
                # Fallback: newest .intunewin in this package folder (never other packages)
                $candidate = Get-ChildItem -LiteralPath $outputFolder -Filter *.intunewin -File -ErrorAction SilentlyContinue |
                             Where-Object { $_.Name -notlike '*.bak.intunewin' } |
                             Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if (-not $candidate) {
                    throw "Build reported success but no .intunewin file was found in $outputFolder"
                }
                $producedPath = $candidate.FullName
            }

            # Prune old backups after a successful build
            if ($KeepBackups -ge 0) {
                $backups = @(Get-ChildItem -LiteralPath $outputFolder -Filter '*.bak.intunewin' -File |
                             Sort-Object LastWriteTime -Descending)
                if ($backups.Count -gt $KeepBackups) {
                    foreach ($old in ($backups | Select-Object -Skip $KeepBackups)) {
                        if ($PSCmdlet.ShouldProcess($old.FullName, 'Remove old backup')) {
                            Remove-Item -LiteralPath $old.FullName -Force
                            Write-BuildLog -LogFile $logFile -Message "Pruned old backup: $($old.Name)"
                        }
                    }
                }
            }

            $file     = Get-Item -LiteralPath $producedPath
            $hash     = (Get-FileHash -LiteralPath $producedPath -Algorithm SHA256).Hash
            $duration = (Get-Date) - $started

            Write-BuildLog -LogFile $logFile -Message ("Produced : {0}" -f $producedPath)
            Write-BuildLog -LogFile $logFile -Message ("Size     : {0:N2} MB" -f ($file.Length / 1MB))
            Write-BuildLog -LogFile $logFile -Message ("SHA256   : {0}" -f $hash)
            Write-BuildLog -LogFile $logFile -Message ("Duration : {0:mm\:ss}" -f $duration)

            if ($PassThru) {
                [pscustomobject]@{
                    PackageName   = $packageName
                    IntuneWinFile = $producedPath
                    SourceFolder  = $resolvedSource
                    SetupFile     = $setup
                    SizeMB        = [math]::Round($file.Length / 1MB, 2)
                    Sha256        = $hash
                    Duration      = $duration
                    LogFile       = $logFile
                }
            }
        }
        catch {
            Write-BuildLog -LogFile $logFile -Message ('ERROR: ' + $_.Exception.Message) -Level 'ERROR'
            throw
        }
        finally {
            Write-BuildLog -LogFile $logFile -Message "==== Build end: $packageName ===="
        }
    }

    end { }
}

# Run directly when invoked with -SourceFolder; dot-source the file to only load the function.
if ($PSBoundParameters.ContainsKey('SourceFolder')) {
    Build-IntuneWinApp @PSBoundParameters
}
