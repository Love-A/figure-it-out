<#
.SYNOPSIS
    What Packwright knows about a package folder, in one place: which file it installs from, the
    commands that installs and uninstalls it with when app.json names none, and what can be shown
    to be wrong with it before it is published. Not a script to run on its own.

.DESCRIPTION
    The studio (Packwright.ps1), Build-IntuneWinApp.ps1, Publish-IntuneWinApp.ps1 and
    Test-IntuneWinApp.ps1 each read this file, so the four of them choose the same setup file,
    fill in the same commands and stop at the same mistakes. They used to have a copy each, and
    copies drift: a package the studio called ready could fail a test install, and a mistake its
    checklist caught went straight through a publish from the command line.

    Everything here works on what it is handed - a folder, a command line, a detection rule as
    app.json writes it - and keeps no state, so the studio can pass what is on screen and the
    scripts what is on disk. Keep the top level of this file to functions and $script:Package*
    variables: it runs in the scope of whichever script reads it.

.NOTES
    Author   : Love A
    Requires : PowerShell 7+, Windows.
    Versioned with Build-IntuneWinApp.ps1 (Build): its changes are under Build in CHANGELOG.md.
#>
if ($MyInvocation.InvocationName -ne '.') {
    throw 'Packwright.Package.ps1 is part of Packwright, and the other scripts read it. Start Packwright.ps1 or one of the other scripts instead.'
}

# Every key app.json may have. One that is not here is pointed out: a misspelt key is otherwise
# read by nobody, and its setting quietly left at the default. Keys starting with _ are comments.
$script:PackageManifestKeys = @(
    '$schema', 'displayName', 'description', 'publisher', 'version', 'owner', 'notes', 'informationUrl',
    'privacyInformationUrl', 'developer', 'installCommandLine', 'uninstallCommandLine', 'runAsAccount',
    'restartBehavior', 'maxRunTimeInMinutes', 'returnCodes', 'allowAvailableUninstall', 'isFeatured',
    'architecture', 'minimumWindowsRelease', 'icon', 'detection', 'requirements', 'dependencies',
    'roleScopeTagIds', 'winget', 'wingetRuntime', 'intune')

# On the machine, not in the package: these are commands, not payload
$script:PackageSystemExe = @(
    'msiexec.exe', 'powershell.exe', 'pwsh.exe', 'cmd.exe', 'cscript.exe', 'wscript.exe',
    'rundll32.exe', 'regsvr32.exe', 'reg.exe', 'sc.exe', 'net.exe', 'dism.exe', 'wusa.exe',
    'taskkill.exe', 'schtasks.exe', 'xcopy.exe', 'robocopy.exe', 'msdt.exe')

#region ---- Reading the files in a package --------------------------------------
# AppVendor/AppName/AppVersion from the $adtSession block of a PSADT package
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

# An MSI's Property table via COM, every handle released. @{} and a warning when it cannot be read.
function Get-PackageMsiProperty {
    param([Parameter(Mandatory)][string]$MsiPath)
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
    catch { Write-Warning "Could not read MSI properties from $([IO.Path]::GetFileName($MsiPath)): $($_.Exception.Message)" }
    finally {
        foreach ($comObject in $database, $installer) {
            if ($comObject) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) }
        }
    }
    $result
}

# The one way the functions here read an MSI. The studio puts its own in its place, which keeps
# what it read for the folder it has open and says in its window when it could not.
function Read-PackageMsi {
    param([Parameter(Mandatory)][string]$MsiPath)
    Get-PackageMsiProperty -MsiPath $MsiPath
}

# Name, publisher and version out of a file's version resource
function Get-SetupFileInfo {
    param([Parameter(Mandatory)][string]$Path)
    $info = @{ Name = $null; Publisher = $null; Version = $null }
    try {
        $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        if ("$($versionInfo.ProductName)".Trim()) { $info.Name = "$($versionInfo.ProductName)".Trim() }
        if ("$($versionInfo.CompanyName)".Trim()) { $info.Publisher = "$($versionInfo.CompanyName)".Trim() }
        # ProductVersion is the assembly's InformationalVersion, which since .NET 8 carries
        # the build's commit sha by default: '1.0.0+8851d91c4e27...'. SemVer says everything
        # after '+' is build metadata that no comparison may consider, and Intune has no use
        # for it either — a package labelled with the sha reads as a different release on
        # every rebuild. Drop it and keep any '-beta.3', which is a real part of the version.
        $rawVersion = "$($versionInfo.ProductVersion)".Trim()
        if (-not $rawVersion) { $rawVersion = "$($versionInfo.FileVersion)".Trim() }
        if ($rawVersion) { $info.Version = (($rawVersion -split '\s')[0] -split '\+')[0] }
    } catch {}
    $info
}

# The product code of the MSI a package holds: its setup file's, when that is an MSI, and else
# that of the one MSI anywhere in the folder - PSADT keeps it under Files\. $null when there is
# none, or more than one to choose between. -MsiFile is a list of the folder's MSIs the caller
# has already.
function Find-PackageProductCode {
    param([Parameter(Mandatory)][string]$Folder, [string]$SetupFile, [object[]]$MsiFile)
    $msiPath = $null
    if ($SetupFile -and [IO.Path]::GetExtension($SetupFile) -ieq '.msi') {
        $setupPath = Join-Path $Folder $SetupFile
        if (Test-Path -LiteralPath $setupPath -PathType Leaf) { $msiPath = $setupPath }
    }
    if (-not $msiPath) {
        $found = if ($PSBoundParameters.ContainsKey('MsiFile')) { @($MsiFile) }
                 else { @(Get-ChildItem -LiteralPath $Folder -Filter *.msi -File -Recurse -ErrorAction SilentlyContinue) }
        # By extension too: with 8.3 names on, *.msi also matches the WinGet runtime's .msixbundle
        $found = @($found | Where-Object { $_ -and $_.Extension -ieq '.msi' })
        if ($found.Count -ne 1) { return $null }
        $msiPath = $found[0].FullName
    }
    $code = "$((Read-PackageMsi -MsiPath $msiPath).ProductCode)".Trim()
    if ($code) { $code } else { $null }
}
#endregion

#region ---- Commands ------------------------------------------------------------
# Split a command line into its arguments, honouring double quotes
function Split-CommandToken {
    param([string]$Command)
    @([regex]::Matches("$Command", '"([^"]*)"|(\S+)') | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } })
}

# Whether a bare name is a command Windows has, rather than a file the package has to hold: one
# of the names above, or any other .exe where a bare name is found on a device. Intune starts
# the command from a 32-bit process, and what that finds is its own System32 - SysWOW64 on
# 64-bit Windows - and the Windows folder: regedit.exe, certutil.exe, icacls.exe. A tool the
# 64-bit System32 alone has (pnputil.exe, where SysWOW64 has none) is not found from there, so
# its bare name is still reported; %SystemRoot%\Sysnative\pnputil.exe is how to reach it.
function Test-WindowsCommand {
    param([string]$Name)
    if ($Name -in $script:PackageSystemExe) { return $true }
    if ([IO.Path]::GetExtension($Name) -ine '.exe') { return $false }
    foreach ($place in [Environment]::GetFolderPath('SystemX86'), [Environment]::GetFolderPath('Windows')) {
        if ($place -and (Test-Path -LiteralPath (Join-Path $place $Name) -PathType Leaf)) { return $true }
    }
    $false
}

