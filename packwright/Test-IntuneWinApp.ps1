<#
.SYNOPSIS
    Install (or uninstall) a package on this computer the way Intune would, and check the result
    with the package's own requirement and detection rules.

.DESCRIPTION
    The step between "it builds" and "it works on the devices". Reads app.json in a package
    folder and does what the Intune Management Extension does with it:

      - copies the package to a folder of its own, as Intune extracts it, and runs the command
        from there - a folder only SYSTEM and administrators can change, as Intune's IMECache
      - fills in what app.json leaves out the way Publish-IntuneWinApp does: the commands of a
        PSADT or MSI package and an MSI's product code, so a package that publishes without
        app.json tests without one
      - runs it as SYSTEM through a one-off scheduled task, or as the signed-in user for an app
        that installs per user — never as the administrator who started the test
      - starts it from a 32-bit cmd.exe, as Intune does: 'powershell.exe' in a command then means
        the 32-bit PowerShell, exactly as on a device
      - evaluates the requirement rules first and the detection rule before and after, in the
        same account the app runs as — an app already detected is not installed again, just as
        Intune would not
      - lists the Apps and features entries the install added, which is what a detection rule is
        best written from

    Changes this computer: the app is really installed. Run it again with -Action Uninstall to
    remove it. Needs to run elevated.

.PARAMETER SourceFolder
    The package folder (the one holding app.json - which an MSI or PSADT package may go without).

.PARAMETER Action
    Install (default) or Uninstall.

.PARAMETER Force
    Run the install even when the detection rule already finds the app.

.PARAMETER ResultPath
    Also write the result as JSON to this file (Packwright reads it from there).

.PARAMETER TimeoutMinutes
    How long the command may run. Intune's default is 60 minutes.

.PARAMETER Pause
    Wait for Enter before the window closes, so the result can be read.

.EXAMPLE
    .\Test-IntuneWinApp.ps1 -SourceFolder "C:\IntunePackages\7-Zip 26.04"

.NOTES
    Author    : Love A
    Requires  : PowerShell 7, administrator rights.
.VERSION
    2026-10-28 - 1.1 - A folder only administrators can change, and app.json read as Publish reads it
    2026-10-08 - 1.0 - Initial version

    What each version changed: CHANGELOG.md
#>
[CmdletBinding()]
param(
    [string]$SourceFolder,

    [ValidateSet('Install', 'Uninstall')]
    [string]$Action = 'Install',

    [switch]$Force,

    [string]$ResultPath,

    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes = 60,

    [switch]$Pause
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw ("Test-IntuneWinApp needs PowerShell 7 — this is Windows PowerShell $($PSVersionTable.PSVersion). " +
           'Start pwsh and run it from there (winget install Microsoft.PowerShell).')
}

# What runs inside the scheduled task, as SYSTEM or as the signed-in user, under Windows
# PowerShell 5.1 — so 5.1 syntax and plain ASCII. It reads its instructions from the work folder
# rather than its command line, so a command with quotes in it arrives exactly as app.json has it
# - and reads them as UTF-8, which 5.1 would otherwise take for the ANSI code page: a script or
# a command with an å in its name would not be found.
$script:TestRunner = @'
param([Parameter(Mandatory = $true)][string]$Work)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$plan = Get-Content -LiteralPath (Join-Path $Work 'plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$package = Join-Path $Work 'package'
$result = [ordered]@{
    Account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Requirements = @(); DetectedBefore = $null; Ran = $false; ExitCode = $null; Seconds = 0
    DetectedAfter = $null; DetectionDetail = ''; Error = ''
}

function Invoke-Script {
    # A detection or requirement script the way Intune runs it: Windows PowerShell, 64-bit unless
    # the rule says runAs32Bit, and what counts is the exit code, what it wrote, and whether it
    # wrote any error
    param([string]$Path, [bool]$Wow)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $system = if ($Wow -and [Environment]::Is64BitOperatingSystem) { 'SysWOW64' } else { 'System32' }
    $start.FileName = Join-Path $env:SystemRoot "$system\WindowsPowerShell\v1.0\powershell.exe"
    $start.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Path + '"'
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.WorkingDirectory = $package
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(300000)) { try { $process.Kill() } catch { }; return [pscustomobject]@{ ExitCode = -1; Output = ''; Error = 'timed out after 5 minutes' } }
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result.Trim(); Error = $stderr.Result.Trim() }
}

function Get-RegistryKey {
    param([string]$KeyPath, [bool]$Wow)
    $parts = $KeyPath -split '\\', 2
    $hive = switch -Regex ($parts[0]) {
        '^(HKEY_LOCAL_MACHINE|HKLM)$' { [Microsoft.Win32.RegistryHive]::LocalMachine }
        '^(HKEY_CURRENT_USER|HKCU)$'  { [Microsoft.Win32.RegistryHive]::CurrentUser }
        default { $null }
    }
    if ($null -eq $hive -or $parts.Count -lt 2) { return $null }
    $view = if ($Wow) { [Microsoft.Win32.RegistryView]::Registry32 } else { [Microsoft.Win32.RegistryView]::Registry64 }
    [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view).OpenSubKey($parts[1])
}

function Test-Comparison {
    param([string]$Have, [string]$Operator, [string]$Want, [string]$Kind)
    if ($Kind -eq 'version') {
        try { $left = [version]$Have; $right = [version]$Want } catch { return $false }
    }
    elseif ($Kind -eq 'integer') {
        try { $left = [int64]$Have; $right = [int64]$Want } catch { return $false }
    }
    elseif ($Kind -eq 'float') {
        try { $left = [double]$Have; $right = [double]$Want } catch { return $false }
    }
    elseif ($Kind -eq 'dateTime') {
        try { $left = [datetime]$Have; $right = [datetime]$Want } catch { return $false }
    }
    else { $left = "$Have"; $right = "$Want" }
    switch ($Operator) {
        'equal'              { return $left -eq $right }
        'notEqual'           { return $left -ne $right }
        'greaterThan'        { return $left -gt $right }
        'greaterThanOrEqual' { return $left -ge $right }
        'lessThan'           { return $left -lt $right }
        'lessThanOrEqual'    { return $left -le $right }
        default              { return $true }
    }
}