# The name of a file the command runs that is not in the package, or $null when there is
# none. This is the failure a copied package folder produces: the commands still name the
# binary that was replaced ('msiexec /i "7z2408-x64.msi"' in a folder now holding
# 7z2501-x64.msi). Nothing used to notice — the package builds, publishes, and fails on
# every device instead. Only bare relative names are judged: those are what this tool
# generates and what a copy gets wrong. An absolute or UNC path is somebody's own
# decision about a file that need not exist here, and is left alone. So is what a switch or a
# property is given, which names something for the program to use rather than a file the
# command runs: the process in 'ServiceUI.exe -Process:explorer.exe', 'LAUNCHAPP=app.exe' to
# msiexec. -FileName is every file name in the folder, subfolders included, when the caller
# has it already.
function Find-MissingCommandFile {
    param([string]$Command, [Parameter(Mandatory)][string]$Folder, [string[]]$FileName)
    if (-not "$Command".Trim()) { return $null }
    if (-not $PSBoundParameters.ContainsKey('FileName')) {
        $FileName = @(Get-ChildItem -LiteralPath $Folder -File -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    }
    foreach ($token in @(Split-CommandToken $Command | ForEach-Object { $_.Trim() })) {
        if ([IO.Path]::GetExtension($token) -notin '.exe', '.msi', '.msp', '.msu', '.ps1', '.cmd', '.bat', '.vbs') { continue }
        if ($token -match '[%$]') { continue }                    # expands to something we cannot know
        if ($token.StartsWith('-') -or $token.Contains('=')) { continue }   # a switch or a property, with its value
        if ($token.StartsWith('\\') -or [IO.Path]::IsPathRooted($token)) { continue }
        if ($token -match '[\\/]') {
            if (-not (Test-Path -LiteralPath (Join-Path $Folder $token) -PathType Leaf)) { return $token }
            # What follows a script are its arguments, not files: '-Id Foo.Bar.exe' is a WinGet id
            if ([IO.Path]::GetExtension($token) -in '.ps1', '.cmd', '.bat') { break }
            continue
        }
        if (Test-WindowsCommand $token) { continue }
        if ($FileName -notcontains $token) { return $token }
        if ([IO.Path]::GetExtension($token) -in '.ps1', '.cmd', '.bat') { break }
    }
    $null
}

# The file in the package root that a command line actually runs, or $null. A hand-written
# app.json has already answered "what installs this package" — 'powershell.exe -File
# .\Install-App.ps1' names the script, not the vendor .exe that happens to sit beside it in
# the payload — so the setup file follows the command rather than the file list.
function Get-SetupCommandFile {
    param([string]$Command, [string[]]$Candidate)
    if (-not "$Command".Trim() -or -not $Candidate) { return $null }
    foreach ($token in @(Split-CommandToken $Command | ForEach-Object { $_.Trim() })) {
        if ($token -match '[%$]') { continue }                    # expands to something we cannot know
        $leaf = try { [IO.Path]::GetFileName($token) } catch { $null }
        if (-not $leaf -or $leaf -in $script:PackageSystemExe) { continue }
        $match = @($Candidate | Where-Object { $_ -ieq $leaf })
        if ($match.Count) { return $match[0] }
    }
    $null
}

# How Windows runs a script from the package root. Intune extracts the package and runs the
# command with that folder as the working directory, so the leading .\ is what makes the
# relative name resolve there — and what lets Find-MissingCommandFile check it is really here.
function Get-ScriptRunCommand {
    param([Parameter(Mandatory)][string]$Script)
    if ([IO.Path]::GetExtension($Script) -ieq '.ps1') {
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `".\$Script`""
    }
    else { "cmd.exe /c `".\$Script`"" }
}

# The uninstall script belonging to an install script: the same name with Install swapped
# for Uninstall, else a plain uninstall file of the same type next to it.
function Find-UninstallScript {
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$Script)
    $extension = [IO.Path]::GetExtension($Script)
    $guesses = @()
    if ($Script -match 'install') { $guesses += ($Script -ireplace '(?<!un)install', 'Uninstall') }
    $guesses += "Uninstall$extension"
    foreach ($guess in $guesses) {
        if ($guess -ieq $Script) { continue }
        $path = Join-Path $Folder $guess
        if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Item -LiteralPath $path).Name }
    }
    $null
}
#endregion

#region ---- The setup file, and what it says about the package -----------------
function Get-SetupKind {
    param([string]$Setup)
    if (-not $Setup) { 'none' }
    elseif ($Setup -ieq 'Invoke-AppDeployToolkit.exe') { 'psadt' }
    elseif ($Setup -like '*.msi') { 'msi' }
    elseif ([IO.Path]::GetExtension($Setup) -in '.ps1', '.cmd', '.bat') { 'script' }
    else { 'exe' }
}

# The file a package installs from, chosen the same way by Build and the studio: the one
# app.json's install command runs; Invoke-AppDeployToolkit.exe for PSADT; the one .msi; with no
# .msi, the one Install*.ps1/.cmd/.bat. Only a certain answer counts — guessing between several
# is how the wrong entry point gets recorded silently — unless -Guess asks for the studio's
# guess as well, which it shows for checking: the first .exe, else the first file it could be.
# @{ SetupFile; Reason }, SetupFile $null when nothing is certain and Reason saying what was found.
function Select-SetupFile {
    param([Parameter(Mandatory)][string]$Folder, [string]$InstallCommand, [switch]$Guess)
    $candidates = @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in '.exe', '.msi', '.ps1', '.cmd', '.bat' } |
                    Select-Object -ExpandProperty Name)
    $named = Get-SetupCommandFile -Command $InstallCommand -Candidate $candidates
    if ($named) { return [pscustomobject]@{ SetupFile = $named; Reason = "the file app.json's install command runs" } }
    if ($candidates -contains 'Invoke-AppDeployToolkit.exe') {
        return [pscustomobject]@{ SetupFile = 'Invoke-AppDeployToolkit.exe'; Reason = 'a PSADT package' }
    }
    $msiFiles = @($candidates | Where-Object { [IO.Path]::GetExtension($_) -ieq '.msi' })
    if ($msiFiles.Count -eq 1) { return [pscustomobject]@{ SetupFile = $msiFiles[0]; Reason = 'the one .msi' } }
    $installScripts = @($candidates | Where-Object {
        [IO.Path]::GetExtension($_) -in '.ps1', '.cmd', '.bat' -and [IO.Path]::GetFileNameWithoutExtension($_) -match '^install' })
    if ($msiFiles.Count -eq 0 -and $installScripts.Count -eq 1) {
        return [pscustomobject]@{ SetupFile = $installScripts[0]; Reason = 'the one install script' }
    }
    if ($Guess) {
        $exeFiles = @($candidates | Where-Object { [IO.Path]::GetExtension($_) -ieq '.exe' })
        if ($exeFiles.Count) { return [pscustomobject]@{ SetupFile = $exeFiles[0]; Reason = 'a guess: the first .exe' } }
        if ($candidates.Count) { return [pscustomobject]@{ SetupFile = $candidates[0]; Reason = 'a guess: the first file it could be' } }
    }
    [pscustomobject]@{
        SetupFile = $null
        Reason    = ('no install command in app.json naming one, no Invoke-AppDeployToolkit.exe, ' +
                     "$($msiFiles.Count) .msi files and $($installScripts.Count) install scripts")
    }
}

# The commands a setup file is installed and uninstalled with when app.json names none: the
# standard ones for PSADT, msiexec for an MSI, powershell.exe or cmd.exe for a script and the
# Uninstall script beside it. Never for a vendor .exe: its switches are a guess, which the
# studio shows for checking (Get-InstallerInfo) and nothing publishes or tests unseen.
# @{ Install; Uninstall; UninstallScript }, empty where there is nothing to say.
function Get-SetupCommand {
    param([string]$Setup, [string]$Folder, [string]$ProductCode)
    $commands = @{ Install = ''; Uninstall = ''; UninstallScript = $null }
    switch (Get-SetupKind $Setup) {
        'psadt' {
            $commands.Install   = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent'
            $commands.Uninstall = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent'
        }
        'msi' {
            $commands.Install = "msiexec /i `"$Setup`" /qn /norestart"
            if ("$ProductCode".Trim()) { $commands.Uninstall = "msiexec /x `"$("$ProductCode".Trim())`" /qn /norestart" }
        }
        'script' {
            $commands.Install = Get-ScriptRunCommand -Script $Setup
            if ($Folder) {
                $commands.UninstallScript = Find-UninstallScript -Folder $Folder -Script $Setup
                if ($commands.UninstallScript) { $commands.Uninstall = Get-ScriptRunCommand -Script $commands.UninstallScript }
            }
        }
    }
    $commands
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
        $msi = Read-PackageMsi -MsiPath $file.FullName
        $info.Engine = 'MSI'
        $info.Name = $msi.ProductName; $info.Publisher = $msi.Manufacturer
        $info.Version = $msi.ProductVersion; $info.ProductCode = $msi.ProductCode
        $info.InstallCommand = "msiexec /i $quoted /qn /norestart"
        if ($msi.ProductCode) { $info.UninstallCommand = "msiexec /x `"$($msi.ProductCode)`" /qn /norestart" }
        $info.Hint = 'MSI package — installs silently with msiexec /qn; detection can use the MSI product code.'
        return [pscustomobject]$info
    }

    $versionInfo = Get-SetupFileInfo -Path $file.FullName
    $info.Name = $versionInfo.Name; $info.Publisher = $versionInfo.Publisher; $info.Version = $versionInfo.Version

    # Read returns what it has to hand, not what it was asked for, and is allowed to come
    # back short well before the end of the file — likeliest from a share, which is where
    # these installers often sit. A single call left the rest of the buffer as zeros, so the
    # engine signature was simply not there and a perfectly ordinary Inno installer came back
    # as 'unknown' with no silent switches. Loop until the buffer is full or the file ends.
    $length = [int][Math]::Min($file.Length, 8MB)
    $bytes = [byte[]]::new($length)
    $filled = 0
    $stream = [IO.File]::OpenRead($file.FullName)
    try {
        while ($filled -lt $length) {
            $got = $stream.Read($bytes, $filled, $length - $filled)
            if ($got -le 0) { break }      # the file is shorter than it said it was
            $filled += $got
        }
    }
    finally { $stream.Dispose() }
    $ascii = [Text.Encoding]::ASCII.GetString($bytes, 0, $filled)
    $wide  = [Text.Encoding]::Unicode.GetString($bytes, 0, $filled - ($filled % 2))

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

# What Intune should run for this setup file, plus any metadata the file itself carries
function Get-SetupDefault {
    param([Parameter(Mandatory)][string]$Folder, [string]$Setup)
    $result = @{
        Kind = Get-SetupKind $Setup; Install = ''; Uninstall = ''; Hint = ''; Engine = ''
        Name = $null; Publisher = $null; Version = $null; ProductCode = $null
    }
    switch ($result.Kind) {
        'psadt' {
            $commands = Get-SetupCommand -Setup $Setup
            $result.Install   = $commands.Install
            $result.Uninstall = $commands.Uninstall
            $result.Hint      = 'PSADT package — the toolkit handles the silent install; these commands are the standard ones.'
        }
        'msi' {
            $msi = Read-PackageMsi -MsiPath (Join-Path $Folder $Setup)
            $commands = Get-SetupCommand -Setup $Setup -ProductCode $msi.ProductCode
            $result.Install     = $commands.Install
            $result.Uninstall   = $commands.Uninstall
            $result.Name        = $msi.ProductName
            $result.Publisher   = $msi.Manufacturer
            $result.Version     = $msi.ProductVersion
            $result.ProductCode = $msi.ProductCode
            $result.Engine = 'MSI'
            $result.Hint = 'MSI package — installs silently with msiexec /qn.'
        }
        'script' {
            # Nothing to read out of a script: no version resource, and the engine
            # signatures Get-InstallerInfo scans 8 MB for would only ever match the script's
            # own text. What it is worth saying is how Windows has to be asked to run it.
            $commands = Get-SetupCommand -Setup $Setup -Folder $Folder
            $result.Install   = $commands.Install
            $result.Uninstall = $commands.Uninstall
            $result.Hint = if ([IO.Path]::GetExtension($Setup) -ieq '.ps1') {
                'Script package — Intune extracts the folder and runs this script from it, so paths inside it are relative to the package.' +
                $(if ($commands.UninstallScript) { " $($commands.UninstallScript) is used to uninstall." } else { ' Nothing here uninstalls it — add an uninstall command if the app needs one.' })
            } else {
                'Script package — Intune extracts the folder and runs this file from it with cmd.exe.'
            }
        }
        'exe' {
            try {
                $info = Get-InstallerInfo -Path (Join-Path $Folder $Setup)
                $result.Install   = $info.InstallCommand
                $result.Uninstall = $info.UninstallCommand
                $result.Hint      = $info.Hint
                $result.Engine    = $info.Engine
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

#region ---- Switches and options an install command can be given ------------------
# One thing an install command can be given: a switch ('/NOICONS'), a switch with a value
# ('/DIR="C:\App"') or an MSI property ('SERVER=sql01'). Key is what stands in the command and
# Separator what joins it to its value: '=', a space, or nothing. Pattern, a regular expression,
# is for a key written more than one way (msiexec's /l*v, /log). Last is NSIS's /D=, which has
# to end the command and takes the rest of it, unquoted. Origin says where the option is from:
# 'file' was read out of this installer, 'engine' is what every installer of its type takes.
function New-SetupOption {
    param([Parameter(Mandatory)][string]$Key, [string]$Label, [string]$Value, [string[]]$Choice, [string]$Note,
          [ValidateSet('file', 'engine')][string]$Origin = 'engine', [string]$Separator = '=', [string]$Pattern,
          [switch]$Flag, [switch]$Last)
    [pscustomobject]@{
        Key = $Key; Label = "$Label"; Value = "$Value"; Choices = @($Choice | Where-Object { "$_" -ne '' })
        Note = "$Note"; Origin = $Origin; Separator = $Separator; Pattern = "$Pattern"
        TakesValue = -not $Flag; Last = [bool]$Last
    }
}

# Where an option stands in a command line: @{ Present; Value; Index; Length }. A key counts
# where a new argument starts, so SERVER= is not found inside DBSERVER=.
function Find-CommandOption {
    param([string]$Command, [Parameter(Mandatory)]$Option)
    $key = if ($Option.Pattern) { "(?:$($Option.Pattern))" } else { [regex]::Escape($Option.Key) }
    $pattern = if (-not $Option.TakesValue) { "(?<!\S)$key(?!\S)" }
               elseif ($Option.Last)        { "(?<!\S)$key$([regex]::Escape($Option.Separator))(?<value>.*)`$" }
               elseif ($Option.Separator -eq ' ') { "(?<!\S)$key\s+(?<value>""[^""]*""|[^\s/-]\S*)" }
               elseif ($Option.Separator -eq '=') { "(?<!\S)$key(?:=(?<value>""[^""]*""|\S*))?(?!\S)" }   # a bare /LOG is there too
               else { "(?<!\S)$key(?<value>""[^""]*""|\S*)" }
    $match = [regex]::Match("$Command", $pattern, 'IgnoreCase')
    if (-not $match.Success) { return @{ Present = $false; Value = ''; Index = -1; Length = 0 } }
    @{ Present = $true; Value = $match.Groups['value'].Value.Trim().Trim('"'); Index = $match.Index; Length = $match.Length }
}

# An option as it is written into a command. A value with a space in it is quoted, and so is
# one with a % in it: Intune expands %ProgramFiles% before the command is split into arguments.
function Format-CommandOption {
    param([Parameter(Mandatory)]$Option, [string]$Value)
    if (-not $Option.TakesValue) { return $Option.Key }
    $text = "$Value".Trim().Trim('"')
    if ($Option.Last) { return "$($Option.Key)$($Option.Separator)$text" }
    $quoted = if ($Option.Separator -eq '' -or -not $text -or $text -match '[\s%]') { '"' + $text + '"' } else { $text }
    "$($Option.Key)$($Option.Separator)$quoted"
}

# The command with an option added, given another value, or taken out. An option already in it
# is changed where it stands; a new one goes on the end, or in front of the one option of
# -Sibling (the others in the same list) that has to be last.
function Set-CommandOption {
    param([string]$Command, [Parameter(Mandatory)]$Option, [string]$Value, [object[]]$Sibling, [switch]$Remove)
    $current = "$Command"
    $found = Find-CommandOption -Command $current -Option $Option
    if ($Remove) {
        if (-not $found.Present) { return $current }
        $start = $found.Index
        while ($start -gt 0 -and [char]::IsWhiteSpace($current[$start - 1])) { $start-- }
        return ($current.Remove($start, $found.Index + $found.Length - $start)).Trim()
    }
    $text = Format-CommandOption -Option $Option -Value $Value
    if ($found.Present) { return $current.Remove($found.Index, $found.Length).Insert($found.Index, $text) }
    if (-not $Option.Last) {
        foreach ($other in @($Sibling | Where-Object { $_ -and $_.Last })) {
            $last = Find-CommandOption -Command $current -Option $other
            if ($last.Present) { return $current.Insert($last.Index, "$text ") }
        }
    }
    ("$($current.TrimEnd()) $text").Trim()
}

# Every row a query finds in an open MSI database, as objects with the columns named in -Column.
# Nothing when the table is not there, which is the ordinary case: an MSI that shows no dialogs
# has no Control table.
function Read-MsiTable {
    param([Parameter(Mandatory)]$Database, [Parameter(Mandatory)][string]$Sql, [Parameter(Mandatory)][string[]]$Column)
    $view = $null
    try {
        $view = $Database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $Database, $Sql)
        [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        while ($true) {
            $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if (-not $record) { break }
            try {
                $row = [ordered]@{}
                for ($index = 0; $index -lt $Column.Count; $index++) {
                    $row[$Column[$index]] = "$($record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, ($index + 1)))"
                }
                [pscustomobject]$row
            }
            finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($record) }
        }
        [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
    }
    catch { }
    finally { if ($view) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view) } }
}

# A dialog text as a label: without the font it is drawn in, the & of its shortcut key and
# the colon. '' for one that says nothing on its own, such as '[ButtonText_Next]'.
function Format-MsiLabel {
    param([string]$Text)
    $label = ("$Text" -replace '\{[\\&][^}]*\}', '' -replace '&(?=\S)', '' -replace '\s+', ' ').Trim().TrimEnd(':').Trim()
    if (-not $label -or $label.Contains('[') -or $label.Length -gt 70) { return '' }
    $label
}

# What an MSI can be told on the command line, from the rows of its tables (-Table, a hashtable
# of table name to rows as Read-MsiTable gives them; Condition is every condition in it). There
# is no list of this in an MSI, so it is put together from where such properties leave tracks:
#   - the fields of its dialogs: what the setup wizard asks is what a silent install is not asked
#   - properties it sets a default for with a custom action, or keeps from the last install
#   - SecureCustomProperties, which names the properties meant to be passed in
#   - public properties with a value in the Property table
# and from the Feature and Directory tables, for ADDLOCAL and the install folder. Only public
# properties count: one with a lower-case letter in its name cannot be set from a command line.
# What comes back is a suggestion - that a property is there does not show the installer acts
# on it in a silent install.
function ConvertTo-MsiOption {
    param([Parameter(Mandatory)][hashtable]$Table)
    $rows = @{}
    foreach ($name in 'Property', 'Control', 'RadioButton', 'ComboBox', 'ListBox', 'CheckBox', 'CustomAction',
                      'Feature', 'Directory', 'Upgrade', 'AppSearch', 'Condition') {
        $rows[$name] = @($Table[$name] | Where-Object { $null -ne $_ })
    }
    $number = { param($text) $value = 0; [void][int]::TryParse("$text", [ref]$value); $value }

    $property = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($row in $rows.Property) { if ($row.Property) { $property[$row.Property] = "$($row.Value)" } }
    # What a 'set property' custom action (type 51) gives each property
    $assigned = [Collections.Generic.Dictionary[string, Collections.Generic.List[string]]]::new([StringComparer]::Ordinal)
    foreach ($row in $rows.CustomAction) {
        if (((& $number $row.Type) -band 0x3F) -ne 51 -or -not $row.Source) { continue }
        if (-not $assigned.ContainsKey($row.Source)) { $assigned[$row.Source] = [Collections.Generic.List[string]]::new() }
        $assigned[$row.Source].Add("$($row.Target)")
    }
    $upgrade   = [Collections.Generic.HashSet[string]]::new([string[]]@($rows.Upgrade   | ForEach-Object { "$($_.ActionProperty)" }), [StringComparer]::Ordinal)
    $searched  = [Collections.Generic.HashSet[string]]::new([string[]]@($rows.AppSearch | ForEach-Object { "$($_.Property)" }), [StringComparer]::Ordinal)
    $directory = [Collections.Generic.HashSet[string]]::new([string[]]@($rows.Directory | ForEach-Object { "$($_.Directory)" }), [StringComparer]::Ordinal)
    $hidden    = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    # Windows Installer's own properties, and the ones the tools that write MSIs leave in every one
    $noise = '^(ALLUSERS|REBOOT|REBOOTPROMPT|INSTALLLEVEL|ADDLOCAL|ADDSOURCE|ADDDEFAULT|REMOVE|REINSTALL|REINSTALLMODE|' +
             'ADVERTISE|TRANSFORMS|PATCH|ACTION|EXECUTEACTION|EXECUTEMODE|LIMITUI|PRIMARYFOLDER|ROOTDRIVE|TARGETDIR|SOURCEDIR|' +
             'UPGRADINGPRODUCTCODE|PREVIOUSVERSIONSINSTALLED|NEWERPRODUCTFOUND|SECUREREPAIRWHITELIST|FILEADDLOCAL|COMPADDLOCAL|' +
             'PROMPTROLLBACKCOST|DISABLEROLLBACK|DISABLEADVTSHORTCUTS)$|^(ARP|MSI|WIX|VSD|CMDLINE_|IS_|ISSCRIPT|ISVROOT|PROGMSG_|AI_|DWUS)'
    $usable = {
        param([string]$Name)
        $Name -cmatch '^[A-Z][A-Z0-9_.]*$' -and $Name -notmatch $noise -and -not $upgrade.Contains($Name) -and
            -not $directory.Contains($Name) -and -not $hidden.Contains($Name)
    }
    $found = [ordered]@{}
    $add = {
        param([string]$Name, [int]$Rank, [string]$Label, [string[]]$Choice)
        if (-not $found.Contains($Name)) {
            $found[$Name] = @{ Name = $Name; Rank = $Rank; Label = ''; Choices = [Collections.Generic.List[string]]::new()
                               Asked = $false; TickBox = $false; Checked = [Collections.Generic.List[string]]::new() }
        }
        $entry = $found[$Name]
        if ($Rank -lt $entry.Rank) { $entry.Rank = $Rank }
        if ($Label -and -not $entry.Label) { $entry.Label = $Label }
        foreach ($value in $Choice) { if ("$value" -ne '' -and -not $entry.Choices.Contains("$value")) { $entry.Choices.Add("$value") } }
    }

    # The dialogs. A field is bound to a property; its label is its own text (a tick box) or the
    # text beside or above it. A field that is not shown is one the author switched off, and
    # its property is left out wherever else it turns up.
    $controls = @($rows.Control | ForEach-Object {
        $attributes = & $number $_.Attributes
        @{ Dialog = "$($_.Dialog_)"; Type = "$($_.Type)"; Property = "$($_.Property)"; Text = "$($_.Text)"
           X = (& $number $_.X); Y = (& $number $_.Y); Visible = [bool]($attributes -band 1); Indirect = [bool]($attributes -band 8) }
    })
    $texts = @($controls | Where-Object { $_.Type -eq 'Text' -and $_.Visible })
    $folders = [Collections.Generic.List[string]]::new()
    $shown = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $notShown = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($control in $controls) {
        if ($control.Type -notin 'Edit', 'PathEdit', 'MaskedEdit', 'CheckBox', 'RadioButtonGroup', 'ComboBox', 'ListBox' -or -not $control.Property) { continue }
        $name = $control.Property
        # An indirect field holds the name of the property it edits: WIXUI_INSTALLDIR = INSTALLFOLDER
        if ($control.Indirect) { $name = if ($property.ContainsKey($name)) { $property[$name] } else { '' } }
        if (-not $name) { continue }
        if ($control.Type -eq 'PathEdit') {
            if ($control.Visible -and $name -cmatch '^[A-Z][A-Z0-9_.]*$' -and -not $folders.Contains($name)) { $folders.Add($name) }
            continue
        }
        # WiX authors bind the dialog to WIXUI_SERVER and copy it to SERVER, the one to set
        if ($name -cmatch '^WIXUI_(.+)$' -and ($property.ContainsKey($Matches[1]) -or $assigned.ContainsKey($Matches[1]) -or $searched.Contains($Matches[1]))) {
            $name = $Matches[1]
        }
        if (-not $control.Visible) { [void]$notShown.Add($name); continue }
        [void]$shown.Add($name)
        if (-not (& $usable $name)) { continue }
        $label = ''
        if ($control.Type -eq 'CheckBox') { $label = Format-MsiLabel $control.Text }
        else {
            $bestScore = [int]::MaxValue
            foreach ($text in $texts) {
                if ($text.Dialog -cne $control.Dialog) { continue }
                $across = $text.X - $control.X; $up = $control.Y - $text.Y
                $score = if ([Math]::Abs($up) -le 10 -and $across -lt 0) { [Math]::Abs($up) }
                         elseif ($up -gt 0 -and $up -le 24 -and [Math]::Abs($across) -le 12) { $up }
                         else { -1 }
                if ($score -lt 0 -or $score -ge $bestScore) { continue }
                $candidate = Format-MsiLabel $text.Text
                if ($candidate) { $label = $candidate; $bestScore = $score }
            }
        }
        $choices = @(switch ($control.Type) {
            'RadioButtonGroup' { $rows.RadioButton | Where-Object { $_.Property -ceq $control.Property } | ForEach-Object { "$($_.Value)" } }
            'ComboBox'         { $rows.ComboBox    | Where-Object { $_.Property -ceq $control.Property } | ForEach-Object { "$($_.Value)" } }
            'ListBox'          { $rows.ListBox     | Where-Object { $_.Property -ceq $control.Property } | ForEach-Object { "$($_.Value)" } }
            'CheckBox'         { $rows.CheckBox    | Where-Object { $_.Property -ceq $control.Property } | ForEach-Object { "$($_.Value)" } }
        })
        & $add $name 1 $label $choices
        $found[$name].Asked = $true
        if ($control.Type -eq 'CheckBox') { $found[$name].TickBox = $true }
    }
    foreach ($name in $notShown) { if (-not $shown.Contains($name)) { [void]$hidden.Add($name) } }

    # A default set by a custom action ('SERVER := localhost' when SERVER was not given), with
    # the values it is ever set to as the choices; and a property kept from the last install,
    # which is set by a custom action and searched for in the registry
    foreach ($name in $assigned.Keys) {
        if (-not (& $usable $name)) { continue }
        $literal = @($assigned[$name] | Where-Object { -not $_.Contains('[') })
        if ($literal.Count) { & $add $name 2 '' @($literal | Select-Object -Unique | Where-Object { $_ -ne '' }) }
        elseif ($searched.Contains($name)) { & $add $name 2 '' @() }
    }
    foreach ($name in @("$(if ($property.ContainsKey('SecureCustomProperties')) { $property['SecureCustomProperties'] })" -split ';' | ForEach-Object { $_.Trim() })) {
        if (-not $name -or -not (& $usable $name)) { continue }
        # A search result is passed along too, and is not something to set
        if ($searched.Contains($name) -and -not $property.ContainsKey($name) -and -not $assigned.ContainsKey($name)) { continue }
        & $add $name 2 '' @()
    }
    foreach ($name in $property.Keys) {
        $value = $property[$name]
        if (-not (& $usable $name) -or $value.Length -gt 60 -or $value.Contains('[')) { continue }
        # Visual Studio's names for the fields of a dialog the setup project does not use
        if ($name -cmatch '^(EDIT|CHECKBOX|BUTTON)[A-C]?\d+$' -and -not $found.Contains($name)) { continue }
        & $add $name 3 '' @()
    }

    $conditions = (@($rows.Condition | ForEach-Object { "$($_.Condition)" }) -join "`n")
    $opposite = @{ '1' = '0'; '0' = '1'; 'true' = 'false'; 'false' = 'true'; 'yes' = 'no'; 'no' = 'yes' }
    $options = @()

    # The install folder: the property the wizard's folder box edits, else a directory with one
    # of the names authors give it
    $folder = if ($folders.Count) { $folders[0] }
              else { 'INSTALLDIR', 'INSTALLFOLDER', 'INSTALLLOCATION', 'APPLICATIONFOLDER', 'APPDIR' | Where-Object { $directory.Contains($_) } | Select-Object -First 1 }
    if ($folder) {
        $default = ''
        if ($assigned.ContainsKey($folder)) { $default = "$($assigned[$folder] | Where-Object { $_ -notmatch '^\[[A-Z_0-9]+\]$' } | Select-Object -First 1)" }
        if (-not $default) {
            $row = $rows.Directory | Where-Object { $_.Directory -ceq $folder } | Select-Object -First 1
            if ($row -and $row.Directory_Parent -and "$($row.DefaultDir)" -notmatch '^(SourceDir|\.)') {
                $default = "[$($row.Directory_Parent)]" + (("$($row.DefaultDir)" -split ':')[0] -split '\|')[-1]
            }
        }
        $options += New-SetupOption -Key $folder -Label 'Install folder' -Origin file `
            -Note $(if ($default) { "Where the app is installed. Default: $default" } else { 'Where the app is installed.' })
    }

    foreach ($entry in @($found.Values | Sort-Object -Stable { $_.Rank })) {
        $name = $entry.Name
        if ($name -ceq $folder) { continue }
        foreach ($match in [regex]::Matches($conditions, "(?<![\w.%`$])$([regex]::Escape($name))\s*~?=\s*""?([^""\s()]*)""?")) {
            $compared = $match.Groups[1].Value
            if ($compared -and -not $entry.Checked.Contains($compared)) { $entry.Checked.Add($compared) }
        }
        $default = if ($property.ContainsKey($name)) { $property[$name] }
                   elseif ($assigned.ContainsKey($name)) {
                       $literal = @($assigned[$name] | Where-Object { -not $_.Contains('[') } | Select-Object -Unique)
                       if ($literal.Count -eq 1) { $literal[0] } else { '' }
                   }
                   else { '' }
        $choices = [Collections.Generic.List[string]]::new()
        foreach ($value in @($default) + @($entry.Choices) + @($entry.Checked)) {
            if ("$value" -ne '' -and -not $choices.Contains("$value")) { $choices.Add("$value") }
        }
        # A value the installer tests for, or a tick box, has an opposite worth offering
        if ($choices.Count -eq 1 -and ($entry.Checked.Count -or $entry.TickBox) -and $opposite.ContainsKey($choices[0])) {
            $other = $opposite[$choices[0]]
            $choices.Add($(if ($choices[0] -ceq $choices[0].ToUpperInvariant()) { $other.ToUpperInvariant() } else { $other }))
        }
        $notes = @()
        if ($entry.Asked) { $notes += $(if ($entry.TickBox) { 'A tick box in the setup wizard.' } else { 'Asked for by the setup wizard.' }) }
        if ($entry.Checked.Count) { $notes += "The installer tests for $($entry.Checked -join ', ')." }
        if ($default -ne '') { $notes += "Default: $default" }
        $options += New-SetupOption -Key $name -Label $entry.Label -Value $default -Origin file -Note ($notes -join ' ') `
            -Choice $(if ($choices.Count -gt 1) { $choices })
    }

    # Features: only worth a row when there is more than one to choose between
    $features = @($rows.Feature | Where-Object { $_.Feature -and (& $number $_.Level) -gt 0 })
    if ($features.Count -gt 1) {
        $level = if ($property.ContainsKey('INSTALLLEVEL')) { & $number $property['INSTALLLEVEL'] } else { 1 }
        if ($level -le 0) { $level = 1 }
        $installed = @($features | Where-Object { (& $number $_.Level) -le $level } | ForEach-Object { $_.Feature })
        $named = @($features | ForEach-Object { if ("$($_.Title)".Trim()) { "$($_.Feature) ($("$($_.Title)".Trim()))" } else { $_.Feature } })
        $options += New-SetupOption -Key 'ADDLOCAL' -Label 'Install only these features' -Origin file -Value ($installed -join ',') `
            -Note "Feature names, with commas between. This MSI has: $($named -join ', ')."
    }
    if (-not $property.ContainsKey('ALLUSERS') -or $property['ALLUSERS'] -ne '1') {
        $options += New-SetupOption -Key 'ALLUSERS' -Label 'Install for all users' -Value '1' `
            -Note 'Per machine. This MSI does not say so itself, and then Windows Installer decides from who runs it.'
    }
    $options
}

# What the MSI at -MsiPath can be told on the command line, read from its tables (see
# ConvertTo-MsiOption). Nothing, and a warning, when it cannot be opened.
function Get-PackageMsiOption {
    param([Parameter(Mandatory)][string]$MsiPath)
    $installer = $null; $database = $null
    $tables = @{}
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($MsiPath, 0))
        $queries = [ordered]@{
            Property     = @('SELECT `Property`,`Value` FROM `Property`', 'Property', 'Value')
            Control      = @('SELECT `Dialog_`,`Type`,`X`,`Y`,`Attributes`,`Property`,`Text` FROM `Control`', 'Dialog_', 'Type', 'X', 'Y', 'Attributes', 'Property', 'Text')
            RadioButton  = @('SELECT `Property`,`Value` FROM `RadioButton`', 'Property', 'Value')
            ComboBox     = @('SELECT `Property`,`Value` FROM `ComboBox`', 'Property', 'Value')
            ListBox      = @('SELECT `Property`,`Value` FROM `ListBox`', 'Property', 'Value')
            CheckBox     = @('SELECT `Property`,`Value` FROM `CheckBox`', 'Property', 'Value')
            CustomAction = @('SELECT `Type`,`Source`,`Target` FROM `CustomAction`', 'Type', 'Source', 'Target')
            Feature      = @('SELECT `Feature`,`Title`,`Level` FROM `Feature`', 'Feature', 'Title', 'Level')
            Directory    = @('SELECT `Directory`,`Directory_Parent`,`DefaultDir` FROM `Directory`', 'Directory', 'Directory_Parent', 'DefaultDir')
            Upgrade      = @('SELECT `ActionProperty` FROM `Upgrade`', 'ActionProperty')
            AppSearch    = @('SELECT `Property` FROM `AppSearch`', 'Property')
        }
        foreach ($name in $queries.Keys) {
            $query = $queries[$name]
            $tables[$name] = @(Read-MsiTable -Database $database -Sql $query[0] -Column $query[1..($query.Count - 1)])
        }
        # A large MSI has thousands of components and a condition on a few of them
        $tables.Condition = @(foreach ($sql in 'SELECT `Condition` FROM `Component` WHERE `Condition` IS NOT NULL',
                                               'SELECT `Condition` FROM `Condition`',
                                               'SELECT `Condition` FROM `InstallExecuteSequence` WHERE `Condition` IS NOT NULL',
                                               'SELECT `Condition` FROM `InstallUISequence` WHERE `Condition` IS NOT NULL') {
            Read-MsiTable -Database $database -Sql $sql -Column 'Condition'
        })
    }
    catch {
        Write-Warning "Could not read the options of $([IO.Path]::GetFileName($MsiPath)): $($_.Exception.Message)"
        return @()
    }
    finally {
        foreach ($comObject in $database, $installer) {
            if ($comObject) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) }
        }
    }
    @(ConvertTo-MsiOption -Table $tables)
}

# The switches every installer made with -Engine takes, beyond the silent ones the install
# command starts with. What one installer adds of its own - an Inno Setup installer's tasks, an
# NSIS installer's own switches - is packed inside it and is not here.
function Get-InstallerEngineOption {
    param([string]$Engine, [string]$LogPath)
    switch ($Engine) {
        'MSI' {
            New-SetupOption -Key '/l*v' -Pattern '/l[a-z*!+]*|/log' -Separator ' ' -Label 'Write a log file' -Value $LogPath `
                -Note 'A verbose log of the install, in the folder Intune collects its own logs from.'
        }
        'Inno Setup' {
            New-SetupOption -Key '/DIR' -Label 'Install folder' -Note 'Where the app is installed.'
            New-SetupOption -Key '/LOG' -Label 'Write a log file' -Value $LogPath -Note 'In the folder Intune collects its own logs from.'
            New-SetupOption -Key '/MERGETASKS' -Label 'Turn tasks on or off' -Value '!desktopicon' `
                -Note 'On top of the tasks ticked by default; ! in front turns one off. The names are the installer''s own: desktopicon is the usual one for the desktop shortcut.'
            New-SetupOption -Key '/TASKS' -Label 'Run only these tasks' -Note 'Task names with commas between; every other task is left out.'
            New-SetupOption -Key '/COMPONENTS' -Label 'Install only these components' -Note 'Component names with commas between, for an installer that has components to choose.'
            New-SetupOption -Key '/LOADINF' -Label 'Answers from a file' `
                -Note 'Run the installer once by hand with /SAVEINF="answers.inf", put the file in the package and name it here: the same choices are then made silently.'
            New-SetupOption -Key '/LANG' -Label 'Language' -Note 'The installer''s own name for the language, such as english.'
            New-SetupOption -Key '/NOICONS' -Flag -Label 'No Start menu folder'
            New-SetupOption -Key '/ALLUSERS' -Flag -Label 'Install for all users' -Note 'For an installer that asks who to install for (Inno Setup 6).'
            New-SetupOption -Key '/NORESTARTAPPLICATIONS' -Flag -Label 'Do not start closed applications again'
        }
        'NSIS' {
            New-SetupOption -Key '/D' -Last -Label 'Install folder' -Note 'Has to be last in the command and without quotes, also when the path has spaces in it.'
            New-SetupOption -Key '/NCRC' -Flag -Label 'Skip the self-check' -Note 'The installer does not verify its own file first, which saves time on a large one.'
        }
        'WiX Burn' {
            New-SetupOption -Key '/log' -Pattern '/l(?:og)?' -Separator ' ' -Label 'Write a log file' -Value $LogPath `
                -Note 'In the folder Intune collects its own logs from; each package in the bundle gets a log beside it.'
        }
        'InstallShield' {
            New-SetupOption -Key '/debuglog' -Separator '' -Label 'Write a log file' -Value $LogPath -Note 'A log of setup.exe itself, in the folder Intune collects its own logs from.'
            New-SetupOption -Key '/SMS' -Flag -Label 'Wait until the install is done' -Note 'For an older InstallScript setup, which otherwise returns before it has finished.'
        }
    }
}

# What can be said about the options of an installer of this type as a whole
function Get-SetupOptionNote {
    param([string]$Engine)
    switch ($Engine) {
        'MSI'           { 'Tick what the install should be given; a value can be changed here or in the command. The first group was read out of this MSI: what its setup wizard asks and the properties it has a default for. That a property is there does not show the installer acts on it silently, so test the install.' }
        'Inno Setup'    { 'Tick what the install should be given; a value can be changed here or in the command. These are the switches every Inno Setup installer takes. The names of its tasks and components are packed inside the installer — the vendor''s documentation has them, or /SAVEINF.' }
        'NSIS'          { 'Tick what the install should be given. These are the switches every NSIS installer takes; any others are the vendor''s own and are in its documentation.' }
        'WiX Burn'      { 'Tick what the install should be given. A bundle also takes its own variables as NAME=value at the end of the command; their names are in the vendor''s documentation.' }
        'InstallShield' { 'Tick what the install should be given. Properties for the MSI inside go within the quotes of /v"...", after /qn: /v"/qn SERVER=sql01".' }
        default         { '' }
    }
}

# The options to offer for the setup file at -Path: for an MSI what was read out of it, then
# what msiexec takes - with a transform lying beside it (-Transform, file names) - and for a
# vendor .exe what its engine takes. Nothing for a type nothing is known about.
function Get-SetupOption {
    param([Parameter(Mandatory)][string]$Path, [string]$Engine, [string[]]$Transform)
    $logPath = "%ProgramData%\Microsoft\IntuneManagementExtension\Logs\$([IO.Path]::GetFileNameWithoutExtension($Path))-install.log"
    $options = @()
    if ($Engine -eq 'MSI') {
        $options += @(Get-PackageMsiOption -MsiPath $Path)
        $transforms = @($Transform | Where-Object { "$_".Trim() })
        if ($transforms.Count) {
            $options += New-SetupOption -Key 'TRANSFORMS' -Label 'Apply a transform' -Value $transforms[0] `
                -Choice $(if ($transforms.Count -gt 1) { $transforms }) -Note 'An .mst file in the package folder, which changes the MSI as it is installed.'
        }
    }
    $options += @(Get-InstallerEngineOption -Engine $Engine -LogPath $logPath)
    @($options)
}
#endregion

#region ---- What app.json says -------------------------------------------------
# The return codes a package is judged by: Intune's own five, with app.json's returnCodes on
# top — a code it names gets the type it gives there, and a code it adds is added. Publish sends
# these to Intune, and Test-IntuneWinApp judges a test install by them.
# @(@{ returnCode; type }), Intune's five first.
function Get-PackageReturnCode {
    param($Manifest)
    $codes = [ordered]@{ '0' = 'success'; '1707' = 'success'; '3010' = 'softReboot'; '1641' = 'hardReboot'; '1618' = 'retry' }
    foreach ($entry in @($Manifest.returnCodes)) {
        if ($null -eq $entry -or "$($entry.returnCode)" -notmatch '^-?\d+$') { continue }
        $codes["$([int]$entry.returnCode)"] = "$($entry.type)"
    }
    @(foreach ($code in $codes.Keys) { @{ returnCode = [int]$code; type = $codes[$code] } })
}

# What app.json says that cannot be right, before anything is built or published: a key nobody
# reads — a misspelling, most likely — is a warning, and a value Intune would refuse or take to
# mean something else stops the run. @{ Severity; Field; Message } each, as Get-PackageCheck.
function Get-ManifestProblem {
    param($Manifest)
    if ($null -eq $Manifest) { return }
    function New-ManifestIssue { param([string]$Severity, [string]$Field, [string]$Message)
        [pscustomobject]@{ Severity = $Severity; Field = $Field; Message = $Message } }
    $names = if ($Manifest -is [System.Collections.IDictionary]) { @($Manifest.Keys) } else { @($Manifest.PSObject.Properties.Name) }
    foreach ($name in $names) {
        if ("$name".StartsWith('_') -or $script:PackageManifestKeys -contains $name) { continue }
        New-ManifestIssue 'Warn' $name "app.json has '$name', which Packwright does not read - a misspelling? It is left out of what is published."
    }
    $runTime = $Manifest.maxRunTimeInMinutes
    if ($null -ne $runTime -and ("$runTime" -notmatch '^\d+$' -or [int64]"$runTime" -lt 1 -or [int64]"$runTime" -gt 1440)) {
        New-ManifestIssue 'Block' 'maxRunTimeInMinutes' "maxRunTimeInMinutes in app.json is '$runTime'; Intune takes a whole number of minutes from 1 to 1440."
    }
    foreach ($flag in 'allowAvailableUninstall', 'isFeatured') {
        $value = $Manifest.$flag
        if ($null -ne $value -and $value -isnot [bool]) {
            New-ManifestIssue 'Block' $flag "$flag in app.json is '$value'; it is true or false, without quotes."
        }
    }
    $types = 'success', 'softReboot', 'hardReboot', 'retry', 'failed'
    foreach ($entry in @($Manifest.returnCodes)) {
        if ($null -eq $entry) { continue }
        $code = "$($entry.returnCode)"
        if ($code -notmatch '^-?\d+$' -or [int64]$code -lt [int]::MinValue -or [int64]$code -gt [int]::MaxValue) {
            New-ManifestIssue 'Block' 'returnCodes' "A return code in app.json is '$code'; Intune takes a whole number that fits in 32 bits (a negative one for an error such as 0x8A150011)."
        }
        elseif ("$($entry.type)" -cnotin $types) {
            New-ManifestIssue 'Block' 'returnCodes' "Return code $code in app.json has the type '$($entry.type)'; Intune knows $($types -join ', ')."
        }
    }
}
#endregion

#region ---- What can be shown to be wrong ----------------------------------------
# '24.08' and '24.8.0.0' are one release written two ways — the MSI pads its ProductVersion
# and the vendor does not. Compare component by component as numbers and let the shorter
# one match as a prefix, so only a real difference is ever reported.
#
# Compared as digit strings with the padding removed, never cast to [int]. A component here
# is whatever survives stripping the non-digits, and that is not bounded by anything: the
# '+<commit sha>' the .NET SDK appends to ProductVersion collapses into a 29-digit run, and
# casting it took the whole window down through ShowDialog the moment a folder was opened.
# Two runs of digits are equal exactly when they are equal once the leading zeros are gone,
# so the comparison that cannot overflow is also the comparison that was wanted.
function Test-VersionMatch {
    param([string]$Left, [string]$Right)
    $leftParts  = @("$Left".Trim()  -split '[.,]' | ForEach-Object { $_ -replace '\D' })
    $rightParts = @("$Right".Trim() -split '[.,]' | ForEach-Object { $_ -replace '\D' })
    if (-not $leftParts[0] -or -not $rightParts[0]) { return "$Left".Trim() -ieq "$Right".Trim() }
    for ($i = 0; $i -lt [Math]::Min($leftParts.Count, $rightParts.Count); $i++) {
        if ("$($leftParts[$i])".TrimStart('0') -ne "$($rightParts[$i])".TrimStart('0')) { return $false }
    }
    $true
}

# Whether a detection rule, as app.json writes it, is one Intune can act on: every field it
# needs, and an MSI rule on the MSI this package holds — a code belonging to another one looks
# finished and then never matches. A script path without a folder is looked for in -BaseFolder.
# @{ Ok; Problem; Message }. Problem is msi-no-code, msi-other, registry-no-key, file-incomplete,
# script-none, script-missing or none, for whoever says it in words of their own.
function Test-DetectionRule {
    param($Detection, [string]$BaseFolder, [string]$PackageProductCode)
    function New-DetectionVerdict { param([string]$Problem, [string]$Message)
        [pscustomobject]@{ Ok = -not $Problem; Problem = $(if ($Problem) { $Problem } else { $null }); Message = $Message } }
    $type = "$($Detection.type)".Trim()
    switch ($type) {
        'msi' {
            $code = "$($Detection.productCode)".Trim()
            if (-not $code) { return New-DetectionVerdict 'msi-no-code' 'The MSI detection rule names no product code.' }
            if ($PackageProductCode -and $code -ine $PackageProductCode) {
                return New-DetectionVerdict 'msi-other' "The detection rule looks for the MSI $code, but the MSI in this package is $PackageProductCode."
            }
            return New-DetectionVerdict '' "Intune checks that the MSI product $code is installed."
        }
        'registry' {
            $key = "$($Detection.keyPath)".Trim()
            if (-not $key) { return New-DetectionVerdict 'registry-no-key' 'The registry detection rule names no key.' }
            if ($key -match '\\Uninstall\\?$') {
                return New-DetectionVerdict 'registry-no-key' "The registry detection rule stops at the Uninstall key, which holds every app; it needs the app's own key below it."
            }
            return New-DetectionVerdict '' "Intune checks the registry key $key."
        }
        'file' {
            if (-not "$($Detection.path)".Trim() -or -not "$($Detection.fileOrFolderName)".Trim()) {
                return New-DetectionVerdict 'file-incomplete' 'The file detection rule needs both a folder path and a file or folder name.'
            }
            return New-DetectionVerdict '' "Intune checks $("$($Detection.path)".Trim())\$("$($Detection.fileOrFolderName)".Trim())."
        }
        'script' {
            $file = "$($Detection.scriptFile)".Trim()
            if (-not $file) { return New-DetectionVerdict 'script-none' 'The script detection rule names no script.' }
            $full = if ([IO.Path]::IsPathRooted($file)) { $file } elseif ($BaseFolder) { Join-Path $BaseFolder $file } else { $file }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                return New-DetectionVerdict 'script-missing' "The detection script $file was not found. A name without a path is looked for beside app.json."
            }
            return New-DetectionVerdict '' "A PowerShell script ($([IO.Path]::GetFileName($file))) decides whether the app is installed."
        }
        '' { return New-DetectionVerdict 'none' 'There is no detection rule.' }
        default { return New-DetectionVerdict 'none' "'$type' is not a detection rule type (expected msi, file, registry or script)." }
    }
}