# The detection rule, evaluated the way Intune evaluates it. @{ Detected; Detail }
function Test-Detection {
    $rule = $plan.Detection
    if (-not $rule) { return [pscustomobject]@{ Detected = $false; Detail = 'The package has no detection rule.' } }
    try {
        switch ("$($rule.type)") {
            'script' {
                $ran = Invoke-Script -Path (Join-Path $package $rule.scriptFile) -Wow ([bool]$rule.runAs32Bit)
                $detected = $ran.ExitCode -eq 0 -and [bool]$ran.Output -and -not $ran.Error
                $detail = 'Detection script: exit {0}, wrote "{1}"{2}' -f $ran.ExitCode, $ran.Output, $(if ($ran.Error) { ", ERROR STREAM: $($ran.Error)" } else { '' })
                return [pscustomobject]@{ Detected = $detected; Detail = $detail }
            }
            'msi' {
                if (-not "$($rule.productCode)".Trim()) {
                    return [pscustomobject]@{ Detected = $false; Detail = 'The MSI rule names no product code, and the package holds no single MSI to take it from.' }
                }
                $installer = New-Object -ComObject WindowsInstaller.Installer
                $state = $installer.ProductState("$($rule.productCode)")
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
                return [pscustomobject]@{ Detected = ($state -eq 5); Detail = ('MSI product {0}: state {1} (5 = installed)' -f $rule.productCode, $state) }
            }
            'registry' {
                $key = Get-RegistryKey -KeyPath "$($rule.keyPath)" -Wow ([bool]$rule.check32BitOn64System)
                $type = if ($rule.detectionType) { "$($rule.detectionType)" } else { 'exists' }
                if ($type -eq 'doesNotExist') {
                    $missing = (-not $key) -or ($rule.valueName -and $null -eq $key.GetValue("$($rule.valueName)"))
                    return [pscustomobject]@{ Detected = $missing; Detail = "Registry $($rule.keyPath): must not exist - $(if ($missing) { 'it does not' } else { 'it does' })" }
                }
                if (-not $key) { return [pscustomobject]@{ Detected = $false; Detail = "Registry key $($rule.keyPath) does not exist." } }
                if (-not $rule.valueName -or $type -eq 'exists') {
                    $present = (-not $rule.valueName) -or ($null -ne $key.GetValue("$($rule.valueName)"))
                    return [pscustomobject]@{ Detected = $present; Detail = "Registry $($rule.keyPath) $($rule.valueName): $(if ($present) { 'exists' } else { 'value missing' })" }
                }
                $value = $key.GetValue("$($rule.valueName)")
                $ok = ($null -ne $value) -and (Test-Comparison -Have "$value" -Operator "$($rule.operator)" -Want "$($rule.detectionValue)" -Kind $type)
                return [pscustomobject]@{ Detected = $ok; Detail = ('Registry {0} {1} = "{2}", rule: {3} {4} {5}' -f $rule.keyPath, $rule.valueName, $value, $type, $rule.operator, $rule.detectionValue) }
            }
            'file' {
                $folder = "$($rule.path)"
                if ($rule.check32BitOn64System) { $folder = $folder -replace '(?i)%ProgramFiles%', ${env:ProgramFiles(x86)} }
                $full = Join-Path ([Environment]::ExpandEnvironmentVariables($folder)) "$($rule.fileOrFolderName)"
                $type = if ($rule.detectionType) { "$($rule.detectionType)" } else { 'exists' }
                $exists = Test-Path -LiteralPath $full
                switch ($type) {
                    'exists'       { return [pscustomobject]@{ Detected = $exists; Detail = "$full $(if ($exists) { 'exists' } else { 'does not exist' })" } }
                    'doesNotExist' { return [pscustomobject]@{ Detected = -not $exists; Detail = "$full must not exist - $(if ($exists) { 'it does' } else { 'it does not' })" } }
                    'version' {
                        $have = if ($exists) { (Get-Item -LiteralPath $full).VersionInfo.FileVersion } else { '' }
                        $ok = $exists -and (Test-Comparison -Have ("$have" -replace '[^\d.].*$', '') -Operator "$($rule.operator)" -Want "$($rule.detectionValue)" -Kind 'version')
                        return [pscustomobject]@{ Detected = $ok; Detail = "$full file version $have, rule: $($rule.operator) $($rule.detectionValue)" }
                    }
                    default { return [pscustomobject]@{ Detected = $exists; Detail = "$full exists: $exists (the $type comparison is not evaluated by this test)" } }
                }
            }
            default { return [pscustomobject]@{ Detected = $false; Detail = "Unknown detection type '$($rule.type)'." } }
        }
    }
    catch { return [pscustomobject]@{ Detected = $false; Detail = 'Evaluating the rule failed: ' + $_.Exception.Message } }
}

try {
    foreach ($requirement in @($plan.Requirements)) {
        if (-not $requirement) { continue }
        $ran = Invoke-Script -Path (Join-Path $package $requirement.scriptFile) -Wow ([bool]$requirement.runAs32Bit)
        # With the defaults Publish-IntuneWinApp gives what the rule leaves out
        $kind = if ("$($requirement.detectionType)".Trim()) { "$($requirement.detectionType)".Trim() } else { 'boolean' }
        $operator = if ("$($requirement.operator)".Trim()) { "$($requirement.operator)".Trim() } else { 'equal' }
        $want = if ("$($requirement.detectionValue)".Trim()) { "$($requirement.detectionValue)".Trim() } else { 'true' }
        $met = $ran.ExitCode -eq 0 -and -not $ran.Error -and (Test-Comparison -Have $ran.Output -Operator $operator -Want $want -Kind $kind)
        $name = if ("$($requirement.displayName)".Trim()) { "$($requirement.displayName)".Trim() } else { [IO.Path]::GetFileName("$($requirement.scriptFile)") }
        $result.Requirements += [pscustomobject]@{ Name = $name; Met = $met; Output = $ran.Output; Error = $ran.Error }
    }
    $before = Test-Detection
    $result.DetectedBefore = $before.Detected
    $unmet = @($result.Requirements | Where-Object { -not $_.Met })
    $skip = $false
    if ($plan.Action -eq 'Install' -and $unmet) { $skip = $true; $result.Error = 'Not applicable: ' + (($unmet | ForEach-Object { $_.Name }) -join ', ') }
    elseif ($plan.Action -eq 'Install' -and $before.Detected -and -not $plan.Force) { $skip = $true }
    elseif ($plan.Action -eq 'Uninstall' -and -not $before.Detected -and -not $plan.Force) { $skip = $true }
    if (-not $skip) {
        # As Intune starts it: from a 32-bit process, in the package folder. And waited for the
        # way Intune waits: for that process alone, not for whatever it leaves running - an
        # installer that starts its app or a tray icon at the end is done when it exits.
        $shell = if ([Environment]::Is64BitOperatingSystem) { Join-Path $env:SystemRoot 'SysWOW64\cmd.exe' } else { Join-Path $env:SystemRoot 'System32\cmd.exe' }
        $command = Get-Content -LiteralPath (Join-Path $Work 'command.txt') -Raw -Encoding UTF8
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = $shell
        $start.Arguments = '/s /c "' + $command.Trim() + '"'
        $start.WorkingDirectory = $package
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $minutes = if ($plan.TimeoutMinutes) { [int]$plan.TimeoutMinutes } else { 60 }
        $started = Get-Date
        $process = [Diagnostics.Process]::Start($start)
        $result.Ran = $true
        if ($process.WaitForExit($minutes * 60000)) { $result.ExitCode = $process.ExitCode }
        else {
            try { $process.Kill() } catch { }
            $result.Error = "Timed out: the command was still running after $minutes minutes, and Intune would have given up on it."
        }
        $result.Seconds = [int]((Get-Date) - $started).TotalSeconds
    }
    $after = Test-Detection
    $result.DetectedAfter = $after.Detected
    $result.DetectionDetail = $after.Detail
}
catch { $result.Error = $_.Exception.Message }
($result | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $Work 'result.json') -Encoding UTF8
'@

function Get-ArpSnapshot {
    param([string]$UserSid)
    $roots = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Hive = 'HKEY_LOCAL_MACHINE'; Is32 = $false }
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Hive = 'HKEY_LOCAL_MACHINE'; Is32 = $true }
    )
    if ($UserSid) { $roots += @{ Path = "Registry::HKEY_USERS\$UserSid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; Hive = 'HKEY_CURRENT_USER'; Is32 = $false } }
    $snapshot = @{}
    foreach ($root in $roots) {
        foreach ($key in @(Get-ChildItem -LiteralPath $root.Path -ErrorAction SilentlyContinue)) {
            $values = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not "$($values.DisplayName)".Trim()) { continue }
            $id = '{0}|{1}|{2}' -f $root.Hive, $root.Is32, $key.PSChildName
            $snapshot[$id] = [pscustomobject]@{
                KeyPath = "$($root.Hive)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($key.PSChildName)"
                Is32Bit = $root.Is32; DisplayName = "$($values.DisplayName)".Trim(); DisplayVersion = "$($values.DisplayVersion)".Trim()
                Publisher = "$($values.Publisher)".Trim(); QuietUninstall = "$($values.QuietUninstallString)".Trim()
            }
        }
    }
    $snapshot
}