# What can be shown to be wrong with a package before it is published, and what is probably
# wrong. Block: Intune would take it, and every device would then fail — no install command, a
# command running a file the package does not hold, a detection rule that cannot match. Warn:
# what a folder copied from the previous release carries over unnoticed, which only whoever
# packages it can call deliberate — a version rule left on the old version, a setup file that
# says it is another version, an uninstall command for an MSI that is gone. @{ Severity; Field;
# Message } each, Severity Block or Warn and Field install, uninstall, detection or version.
# Without -Folder, what the folder holds is not judged; a command or detection rule that is not
# passed is not judged either.
function Get-PackageCheck {
    param(
        [string]$Folder, [string[]]$FileName,
        [AllowEmptyString()][string]$InstallCommand, [AllowEmptyString()][string]$UninstallCommand,
        [string]$Version, $Detection, [string]$DetectionBase,
        [string]$SetupFile, [string]$SetupVersion, [string]$PackageProductCode
    )
    function New-PackageIssue { param([string]$Severity, [string]$Field, [string]$Message)
        [pscustomobject]@{ Severity = $Severity; Field = $Field; Message = $Message } }

    if ($PSBoundParameters.ContainsKey('InstallCommand') -and -not "$InstallCommand".Trim()) {
        New-PackageIssue 'Block' 'install' 'Install command is missing'
    }
    if ($Folder) {
        if (-not $PSBoundParameters.ContainsKey('FileName')) {
            $FileName = @(Get-ChildItem -LiteralPath $Folder -File -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        }
        foreach ($pair in @(@{ Label = 'install'; Text = $InstallCommand }, @{ Label = 'uninstall'; Text = $UninstallCommand })) {
            $missing = Find-MissingCommandFile -Command $pair.Text -Folder $Folder -FileName $FileName
            if ($missing) { New-PackageIssue 'Block' $pair.Label "The $($pair.Label) command runs $missing, which is not in this package" }
        }
    }
    if ($PSBoundParameters.ContainsKey('Detection')) {
        $base = if ($DetectionBase) { $DetectionBase } else { $Folder }
        $rule = Test-DetectionRule -Detection $Detection -BaseFolder $base -PackageProductCode $PackageProductCode
        if (-not $rule.Ok) { New-PackageIssue 'Block' 'detection' $rule.Message }
    }

    $Version = "$Version".Trim()
    $value = "$($Detection.detectionValue)".Trim()
    if ($Version -and $value -and "$($Detection.type)".Trim() -in 'file', 'registry' -and "$($Detection.detectionType)".Trim() -eq 'version' -and
        -not (Test-VersionMatch $value $Version)) {
        New-PackageIssue 'Warn' 'detection' ("The detection rule compares against $value, but this package is version $Version. " +
                                            'A rule left on the previous version makes Intune treat the old release as installed.')
    }
    $SetupVersion = "$SetupVersion".Trim()
    if ($Version -and $SetupVersion -and -not (Test-VersionMatch $SetupVersion $Version)) {
        New-PackageIssue 'Warn' 'version' "$SetupFile says it is version $SetupVersion, but this package is labelled $Version."
    }
    # 'msiexec /x {code}' left over from the MSI that was replaced uninstalls nothing
    if ($PackageProductCode) {
        $uninstallCode = ([regex]::Match("$UninstallCommand", '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}')).Value
        if ($uninstallCode -and $uninstallCode -ine $PackageProductCode) {
            New-PackageIssue 'Warn' 'uninstall' "The uninstall command removes $uninstallCode, which is not the MSI in this package ($PackageProductCode)."
        }
    }
}
#endregion