# What an exit code means, in Intune's words or WinGet's
function Get-ExitCodeMeaning {
    param($Code)
    if ($null -eq $Code) { return '' }
    $code = [int]$Code
    $known = @{ 0 = 'success'; 1707 = 'success'; 3010 = 'success, restart needed (soft reboot)'; 1641 = 'success, restart started (hard reboot)'
                1618 = 'retry: Intune tries again in five minutes, three times'; 1 = 'failed' }
    if ($known.ContainsKey($code)) { return $known[$code] }
    $hex = '0x{0:X8}' -f $code
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hex -like '0x8A15*' -and $winget) {
        $text = @(& $winget.Source error $hex 2>$null | Where-Object { "$_".Trim() })
        if ($text) { return "failed: $($text -join ' ')" }
    }
    "failed ($hex)"
}

# A folder the package is run from as SYSTEM: only SYSTEM and administrators may change it, as
# with Intune's own IMECache. ProgramData lets every user add files and folders to the folders in
# it, and one that somebody else made there is theirs to change - so the test makes the folder
# the administrators' own each time, with ProgramData's permissions less that one, and the test
# folders made in it inherit them. Everyone can still look in.
function Protect-TestFolder {
    param([Parameter(Mandatory)][string]$Path)
    $null = New-Item -ItemType Directory -Path $Path -Force
    $folder = Get-Item -LiteralPath $Path -Force
    if ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "$Path is a link to another folder. The test runs packages as SYSTEM from it, so it does not use a link there: remove it and test again."
    }
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
    $security.SetAccessRuleProtection($true, $false)
    foreach ($rule in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]$rule[0], $rule[1], 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    }
    try { [IO.FileSystemAclExtensions]::SetAccessControl($folder, $security) }
    catch {
        # Made by someone who shut the administrators out: take it back first
        $null = & takeown.exe /F $Path /A 2>&1
        [IO.FileSystemAclExtensions]::SetAccessControl($folder, $security)
    }
}

# An MSI's ProductCode, read from its Property table without installing anything
function Get-MsiProductCode {
    param([Parameter(Mandatory)][string]$Path)
    $installer = $null; $database = $null; $view = $null; $record = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database,
                    "SELECT Value FROM Property WHERE Property='ProductCode'")
        [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        $code = if ($record) { "$($record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, 1))".Trim() } else { '' }
        [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
        $code
    }
    catch { '' }
    finally {
        foreach ($comObject in $record, $view, $database, $installer) {
            if ($comObject) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) }
        }
    }
}

# What Publish-IntuneWinApp fills in when app.json leaves it out: the commands of a PSADT package
# or of an MSI that is the package's setup file, and the product code of the MSI the package
# holds. An MSI only when there is exactly one, so there is no guessing which; it is the setup
# file when it lies in the package folder itself. @{ Install; Uninstall; ProductCode; MsiSetup }
function Get-PackageDefault {
    param([Parameter(Mandatory)][string]$Folder)
    $defaults = @{ Install = ''; Uninstall = ''; ProductCode = ''; MsiSetup = $false }
    # By extension too: with 8.3 names on, *.msi also matches the WinGet runtime's .msixbundle
    $msi = @(Get-ChildItem -LiteralPath $Folder -Filter *.msi -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.msi' })
    if ($msi.Count -eq 1) { $defaults.ProductCode = Get-MsiProductCode -Path $msi[0].FullName }
    if (Test-Path -LiteralPath (Join-Path $Folder 'Invoke-AppDeployToolkit.exe') -PathType Leaf) {
        $defaults.Install = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent'
        $defaults.Uninstall = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent'
    }
    elseif ($msi.Count -eq 1 -and $msi[0].DirectoryName -ieq $Folder.TrimEnd('\')) {
        $defaults.MsiSetup = $true
        $defaults.Install = "msiexec /i `"$($msi[0].Name)`" /qn /norestart"
        if ($defaults.ProductCode) { $defaults.Uninstall = "msiexec /x `"$($defaults.ProductCode)`" /qn /norestart" }
    }
    $defaults
}

function Test-IntuneWinApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [ValidateSet('Install', 'Uninstall')][string]$Action = 'Install',
        [switch]$Force,
        [string]$ResultPath,
        [int]$TimeoutMinutes = 60
    )
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'The test runs the package as SYSTEM through a scheduled task, which needs an elevated PowerShell. Start it as administrator.'
    }
    $SourceFolder = (Resolve-Path -LiteralPath $SourceFolder).ProviderPath
    $manifestPath = Join-Path $SourceFolder 'app.json'
    $hasManifest = Test-Path -LiteralPath $manifestPath
    $manifest = if ($hasManifest) { Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    if ("$($manifest.winget.delivery)" -eq 'store') {
        throw 'An Intune Store app is installed by Intune itself; there is no command here to test. Publish it and assign it to a test device.'
    }
    $defaults = Get-PackageDefault -Folder $SourceFolder
    $command = if ($Action -eq 'Install') { "$($manifest.installCommandLine)".Trim() } else { "$($manifest.uninstallCommandLine)".Trim() }
    $derived = -not $command
    if ($derived) { $command = if ($Action -eq 'Install') { $defaults.Install } else { $defaults.Uninstall } }
    if (-not $command -and -not $hasManifest) { throw "No app.json in $SourceFolder — save the package in Packwright first. Only a PSADT or MSI package does without one." }
    if (-not $command) { throw "app.json has no $($Action.ToLowerInvariant()) command." }

    # The detection rule as Publish-IntuneWinApp writes it: an MSI rule that names no product code,
    # or an MSI package with no rule at all, goes by the product code of the package's MSI
    $detection = $manifest.detection
    if (($detection -and "$($detection.type)" -eq 'msi' -and -not "$($detection.productCode)".Trim()) -or (-not $detection -and $defaults.MsiSetup)) {
        $detection = [pscustomobject]@{ type = 'msi'; productCode = $defaults.ProductCode }
    }
    $runAs = if ("$($manifest.runAsAccount)" -eq 'user') { 'user' } else { 'system' }

    # The account the app installs as. Per user means the person signed in at the console, as
    # Intune would — not the administrator who elevated this window, who may be someone else.
    $userName = $null; $userSid = $null
    if ($runAs -eq 'user') {
        $userName = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
        if (-not $userName) { throw 'This app installs per user, and nobody is signed in at the console to install it for.' }
        $userSid = ([Security.Principal.NTAccount]$userName).Translate([Security.Principal.SecurityIdentifier]).Value
    }

    $stamp = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $testRoot = Join-Path $env:ProgramData 'Packwright\Test'
    Protect-TestFolder -Path (Split-Path -Parent $testRoot)
    Protect-TestFolder -Path $testRoot
    $work = Join-Path $testRoot $stamp
    $package = Join-Path $work 'package'
    $null = New-Item -ItemType Directory -Path $package -Force
    # By literal path: a folder named 'App [x64]' is a wildcard pattern to -Path, and matches nothing
    Get-ChildItem -LiteralPath $SourceFolder -Force | Copy-Item -Destination $package -Recurse -Force
    if ($userName) {
        # The signed-in user has to be able to write the result where the task leaves it
        & icacls.exe $work /grant "*${userSid}:(OI)(CI)M" /T /Q | Out-Null
    }
    $plan = [ordered]@{
        Action = $Action; Force = [bool]$Force; TimeoutMinutes = $TimeoutMinutes
        Detection = $detection; Requirements = @($manifest.requirements)
    }
    # With a byte order mark, so the runner under Windows PowerShell 5.1 reads them as UTF-8
    $withBom = [Text.UTF8Encoding]::new($true)
    [IO.File]::WriteAllText((Join-Path $work 'plan.json'), ($plan | ConvertTo-Json -Depth 8), $withBom)
    [IO.File]::WriteAllText((Join-Path $work 'command.txt'), $command, $withBom)
    [IO.File]::WriteAllText((Join-Path $work 'run.ps1'), $script:TestRunner, $withBom)

    Write-Host ("{0} '{1}' as {2}" -f $Action, $manifest.displayName, $(if ($userName) { $userName } else { 'SYSTEM' })) -ForegroundColor Cyan
    Write-Host "  command: $command$(if ($derived) { '  (not in app.json: as Publish-IntuneWinApp derives it)' })"
    Write-Host "  copy of the package: $package"
    $before = Get-ArpSnapshot -UserSid $userSid

    $taskName = "Packwright test $stamp"
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $taskAction = New-ScheduledTaskAction -Execute $shell -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Work "{1}"' -f (Join-Path $work 'run.ps1'), $work)
    $taskPrincipal = if ($userName) { New-ScheduledTaskPrincipal -UserId $userName -LogonType Interactive -RunLevel Limited }
                     else { New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest }
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes($TimeoutMinutes + 10))
    $null = Register-ScheduledTask -TaskName $taskName -Action $taskAction -Principal $taskPrincipal -Settings $taskSettings -Force
    $resultFile = Join-Path $work 'result.json'
    try {
        Start-ScheduledTask -TaskName $taskName
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes + 10)
        while (-not (Test-Path -LiteralPath $resultFile) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
            if ($state -eq 'Ready' -and -not (Test-Path -LiteralPath $resultFile)) {
                Start-Sleep -Seconds 2
                if (-not (Test-Path -LiteralPath $resultFile)) { break }
            }
        }
    }
    finally { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
    if (-not (Test-Path -LiteralPath $resultFile)) {
        throw "The test task ended without a result. Its folder is kept for a look: $work"
    }
    $ran = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json

    $after = Get-ArpSnapshot -UserSid $userSid
    $added = @(foreach ($id in $after.Keys) {
        $entry = $after[$id]
        if (-not $before.ContainsKey($id)) { $entry | Add-Member -NotePropertyName Change -NotePropertyValue 'added' -PassThru }
        elseif ($before[$id].DisplayVersion -ne $entry.DisplayVersion) { $entry | Add-Member -NotePropertyName Change -NotePropertyValue "version $($before[$id].DisplayVersion) -> $($entry.DisplayVersion)" -PassThru }
    })
    $removed = @(foreach ($id in $before.Keys) { if (-not $after.ContainsKey($id)) { $before[$id] } })

    # The WinGet runner's own log, when this is a WinGet package or the WinGet runtime
    $logTail = @()
    $logName = if ($manifest.winget.id) { 'Packwright-WinGet-{0}.log' -f ("$($manifest.winget.id)" -replace '[^A-Za-z0-9._-]', '_') }
               elseif ($manifest.wingetRuntime) { 'Packwright-WinGet-runtime.log' }
    if ($logName) {
        $candidates = @((Join-Path $env:ProgramData "Microsoft\IntuneManagementExtension\Logs\$logName"))
        if ($userSid) {
            $profilePath = (Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.SID -eq $userSid }).LocalPath
            if ($profilePath) { $candidates += Join-Path $profilePath "AppData\Local\Temp\$logName" }
        }
        $log = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($log) { $logTail = @(Get-Content -LiteralPath $log -Tail 40) }
    }

    # The apps this one depends on, which Intune installs first and this test does not
    $dependencies = @(foreach ($dependency in @($manifest.dependencies)) {
        if (-not $dependency) { continue }
        if ("$($dependency.displayName)".Trim()) { "$($dependency.displayName)".Trim() } else { "$($dependency.appId)".Trim() }
    })

    # As Intune judges it: the exit code first - a failure is a failure whatever the detection
    # finds afterwards - and only after a successful one, the detection rule
    $verdict = if ($ran.Error -like 'Not applicable*') { 'Not applicable' }
               elseif (-not $ran.Ran -and $ran.Error) { 'Could not run' }
               elseif (-not $ran.Ran) { if ($Action -eq 'Install') { 'Already installed' } else { 'Not installed' } }
               elseif ($null -eq $ran.ExitCode) { "$Action timed out" }
               elseif ([int]$ran.ExitCode -eq 1618) { "$Action to be tried again (1618)" }
               elseif ([int]$ran.ExitCode -notin 0, 1707, 3010, 1641) { "$Action failed" }
               elseif ($Action -eq 'Install' -and $ran.DetectedAfter) { 'Installed and detected' }
               elseif ($Action -eq 'Install') { 'Not detected after install' }
               elseif (-not $ran.DetectedAfter) { 'Uninstalled' }
               else { 'Still detected after uninstall' }
    $outcome = [pscustomobject]@{
        Action          = $Action
        Verdict         = $verdict
        Succeeded       = $verdict -in 'Installed and detected', 'Uninstalled', 'Already installed', 'Not installed'
        Account         = $ran.Account
        Requirements    = @($ran.Requirements)
        DetectedBefore  = $ran.DetectedBefore
        Ran             = $ran.Ran
        ExitCode        = $ran.ExitCode
        ExitMeaning     = Get-ExitCodeMeaning $ran.ExitCode
        Seconds         = $ran.Seconds
        DetectedAfter   = $ran.DetectedAfter
        DetectionDetail = $ran.DetectionDetail
        Error           = "$($ran.Error)"
        ArpAdded        = $added
        ArpRemoved      = $removed
        LogTail         = $logTail
        Dependencies    = $dependencies
        WorkFolder      = $work
    }
    if ($ResultPath) { ($outcome | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $ResultPath -Encoding UTF8 }
    Remove-Item -LiteralPath $package -Recurse -Force -ErrorAction SilentlyContinue

    $color = if ($outcome.Succeeded) { 'Green' } else { 'Red' }
    Write-Host ''
    Write-Host "  $verdict" -ForegroundColor $color
    foreach ($requirement in $outcome.Requirements) { Write-Host ("  requirement '{0}': {1}" -f $requirement.Name, $(if ($requirement.Met) { 'met' } else { "NOT met ($($requirement.Output) $($requirement.Error))".Trim() })) }
    if ($outcome.Ran) { Write-Host ("  exit code {0} - {1} ({2} s)" -f $outcome.ExitCode, $outcome.ExitMeaning, $outcome.Seconds) }
    elseif ($outcome.Error) { Write-Host "  $($outcome.Error)" }
    else { Write-Host '  The detection rule already found the app, so nothing was run (as Intune would). Use -Force to run it anyway.' }
    Write-Host "  detection: $($outcome.DetectionDetail)"
    if ($dependencies) { Write-Host "  depends on: $($dependencies -join ', ') - Intune installs that first; this test did not" -ForegroundColor Yellow }
    foreach ($entry in $added) { Write-Host ("  Apps and features, {0}: {1} {2}  [{3}]" -f $entry.Change, $entry.DisplayName, $entry.DisplayVersion, $entry.KeyPath) }
    foreach ($entry in $removed) { Write-Host ("  Apps and features, removed: {0} {1}" -f $entry.DisplayName, $entry.DisplayVersion) }
    if ($logTail) { Write-Host '  --- WinGet runner log (last lines) ---'; $logTail | ForEach-Object { Write-Host "  $_" } }
    $outcome
}

# Run directly with -SourceFolder; dot-source the file to only load the function.
if ($PSBoundParameters.ContainsKey('SourceFolder')) {
    $exitCode = 0
    try {
        $outcome = Test-IntuneWinApp -SourceFolder $SourceFolder -Action $Action -Force:$Force -ResultPath $ResultPath -TimeoutMinutes $TimeoutMinutes
        if (-not $outcome.Succeeded) { $exitCode = 1 }
    }
    catch {
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        if ($ResultPath) {
            ([pscustomobject]@{ Action = $Action; Verdict = 'Could not run'; Succeeded = $false; Error = $_.Exception.Message } | ConvertTo-Json) |
                Set-Content -LiteralPath $ResultPath -Encoding UTF8
        }
        $exitCode = 2
    }
    if ($Pause) { Write-Host ''; Read-Host 'Press Enter to close this window' | Out-Null }
    exit $exitCode
}
