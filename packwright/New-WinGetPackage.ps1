<#
.SYNOPSIS
    Create an Intune package folder that installs an app with WinGet — from the Microsoft Store
    or from the WinGet community repository — plus the WinGet runtime package it relies on.

.DESCRIPTION
    The fourth engine beside Build-IntuneWinApp and Publish-IntuneWinApp. It writes an ordinary
    package folder: scripts and an app.json, which the other two engines build and publish
    exactly like any other package, and which Packwright opens like any other folder.

      - Looks apps up in the Microsoft Store catalog (the same REST service winget itself asks)
        and in the WinGet community repository (through winget on this computer)
      - Decides how Intune has to run the install — as SYSTEM or as the signed-in user, which
        scope and architecture to ask winget for — from the package manifest, and writes the
        detection rule from it, on what outlives the version installed today: the MSIX package
        family, an MSI's upgrade code, an uninstall key without a version in it, or else WinGet
        itself - so no test install is needed when the manifest says
      - Writes Install-, Uninstall-, Detect- and Require- scripts that run under Windows
        PowerShell 5.1 on the device and handle what winget needs there (see the templates)
      - Gives the package the app's icon: the Store's, the manifest's, the installed app's, or
        the installer's own - downloaded, checked against the manifest's SHA-256, read without
        being run, and deleted
      - Honours Packwright.policy.json: an organisation that allows only the Microsoft Store
        gets no community packages out of this script, whoever runs it
      - New-WinGetRuntimePackage builds the package that makes winget usable for SYSTEM on a
        device: App Installer with its framework packages, and the Visual C++ runtime that
        winget.exe needs when it is started by its full path

    Run it directly:
      .\New-WinGetPackage.ps1 -Id 7zip.7zip -Source winget -Version 26.04
      .\New-WinGetPackage.ps1 -Id 9MSPC6MP8FM4 -Source msstore
      .\New-WinGetPackage.ps1 -Search whiteboard -Source msstore
      .\New-WinGetPackage.ps1 -Runtime
    or dot-source it to load the functions, as Packwright does.

.PARAMETER Id
    The package identifier: 9MSPC6MP8FM4 / XP89DCGQ3K6VLD in the Microsoft Store, 7zip.7zip in
    the community repository.

.PARAMETER Source
    msstore (Microsoft Store) or winget (the community repository).

.PARAMETER Version
    Community packages only: the version to install. Without it the latest version is pinned;
    -Latest installs whatever is newest on the day each device installs it.

.PARAMETER Delivery
    msstore only: win32 (a Win32 app that runs these scripts, the default) or store (Intune's
    own Microsoft Store app type — nothing to build, and it keeps working on devices where the
    Microsoft Store app is blocked).

.PARAMETER PackageRoot
    Where the package folder is created. Default: %USERPROFILE%\IntunePackages.

.PARAMETER Search
    List what the source has for this text instead of creating anything.

.PARAMETER Runtime
    Create the WinGet runtime package instead of an app package.

.PARAMETER NoIconDownload
    Do not download the installer to take the app's icon from it, when neither the catalog nor
    an installed copy on this computer has one.

.NOTES
    Author    : Love A
    Requires  : PowerShell 7 on the packaging computer; winget for community packages. The
                scripts it writes run under Windows PowerShell 5.1 on the devices.
.VERSION
    2026-10-27 - 1.2 - Runner 1.1: a time limit, and WinGet's install lock waited for in the open.
                       winget.exe waits for the mutex WinGetCrossProcessInstallLock before it
                       starts an installer, for as long as it takes and silently when its output
                       is captured; one installation that never let go of it left every later
                       install on a device at "Installing" until Intune stopped it after an hour,
                       with nothing in either log. The install and uninstall scripts now look at
                       the lock first and wait for it ten minutes at most, then give winget until
                       55 minutes have passed, stop it there - not the installer it started - and
                       return 1618, so Intune tries again. The log names the winget, WinGet COM
                       server and Windows Installer processes running then, with their start
                       times. winget's own log is copied beside the runner's as SYSTEM too: there
                       it is in SystemTemp\WinGet\defaultState, and only a user's DiagOutputDir
                       was looked for.
    2026-10-12 - 1.1 - A package gets the app's icon. The catalog named one only for MSIX apps
                       from the Store and for the few community manifests that carry one, so
                       Win32 apps from the Store (XP ids) and most community apps had none.
                       Now: the Store's (for XP ids from the app's page in the web Store), the
                       manifest's, the app's when it is installed on this computer, and else the
                       installer's - downloaded (200 MB at most), checked against the manifest's
                       SHA-256, read without being run (an .exe's own icon, an MSI's
                       ARPPRODUCTICON from its Icon table), and deleted. A catalog icon below
                       128 px gives way to a larger one, and sizes are the ones the files really
                       hold: PrivateExtractIcons enlarges a 32 px icon to whatever it is asked
                       for. Store pages' 1080 px pictures are saved at 512.
    2026-10-08 - 1.0 - Initial version.
#>
[CmdletBinding()]
param(
    [string]$Id,

    [ValidateSet('msstore', 'winget')]
    [string]$Source,

    [string]$Version,

    [switch]$Latest,

    [ValidateSet('win32', 'store')]
    [string]$Delivery,

    [string]$PackageRoot,

    [string]$Search,

    [switch]$Runtime,

    [switch]$NoIconDownload
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw ("New-WinGetPackage needs PowerShell 7 — this is Windows PowerShell $($PSVersionTable.PSVersion). " +
           'Start pwsh and run it from there (winget install Microsoft.PowerShell).')
}

# The version of the scripts this engine writes into a package. Packwright compares the scripts
# in a package folder with what this version would write, so a package made by an older
# Packwright — or edited by hand — is pointed out instead of published as it is.
$script:WinGetRunnerVersion = '1.1'

# The oldest winget the scripts accept. 1.29.280 is the first release that installs a Store
# app for every user when run as SYSTEM and provisions it (winget-cli #6194, #6236); older
# clients refuse a machine-wide Store install outside SYSTEM and may leave it unprovisioned.
$script:WinGetMinimumVersion = '1.29.280'

$script:StoreCatalog = 'https://storeedgefd.dsx.mp.microsoft.com/v9.0'
$script:SourceLabels = @{
    msstore = 'Microsoft Store'
    winget  = 'WinGet community repository'
}

#region ---- Organisation policy ----------------------------------------------------
# Packwright.policy.json sits next to the scripts and travels with them — in the team's copy of
# the repository or on the share everybody starts Packwright from. It is a guardrail for the
# people packaging, not a security boundary: the boundary for "nothing but the Store" on the
# devices is App Installer's own policy (EnableDefaultSource = Disabled), see the README.
#
# A policy file that exists but cannot be read allows nothing at all. An organisation that wrote
# "msstore only" and then broke the JSON with a stray comma did not mean "everything" - and one
# that misspelled allowedSources did not either: a policy file has to say what it allows.
function Get-PackwrightPolicy {
    param([string]$Path = (Join-Path $PSScriptRoot 'Packwright.policy.json'))

    $policy = [ordered]@{
        Path             = $Path
        Exists           = $false
        AllowedSources   = @('msstore', 'winget')
        DefaultSource    = 'msstore'
        StoreMarket      = Get-WindowsRegion
        StoreMarketFrom  = 'windows'
        StoreLocale      = [Globalization.CultureInfo]::CurrentCulture.Name
        StoreDelivery    = 'win32'
        RuntimeLink      = 'requirement'
        RuntimeAppName   = 'WinGet runtime'
        Restricted       = $false
        Problems         = @()
    }
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]$policy }

    $policy.Exists = $true
    $raw = $null
    try { $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { $raw = $null }
    # Keys whatever their case: JSON tells "AllowedSources" from "allowedSources", people do not.
    # Keys that start with _ are comments.
    $section = $null
    if ($raw -is [System.Collections.IDictionary]) { foreach ($key in $raw.Keys) { if ("$key" -ieq 'winget') { $section = $raw[$key] } } }
    if ($section -isnot [System.Collections.IDictionary]) {
        $policy.AllowedSources = @()
        $policy.Restricted = $true
        $policy.Problems += "$Path could not be read as a policy (it needs a ""winget"" section), so no source is allowed until it is fixed."
        return [pscustomobject]$policy
    }
    $winget = @{}
    foreach ($key in $section.Keys) { if (-not "$key".StartsWith('_')) { $winget["$key"] = $section[$key] } }
    $known = 'allowedSources', 'defaultSource', 'storeMarket', 'storeLocale', 'storeDelivery', 'runtimeLink', 'runtimeAppName'
    $unknown = @($winget.Keys | Where-Object { $_ -notin $known })
    if ($unknown) {
        $named = ($unknown | ForEach-Object { '"' + $_ + '"' }) -join ', '
        $policy.Problems += "$(Split-Path -Leaf $Path) has $named, which Packwright does not know and ignores. Check the spelling; it knows $($known -join ', ')."
    }

    if ($winget.ContainsKey('allowedSources')) {
        $named = @($winget['allowedSources'] | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ })
        $unknownSources = @($named | Where-Object { $_ -notin 'msstore', 'winget' })
        if ($unknownSources) { $policy.Problems += "allowedSources names $($unknownSources -join ', '), which Packwright does not know; only msstore and winget are." }
        $policy.AllowedSources = @($named | Where-Object { $_ -in 'msstore', 'winget' } | Select-Object -Unique)
    }
    else {
        $policy.AllowedSources = @()
        $policy.Problems += "$(Split-Path -Leaf $Path) does not say which sources it allows (allowedSources), so no source is allowed until it does."
    }
    $policy.Restricted = $policy.AllowedSources.Count -lt 2
    if ($winget['defaultSource'] -in $policy.AllowedSources) { $policy.DefaultSource = "$($winget['defaultSource'])".ToLowerInvariant() }
    elseif ($policy.AllowedSources.Count) { $policy.DefaultSource = $policy.AllowedSources[0] }
    if ("$($winget['storeMarket'])" -match '^[A-Za-z]{2}$') {
        $policy.StoreMarket = "$($winget['storeMarket'])".ToUpperInvariant()
        $policy.StoreMarketFrom = 'policy'
    }
    elseif ("$($winget['storeMarket'])".Trim()) {
        $policy.Problems += "storeMarket ""$($winget['storeMarket'])"" is not a two-letter country code, so the market is $($policy.StoreMarket), from Windows."
    }
    if ("$($winget['storeLocale'])".Trim()) { $policy.StoreLocale = "$($winget['storeLocale'])".Trim() }
    if ($winget['storeDelivery'] -in 'win32', 'store') { $policy.StoreDelivery = "$($winget['storeDelivery'])".ToLowerInvariant() }
    if ($winget['runtimeLink'] -in 'requirement', 'dependency') { $policy.RuntimeLink = "$($winget['runtimeLink'])".ToLowerInvariant() }
    if ("$($winget['runtimeAppName'])".Trim()) { $policy.RuntimeAppName = "$($winget['runtimeAppName'])".Trim() }
    [pscustomobject]$policy
}

# The market Store apps are looked up in when the policy names none: the "Country or region" set
# in Windows on this computer - the setting the Store and WinGet go by on the devices - rather
# than its regional format, which plenty of people everywhere leave on English (United States).
# Two letters; a region Windows gives as a number (World, Latin America) falls back to the format.
function Get-WindowsRegion {
    try {
        $name = "$((Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\International\Geo' -Name Name -ErrorAction Stop).Name)".Trim()
        if ($name -match '^[A-Za-z]{2}$') { return $name.ToUpperInvariant() }
    }
    catch { }
    try {
        $region = [Globalization.RegionInfo]::new([Globalization.CultureInfo]::CurrentCulture.Name).TwoLetterISORegionName
        if ($region -match '^[A-Za-z]{2}$') { return $region.ToUpperInvariant() }
    }
    catch { }
    'US'
}

# 'SE (Sweden)', for messages
function Format-StoreMarket {
    param([string]$Market)
    try { '{0} ({1})' -f $Market, [Globalization.RegionInfo]::new($Market).EnglishName } catch { $Market }
}

# $null when the source may be used, otherwise the sentence that says why not
function Get-WinGetSourceRefusal {
    param([Parameter(Mandatory)][string]$Source, $Policy = (Get-PackwrightPolicy))
    if ($Source -notin 'msstore', 'winget') { return "'$Source' is not a source Packwright packages from (msstore or winget)." }
    if ($Source -in $Policy.AllowedSources) { return $null }
    $allowed = if ($Policy.AllowedSources.Count) { ($Policy.AllowedSources | ForEach-Object { $script:SourceLabels[$_] }) -join ' and ' } else { 'nothing' }
    "Your organisation allows packages from $allowed only ($(Split-Path -Leaf $Policy.Path)) — not from the $($script:SourceLabels[$Source])."
}
#endregion

#region ---- winget on this computer ------------------------------------------------
# The packaging computer asks its own winget about the community repository. Arguments go in
# through ArgumentList, so .NET does the quoting, and the output is read as UTF-8 — what winget
# writes to a pipe — rather than in the console's OEM code page, where 'Copyright ©' and every
# å, ä and ö in a Swedish publisher name would come back garbled.
function Find-LocalWinGet {
    $command = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $command.Source } else { $null }
}

function Invoke-WinGetCli {
    param([Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSeconds = 300)
    $exe = Find-LocalWinGet
    if (-not $exe) {
        throw ('WinGet is not available on this computer, so the community repository cannot be searched from here. ' +
               'Install App Installer from the Microsoft Store, or package from the Microsoft Store source instead.')
    }
    $start = [Diagnostics.ProcessStartInfo]::new($exe)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            throw "winget $($Arguments[0]) did not finish within $TimeoutSeconds seconds."
        }
        $process.WaitForExit()
        $lines = @(("$($stdout.Result)`n$($stderr.Result)" -split '\r?\n') | ForEach-Object {
            # A redraw of a progress bar or spinner is written over with carriage returns:
            # keep what was left on the line, and drop the bars and spinners themselves
            $shown = ($_ -split "`r")[-1].TrimEnd()
            if ($shown -match '^\s*[-\\|/]\s*$' -or $shown -match ('[' + [char]0x2580 + '-' + [char]0x259F + ']')) { return }
            $shown
        })
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $lines }
    }
    finally { $process.Dispose() }
}

function Format-WinGetCode {
    param([int]$Code)
    '0x{0:X8}' -f $Code
}
#endregion

#region ---- Reading winget manifests (YAML) ---------------------------------------
# winget keeps the merged manifest of every package version it has looked at as plain YAML in
# its cache. That is the only place the community repository's per-installer details — scope,
# product code, the Apps & features entry, the package family name — can be read without
# installing anything, and they are exactly what decides how Intune has to run and detect the
# app. 'winget show' prints none of them, and prints the rest in the display language.
#
# PowerShell has no YAML reader, and none is worth a dependency for what this needs: the
# manifests are machine-written (yaml-cpp, two-space indents, keys sorted), so this reads that
# block style — mappings, sequences, compact sequences under a key, "- key: value" items,
# quoted and block scalars. Anything it does not understand is skipped rather than guessed at;
# the worst outcome is a field left empty, which only means a detection rule is not suggested.
function Get-YamlIndent {
    param([string]$Line)
    $Line.Length - $Line.TrimStart(' ').Length
}

function Test-YamlIgnorable {
    param([string]$Line)
    $trimmed = $Line.Trim()
    (-not $trimmed) -or $trimmed.StartsWith('#') -or $trimmed -eq '---' -or $trimmed -eq '...'
}

function Skip-YamlIgnorable {
    param($State)
    while ($State.Index -lt $State.Lines.Count -and (Test-YamlIgnorable $State.Lines[$State.Index])) { $State.Index++ }
}

function Test-YamlSequenceItem {
    param([string]$Content)
    $Content -eq '-' -or $Content.StartsWith('- ')
}

$script:YamlKeyPattern = '^(?<key>[^\s:#''"\-][^:]*?|''[^'']*''|"[^"]*")\s*:(?:\s+(?<value>.*))?$'

function ConvertFrom-YamlDoubleQuoted {
    param([string]$Body)
    $text = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Body.Length; $i++) {
        $char = $Body[$i]
        if ($char -ne '\' -or $i -eq $Body.Length - 1) { [void]$text.Append($char); continue }
        $i++
        $escape = $Body[$i]
        $hexLength = switch -CaseSensitive ("$escape") { 'x' { 2 } 'u' { 4 } 'U' { 8 } default { 0 } }
        if ($hexLength -and $i + $hexLength -lt $Body.Length + 1) {
            $hex = $Body.Substring($i + 1, [Math]::Min($hexLength, $Body.Length - $i - 1))
            try { [void]$text.Append([char]::ConvertFromUtf32([Convert]::ToInt32($hex, 16))); $i += $hex.Length; continue }
            catch { [void]$text.Append('\').Append($escape); continue }
        }
        switch -CaseSensitive ("$escape") {
            'n'     { [void]$text.Append("`n") }
            't'     { [void]$text.Append("`t") }
            'r'     { [void]$text.Append("`r") }
            '0'     { [void]$text.Append([char]0) }
            '"'     { [void]$text.Append('"') }
            '\'     { [void]$text.Append('\') }
            '/'     { [void]$text.Append('/') }
            ' '     { [void]$text.Append(' ') }
            default { [void]$text.Append('\').Append($escape) }
        }
    }
    $text.ToString()
}

function ConvertFrom-YamlScalar {
    param([string]$Text)
    $value = $Text.Trim()
    if ($value.Length -ge 2 -and $value.StartsWith("'") -and $value.EndsWith("'")) {
        return $value.Substring(1, $value.Length - 2).Replace("''", "'")
    }
    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
        return ConvertFrom-YamlDoubleQuoted $value.Substring(1, $value.Length - 2)
    }
    $comment = $value.IndexOf(' #')
    if ($comment -ge 0) { $value = $value.Substring(0, $comment).TrimEnd() }
    if ($value -in '~', 'null') { return $null }
    $value
}

function Read-YamlBlockScalar {
    param($State, [int]$Indent, [string]$Indicator)
    $lines = [Collections.Generic.List[string]]::new()
    $blockIndent = $null
    while ($State.Index -lt $State.Lines.Count) {
        $line = $State.Lines[$State.Index]
        if (-not $line.Trim()) { $lines.Add(''); $State.Index++; continue }
        $lineIndent = Get-YamlIndent $line
        if ($lineIndent -le $Indent) { break }
        if ($null -eq $blockIndent) { $blockIndent = $lineIndent }
        if ($lineIndent -lt $blockIndent) { break }
        $lines.Add($line.Substring($blockIndent))
        $State.Index++
    }
    while ($lines.Count -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    if ($Indicator.StartsWith('|')) { return ($lines -join "`n") }
    # Folded: single line breaks become spaces, an empty line stays a line break
    (($lines -join "`n") -replace '(?<!\n)\n(?!\n)', ' ') -replace '\n\n', "`n"
}

function Read-YamlValue {
    param($State, [int]$Indent, [string]$Value)
    $trimmed = $Value.Trim()
    if (-not $trimmed) {
        # A nested block, a compact sequence at the key's own indent, or nothing at all
        Skip-YamlIgnorable $State
        if ($State.Index -ge $State.Lines.Count) { return $null }
        $next = $State.Lines[$State.Index]
        $nextIndent = Get-YamlIndent $next
        if ($nextIndent -gt $Indent) { return Read-YamlNode $State $nextIndent }
        if ($nextIndent -eq $Indent -and (Test-YamlSequenceItem $next.Substring($Indent))) {
            return , (Read-YamlSequence $State $Indent)
        }
        return $null
    }
    if ($trimmed -match '^[|>][+-]?\d*$') { return Read-YamlBlockScalar $State $Indent $trimmed }
    if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']')) {
        $inner = $trimmed.Substring(1, $trimmed.Length - 2)
        if (-not $inner.Trim()) { return , @() }
        # Each item: a quoted string (which may hold commas), or anything up to the next comma
        return , @([regex]::Matches($inner, '\s*("(?:[^"\\]|\\.)*"|''(?:[^'']|'''')*''|[^,]+)') |
                   ForEach-Object { ConvertFrom-YamlScalar $_.Groups[1].Value } | Where-Object { $null -ne $_ -and "$_".Trim() -ne '' })
    }
    # A quoted string, which the writer may have wrapped over several lines - Git's description
    # is four lines and an empty one in single quotes
    if ($trimmed.StartsWith('"') -or $trimmed.StartsWith("'")) {
        $parts = [Collections.Generic.List[string]]::new()
        $parts.Add($trimmed)
        while ((Find-YamlClosingQuote ($parts -join "`n")) -lt 0 -and $State.Index -lt $State.Lines.Count) {
            # Never past the next key: a quote left open must not swallow the installers
            $next = $State.Lines[$State.Index]
            if ($next.Trim() -and (Get-YamlIndent $next) -le $Indent) { break }
            $parts.Add($next.Trim())
            $State.Index++
        }
        $quoted = $parts -join "`n"
        $close = Find-YamlClosingQuote $quoted
        if ($close -ge 0) { $quoted = $quoted.Substring(0, $close + 1) }   # and not a comment after it
        return ConvertFrom-YamlScalar (ConvertTo-YamlFolded -Text $quoted -Quote $trimmed[0])
    }
    $scalar = ConvertFrom-YamlScalar $trimmed
    # A plain scalar may go on over more-indented lines that are not keys of their own
    while ($State.Index -lt $State.Lines.Count) {
        $next = $State.Lines[$State.Index]
        if (Test-YamlIgnorable $next) { break }
        if ((Get-YamlIndent $next) -le $Indent) { break }
        $content = $next.Trim()
        if ($content -match $script:YamlKeyPattern -or (Test-YamlSequenceItem $content)) { break }
        $scalar = "$scalar $content"
        $State.Index++
    }
    $scalar
}

# Where a quoted scalar ends: the quote that closes it, past the escaped ones - '' in single
# quotes, \" in double quotes. -1 while it goes on.
function Find-YamlClosingQuote {
    param([string]$Text)
    $quote = $Text[0]
    for ($i = 1; $i -lt $Text.Length; $i++) {
        $char = $Text[$i]
        if ($quote -eq '"' -and $char -eq '\') { $i++; continue }
        if ($char -ne $quote) { continue }
        if ($quote -eq "'" -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++; continue }
        return $i
    }
    -1
}

# A quoted scalar's own line breaks, as YAML reads them: one becomes a space, each empty line a
# line break, and in double quotes a backslash at the end of a line joins it to the next
function ConvertTo-YamlFolded {
    param([string]$Text, [char]$Quote)
    $lines = $Text -split "`n"
    $folded = [Text.StringBuilder]::new($lines[0])
    $breaks = 0
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if (-not $lines[$i]) { $breaks++; continue }
        if ($breaks) { [void]$folded.Append("`n" * $breaks); $breaks = 0 }
        elseif ($Quote -eq '"' -and $folded.ToString() -match '(?<!\\)(\\\\)*\\$') { $folded.Length-- }
        else { [void]$folded.Append(' ') }
        [void]$folded.Append($lines[$i])
    }
    $folded.ToString()
}

function Read-YamlMapping {
    param($State, [int]$Indent)
    $map = [ordered]@{}
    while ($true) {
        Skip-YamlIgnorable $State
        if ($State.Index -ge $State.Lines.Count) { break }
        $line = $State.Lines[$State.Index]
        $lineIndent = Get-YamlIndent $line
        if ($lineIndent -lt $Indent) { break }
        # Deeper than any key here and claimed by nothing above: a stray continuation line.
        # Stepping over it keeps the keys after it; stopping would have dropped all of them.
        if ($lineIndent -gt $Indent) { $State.Index++; continue }
        $content = $line.Substring($Indent)
        if (Test-YamlSequenceItem $content) { break }       # a sequence at this indent belongs to the key above
        $match = [regex]::Match($content, $script:YamlKeyPattern)
        $State.Index++
        if (-not $match.Success) { continue }
        $key = $match.Groups['key'].Value.Trim().Trim("'", '"')
        $value = if ($match.Groups['value'].Success) { $match.Groups['value'].Value } else { '' }
        $map[$key] = Read-YamlValue $State $Indent $value
    }
    $map
}

function Read-YamlSequence {
    param($State, [int]$Indent)
    $items = [Collections.Generic.List[object]]::new()
    while ($true) {
        Skip-YamlIgnorable $State
        if ($State.Index -ge $State.Lines.Count) { break }
        $line = $State.Lines[$State.Index]
        $lineIndent = Get-YamlIndent $line
        if ($lineIndent -lt $Indent) { break }
        if ($lineIndent -gt $Indent) { $State.Index++; continue }
        $content = $line.Substring($Indent)
        if (-not (Test-YamlSequenceItem $content)) { break }
        $afterDash = $content.Substring(1)
        $rest = $afterDash.TrimStart(' ')
        if (-not $rest) {
            $State.Index++
            Skip-YamlIgnorable $State
            if ($State.Index -lt $State.Lines.Count -and (Get-YamlIndent $State.Lines[$State.Index]) -gt $Indent) {
                $items.Add((Read-YamlNode $State (Get-YamlIndent $State.Lines[$State.Index])))
            }
            else { $items.Add($null) }
        }
        elseif ($rest -match $script:YamlKeyPattern) {
            # "- key: value" starts a mapping whose further keys line up with this first one
            $itemIndent = $Indent + 1 + ($afterDash.Length - $rest.Length)
            $State.Lines[$State.Index] = (' ' * $itemIndent) + $rest
            $items.Add((Read-YamlMapping $State $itemIndent))
        }
        else {
            $State.Index++
            $items.Add((Read-YamlValue $State ($Indent + 1) $rest))
        }
    }
    # One object, not its items: PowerShell unrolls an array written to the pipeline, which
    # turned a one-item list into a bare string and an empty one into $null
    , $items.ToArray()
}

function Read-YamlNode {
    param($State, [int]$Indent)
    Skip-YamlIgnorable $State
    if ($State.Index -ge $State.Lines.Count) { return $null }
    $content = $State.Lines[$State.Index].Substring([Math]::Min($Indent, $State.Lines[$State.Index].Length))
    if (Test-YamlSequenceItem $content) { return , (Read-YamlSequence $State $Indent) }
    Read-YamlMapping $State $Indent
}

function ConvertFrom-WinGetManifestYaml {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split '\r?\n')) { $lines.Add($line.TrimEnd().Replace("`t", '  ')) }
    $state = @{ Lines = $lines; Index = 0 }
    Skip-YamlIgnorable $state
    if ($state.Index -ge $lines.Count) { return [ordered]@{} }
    $node = Read-YamlNode $state (Get-YamlIndent $lines[$state.Index])
    if ($node -is [Collections.IDictionary]) { $node } else { [ordered]@{} }
}
#endregion

#region ---- The catalogs -----------------------------------------------------------
# Both sources end up in the same shape, so the plan below never needs to know where a package
# came from except where the sources really differ:
#   Id, Source, Name, Publisher, Version, Versions, Description, Homepage, PrivacyUrl, License,
#   LicenseUrl, Author, Pricing, Market, Markets, Installers, IconUrl, ManifestComplete
# Each installer: Architecture, InstallerType, Scope, Locale, ProductCode, PackageFamilyName,
#   Arp (the Apps & features entries the installer writes, with their product and upgrade
#   codes), Url, UrlHost, Sha256, Markets

function New-WinGetInstallerInfo {
    param([Collections.IDictionary]$Installer, [Collections.IDictionary]$Root = @{})
    # Installer fields a manifest may give once at the top, for every installer
    $pick = {
        param([string]$Name)
        if ($null -ne $Installer[$Name] -and "$($Installer[$Name])" -ne '') { $Installer[$Name] } else { $Root[$Name] }
    }
    # The type winget is asked for (--installer-type), and the type that actually installs,
    # which for a zip is the installer inside it — what the detection rule has to follow
    $rawType = "$(& $pick 'InstallerType')".ToLowerInvariant()
    $type = $rawType
    if ($type -eq 'zip' -and "$(& $pick 'NestedInstallerType')") { $type = "$(& $pick 'NestedInstallerType')".ToLowerInvariant() }
    $arp = @(foreach ($entry in @(& $pick 'AppsAndFeaturesEntries')) {
        if ($entry -isnot [Collections.IDictionary]) { continue }
        [pscustomobject]@{
            DisplayName    = "$($entry['DisplayName'])".Trim()
            DisplayVersion = "$($entry['DisplayVersion'])".Trim()
            ProductCode    = "$($entry['ProductCode'])".Trim()
            UpgradeCode    = "$($entry['UpgradeCode'])".Trim()
            Publisher      = "$($entry['Publisher'])".Trim()
            InstallerType  = "$($entry['InstallerType'])".Trim().ToLowerInvariant()
        }
    })
    $url = "$(& $pick 'InstallerUrl')".Trim()
    [pscustomobject]@{
        Architecture      = "$(& $pick 'Architecture')".Trim().ToLowerInvariant()
        InstallerType     = $type
        RequestType       = $rawType
        Scope             = "$(& $pick 'Scope')".Trim().ToLowerInvariant()
        Locale            = "$(& $pick 'InstallerLocale')".Trim()
        ProductCode       = "$(& $pick 'ProductCode')".Trim()
        PackageFamilyName = "$(& $pick 'PackageFamilyName')".Trim()
        Arp               = $arp
        Url               = $url
        UrlHost           = $(try { ([Uri]$url).Host } catch { '' })
        Sha256            = "$(& $pick 'InstallerSha256')".Trim()
        Markets           = @(@(& $pick 'Markets') | ForEach-Object { if ($_ -is [Collections.IDictionary]) { $_['AllowedMarkets'] } } | Where-Object { $_ })
    }
}

# --- Microsoft Store ---------------------------------------------------------------
# The Store source is a REST service — the one winget's msstore source is configured with — and
# it answers in JSON, so none of this depends on winget being installed here or on the language
# winget would print in. The market decides which installers come back: the Store is sold per
# country, and an app that is not offered in the devices' market cannot be installed on them.
function Invoke-StoreCatalog {
    param([Parameter(Mandatory)][string]$Path, $Body)
    $request = @{ Uri = "$script:StoreCatalog/$Path"; TimeoutSec = 30; ErrorAction = 'Stop'; Headers = @{ Accept = 'application/json' } }
    if ($null -ne $Body) {
        $request.Method = 'Post'
        $request.Body = $Body | ConvertTo-Json -Depth 6 -Compress
        $request.ContentType = 'application/json'
    }
    Invoke-RestMethod @request
}

function Search-StoreCatalog {
    param([Parameter(Mandatory)][string]$Query, [int]$Limit = 40)
    $answer = Invoke-StoreCatalog -Path 'manifestSearch' -Body @{
        Query = @{ KeyWord = $Query; MatchType = 'Substring' }; MaximumResults = $Limit }
    @(foreach ($hit in @($answer.Data)) {
        if (-not $hit.PackageIdentifier) { continue }
        $hitVersion = "$(@($hit.Versions)[0].PackageVersion)"
        [pscustomobject]@{
            Id        = "$($hit.PackageIdentifier)"
            Name      = "$($hit.PackageName)"
            Publisher = "$($hit.Publisher)"
            Version   = $(if ($hitVersion -and $hitVersion -ne 'Unknown') { $hitVersion } else { '' })
            Source    = 'msstore'
            Kind      = $(if ("$($hit.PackageIdentifier)" -like 'XP*') { 'Win32 app' } else { 'Store app' })
        }
    })
}

function Get-StoreCatalogEntry {
    param([Parameter(Mandatory)][string]$Id, $Policy = (Get-PackwrightPolicy))
    $market = $Policy.StoreMarket
    $answer = $null
    try {
        $answer = Invoke-StoreCatalog -Path ('packageManifests/{0}?Market={1}&Locale={2}' -f
            [Uri]::EscapeDataString($Id), $market, [Uri]::EscapeDataString($Policy.StoreLocale))
    }
    catch {
        $status = [int]$_.Exception.Response.StatusCode
        if ($status -notin 204, 404) { throw "The Microsoft Store catalog could not be asked about ${Id}: $($_.Exception.Message)" }
    }
    # Nothing for this market need not mean no such app: it may be sold elsewhere only. Asked
    # without a market the Store still names it, and the plan can say it is not offered here -
    # with its installers left out, as they are for other markets' devices.
    $offered = [bool]($answer -and $answer.Data)
    if (-not $offered) {
        try { $answer = Invoke-StoreCatalog -Path ('packageManifests/{0}?Locale={1}' -f [Uri]::EscapeDataString($Id), [Uri]::EscapeDataString($Policy.StoreLocale)) }
        catch { $answer = $null }
    }
    $data = $answer.Data
    if (-not $data) { throw "The Microsoft Store has no app with the id $Id." }
    $latest = @($data.Versions)[0]
    $locale = $latest.DefaultLocale
    # The description in the devices' own language, where the Store has one
    $localized = @($latest.Locales) | Where-Object { "$($_.PackageLocale)" -ieq $Policy.StoreLocale } | Select-Object -First 1
    $text = {
        param([string]$Name)
        $value = "$($localized.$Name)".Trim()
        if ($value) { $value } else { "$($locale.$Name)".Trim() }
    }

    $installers = @(foreach ($installer in @($latest.Installers)) {
        if (-not $offered) { continue }
        $asTable = @{}
        foreach ($property in $installer.PSObject.Properties) { $asTable[$property.Name] = $property.Value }
        # The nested objects in the shape the YAML reader hands them over in
        $asTable['AppsAndFeaturesEntries'] = @(foreach ($entry in @($installer.AppsAndFeaturesEntries)) {
            if (-not $entry) { continue }
            $row = @{}
            foreach ($property in $entry.PSObject.Properties) { $row[$property.Name] = $property.Value }
            $row
        })
        $asTable['Markets'] = @(@{ AllowedMarkets = @($installer.Markets.AllowedMarkets) })
        New-WinGetInstallerInfo -Installer $asTable
    })
    $pricing = (@($locale.Agreements) | Where-Object { $_.AgreementLabel -eq 'Pricing' } | Select-Object -First 1).Agreement
    $latestVersion = "$($latest.PackageVersion)"
    $description = & $text 'Description'
    if (-not $description) { $description = & $text 'ShortDescription' }
    $homepage = & $text 'PackageUrl'
    if (-not $homepage) { $homepage = & $text 'PublisherUrl' }
    [pscustomobject]@{
        Id               = "$($data.PackageIdentifier)"
        Source           = 'msstore'
        Name             = & $text 'PackageName'
        Publisher        = & $text 'Publisher'
        Version          = $(if ($latestVersion -and $latestVersion -ne 'Unknown') { $latestVersion } else { '' })
        Versions         = @()
        Description      = $description
        Homepage         = $homepage
        PrivacyUrl       = & $text 'PrivacyUrl'
        License          = & $text 'License'
        LicenseUrl       = & $text 'LicenseUrl'
        Author           = & $text 'Author'
        Pricing          = "$pricing"
        Market           = $market
        Markets          = @($installers | ForEach-Object { $_.Markets } | Select-Object -Unique)
        Installers       = $installers
        IconUrl          = ''
        ManifestComplete = $true
    }
}

# The Store's own artwork for an MSIX app: a square tile, the largest up to 320 px, and the colour
# it is drawn on. A Store tile is a transparent logo meant for that colour, and left on the white
# of the Company Portal it shrinks to a speck. Win32 apps from the Store (XP ids) are not in this
# catalog; they get their icon the way any other package does, from the installed app.
function Get-StoreIcon {
    param([Parameter(Mandatory)][string]$Id, $Policy = (Get-PackwrightPolicy))
    try {
        $answer = Invoke-RestMethod -TimeoutSec 20 -ErrorAction Stop -Uri (
            'https://displaycatalog.mp.microsoft.com/v7.0/products?bigIds={0}&market={1}&languages={2},en-us,neutral' -f
            [Uri]::EscapeDataString($Id), $Policy.StoreMarket, $Policy.StoreLocale.ToLowerInvariant())
        $best = @(@($answer.Products)[0].LocalizedProperties | ForEach-Object { $_.Images }) |
                Where-Object { $_.ImagePurpose -in 'Tile', 'Logo' -and $_.Width -eq $_.Height -and $_.Width -le 320 } |
                Sort-Object Width -Descending | Select-Object -First 1
        if ($best -and $best.Uri) {
            return [pscustomobject]@{
                Url = $(if ("$($best.Uri)".StartsWith('//')) { "https:$($best.Uri)" } else { "$($best.Uri)" })
                Background = $(if ("$($best.BackgroundColor)" -match '^#[0-9A-Fa-f]{6}$') { "$($best.BackgroundColor)" } else { '' })
            }
        }
    }
    catch { }
    $null
}

# --- WinGet community repository ---------------------------------------------------
# winget's table puts each column where the header puts its title. Positions, not words: the
# header is in the display language. A cell that is too wide is cut short with '…', and an id
# cut short is useless, so such a row is dropped rather than guessed at.
function ConvertFrom-WinGetTable {
    param([string[]]$Lines)
    $dashes = -1
    for ($i = 1; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^-{10,}\s*$') { $dashes = $i; break } }
    if ($dashes -lt 1 -or $dashes -ge $Lines.Count - 1) { return @() }
    $starts = @([regex]::Matches($Lines[$dashes - 1], '\S+') | ForEach-Object { $_.Index })
    if ($starts.Count -lt 3) { return @() }
    $cell = {
        param([string]$Row, [int]$Column)
        $from = $starts[$Column]
        if ($from -ge $Row.Length) { return '' }
        $to = if ($Column + 1 -lt $starts.Count) { [Math]::Min($starts[$Column + 1], $Row.Length) } else { $Row.Length }
        $Row.Substring($from, $to - $from).Trim()
    }
    $ellipsis = [string][char]0x2026
    @(foreach ($row in $Lines[($dashes + 1)..($Lines.Count - 1)]) {
        if (-not $row.Trim()) { continue }
        $rowId = & $cell $row 1
        $rowVersion = & $cell $row 2
        # Characters drawn two columns wide in a name shift the rest of the row to the left.
        # Look for the id near where it should have been instead.
        if (-not $rowId -or $rowId -match '\s' -or $rowId -notmatch '\.') {
            $near = [regex]::Matches($row, '\S+') |
                    Where-Object { $_.Value -match '^\S+\.\S+$' -and [Math]::Abs($_.Index - $starts[1]) -le 12 } |
                    Select-Object -First 1
            if (-not $near) { continue }
            $rowId = $near.Value
            $rowVersion = ([regex]::Matches($row.Substring($near.Index + $near.Length), '\S+') | Select-Object -First 1).Value
        }
        if ($rowId.EndsWith($ellipsis) -or $rowId.EndsWith('...')) { continue }
        [pscustomobject]@{
            Id = $rowId; Name = (& $cell $row 0).TrimEnd([char]0x2026); Publisher = ''
            Version = "$rowVersion"; Source = 'winget'; Kind = ''
        }
    })
}

function Search-CommunityCatalog {
    param([Parameter(Mandatory)][string]$Query, [int]$Limit = 40)
    $result = Invoke-WinGetCli -Arguments @('search', $Query, '--source', 'winget', '--count', "$Limit",
                                           '--accept-source-agreements', '--disable-interactivity')
    if ($result.ExitCode -ne 0) {
        if ((Format-WinGetCode $result.ExitCode) -eq '0x8A150014') { return @() }   # nothing found
        $last = @($result.Output | Where-Object { $_.Trim() }) | Select-Object -Last 1
        throw "winget search failed ($(Format-WinGetCode $result.ExitCode)): $last"
    }
    ConvertFrom-WinGetTable -Lines $result.Output
}

function Get-CommunityCatalogVersion {
    param([Parameter(Mandatory)][string]$Id)
    $result = Invoke-WinGetCli -Arguments @('show', '--id', $Id, '--exact', '--source', 'winget', '--versions',
                                           '--accept-source-agreements', '--disable-interactivity')
    if ($result.ExitCode -ne 0) {
        if ((Format-WinGetCode $result.ExitCode) -eq '0x8A150014') { throw "The WinGet community repository has no package with the id $Id." }
        throw "winget show $Id failed ($(Format-WinGetCode $result.ExitCode))."
    }
    $after = $false
    @(foreach ($line in $result.Output) {
        if ($line -match '^-{3,}\s*$') { $after = $true; continue }
        if ($after -and $line.Trim()) { $line.Trim() }
    })
}

# Where winget keeps the merged manifest of one package version after it has shown it
function Get-CommunityManifestPath {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Version)
    $cache = Join-Path ([IO.Path]::GetTempPath()) 'WinGet\cache\V2_M\Microsoft.Winget.Source_8wekyb3d8bbwe\manifests'
    $folder = Join-Path $cache ((@($Id.Substring(0, 1).ToLowerInvariant()) + $Id.Split('.') + $Version) -join '\')
    Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

function Get-CommunityCatalogEntry {
    param([Parameter(Mandatory)][string]$Id, [string]$Version)
    $versions = @(Get-CommunityCatalogVersion -Id $Id)
    if (-not $Version) { $Version = $versions | Select-Object -First 1 }
    elseif ($versions -and $versions -notcontains $Version) {
        throw ("The WinGet community repository has no version $Version of $Id. It has " +
               "$(@($versions | Select-Object -First 6) -join ', ')$(if ($versions.Count -gt 6) { ', …' }).")
    }
    $shown = Invoke-WinGetCli -Arguments @('show', '--id', $Id, '--exact', '--source', 'winget', '--version', $Version,
                                          '--accept-source-agreements', '--disable-interactivity')
    if ($shown.ExitCode -ne 0) { throw "winget show $Id $Version failed ($(Format-WinGetCode $shown.ExitCode))." }

    $manifest = $null
    $path = Get-CommunityManifestPath -Id $Id -Version $Version
    if ($path) {
        try { $manifest = ConvertFrom-WinGetManifestYaml -Text ([IO.File]::ReadAllText($path)) } catch { $manifest = $null }
    }
    if ($manifest -and "$($manifest['PackageIdentifier'])" -ine $Id) { $manifest = $null }

    if (-not $manifest) {
        # The cache moved or could not be read. What 'winget show' printed still names the package;
        # the installer details that decide scope and detection are unknown, and the plan says so.
        $label = {
            param([string]$Name)
            $line = $shown.Output | Where-Object { $_ -match "^\s*$Name\s*:\s*(.+)$" } | Select-Object -First 1
            if ($line -match "^\s*$Name\s*:\s*(.+)$") { $Matches[1].Trim() } else { '' }
        }
        $title = $shown.Output | Where-Object { $_ -match '\[\S+\]\s*$' } | Select-Object -First 1
        $installerUrl = & $label 'Installer Url'
        return [pscustomobject]@{
            Id = $Id; Source = 'winget'
            Name = $(if ($title -match '^\S+\s+(.+?)\s*\[') { $Matches[1] } else { $Id })
            Publisher = & $label 'Publisher'; Version = $Version; Versions = $versions
            Description = & $label 'Description'; Homepage = & $label 'Homepage'; PrivacyUrl = ''
            License = & $label 'License'; LicenseUrl = & $label 'License Url'; Author = & $label 'Author'
            Pricing = ''; Market = ''; Markets = @()
            Installers = @([pscustomobject]@{
                Architecture = ''; InstallerType = (& $label 'Installer Type').ToLowerInvariant(); RequestType = (& $label 'Installer Type').ToLowerInvariant(); Scope = ''; Locale = ''
                ProductCode = ''; PackageFamilyName = ''; Arp = @(); Url = $installerUrl
                UrlHost = $(try { ([Uri]$installerUrl).Host } catch { '' })
                Sha256 = & $label 'Installer SHA256'; Markets = @() })
            IconUrl = ''; ManifestComplete = $false
        }
    }

    $installers = @(foreach ($installer in @($manifest['Installers'])) {
        if ($installer -is [Collections.IDictionary]) { New-WinGetInstallerInfo -Installer $installer -Root $manifest }
    })
    $icon = @($manifest['Icons']) | Where-Object { $_ -is [Collections.IDictionary] -and $_['IconUrl'] } |
            Sort-Object @{ Expression = { switch ("$($_['IconFileType'])") { 'png' { 0 } 'ico' { 1 } default { 2 } } } } |
            Select-Object -First 1
    $description = "$($manifest['Description'])".Trim()
    if (-not $description) { $description = "$($manifest['ShortDescription'])".Trim() }
    $homepage = "$($manifest['PackageUrl'])".Trim()
    if (-not $homepage) { $homepage = "$($manifest['PublisherUrl'])".Trim() }
    [pscustomobject]@{
        Id               = "$($manifest['PackageIdentifier'])"
        Source           = 'winget'
        Name             = "$($manifest['PackageName'])"
        Publisher        = "$($manifest['Publisher'])"
        Version          = "$($manifest['PackageVersion'])"
        Versions         = $versions
        Description      = $description
        Homepage         = $homepage
        PrivacyUrl       = "$($manifest['PrivacyUrl'])"
        License          = "$($manifest['License'])"
        LicenseUrl       = "$($manifest['LicenseUrl'])"
        Author           = "$($manifest['Author'])"
        Pricing          = ''
        Market           = ''
        Markets          = @()
        Installers       = $installers
        IconUrl          = $(if ($icon) { "$($icon['IconUrl'])" } else { '' })
        ManifestComplete = $true
    }
}

# --- Either source -----------------------------------------------------------------
function Search-WinGetCatalog {
    param([Parameter(Mandatory)][string]$Query, [Parameter(Mandatory)][ValidateSet('msstore', 'winget')][string]$Source,
          [int]$Limit = 40, $Policy = (Get-PackwrightPolicy))
    $refusal = Get-WinGetSourceRefusal -Source $Source -Policy $Policy
    if ($refusal) { throw $refusal }
    if (-not $Query.Trim()) { return @() }
    if ($Source -eq 'msstore') { Search-StoreCatalog -Query $Query.Trim() -Limit $Limit }
    else { Search-CommunityCatalog -Query $Query.Trim() -Limit $Limit }
}

function Get-WinGetCatalogEntry {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][ValidateSet('msstore', 'winget')][string]$Source,
          [string]$Version, $Policy = (Get-PackwrightPolicy))
    $refusal = Get-WinGetSourceRefusal -Source $Source -Policy $Policy
    if ($refusal) { throw $refusal }
    if ($Source -eq 'msstore') {
        $entry = Get-StoreCatalogEntry -Id $Id -Policy $Policy
        # An MSIX app's tile from the display catalog, which has its colour; a Win32 app from the
        # Store is not in that catalog, and its icon comes from its page in the web Store
        $icon = if (@($entry.Installers | Where-Object { $_.InstallerType -eq 'msstore' })) { Get-StoreIcon -Id $entry.Id -Policy $Policy }
        if (-not $icon) { $icon = Get-StoreWebIcon -Id $entry.Id -Policy $Policy }
        if ($icon) {
            $entry.IconUrl = $icon.Url
            $entry | Add-Member -NotePropertyName IconBackground -NotePropertyValue $icon.Background -Force
        }
        return $entry
    }
    Get-CommunityCatalogEntry -Id $Id -Version $Version
}

# WPF's imaging classes only work on an STA thread, and a background runspace is MTA unless
# told otherwise. Self-contained, because it may run on a runspace of its own: the largest frame
# of an .ico, .png or .jpg, at most 512 px, drawn on a background colour when there is one,
# saved as PNG. Returns its side, or 0 for a picture that is not square enough to be an icon -
# a web page's banner taken for one.
$script:IconWork = {
    param([string]$Source, [string]$Target, [string]$Background)
    Add-Type -AssemblyName PresentationCore, WindowsBase
    $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create([IO.MemoryStream]::new([IO.File]::ReadAllBytes($Source)), 'None', 'OnLoad')
    $frame = $decoder.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1
    $longest = [Math]::Max($frame.PixelWidth, $frame.PixelHeight)
    if ($longest -gt 1.25 * [Math]::Max(1, [Math]::Min($frame.PixelWidth, $frame.PixelHeight))) { return 0 }
    [Windows.Media.Imaging.BitmapSource]$picture = $frame
    # Intune keeps the logo in the app itself, sent in full with every change: a Store page's
    # 1080 px picture is ten times what the Company Portal ever shows
    if ($longest -gt 512) {
        $picture = [Windows.Media.Imaging.TransformedBitmap]::new($frame, [Windows.Media.ScaleTransform]::new(512 / $longest, 512 / $longest))
    }
    $side = [Math]::Max($picture.PixelWidth, $picture.PixelHeight)
    if ($Background) {
        $visual = [Windows.Media.DrawingVisual]::new()
        $context = $visual.RenderOpen()
        $context.DrawRectangle([Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($Background)), $null,
                               [Windows.Rect]::new(0, 0, $side, $side))
        $context.DrawImage($picture, [Windows.Rect]::new(($side - $picture.PixelWidth) / 2, ($side - $picture.PixelHeight) / 2, $picture.PixelWidth, $picture.PixelHeight))
        $context.Close()
        $picture = [Windows.Media.Imaging.RenderTargetBitmap]::new($side, $side, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $picture.Render($visual)
    }
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($picture))
    $output = [IO.File]::Create($Target)
    try { $encoder.Save($output) } finally { $output.Dispose() }
    $side
}

function Invoke-StaWork {
    param([Parameter(Mandatory)][scriptblock]$Work, [object[]]$Arguments = @())
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') { return & $Work @Arguments }
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    try {
        [void]$shell.AddScript($Work.ToString())
        foreach ($argument in $Arguments) { [void]$shell.AddArgument($argument) }
        $shell.Invoke()
    }
    finally { $shell.Dispose(); $runspace.Dispose() }
}

# The icon a catalog names, saved as a PNG: an .ico is converted, because Intune's logo has to
# be a PNG or a JPEG, and a Store tile is drawn on its own colour. Its side in pixels, or $null
# when there was none to get.
function Save-WinGetIcon {
    param([string]$Url, [Parameter(Mandatory)][string]$Destination, [string]$Background)
    if (-not $Url) { return $null }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('Packwright-wingeticon-{0}' -f [guid]::NewGuid())
    try {
        Invoke-WebRequest -Uri $Url -OutFile $temporary -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop | Out-Null
        $head = [byte[]]::new(4)
        $stream = [IO.File]::OpenRead($temporary)
        try { [void]$stream.Read($head, 0, 4) } finally { $stream.Dispose() }
        $png  = $head[0] -eq 0x89 -and $head[1] -eq 0x50
        $jpeg = $head[0] -eq 0xFF -and $head[1] -eq 0xD8
        $ico  = $head[0] -eq 0 -and $head[1] -eq 0 -and $head[2] -eq 1 -and $head[3] -eq 0
        if (-not ($png -or $jpeg -or $ico)) { return $null }
        $side = @(Invoke-StaWork -Work $script:IconWork -Arguments @($temporary, $Destination, $Background))[-1]
        if ($side -gt 0) { $side } else { $null }
    }
    catch { $null }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

# The icon on the app's page in the web Store, apps.microsoft.com: the one place that has one
# for the Store's Win32 apps (XP ids), which its other catalogs leave out. The page gives it as
# its og:image, and says in iconUrlBackground whether it is meant to be drawn on a colour.
function Get-StoreWebIcon {
    param([Parameter(Mandatory)][string]$Id, $Policy = (Get-PackwrightPolicy))
    try {
        $page = Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop -Uri (
            'https://apps.microsoft.com/detail/{0}?hl={1}&gl={2}' -f $Id.ToLowerInvariant(), [Uri]::EscapeDataString($Policy.StoreLocale), $Policy.StoreMarket)
        Read-StoreWebIcon -Html "$($page.Content)"
    }
    catch { $null }
}

function Read-StoreWebIcon {
    param([string]$Html)
    $meta = [regex]::Match($Html, '<meta[^>]*property="og:image"[^>]*>').Value
    $url = [Net.WebUtility]::HtmlDecode([regex]::Match($meta, 'content="([^"]+)"').Groups[1].Value)
    if ($url -notmatch '^https://') { return $null }
    [pscustomobject]@{ Url = $url; Background = [regex]::Match($Html, '"iconUrlBackground"\s*:\s*"(#[0-9A-Fa-f]{6})"').Groups[1].Value }
}
#endregion

#region ---- The app's own icon ----------------------------------------------------
# A package without a logo shows in the Company Portal with a generic icon. The catalogs name
# one for Store apps and, now and then, for a community package; for the rest the app's own
# icon is taken from where it is: the app installed on this computer, or else the installer the
# manifest names - downloaded here, checked against the manifest's SHA-256 the way winget
# checks it, read without being run, and deleted again.

# More than this is not downloaded just for an icon
$script:IconDownloadLimitMB = 200

# PrivateExtractIcons gives the largest icon in an .exe or .dll, up to 256 px; .NET only gives
# the 32 px one. The type the studio compiles for the same purpose, so whichever comes first
# serves both - a second Add-Type of the same name would fail.
function Initialize-WinGetIconApi {
    if ('StudioIconApi' -as [type]) { return $true }
    try {
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
        $true
    }
    catch { $false }
}

# How large the icons in a program file really are. PrivateExtractIcons hands back whatever
# size it is asked for, scaling up when it has to: asked for 256 px from 7-Zip's installer, it
# returns its 32 px icon blown up into blocks. The icon group says which sizes are there.
function Get-WinGetNativeIconSize {
    param([Parameter(Mandatory)][string]$File, [int]$Index = 0)
    try {
        if (-not ('PackwrightIconSizes' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PackwrightIconSizes {
    delegate bool EnumNameProc(IntPtr module, IntPtr type, IntPtr name, IntPtr param);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadLibraryEx(string file, IntPtr reserved, uint flags);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool EnumResourceNames(IntPtr module, IntPtr type, EnumNameProc callback, IntPtr param);
    [DllImport("kernel32.dll")] static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll")] static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] static extern IntPtr LockResource(IntPtr data);
    [DllImport("kernel32.dll")] static extern uint SizeofResource(IntPtr module, IntPtr resource);

    // The largest icon in the index-th icon group, read as data, never run; 0 when there is none
    public static int Largest(string file, int index) {
        IntPtr module = LoadLibraryEx(file, IntPtr.Zero, 0x2 | 0x20);
        if (module == IntPtr.Zero) return 0;
        try {
            IntPtr group = IntPtr.Zero;
            int seen = 0;
            EnumResourceNames(module, (IntPtr)14, (m, t, name, p) => {
                if (seen++ != index) return true;
                group = FindResource(m, name, t);
                return false;
            }, IntPtr.Zero);
            if (group == IntPtr.Zero) return 0;
            IntPtr data = LockResource(LoadResource(module, group));
            uint length = SizeofResource(module, group);
            if (data == IntPtr.Zero || length < 6) return 0;
            int largest = 0;
            for (int i = 0; i < Marshal.ReadInt16(data, 4) && 6 + (i + 1) * 14 <= length; i++) {
                int width = Marshal.ReadByte(data, 6 + i * 14);
                largest = Math.Max(largest, width == 0 ? 256 : width);
            }
            return largest;
        }
        finally { FreeLibrary(module); }
    }
}
'@
        }
        [PackwrightIconSizes]::Largest($File, $Index)
    }
    catch { 0 }
}

# The icon in an .exe, .dll or .ico as a PNG; its side in pixels, or $null. Told apart by their
# first bytes rather than their names: what an MSI's Icon table holds has no extension.
function Export-WinGetFileIcon {
    param([Parameter(Mandatory)][string]$File, [int]$Index = 0, [Parameter(Mandatory)][string]$Destination)
    $head = [byte[]]::new(4)
    try {
        $stream = [IO.File]::OpenRead($File)
        try { [void]$stream.Read($head, 0, 4) } finally { $stream.Dispose() }
    }
    catch { return $null }
    if ($head[0] -eq 0 -and $head[1] -eq 0 -and $head[2] -eq 1 -and $head[3] -eq 0) {
        try { $side = @(Invoke-StaWork -Work $script:IconWork -Arguments @($File, $Destination, ''))[-1] } catch { return $null }
        return $(if ($side -gt 0) { $side } else { $null })
    }
    if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A -or -not (Initialize-WinGetIconApi)) { return $null }   # 'MZ': a program file
    Add-Type -AssemblyName System.Drawing
    # The size the file has, so a small icon is reported as small rather than enlarged
    $native = Get-WinGetNativeIconSize -File $File -Index $Index
    $sizes = if ($native -ge 16) { @([Math]::Min(256, $native)) } else { @(256, 128, 64, 48, 32) }
    foreach ($size in $sizes) {
        $handles = [IntPtr[]]::new(1)
        $ids = [int[]]::new(1)
        $found = [StudioIconApi]::PrivateExtractIcons($File, $Index, $size, $size, $handles, $ids, 1, 0)
        if ($found -le 0 -or $handles[0] -eq [IntPtr]::Zero) { continue }
        $icon = $null; $bitmap = $null
        try {
            $icon = [Drawing.Icon]::FromHandle($handles[0])
            $bitmap = $icon.ToBitmap()
            $bitmap.Save($Destination, [Drawing.Imaging.ImageFormat]::Png)
            return $bitmap.Width
        }
        catch { }
        finally {
            if ($bitmap) { $bitmap.Dispose() }
            if ($icon) { $icon.Dispose() }
            [void][StudioIconApi]::DestroyIcon($handles[0])
        }
    }
    $null
}

# A DisplayIcon value: "C:\path\app.exe,0", a bare path, quoted or not, %variables% and all.
# @{ File; Index }, or $null when the file is not there.
function Resolve-WinGetIconReference {
    param([string]$Reference)
    $path = [Environment]::ExpandEnvironmentVariables("$Reference".Trim()).Trim('"')
    $index = 0
    if ($path -match '^(?<file>.*?),\s*(?<index>-?\d+)\s*$') {
        $path = $Matches.file.Trim().Trim('"')
        $index = [Math]::Max(0, [int]$Matches.index)
    }
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return @{ File = $path; Index = $index } }
    $null
}

# An Apps and features name that is this app: the same name, or the name and then its version
# ('7-Zip 26.04 (x64 edition)'). Never just the same beginning - 'Microsoft Edge WebView2
# Runtime' is not Microsoft Edge.
function Test-WinGetAppName {
    param([string]$DisplayName, [string[]]$Names)
    foreach ($name in @($Names | Where-Object { $_ })) {
        if ($DisplayName -ieq $name) { return $true }
        if ($DisplayName.Length -gt $name.Length + 1 -and $DisplayName.StartsWith("$name ", [StringComparison]::OrdinalIgnoreCase) -and
            $DisplayName.Substring($name.Length + 1) -match '^v?\d') { return $true }
    }
    $false
}

# The app installed on this computer, if it is: found by what the manifest says it writes - the
# uninstall key, an MSI's upgrade code - or else by its name in Apps and features. Its own
# DisplayIcon: @{ File; Index; From }, or $null.
function Find-WinGetInstalledIcon {
    param([Parameter(Mandatory)]$Info, $Plan)
    $keys = [Collections.Generic.List[string]]::new()
    if ($Plan -and $Plan.ProductCode) { $keys.Add("$($Plan.ProductCode)") }
    foreach ($installer in @($Info.Installers)) {
        if ($installer.ProductCode) { $keys.Add("$($installer.ProductCode)") }
        foreach ($entry in @($installer.Arp)) { if ($entry.ProductCode) { $keys.Add("$($entry.ProductCode)") } }
    }
    $upgradeCodes = @(@($Info.Installers).Arp | ForEach-Object { $_.UpgradeCode } | Where-Object { Test-WinGetGuid $_ } | Select-Object -Unique)
    if ($upgradeCodes) {
        try {
            $msi = New-Object -ComObject WindowsInstaller.Installer
            foreach ($code in $upgradeCodes) {
                # [string]: a value out of a pipeline is wrapped, and COM refuses the wrapper (DISP_E_TYPEMISMATCH)
                foreach ($product in @($msi.GetType().InvokeMember('RelatedProducts', 'GetProperty', $null, $msi, @([string]$code)))) { $keys.Add("$product") }
            }
        }
        catch { }
    }
    $names = @(@(@($Info.Installers).Arp | ForEach-Object { $_.DisplayName }) + $Info.Name | Where-Object { $_ } | Select-Object -Unique)
    $byName = $null
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                      'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall') {
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $entry = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            $icon = Resolve-WinGetIconReference "$($entry.DisplayIcon)"
            if (-not $icon) { continue }
            $icon.From = "$($entry.DisplayName), installed on this computer"
            if ($keys -contains $key.PSChildName) { return $icon }
            if (-not $byName -and (Test-WinGetAppName -DisplayName "$($entry.DisplayName)" -Names $names)) { $byName = $icon }
        }
    }
    $byName
}

# A download that stops at a size, rather than finding out how big it was afterwards. The proxy
# is the system's, signed in to as this user, as Windows itself would.
function Save-LimitedDownload {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Destination, [int]$LimitMB = $script:IconDownloadLimitMB,
          [string]$Activity = 'Downloading')
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.DefaultProxyCredentials = [Net.CredentialCache]::DefaultCredentials
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(15)
    $limit = [int64]$LimitMB * 1MB
    $hostName = ([Uri]$Url).Host
    try {
        $response = $client.GetAsync($Url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        [void]$response.EnsureSuccessStatusCode()
        $length = $response.Content.Headers.ContentLength
        if ($length -gt $limit) { throw ('it is {0:N0} MB, more than the {1} MB Packwright fetches for an icon' -f ($length / 1MB), $LimitMB) }
        $body = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $output = [IO.File]::Create($Destination)
        try {
            $buffer = [byte[]]::new(1MB)
            $total = 0L
            while (($read = $body.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $total += $read
                if ($total -gt $limit) { throw "it is more than the $LimitMB MB Packwright fetches for an icon" }
                $output.Write($buffer, 0, $read)
                $status = if ($length) { '{0:N0} of {1:N0} MB from {2}' -f ($total / 1MB), ($length / 1MB), $hostName } else { '{0:N0} MB from {1}' -f ($total / 1MB), $hostName }
                Write-Progress -Activity $Activity -Status $status -PercentComplete $(if ($length) { [int](100 * $total / $length) } else { -1 })
            }
        }
        finally { $output.Dispose(); $body.Dispose() }
        Write-Progress -Activity $Activity -Completed
    }
    finally { $client.Dispose(); $handler.Dispose() }
}

# The icon an MSI shows in Apps and features: ARPPRODUCTICON names a row of its Icon table, and
# exporting the table writes each row's binary into a file. Read through Windows Installer's
# database API - nothing in the package runs. The file's path, or $null.
function Export-MsiProductIcon {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Folder)
    $msi = $null; $database = $null; $view = $null; $record = $null
    try {
        $msi = New-Object -ComObject WindowsInstaller.Installer
        # Plain strings and numbers only: a path from Join-Path is wrapped, and COM refuses the
        # wrapper with DISP_E_TYPEMISMATCH
        $database = $msi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $msi, @([string]$Path, [int]0))
        $wanted = ''
        try {
            $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database,
                        @('SELECT `Value` FROM `Property` WHERE `Property` = ''ARPPRODUCTICON'''))
            [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if ($record) { $wanted = "$($record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1)))" }
            [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
        }
        catch { $wanted = '' }
        $exported = Join-Path $Folder 'msi-tables'
        $null = New-Item -ItemType Directory -Path $exported -Force
        [void]$database.GetType().InvokeMember('Export', 'InvokeMethod', $null, $database, @('Icon', [string]$exported, 'Icon.idt'))
        # Each row as a file named after it, with .ibd added
        $icons = @(Get-ChildItem -LiteralPath (Join-Path $exported 'Icon') -File -ErrorAction SilentlyContinue)
        $pick = @($icons | Where-Object { $wanted -and $_.Name -in $wanted, "$wanted.ibd" }) + @($icons | Sort-Object Length -Descending) | Select-Object -First 1
        if ($pick) { $pick.FullName } else { $null }
    }
    catch { $null }
    finally {
        # Let go of the database, or the downloaded file stays locked and cannot be deleted
        foreach ($com in $record, $view, $database, $msi) { if ($com) { try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) } catch { } } }
    }
}

# The icon of the installer the manifest names, into Destination. @{ Size; Note }: Size $null
# and the reason in Note when there was none to take.
function Save-WinGetInstallerIcon {
    param([Parameter(Mandatory)]$Installer, [Parameter(Mandatory)][string]$Destination, [int]$LimitMB = $script:IconDownloadLimitMB)
    $kind = if ($Installer.RequestType -eq 'zip') { '' }
            elseif ($Installer.InstallerType -in 'msi', 'wix') { 'msi' }
            elseif ($Installer.InstallerType -in 'exe', 'nullsoft', 'inno', 'burn', 'portable') { 'exe' }
            else { '' }
    if (-not $kind -or "$($Installer.Url)" -notmatch '^https://' -or "$($Installer.Sha256)" -notmatch '^[0-9A-Fa-f]{64}$') {
        return [pscustomobject]@{ Size = $null; Note = 'the manifest names no installer an icon can be read from' }
    }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('Packwright-installericon-{0}' -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $work -Force
    try {
        $file = Join-Path $work "installer.$kind"
        try { Save-LimitedDownload -Url $Installer.Url -Destination $file -LimitMB $LimitMB -Activity 'Taking the icon from the installer' }
        catch { return [pscustomobject]@{ Size = $null; Note = "the installer was not downloaded: $($_.Exception.Message)" } }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $Installer.Sha256) {
            return [pscustomobject]@{ Size = $null; Note = "the installer from $($Installer.UrlHost) does not match the SHA-256 in the manifest, so it was not opened" }
        }
        $source = if ($kind -eq 'exe') { $file } else { Export-MsiProductIcon -Path $file -Folder $work }
        $size = if ($source) { Export-WinGetFileIcon -File $source -Destination $Destination } else { $null }
        [pscustomobject]@{ Size = $size; Note = $(if ($size) { "the installer from $($Installer.UrlHost)" } else { 'the installer holds no icon' }) }
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

# The icon for a package: the catalog's, the installed app's, the installer's - in that order,
# and on to the next while the best so far is smaller than the Company Portal shows it. A
# community manifest's icon is often 48 px, and 7-Zip's MSI has none while its .exe has one of
# 256. Into Folder as icon.png. @{ File; From; Size } - File $null and the reason in From when
# there was none.
function Save-WinGetPackageIcon {
    param([Parameter(Mandatory)]$Info, $Plan, [Parameter(Mandatory)][string]$Folder, [switch]$NoDownload)
    $work = Join-Path ([IO.Path]::GetTempPath()) ('Packwright-icon-{0}' -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $work -Force
    $best = $null
    $missing = [Collections.Generic.List[string]]::new()
    $sharp = 128
    try {
        if ($Info.IconUrl) {
            $path = Join-Path $work 'catalog.png'
            $size = Save-WinGetIcon -Url $Info.IconUrl -Destination $path -Background "$($Info.IconBackground)"
            if ($size) { $best = [pscustomobject]@{ Size = $size; Path = $path; From = $(if ($Info.Source -eq 'msstore') { 'the Microsoft Store' } else { 'the manifest' }) } }
        }
        if (-not $best) { $missing.Add('the catalog has none') }
        if (-not $best -or $best.Size -lt $sharp) {
            $installed = Find-WinGetInstalledIcon -Info $Info -Plan $Plan
            $path = Join-Path $work 'installed.png'
            $size = if ($installed) { Export-WinGetFileIcon -File $installed.File -Index $installed.Index -Destination $path }
            if ($size -gt $(if ($best) { $best.Size } else { 0 })) { $best = [pscustomobject]@{ Size = $size; Path = $path; From = $installed.From } }
            if (-not $installed) { $missing.Add('the app is not installed on this computer') }
        }
        $installer = if ($Plan) { $Plan.Installer } else { $null }
        if ((-not $best -or $best.Size -lt $sharp) -and $installer) {
            if ($NoDownload) { $missing.Add('the installer was not to be downloaded') }
            else {
                # The installer winget runs, and an .exe of the same app after it, should that be an MSI without an icon
                $others = @($Info.Installers | Where-Object { $_ -ne $installer -and $_.InstallerType -in 'exe', 'nullsoft', 'inno', 'burn' -and $_.RequestType -ne 'zip' } |
                            Sort-Object { if ($_.Architecture -eq $installer.Architecture) { 0 } else { 1 } } | Select-Object -First 1)
                $attempt = 0
                foreach ($candidate in @($installer) + $others) {
                    $attempt++
                    $path = Join-Path $work "installer-$attempt.png"
                    $taken = Save-WinGetInstallerIcon -Installer $candidate -Destination $path
                    if ($taken.Size -gt $(if ($best) { $best.Size } else { 0 })) { $best = [pscustomobject]@{ Size = $taken.Size; Path = $path; From = $taken.Note } }
                    if (-not $taken.Size) { $missing.Add($taken.Note) }
                    if ($best -and $best.Size -ge $sharp) { break }
                }
            }
        }
        if ($best) {
            Copy-Item -LiteralPath $best.Path -Destination (Join-Path $Folder 'icon.png') -Force
            return [pscustomobject]@{ File = 'icon.png'; From = $best.From; Size = $best.Size }
        }
        [pscustomobject]@{ File = $null; From = (($missing | Select-Object -Unique) -join ', '); Size = 0 }
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
#endregion

#region ---- Script templates (they run on the devices) --------------------------------
# Everything below is written into package folders and runs on the devices, so it is held to
# what the devices have: Windows PowerShell 5.1, started by the Intune Management Extension as a
# 32-bit process, as SYSTEM or as the signed-in user, with no console. Three rules follow:
#   - 5.1 syntax only, and plain ASCII: a script without a BOM is read in the ANSI code page
#     by 5.1, so one em dash in a comment is enough to break a string on a Swedish device
#   - a detection or requirement script writes nothing but its answer: Intune reads any text
#     as "detected", and anything on the error stream as "not installed"
#   - no test hooks: a switch that points SYSTEM at another winget.exe would be a way to run
#     anything as SYSTEM. The self-test swaps functions in a copy instead.
# Values are filled in where a token like __ID__ stands. The same parameters always give the
# same bytes, which is what lets Packwright tell a current script from an old or edited one.

# The 64-bit restart. Intune starts powershell.exe from a 32-bit process and so gets the 32-bit
# Windows PowerShell, where Program Files means Program Files (x86) and the AppX and DISM
# cmdlets do not load. The arguments are read back from the command line exactly as Intune
# passed them, so nothing is quoted a second time on the way through.
$script:TplRelaunch = @'
# --- Run as 64-bit -------------------------------------------------------------------------
# Intune starts powershell.exe from a 32-bit process, which gets the 32-bit PowerShell: there,
# Program Files is Program Files (x86) and the AppX and DISM cmdlets do not load. Start again
# as 64-bit with the arguments exactly as Intune gave them.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $nativeShell = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $nativeShell) {
        $commandLine = [Environment]::CommandLine.TrimStart()
        if ($commandLine.StartsWith('"')) { $passOn = $commandLine.Substring($commandLine.IndexOf('"', 1) + 1) }
        else {
            $space = $commandLine.IndexOf(' ')
            $passOn = if ($space -lt 0) { '' } else { $commandLine.Substring($space) }
        }
        $restart = New-Object System.Diagnostics.ProcessStartInfo $nativeShell, $passOn.Trim()
        $restart.UseShellExecute = $false
        $restart.WorkingDirectory = (Get-Location).ProviderPath
        $restarted = [Diagnostics.Process]::Start($restart)
        $restarted.WaitForExit()
        exit $restarted.ExitCode
    }
}
'@

$script:TplLog = @'
# --- Log -----------------------------------------------------------------------------------
# Beside the Intune Management Extension's own logs, so 'Collect diagnostics' brings it along.
# A per-user install runs as a user who cannot write there, and logs to %TEMP% instead.
$script:RunnerLog = $null
foreach ($logFolder in @((Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'), $env:TEMP)) {
    if (-not $logFolder) { continue }
    try {
        if (-not (Test-Path -LiteralPath $logFolder)) { [void](New-Item -ItemType Directory -Path $logFolder -Force) }
        $candidate = Join-Path $logFolder $LogName
        [IO.File]::AppendAllText($candidate, '')
        $script:RunnerLog = $candidate
        break
    }
    catch { }
}

function Write-RunnerLog {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    if (-not $script:RunnerLog) { return }
    try {
        $existing = Get-Item -LiteralPath $script:RunnerLog -ErrorAction SilentlyContinue
        if ($existing -and $existing.Length -gt 1MB) {
            Move-Item -LiteralPath $script:RunnerLog -Destination ($script:RunnerLog -replace '\.log$', '.lo_') -Force
        }
        [IO.File]::AppendAllText($script:RunnerLog, $line + "`r`n", [Text.Encoding]::UTF8)
    }
    catch { }
}

function Exit-Runner {
    param([int]$Code, [string]$Reason)
    if ($Reason) { Write-RunnerLog $Reason }
    Write-RunnerLog ('==== Exit code {0} (0x{0:X8})' -f $Code)
    exit $Code
}
'@

# What every script needs to find and run winget, read policy and talk about the result. The
# detection and requirement scripts take this too and stay silent: nothing here writes output.
$script:TplTools = @'
# --- Tools ---------------------------------------------------------------------------------
# A command line the way a C program splits it again: quote what has spaces or quotes in it,
# and double the backslashes that come before a quote.
function ConvertTo-CommandLineArgument {
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    '"' + $escaped + '"'
}

# Run a program and keep what it printed. Started directly rather than with '&', because 5.1
# re-quotes arguments that contain quotes wrongly, and turns the first line on the error stream
# into a terminating error when ErrorActionPreference is Stop. One still running after
# -TimeoutSeconds is stopped - itself, not what it started - and what it printed until then is
# kept, unless something it started holds its output open.
function Invoke-Tool {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 0)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $FilePath
    $start.Arguments = (@($Arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timedOut = $TimeoutSeconds -gt 0 -and -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        try { $process.Kill() } catch { }
        [void]$process.WaitForExit(5000)
        $printed = @(foreach ($stream in $stdout, $stderr) { try { if ($stream.Wait(5000)) { $stream.Result } } catch { } })
    }
    else {
        $process.WaitForExit()
        $printed = @($stdout.Result, $stderr.Result)
    }
    $lines = @(($printed -join "`n") -split '\r?\n' | ForEach-Object {
        # Progress bars and spinners redraw with carriage returns: keep what stayed on the line
        $shown = ($_ -split "`r")[-1].TrimEnd()
        if ($shown -and $shown -notmatch '^\s*[-\\|/]\s*$' -and $shown -notmatch ('[' + [char]0x2580 + '-' + [char]0x259F + ']')) { $shown }
    })
    [pscustomobject]@{ ExitCode = $(if ($timedOut) { -1 } else { $process.ExitCode }); Output = $lines; TimedOut = $timedOut; ProcessId = $process.Id }
}

function Get-NativeArchitecture {
    $name = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($name) { 'AMD64' { 'x64' } 'ARM64' { 'arm64' } default { 'x86' } }
}

# A value under HKLM from the 64-bit registry, whatever this process is
function Get-MachineValue {
    param([string]$Key, [string]$Name)
    try {
        $view = if ([Environment]::Is64BitOperatingSystem) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Registry32 }
        $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        $opened = $hive.OpenSubKey($Key)
        if ($opened) { return $opened.GetValue($Name) }
    }
    catch { }
    $null
}

# SYSTEM has no 'winget' command: the alias that makes it work lives in each user's profile.
# SYSTEM has to run winget.exe out of the App Installer package folder by its full path - the
# newest one there for this processor.
function Find-WinGet {
    if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        $alias = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($alias) { return [pscustomobject]@{ Path = $alias.Source; Version = $null } }
    }
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $pattern = 'Microsoft.DesktopAppInstaller_*_{0}__8wekyb3d8bbwe' -f (Get-NativeArchitecture)
    $best = $null
    foreach ($folder in @(Get-ChildItem -LiteralPath (Join-Path $programFiles 'WindowsApps') -Directory -Filter $pattern -ErrorAction SilentlyContinue)) {
        $exe = Join-Path $folder.FullName 'winget.exe'
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        $folderVersion = $null
        try { $folderVersion = [version]($folder.Name.Split('_')[1]) } catch { continue }
        if (-not $best -or $folderVersion -gt $best.Version) { $best = [pscustomobject]@{ Path = $exe; Version = $folderVersion } }
    }
    $best
}

# winget, if it starts and is new enough: @{ Path; Version; Problem }. Started by its full path
# it needs the Visual C++ runtime, which an image does not always have; without it the process
# dies before it prints anything, with 0xC0000135.
function Test-WinGet {
    param([version]$Minimum)
    $found = Find-WinGet
    if (-not $found) {
        return [pscustomobject]@{ Path = $null; Version = $null; Problem = 'WinGet was not found for this account: App Installer is missing, or not registered yet on a new device.' }
    }
    $probe = Invoke-Tool -FilePath $found.Path -Arguments @('--version') -TimeoutSeconds 120
    if ($probe.TimedOut) { return [pscustomobject]@{ Path = $found.Path; Version = $found.Version; Problem = 'winget --version did not answer within two minutes.' } }
    if ($probe.ExitCode -eq 0xC0000135 -or $probe.ExitCode -eq 0xC000007B) {
        return [pscustomobject]@{ Path = $found.Path; Version = $found.Version
            Problem = ('winget.exe could not start (0x{0:X8}): started by its full path it needs the Visual C++ runtime, which is missing.' -f $probe.ExitCode) }
    }
    $reported = $null
    foreach ($line in $probe.Output) {
        if ($line -match '(\d+\.\d+\.\d+)') { try { $reported = [version]$Matches[1] } catch { }; break }
    }
    $version = if ($reported) { $reported } else { $found.Version }
    if (-not $version -or (ConvertTo-FullVersion $version) -lt (ConvertTo-FullVersion $Minimum)) {
        return [pscustomobject]@{ Path = $found.Path; Version = $version; Problem = ('WinGet {0} is older than {1}.' -f $version, $Minimum) }
    }
    [pscustomobject]@{ Path = $found.Path; Version = $version; Problem = $null }
}

# Four parts, the missing ones as 0. A [version] with fewer parts counts its missing ones as -1,
# so 1.29.380 is less than 1.29.380.0 - and winget says the one while App Installer says the other.
function ConvertTo-FullVersion {
    param([version]$Version)
    if (-not $Version) { return $null }
    New-Object System.Version $Version.Major, $Version.Minor, ([Math]::Max(0, $Version.Build)), ([Math]::Max(0, $Version.Revision))
}

# The leading digits-and-dots of a version text as a [version] ('26.04' -> 26.4.0.0), or $null
function ConvertTo-ComparableVersion {
    param([string]$Text)
    if ($Text -notmatch '^\s*v?(\d+(?:\.\d+){0,3})') { return $null }
    $parts = @($Matches[1].Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    try { [version]($parts -join '.') } catch { $null }
}
'@

# What the install and uninstall scripts share beyond the tools: the policy check and the
# translation of winget's result into what Intune acts on.
$script:TplRunner = @'
# --- Policy ------------------------------------------------------------------------------
# A source that policy turns off cannot be reached at all. Say which policy, rather than leave
# winget's 'source not found' to be puzzled over in the Intune portal.
function Get-PolicyBlock {
    $appInstaller = 'SOFTWARE\Policies\Microsoft\Windows\AppInstaller'
    $blocked = @()
    if ((Get-MachineValue $appInstaller 'EnableAppInstaller') -eq 0) { $blocked += 'App Installer is turned off (EnableAppInstaller)' }
    if ((Get-MachineValue $appInstaller 'EnableWindowsPackageManagerCommandLineInterfaces') -eq 0) {
        $blocked += 'the WinGet command line is turned off (EnableWindowsPackageManagerCommandLineInterfaces)'
    }
    if ($Source -eq 'msstore' -and (Get-MachineValue $appInstaller 'EnableMicrosoftStoreSource') -eq 0) {
        $blocked += 'the Microsoft Store source is turned off (EnableMicrosoftStoreSource)'
    }
    if ($Source -eq 'winget' -and (Get-MachineValue $appInstaller 'EnableDefaultSource') -eq 0) {
        $blocked += 'the WinGet community repository is turned off (EnableDefaultSource)'
    }
    if ($blocked) { return ('Policy on this device: ' + ($blocked -join '; ') + '.') }
    $null
}

function Write-StoreBlockNote {
    if ($Source -eq 'msstore' -and (Get-MachineValue 'SOFTWARE\Policies\Microsoft\WindowsStore' 'RemoveWindowsStore') -eq 1) {
        Write-RunnerLog ('Note: the Microsoft Store app is turned off on this device (RemoveWindowsStore). WinGet''s command line ' +
                         'refuses Store installs then (0x8A15001B); Intune''s own Microsoft Store app type is not affected.')
    }
}

# --- Result --------------------------------------------------------------------------------
$script:RetryLater = @{
    '0x8A150101' = 'the application is running'
    '0x8A150102' = 'another installation is in progress'
    '0x8A150103' = 'a file it needs is in use'
    '0x8A150111' = 'the application is in use by another application'
    '0x8A150107' = 'there is no network connection'
    '0x8A150008' = 'the installer could not be downloaded'
    '0x8A15002E' = 'the download came back the wrong size'
    '0x8A150086' = 'the download came back empty'
    '0x8A15006D' = 'a service it needs is busy'
    '0x8A150045' = 'the source could not be opened'
    '0x8A15004B' = 'a source could not be opened'
    '0x8A15007F' = 'the Microsoft Store catalog could not be reached'
    '0x8A150081' = 'the Microsoft Store download details could not be fetched'
    '0x8A150083' = 'the Microsoft Store license could not be fetched'
    '0x8A15010A' = 'the device has to restart before it can install'
    '0x8A150106' = 'there is not enough memory'
}
$script:FailureNote = @{
    '0x8A15001B' = ('the Microsoft Store app is blocked by policy on this device. WinGet''s command line refuses Store installs ' +
                    'then; Intune''s own Microsoft Store app type does not - publish the app that way instead')
    '0x8A15001C' = 'this Store app is blocked by policy on this device'
    '0x8A15003A' = 'a Group Policy blocks it'
    '0x8A150010' = 'none of the installers fits this device: its architecture, the scope, the installer type - or for a Store app, the country or region the device is set to'
    '0x8A150011' = 'the downloaded installer does not match the hash in the manifest; nothing was run'
    '0x8A150014' = 'no package with this id was found in the source'
    '0x8A150041' = 'the package agreements were not accepted'
    '0x8A150046' = 'the source agreements were not accepted'
    '0x8A150085' = 'the Microsoft Store would not license the app for this device'
    '0x8A150105' = 'the disk is full'
    '0x8A150113' = 'the package is not supported on this version of Windows'
}

function ConvertTo-IntuneResult {
    param([int]$Code, [string]$Action)
    $hex = '0x{0:X8}' -f $Code
    if ($Code -eq 0) { Write-RunnerLog "WinGet: $Action succeeded."; return 0 }
    $already = @{
        '0x8A150061' = 'a version of it is already installed'
        '0x8A15010D' = 'another version is already installed'
        '0x8A15010E' = 'a newer version is already installed'
        '0x8A15002B' = 'it is installed and there is nothing newer'
    }
    if ($Action -eq 'install' -and $already.ContainsKey($hex)) {
        Write-RunnerLog ("WinGet {0}: {1}. Counted as installed - Intune's detection rule has the last word." -f $hex, $already[$hex])
        return 0
    }
    if ($Action -eq 'uninstall' -and $hex -eq '0x8A150014') {
        Write-RunnerLog 'Nothing to remove: WinGet finds no installed package with this id.'
        return 0
    }
    if ($hex -eq '0x8A150109') { Write-RunnerLog 'A restart finishes the installation.'; return 3010 }
    if ($hex -eq '0x8A15010B') { Write-RunnerLog 'The installer started a restart.'; return 1641 }
    if ($script:RetryLater.ContainsKey($hex)) {
        Write-RunnerLog ('WinGet {0}: {1}. Intune tries again in five minutes.' -f $hex, $script:RetryLater[$hex])
        return 1618
    }
    $note = if ($script:FailureNote.ContainsKey($hex)) { $script:FailureNote[$hex] } else { "look it up with: winget error $hex" }
    Write-RunnerLog ('WinGet failed with {0}: {1}.' -f $hex, $note)
    $Code
}

# winget's own log of the run, copied beside ours. Where winget keeps it depends on how it was
# started, so ask winget --info before the run, and take the log written after it started. As
# SYSTEM that is SystemTemp, where SYSTEM's temporary files go on current Windows - not the %TEMP%
# this script is given - so SystemTemp is looked in by name as well.
$script:WinGetLogFolders = @()
function Find-WinGetLogFolder {
    param([string]$WinGet)
    $folders = @()
    try {
        foreach ($line in (Invoke-Tool -FilePath $WinGet -Arguments @('--info') -TimeoutSeconds 60).Output) {
            if ($line -match '\s{2,}(\S.*\\(DiagOutputDir|defaultState))\s*$') { $folders += [Environment]::ExpandEnvironmentVariables($Matches[1]) }
        }
    }
    catch { }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { $folders += Join-Path $env:SystemRoot 'SystemTemp\WinGet\defaultState' }
    if ($env:TEMP) { $folders += Join-Path $env:TEMP 'WinGet\defaultState' }
    $script:WinGetLogFolders = @($folders | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
}

function Save-WinGetLog {
    param([datetime]$Since)
    if (-not $script:RunnerLog -or -not $script:WinGetLogFolders.Count) { return }
    try {
        $latest = @($script:WinGetLogFolders | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'WinGet-*.log' -File -ErrorAction SilentlyContinue }) |
                  Where-Object { $_.LastWriteTime -ge $Since } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            $copy = $script:RunnerLog -replace '\.log$', '-winget.log'
            Copy-Item -LiteralPath $latest.FullName -Destination $copy -Force
            Write-RunnerLog "WinGet's own log of this run: $copy"
        }
    }
    catch { }
}

function Write-ToolOutput {
    param([string[]]$Lines)
    foreach ($line in $Lines) { if ($line.Trim()) { Write-RunnerLog ('  | ' + $line) } }
}

# --- Time limit and WinGet's install lock ----------------------------------------------------
# Intune gives an install or uninstall command 60 minutes, unless the app is given longer, and
# then stops it with nothing in the log but that it timed out. winget gets until 55 minutes have
# passed instead: one still running then is stopped here, the log says what was going on, and
# 1618 has Intune try again in five minutes. An app given longer in Intune still stops at 55.
$script:Deadline = (Get-Date).AddMinutes(55)

# WinGet runs one installation at a time. Before it starts an installer, winget.exe waits for the
# mutex WinGetCrossProcessInstallLock (WinGet's own name for it, in 1.29) for as long as it
# takes - and without a word when its output goes to a file, as here. One that never lets go, an
# installer that hangs or a stuck WinGet COM server, leaves every winget after it waiting until
# Intune gives up. So the lock is looked at first, and waited for here, ten minutes at most, where
# the wait shows in the log. Should WinGet name it differently one day, no lock is found and the
# time limit is what is left.
$script:LockWaitMinutes = 10

function Test-InstallLockFree {
    $lock = $null
    try {
        if (-not [Threading.Mutex]::TryOpenExisting('WinGetCrossProcessInstallLock', [ref]$lock)) { return $true }
        $taken = $false
        try { $taken = $lock.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $taken = $true }
        if ($taken) { $lock.ReleaseMutex() }
        return $taken
    }
    catch { return $true }
    finally { if ($lock) { $lock.Dispose() } }
}

function Wait-InstallLock {
    if (Test-InstallLockFree) { return $true }
    $until = (Get-Date).AddMinutes($script:LockWaitMinutes)
    if ($until -gt $script:Deadline) { $until = $script:Deadline }
    Write-RunnerLog ('Another installation holds WinGet''s install lock. Waiting for it until {0:HH:mm:ss}.' -f $until)
    while ((Get-Date) -lt $until) {
        Start-Sleep -Seconds 2
        if (Test-InstallLockFree) { Write-RunnerLog 'The other installation has let go of the lock.'; return $true }
    }
    $false
}

function Write-ProcessLine {
    param($Entry)
    $commandLine = "$($Entry.CommandLine)"
    if ($commandLine.Length -gt 300) { $commandLine = $commandLine.Substring(0, 300) + '...' }
    Write-RunnerLog ('  {0}, process {1}, started {2:yyyy-MM-dd HH:mm:ss} by process {3}: {4}' -f
        $Entry.Name, $Entry.ProcessId, $Entry.CreationDate, $Entry.ParentProcessId, $commandLine)
}

# Who else is installing, and since when: when one of them never finishes, this is the line that
# names it. winget, the WinGet COM server that Intune's own Store apps install through, and
# Windows Installer.
function Write-OtherInstallation {
    param([int[]]$Except = @())
    try {
        $others = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop -Filter (
            "Name = 'winget.exe' OR Name = 'WindowsPackageManagerServer.exe' OR Name = 'msiexec.exe'") |
            Where-Object { $Except -notcontains $_.ProcessId })
    }
    catch { Write-RunnerLog ('The running processes could not be listed: ' + $_.Exception.Message); return }
    if (-not $others.Count) { Write-RunnerLog 'No other winget, WinGet COM server or Windows Installer process is running.'; return }
    Write-RunnerLog 'Running now:'
    foreach ($other in $others) { Write-ProcessLine $other }
}

# One winget install or uninstall within the time limit: the install lock waited for first, then
# winget given until the deadline. $null when the lock stayed taken, and a result with TimedOut
# when winget had to be stopped: either way Intune is to try again later.
function Invoke-WinGetAction {
    param([string]$WinGet, [string[]]$Arguments)
    if (-not (Wait-InstallLock)) {
        Write-RunnerLog ('Another installation has held WinGet''s install lock for {0} minutes, and winget would only wait behind it.' -f $script:LockWaitMinutes)
        Write-OtherInstallation
        Write-RunnerLog 'If this keeps happening, whatever holds the lock is stuck. A restart frees it.'
        return $null
    }
    Write-RunnerLog ('winget ' + (@($Arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '))
    $started = Get-Date
    $result = Invoke-Tool -FilePath $WinGet -Arguments $Arguments -TimeoutSeconds ([Math]::Max(1, [int]($script:Deadline - $started).TotalSeconds))
    Write-ToolOutput $result.Output
    if ($result.TimedOut) {
        Write-RunnerLog ('winget was still running after {0:0} minutes, and was stopped.' -f ((Get-Date) - $started).TotalMinutes)
        $children = @()
        try { $children = @(Get-CimInstance -ClassName Win32_Process -Filter ('ParentProcessId = {0}' -f $result.ProcessId) -ErrorAction Stop) } catch { }
        if ($children.Count) {
            Write-RunnerLog 'What it had started is left running - stopping an installer halfway can leave the app half installed:'
            foreach ($child in $children) { Write-ProcessLine $child }
        }
        Write-OtherInstallation -Except (@($result.ProcessId) + @($children | ForEach-Object { $_.ProcessId }))
    }
    Save-WinGetLog -Since $started
    $result
}

function Write-RunnerStart {
    param([string]$What)
    Write-RunnerLog ('==== Packwright WinGet runner {0}: {1}' -f $RunnerVersion, $What)
    Write-RunnerLog ('Running as {0}, Windows PowerShell {1}, {2}-bit, in {3}' -f
        [Security.Principal.WindowsIdentity]::GetCurrent().Name, $PSVersionTable.PSVersion,
        $(if ([Environment]::Is64BitProcess) { 64 } else { 32 }), (Get-Location).ProviderPath)
}
'@

$script:TplInstall = @'
<#
.SYNOPSIS
    Installs __ID__ from the __SOURCELABEL__ with WinGet, for Intune.

.DESCRIPTION
    Packwright WinGet runner __RUNNER__. Generated by Packwright - change the WinGet settings
    in Packwright rather than this file: Packwright checks it is unchanged before publishing.

    Intune runs this as the install command of a Win32 app, under Windows PowerShell 5.1, as
    SYSTEM (or as the signed-in user for an app that installs per user). In order, it:
      - starts again as 64-bit (Intune starts a 32-bit powershell.exe)
      - stops if App Installer or the source is turned off by policy on the device
      - finds winget.exe the way SYSTEM has to, by its full path, and checks it starts and is
        at least version __MINIMUM__
      - waits, ten minutes at most, for another installation to let go of WinGet's install lock
      - installs from exactly the one source it is given, dependencies included, and stops
        winget if it is still running 55 minutes in, before Intune's own limit of 60
      - turns the result into the return codes Intune acts on

    Exit codes: 0 installed, 3010 restart needed, 1641 restart started, 1618 not ready yet -
    WinGet not usable yet, another installation holding WinGet's install lock, or winget
    stopped at the time limit (Intune tries again after five minutes). Any other code is
    WinGet's own: look it up with
        winget error <code>

    Log: %ProgramData%\Microsoft\IntuneManagementExtension\Logs\Packwright-WinGet-<id>.log,
    or %TEMP% when a per-user install cannot write there.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Id,

    [Parameter(Mandatory = $true)]
    [ValidateSet('msstore', 'winget')]
    [string]$Source,

    [string]$Version,

    [ValidateSet('machine', 'user')]
    [string]$Scope,

    [ValidateSet('x86', 'x64', 'arm64')]
    [string]$Architecture,

    [ValidatePattern('^[a-z]+$')]
    [string]$InstallerType,

    [string]$Locale,

    [string]$Override,

    [string]$Custom
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$RunnerVersion = '__RUNNER__'
$MinimumWinGet = [version]'__MINIMUM__'
$LogName = 'Packwright-WinGet-{0}.log' -f ($Id -replace '[^A-Za-z0-9._-]', '_')

__RELAUNCH__
__LOG__
__TOOLS__
__RUNNER_COMMON__
# --- Install -------------------------------------------------------------------------------
Write-RunnerStart ('install {0} from {1}, {2}' -f $Id, $Source, $(if ($Version) { "version $Version" } else { 'the latest version' }))
try {
    if ([Environment]::OSVersion.Version.Build -lt 17763) {
        Exit-Runner 0x8A150113 ('Windows build {0} is older than 17763 (1809), the oldest App Installer runs on.' -f [Environment]::OSVersion.Version.Build)
    }
    $blocked = Get-PolicyBlock
    if ($blocked) { Exit-Runner 0x8A15003A $blocked }
    Write-StoreBlockNote

    $winget = Test-WinGet -Minimum $MinimumWinGet
    if ($winget.Problem) {
        Exit-Runner 1618 ($winget.Problem + ' The WinGet runtime app sets that right; Intune tries this app again in five minutes.')
    }
    Write-RunnerLog ('WinGet {0} at {1}' -f $winget.Version, $winget.Path)
    Find-WinGetLogFolder -WinGet $winget.Path

    # --source and --dependency-source: the package and everything it pulls in come from this
    # one source, and nothing falls back to another one that happens to be configured
    $arguments = @('install', '--id', $Id, '--exact', '--source', $Source, '--dependency-source', $Source,
                   '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($Version)       { $arguments += @('--version', $Version) }
    if ($Scope)         { $arguments += @('--scope', $Scope) }
    if ($Architecture)  { $arguments += @('--architecture', $Architecture) }
    if ($InstallerType) { $arguments += @('--installer-type', $InstallerType) }
    if ($Locale)        { $arguments += @('--locale', $Locale) }
    if ($Override)      { $arguments += @('--override', $Override) }
    if ($Custom)        { $arguments += @('--custom', $Custom) }
    if ($script:RunnerLog) { $arguments += @('--log', ($script:RunnerLog -replace '\.log$', '-installer.log')) }

    $result = Invoke-WinGetAction -WinGet $winget.Path -Arguments $arguments
    if (-not $result -or $result.TimedOut) { Exit-Runner 1618 'Intune tries again in five minutes.' }
    Exit-Runner (ConvertTo-IntuneResult -Code $result.ExitCode -Action 'install')
}
catch {
    Exit-Runner 1 ('Stopped by an unexpected error: ' + $_.Exception.Message)
}
'@

$script:TplUninstall = @'
<#
.SYNOPSIS
    Uninstalls __ID__ (__SOURCELABEL__) with WinGet, for Intune.

.DESCRIPTION
    Packwright WinGet runner __RUNNER__. Generated by Packwright - change the WinGet settings
    in Packwright rather than this file: Packwright checks it is unchanged before publishing.

    Removes the package by its WinGet id. When WinGet cannot - the source is turned off by
    policy since it was installed, or WinGet is gone - it falls back to the product code, and
    for an MSIX app to removing the app package directly, for every user.

    Exit codes, install lock and time limit as for the install script; 0 also when the app is
    not there.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Id,

    [Parameter(Mandatory = $true)]
    [ValidateSet('msstore', 'winget')]
    [string]$Source,

    [ValidateSet('machine', 'user')]
    [string]$Scope,

    [string]$ProductCode,

    [string]$PackageFamilyName
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$RunnerVersion = '__RUNNER__'
$MinimumWinGet = [version]'__MINIMUM__'
$LogName = 'Packwright-WinGet-{0}.log' -f ($Id -replace '[^A-Za-z0-9._-]', '_')

__RELAUNCH__
__LOG__
__TOOLS__
__RUNNER_COMMON__
# An MSIX app without WinGet: take it off every profile and stop it being provisioned for new
# ones (as SYSTEM), or off this user's profile (as the user).
function Remove-AppPackageDirectly {
    param([string]$FamilyName)
    $name = $FamilyName.Substring(0, $FamilyName.LastIndexOf('_'))
    try {
        if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
            foreach ($provisioned in @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $name })) {
                Write-RunnerLog ('Removing the provisioned package {0}' -f $provisioned.PackageName)
                [void](Remove-AppxProvisionedPackage -Online -PackageName $provisioned.PackageName)
            }
            foreach ($installed in @(Get-AppxPackage -AllUsers -Name $name)) {
                Write-RunnerLog ('Removing {0} for every user' -f $installed.PackageFullName)
                Remove-AppxPackage -Package $installed.PackageFullName -AllUsers
            }
        }
        else {
            foreach ($installed in @(Get-AppxPackage -Name $name)) {
                Write-RunnerLog ('Removing {0}' -f $installed.PackageFullName)
                Remove-AppxPackage -Package $installed.PackageFullName
            }
        }
        return 0
    }
    catch {
        Write-RunnerLog ('Removing the app package failed: ' + $_.Exception.Message)
        return 1
    }
}

# --- Uninstall -----------------------------------------------------------------------------
# By the WinGet id first. "Not found" there is not the end of it: the source may have been
# turned off since, or winget may no longer match the id to what is installed. So the product
# code and the app package get their turn, and only when none of them finds anything is there
# nothing to remove.
Write-RunnerStart ('uninstall {0} ({1})' -f $Id, $Source)
try {
    $failure = $null
    $winget = Test-WinGet -Minimum $MinimumWinGet
    if ($winget.Problem) { Write-RunnerLog $winget.Problem }
    else {
        Write-RunnerLog ('WinGet {0} at {1}' -f $winget.Version, $winget.Path)
        Find-WinGetLogFolder -WinGet $winget.Path
        $attempts = @()
        $blocked = Get-PolicyBlock
        if ($blocked) { Write-RunnerLog ($blocked + ' Trying without the source.') }
        else {
            $byId = @('uninstall', '--id', $Id, '--exact', '--source', $Source, '--silent', '--accept-source-agreements', '--disable-interactivity')
            if ($Scope) { $byId += @('--scope', $Scope) }
            $attempts += , $byId
        }
        if ($ProductCode) {
            $byCode = @('uninstall', '--product-code', $ProductCode, '--exact', '--silent', '--accept-source-agreements', '--disable-interactivity')
            if ($Scope) { $byCode += @('--scope', $Scope) }
            $attempts += , $byCode
        }
        foreach ($arguments in $attempts) {
            $result = Invoke-WinGetAction -WinGet $winget.Path -Arguments $arguments
            if (-not $result -or $result.TimedOut) { Exit-Runner 1618 'Intune tries again in five minutes.' }
            if ($result.ExitCode -eq 0x8A150014) { Write-RunnerLog 'WinGet finds nothing installed by that.'; continue }
            $code = ConvertTo-IntuneResult -Code $result.ExitCode -Action 'uninstall'
            if ($code -in 0, 1618, 1641, 3010) { Exit-Runner $code }
            $failure = $code
        }
    }
    if ($PackageFamilyName) { Exit-Runner (Remove-AppPackageDirectly -FamilyName $PackageFamilyName) }
    if ($winget.Problem) { Exit-Runner 1618 'WinGet is not usable on this device yet; Intune tries again in five minutes.' }
    if ($null -ne $failure) { Exit-Runner $failure }
    Exit-Runner 0 'Nothing to remove: neither the WinGet id nor the product code finds the app installed.'
}
catch {
    Exit-Runner 1 ('Stopped by an unexpected error: ' + $_.Exception.Message)
}
'@

# Detection, MSIX: by package family. As SYSTEM (an app installed for every user) the answer
# is "provisioned" - what each profile gets at sign-in, and what the install provisions. A
# machine-wide app that winget installed but did not provision is reported missing, so Intune
# installs it again, and that install provisions it: the rule repairs rather than hides it.
$script:TplDetectAppx = @'
<#
    Packwright WinGet detection __RUNNER__ for __ID__ (__SOURCELABEL__). Generated by Packwright.
    Intune counts the app as installed when this writes a line and exits 0; it writes nothing
    else, and nothing at all to the error stream.
#>
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$familyName = '__FAMILY__'
$name = $familyName.Substring(0, $familyName.LastIndexOf('_'))
$publisherId = $familyName.Substring($familyName.LastIndexOf('_') + 1)
$found = $null
try {
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        $hit = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $name -and $_.PublisherId -eq $publisherId }) | Select-Object -First 1
        if ($hit) { $found = $hit.PackageName }
    }
    else {
        $hit = @(Get-AppxPackage -Name $name | Where-Object { $_.PackageFamilyName -eq $familyName }) | Select-Object -First 1
        if ($hit) { $found = $hit.PackageFullName }
    }
}
catch { $found = $null }
if ($found) { Write-Output ('Installed: ' + $found) }
exit 0
'@

# Detection, MSI: by upgrade code. A product code belongs to one release, and an app that updates
# itself moves on to the next one: a rule on the old code never matches again, Intune installs
# on top, WinGet answers that a newer version is already there, and the device reports the app
# as failed. The upgrade code stays the same from one release to the next, so this finds the app
# whatever version it has moved on to - and for a pinned package, checks it is at least that one.
$script:TplDetectMsi = @'
<#
    Packwright WinGet detection __RUNNER__ for __ID__ (__SOURCELABEL__). Generated by Packwright.
    Looks for an installed MSI with the upgrade code __UPGRADECODE____VERSIONNOTE__. The upgrade
    code stays the same from one version to the next, so an app that updates itself is still
    found. Intune counts the app as installed when this writes a line and exits 0; it writes
    nothing else, and nothing at all to the error stream.
#>
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
__TOOLS__
$upgradeCode = '__UPGRADECODE__'
$minimumVersion = '__MINVERSION__'
$found = $null
try {
    $msi = New-Object -ComObject WindowsInstaller.Installer
    $wanted = ConvertTo-ComparableVersion $minimumVersion
    $related = $msi.GetType().InvokeMember('RelatedProducts', 'GetProperty', $null, $msi, @($upgradeCode))
    foreach ($product in @($related)) {
        $version = "$($msi.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $msi, @($product, 'VersionString')))"
        $have = ConvertTo-ComparableVersion $version
        if (-not $wanted -or ($have -and $have -ge $wanted)) { $found = '{0} {1}' -f $product, $version; break }
    }
}
catch { $found = $null }
if ($found) { Write-Output ('Installed: ' + $found) }
exit 0
'@

# Detection, by asking WinGet: for an app whose manifest names no key that stays put between
# versions (a bundle's code, or Opera's 'Opera 136.0.6008.22'), or does not say whether it
# installs for every user. 'winget list --id' recognises the app the way 'winget upgrade' does,
# and by what winget recorded when it installed it, so it follows the app from one version to
# the next. The Version column is the package version - winget maps the Apps and features
# version onto it - so a pinned package is compared with its own version.
$script:TplDetectWinGet = @'
<#
    Packwright WinGet detection __RUNNER__ for __ID__ (__SOURCELABEL__). Generated by Packwright.
    Asks WinGet whether __ID__ is installed__VERSIONNOTE__, recognising it the way
    winget upgrade does. Intune counts the app as installed when this writes a line and exits 0;
    it writes nothing else, and nothing at all to the error stream.
#>
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
__TOOLS__
$id = '__ID__'
$source = '__SOURCE__'
$minimumVersion = '__MINVERSION__'

# The Version cells of winget's table: the third column, wherever the header puts it and in
# whatever language the header is. Only rows that name the package count; installed for every
# user and for this one too, it is two.
function Get-ListedVersion {
    param([string[]]$Lines, [string]$PackageId)
    for ($i = 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^-{10,}\s*$') { continue }
        $starts = @([regex]::Matches($Lines[$i - 1], '\S+') | ForEach-Object { $_.Index })
        if ($starts.Count -lt 3) { return @() }
        return @(foreach ($row in @($Lines | Select-Object -Skip ($i + 1))) {
            if ($row.IndexOf($PackageId, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or $row.Length -le $starts[2]) { continue }
            $end = if ($starts.Count -gt 3) { [Math]::Min($starts[3], $row.Length) } else { $row.Length }
            $row.Substring($starts[2], $end - $starts[2]).Trim()
        })
    }
    @()
}

$found = $null
try {
    $winget = Test-WinGet -Minimum ([version]'__MINIMUM__')
    if (-not $winget.Problem) {
        $listed = Invoke-Tool -FilePath $winget.Path -TimeoutSeconds 240 -Arguments @(
            'list', '--id', $id, '--exact', '--source', $source, '--accept-source-agreements', '--disable-interactivity')
        if ($listed.ExitCode -eq 0) {
            $versions = @(Get-ListedVersion -Lines $listed.Output -PackageId $id)
            $wanted = ConvertTo-ComparableVersion $minimumVersion
            $older = $false
            if ($wanted -and $versions.Count) {
                # Older only when every row says so. '< 2.0' is winget's way of saying older than
                # any version it knows; a version it cannot read is no reason to install it again.
                $older = $true
                foreach ($version in $versions) {
                    if ($version.StartsWith('<')) { continue }
                    $have = ConvertTo-ComparableVersion $version
                    if (-not $have -or $have -ge $wanted) { $older = $false }
                }
            }
            if (-not $older) { $found = ('{0} {1}' -f $id, ($versions -join ', ')).Trim() }
        }
    }
}
catch { $found = $null }
if ($found) { Write-Output ('Installed: ' + $found) }
exit 0
'@

# Requirement: Intune only offers the app where winget is ready for it. Not applicable is what
# a device without it reports, rather than a failed install - and when the WinGet runtime app
# has run, the next evaluation finds it ready.
$script:TplRequire = @'
<#
    Packwright WinGet requirement __RUNNER__: is WinGet __MINIMUM__ or later ready for this account?
    Generated by Packwright. Writes True or False and nothing else.
#>
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
__TOOLS__
$ready = $false
try { $ready = -not (Test-WinGet -Minimum ([version]'__MINIMUM__')).Problem }
catch { $ready = $false }
Write-Output $ready
exit 0
'@

$script:TplRuntimeInstall = @'
<#
.SYNOPSIS
    Makes WinGet usable for SYSTEM on this device, for the apps Packwright installs with it.

.DESCRIPTION
    Packwright WinGet runtime __RUNNER__. Generated by Packwright.

    Intune runs the WinGet apps Packwright makes as SYSTEM, and SYSTEM starts winget.exe by its
    full path. That needs two things an image does not always have:
      - the Visual C++ runtime: started that way, winget.exe looks for it in System32, and dies
        with 0xC0000135 when it is not there
      - App Installer __APPINSTALLER__ or later, with its framework packages: older versions
        cannot install a Store app for every user as SYSTEM
    This installs whichever is missing or older, from the files in this package, and then
    checks that winget starts. App Installer is provisioned, so every user gets it too.
#>
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$RunnerVersion = '__RUNNER__'
$LogName = 'Packwright-WinGet-runtime.log'

__RELAUNCH__
__LOG__
__TOOLS__
function Get-VCRuntimeVersion {
    param([string]$Architecture)
    $leaf = switch ($Architecture) { 'x64' { 'X64' } 'arm64' { 'ARM64' } default { 'X86' } }
    foreach ($key in "SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\$leaf", "SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\$leaf") {
        if ((Get-MachineValue $key 'Installed') -eq 1) {
            try { return [version]('{0}.{1}.{2}' -f (Get-MachineValue $key 'Major'), (Get-MachineValue $key 'Minor'), (Get-MachineValue $key 'Bld')) }
            catch { }
        }
    }
    $null
}

function Test-FrameworkPresent {
    param([string]$Name, [string]$Version, [string]$Architecture)
    try {
        foreach ($package in @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue)) {
            if ("$($package.Architecture)" -ieq $Architecture -and [version]"$($package.Version)" -ge [version]$Version) { return $true }
        }
    }
    catch { }
    $false
}

$runtime = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime.json') -Raw | ConvertFrom-Json
$architecture = Get-NativeArchitecture
Write-RunnerLog ('==== Packwright WinGet runtime {0}: App Installer {1}, {2}' -f $RunnerVersion, $runtime.appInstaller.version, $architecture)
try {
    if ([Environment]::OSVersion.Version.Build -lt 17763) {
        Exit-Runner 0x8A150113 ('Windows build {0} is older than 17763 (1809), the oldest App Installer runs on.' -f [Environment]::OSVersion.Version.Build)
    }
    $result = 0

    # 1. The Visual C++ runtime winget.exe loads from System32 when started by its full path
    $redist = $runtime.vcRedist.$architecture
    if (-not $redist) { Write-RunnerLog "This package carries no Visual C++ runtime for $architecture." }
    else {
        $have = Get-VCRuntimeVersion -Architecture $architecture
        if ($have -and $have -ge [version]$redist.version) { Write-RunnerLog ('Visual C++ runtime {0} is already here.' -f $have) }
        else {
            Write-RunnerLog ('Installing the Visual C++ runtime {0} (found: {1})' -f $redist.version, $(if ($have) { $have } else { 'none' }))
            $setup = Invoke-Tool -FilePath (Join-Path $PSScriptRoot $redist.file) -Arguments @('/install', '/quiet', '/norestart')
            if ($setup.ExitCode -eq 3010) { $result = 3010; Write-RunnerLog 'The Visual C++ runtime asks for a restart.' }
            elseif ($setup.ExitCode -notin 0, 1638) { Exit-Runner $setup.ExitCode 'The Visual C++ runtime did not install.' }
        }
    }

    # 2. App Installer, provisioned for every user, with the framework packages it needs
    $wanted = [version]$runtime.appInstaller.version
    $current = Find-WinGet
    if ($current -and $current.Version -and $current.Version -ge $wanted) {
        Write-RunnerLog ('App Installer {0} is already here.' -f $current.Version)
    }
    else {
        $dependencies = @(foreach ($dependency in @($runtime.dependencies.$architecture)) {
            if (-not $dependency) { continue }
            if (Test-FrameworkPresent -Name $dependency.name -Version $dependency.version -Architecture $architecture) {
                Write-RunnerLog ('{0} {1} or newer is already here.' -f $dependency.name, $dependency.version)
                continue
            }
            Join-Path $PSScriptRoot $dependency.file
        })
        $provision = @{ Online = $true; PackagePath = (Join-Path $PSScriptRoot $runtime.appInstaller.file); ErrorAction = 'Stop' }
        if ($dependencies) { $provision.DependencyPackagePath = $dependencies }
        if ($runtime.appInstaller.license) { $provision.LicensePath = Join-Path $PSScriptRoot $runtime.appInstaller.license }
        else { $provision.SkipLicense = $true }
        Write-RunnerLog ('Provisioning App Installer {0} (found: {1}) with {2} framework package(s)' -f $wanted,
            $(if ($current -and $current.Version) { $current.Version } else { 'none' }), $dependencies.Count)
        [void](Add-AppxProvisionedPackage @provision)
    }

    # 3. Proof: winget starts for this account
    $winget = Test-WinGet -Minimum $wanted
    if ($winget.Problem) { Exit-Runner 1 ('WinGet is still not usable: ' + $winget.Problem) }
    Write-RunnerLog ('WinGet {0} is ready at {1}' -f $winget.Version, $winget.Path)
    Exit-Runner $result
}
catch {
    Exit-Runner 1 ('Stopped by an unexpected error: ' + $_.Exception.Message)
}
'@

$script:TplRuntimeDetect = @'
<#
    Packwright WinGet runtime detection __RUNNER__. Generated by Packwright.
    Installed when winget starts for SYSTEM and App Installer is __APPINSTALLER__ or later.
    Writes one line when it is, and nothing else.
#>
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
__TOOLS__
$found = $null
try {
    $installed = Find-WinGet
    if ($installed -and $installed.Version -and $installed.Version -ge [version]'__APPINSTALLER__') {
        if (-not (Test-WinGet -Minimum ([version]'__MINIMUM__')).Problem) { $found = $installed.Version }
    }
}
catch { $found = $null }
if ($found) { Write-Output ('WinGet ready: App Installer ' + $found) }
exit 0
'@

$script:TplRuntimeUninstall = @'
<#
    Packwright WinGet runtime __RUNNER__. Generated by Packwright.
    App Installer is part of Windows and the Visual C++ runtime is shared with other programs,
    so removing this app from Intune takes nothing away from the device.
#>
$LogName = 'Packwright-WinGet-runtime.log'
__LOG__
Write-RunnerLog 'WinGet runtime: uninstall requested. App Installer and the Visual C++ runtime stay - other programs use them.'
exit 0
'@

# A fingerprint of the templates as they are in this runner version. A package's scripts are
# judged by it: same version and different text means edited by hand. So a template that
# changes without a new $script:WinGetRunnerVersion would make every package written before it
# look tampered with - and, where an organisation restricts its sources, unpublishable. The
# self-test compares this with the templates and fails until both are brought up to date.
$script:WinGetTemplateHash = 'C9632807FD641746'

function Get-WinGetTemplateHash {
    $text = ($script:TplRelaunch, $script:TplLog, $script:TplTools, $script:TplRunner, $script:TplInstall, $script:TplUninstall,
             $script:TplDetectAppx, $script:TplDetectMsi, $script:TplDetectWinGet, $script:TplRequire, $script:TplRuntimeInstall,
             $script:TplRuntimeDetect, $script:TplRuntimeUninstall | ForEach-Object { $_ -replace '\r?\n', "`n" }) -join "`n----`n"
    $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))
    [Convert]::ToHexString($bytes).Substring(0, 16)
}

# One template filled in. Values are written into single-quoted strings, so a quote in one is
# doubled - and to PowerShell the typographic quotes are quotes too: a name with a curly quote in
# it would end the string, and what follows would run as code.
function Format-WinGetTemplate {
    param([Parameter(Mandatory)][string]$Template, [hashtable]$Values = @{})
    $text = $Template.Replace('__RELAUNCH__', $script:TplRelaunch.TrimEnd()).
                      Replace('__LOG__', $script:TplLog.TrimEnd()).
                      Replace('__TOOLS__', $script:TplTools.TrimEnd()).
                      Replace('__RUNNER_COMMON__', $script:TplRunner.TrimEnd())
    $text = $text.Replace('__RUNNER__', $script:WinGetRunnerVersion).Replace('__MINIMUM__', $script:WinGetMinimumVersion)
    foreach ($key in $Values.Keys) {
        $value = "$($Values[$key])"
        foreach ($quote in [char]0x27, [char]0x2018, [char]0x2019, [char]0x201A, [char]0x201B) { $value = $value.Replace([string]$quote, [string]$quote * 2) }
        $text = $text.Replace("__$($key)__", $value)
    }
    # CRLF, the way a script edited on Windows is saved, so a comparison is not thrown by line ends
    ($text -replace '\r?\n', "`r`n").TrimEnd() + "`r`n"
}
#endregion

#region ---- The plan: how Intune has to run and detect it ---------------------------
# Everything here is decided from the manifest, before anything is installed anywhere:
#   - which installer winget is asked for. Intune's x64 includes ARM64 devices, and an ARM64
#     device left to choose takes the arm64 installer — another product code, a detection rule
#     that never matches, a reinstall every day. 7-Zip has an .exe and an .msi for x64 and
#     winget picks the .msi. So the architecture and the installer type are chosen here and
#     passed to winget, and the detection rule is written for exactly that installer.
#   - SYSTEM or the signed-in user. A per-user installer run as SYSTEM installs into SYSTEM's
#     own profile, where nobody ever sees it, and reports success.
#   - the detection rule, on something that outlives the version installed today: apps update
#     themselves, and a rule on today's product code stops matching the day one does - Intune
#     installs on top, WinGet answers that a newer version is already there, and the device
#     reports a failure. So: the MSIX package family; an MSI's upgrade code; an uninstall key
#     without a version in it; and for everything else, WinGet itself is asked.

function Test-WinGetGuid {
    param([string]$Text)
    $Text -match '^\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$'
}

# An uninstall key that stays the same from one version to the next: not a GUID - an MSI's
# product code or a bundle's code, new with each release - and with nothing in it that is a
# version, like Opera's 'Opera 136.0.6008.22'. Inno Setup's '{...}_is1' stays put, and passes.
function Test-WinGetStableKey {
    param([string]$Key, [string[]]$Versions)
    if (-not $Key -or (Test-WinGetGuid $Key) -or $Key -match '\d+\.\d+') { return $false }
    foreach ($version in $Versions) {
        if ("$version".Length -ge 2 -and $Key.IndexOf("$version", [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
    }
    $true
}

# The upgrade code of an installer that is an MSI itself. A burn bundle has an upgrade code of
# its own, which Windows Installer has never heard of: looked for there, it is never found.
function Get-WinGetUpgradeCode {
    param($Installer)
    if ($Installer.InstallerType -notin 'msi', 'wix') { return '' }
    $entry = @($Installer.Arp) | Where-Object { Test-WinGetGuid $_.UpgradeCode } | Select-Object -First 1
    if ($entry) { $entry.UpgradeCode } else { '' }
}

# A version Intune's version comparison can take: digits and dots, two to four parts
function Test-WinGetComparableVersion {
    param([string]$Text)
    "$Text".Trim() -match '^\d+(\.\d+){1,3}$'
}

function Get-WinGetDetectionKey {
    param($Installer)
    $entry = @($Installer.Arp) | Where-Object { $_.ProductCode } | Select-Object -First 1
    if ($entry) { $entry.ProductCode } else { $Installer.ProductCode }
}

function Select-WinGetInstaller {
    param([object[]]$Installers, [string[]]$Versions)
    $architectureRank = @{ 'x64' = 0; 'x86' = 1; 'neutral' = 2; '' = 3; 'arm64' = 4 }
    $scopeRank = @{ 'machine' = 0; '' = 1; 'user' = 2 }
    $typeRank = @{ 'msix' = 0; 'appx' = 0; 'msi' = 1; 'wix' = 1; 'burn' = 2; 'inno' = 3; 'nullsoft' = 3; 'exe' = 4; 'portable' = 5 }
    @($Installers) | Where-Object { $architectureRank.ContainsKey($_.Architecture) } |
        Sort-Object @{ Expression = { $architectureRank[$_.Architecture] } },
                    @{ Expression = { if ($scopeRank.ContainsKey($_.Scope)) { $scopeRank[$_.Scope] } else { 1 } } },
                    @{ Expression = {
                        # Something the device can detect it by without asking WinGet: 7-Zip's
                        # '7-Zip' key, or its MSI's upgrade code
                        if ($_.PackageFamilyName -and $_.InstallerType -in 'msix', 'appx') { 0 }
                        elseif (Get-WinGetUpgradeCode $_) { 1 }
                        elseif ($_.Scope -in 'machine', 'user' -and (Test-WinGetStableKey -Key (Get-WinGetDetectionKey $_) -Versions $Versions)) { 1 }
                        else { 2 } } },
                    @{ Expression = { if ($typeRank.ContainsKey($_.InstallerType)) { $typeRank[$_.InstallerType] } else { 6 } } } |
        Select-Object -First 1
}

function Get-IntuneArchitectureFor {
    param([string[]]$Architectures)
    if ('x86' -in $Architectures -or 'neutral' -in $Architectures) { return 'neutral' }
    if ('x64' -in $Architectures) { return 'x64' }
    if ('arm64' -in $Architectures) { return 'arm64' }
    'x64'
}

function New-WinGetInstallPlan {
    param(
        [Parameter(Mandatory)]$Info,
        [switch]$Latest,
        [ValidateSet('win32', 'store')][string]$Delivery = 'win32',
        $Policy = (Get-PackwrightPolicy)
    )
    $blockers = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $notes    = [Collections.Generic.List[string]]::new()

    $refusal = Get-WinGetSourceRefusal -Source $Info.Source -Policy $Policy
    if ($refusal) { $blockers.Add($refusal) }
    $installers = @($Info.Installers | Where-Object { $_ })
    if ($Info.Source -eq 'msstore') {
        # The Store hands out free licences to devices; anything bought needs a licence per
        # device that neither winget nor Intune's Store app type can get
        if ($Info.Pricing -and $Info.Pricing -notin 'Free', 'Freemium') {
            $blockers.Add("This Store app is $($Info.Pricing.ToLowerInvariant()), not free. Only free apps can be installed on devices this way.")
        }
        if (-not $installers.Count) {
            $from = if ($Policy.StoreMarketFrom -eq 'policy') { "the storeMarket in $(Split-Path -Leaf $Policy.Path)" }
                    else { "this computer's country or region in Windows; if your devices are elsewhere, set storeMarket in Packwright.policy.json" }
            $blockers.Add(("The Microsoft Store does not offer this app in the $(Format-StoreMarket $Info.Market) market, so devices there cannot install it. " +
                           "The market is $from."))
        }
    }
    if ($Delivery -eq 'store' -and $Info.Source -ne 'msstore') {
        $blockers.Add("Intune's Microsoft Store app type takes apps from the Microsoft Store only.")
    }

    $pinned = $Info.Source -eq 'winget' -and -not $Latest -and [bool]$Info.Version
    $plan = [ordered]@{
        Id = $Info.Id; Source = $Info.Source; Name = $Info.Name; Delivery = $Delivery
        Version = $(if ($pinned) { $Info.Version } else { '' })
        Label = $(if ($pinned) { $Info.Version } else { '' })
        RunAs = 'system'; Scope = ''; Architecture = ''; InstallerType = ''; IntuneArchitecture = 'x64'
        PackageFamilyName = ''; ProductCode = ''; Installer = $null
        Detection = $null; Detect = $null; DetectionText = ''
        Blockers = $blockers; Warnings = $warnings; Notes = $notes
    }
    $hosts = @($installers | ForEach-Object { $_.UrlHost } | Where-Object { $_ } | Select-Object -Unique)

    if ($Delivery -eq 'store') {
        $userOnly = $installers.Count -and -not @($installers | Where-Object { $_.InstallerType -eq 'msstore' -or $_.Scope -ne 'user' }).Count
        $plan.RunAs = if ($userOnly) { 'user' } else { 'system' }
        $plan.IntuneArchitecture = Get-IntuneArchitectureFor @($installers.Architecture)
        $notes.Add("Intune's own Microsoft Store app type installs it, detects it and keeps it up to date. Nothing is built or uploaded, and it keeps working on devices where the Microsoft Store app is blocked.")
        return [pscustomobject]$plan
    }

    $storeApp = @($installers | Where-Object { $_.InstallerType -eq 'msstore' })
    if ($storeApp.Count) {
        # A Store app (MSIX): winget hands it to the Store's install service, which decides the
        # architecture itself, and installs it for every user when asked for machine scope as
        # SYSTEM - provisioned, so new profiles get it too
        $plan.Scope = 'machine'
        $plan.PackageFamilyName = ($storeApp | Where-Object { $_.PackageFamilyName } | Select-Object -First 1).PackageFamilyName
        $plan.IntuneArchitecture = Get-IntuneArchitectureFor @($storeApp.Architecture)
        if ($plan.PackageFamilyName) {
            $plan.Detect = [ordered]@{ kind = 'appx'; packageFamilyName = $plan.PackageFamilyName }
            $plan.Detection = [ordered]@{ type = 'script'; scriptFile = 'Detect-WinGetApp.ps1' }
            $plan.DetectionText = "Intune checks that the app package $($plan.PackageFamilyName) is installed for every user."
        }
        else { $blockers.Add('The Store gives no package family name for this app, so there is nothing to detect it by.') }
        $notes.Add('A Microsoft Store app: installed for every user, and the Store keeps it up to date on the devices by itself.')
    }
    else {
        $chosen = Select-WinGetInstaller -Installers $installers -Versions @($Info.Version)
        if (-not $chosen) {
            # No installers at all is a Store app not offered in this market, said above
            if ($installers.Count) { $blockers.Add('The manifest has no installer for x64, x86 or ARM64 Windows.') }
            return [pscustomobject]$plan
        }
        $plan.Installer = $chosen
        if ($chosen.Architecture -in 'x86', 'x64', 'arm64') { $plan.Architecture = $chosen.Architecture }
        if ($chosen.RequestType) { $plan.InstallerType = $chosen.RequestType }
        if ($chosen.Scope -in 'machine', 'user') { $plan.Scope = $chosen.Scope }
        $plan.RunAs = if ($chosen.Scope -eq 'user') { 'user' } else { 'system' }
        $plan.IntuneArchitecture = switch ($chosen.Architecture) { 'x86' { 'x86,x64' } 'arm64' { 'arm64' } default { 'x64' } }
        $plan.PackageFamilyName = $chosen.PackageFamilyName

        $entry = @($chosen.Arp) | Select-Object -First 1
        $key = Get-WinGetDetectionKey $chosen
        $plan.ProductCode = $key
        $upgradeCode = Get-WinGetUpgradeCode $chosen
        $arpVersion = if ($entry -and $entry.DisplayVersion) { $entry.DisplayVersion } else { $plan.Version }
        $hive = if ($chosen.Scope -eq 'user') { 'HKEY_CURRENT_USER' } else { 'HKEY_LOCAL_MACHINE' }

        if ($chosen.InstallerType -in 'msix', 'appx' -and $chosen.PackageFamilyName) {
            $plan.Detect = [ordered]@{ kind = 'appx'; packageFamilyName = $chosen.PackageFamilyName }
            $plan.Detection = [ordered]@{ type = 'script'; scriptFile = 'Detect-WinGetApp.ps1' }
            $plan.DetectionText = "Intune checks that the app package $($chosen.PackageFamilyName) is installed."
        }
        elseif ($upgradeCode) {
            # The MSI's version is what Apps and features shows, which the manifest gives when it
            # differs from the package version
            $minimum = if ($pinned) { $arpVersion } else { '' }
            $plan.Detect = [ordered]@{ kind = 'msi'; upgradeCode = $upgradeCode; minimumVersion = $minimum }
            $plan.Detection = [ordered]@{ type = 'script'; scriptFile = 'Detect-WinGetApp.ps1' }
            $plan.DetectionText = "Intune looks for the MSI with the upgrade code $upgradeCode" +
                $(if ($minimum) { ", at version $minimum or later." } else { ', whatever version it has updated itself to since.' })
        }
        elseif ($chosen.Scope -in 'machine', 'user' -and (Test-WinGetStableKey -Key $key -Versions @($Info.Version, $arpVersion))) {
            $keyPath = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$key"
            $byVersion = $pinned -and (Test-WinGetComparableVersion $arpVersion)
            $plan.Detection = [ordered]@{
                type = 'registry'; keyPath = $keyPath
                valueName = $(if ($byVersion) { 'DisplayVersion' } else { '' })
                detectionType = $(if ($byVersion) { 'version' } else { 'exists' })
                operator = $(if ($byVersion) { 'greaterThanOrEqual' } else { 'notConfigured' })
            }
            if ($byVersion) { $plan.Detection.detectionValue = $arpVersion }
            $plan.Detection.check32BitOn64System = ($chosen.Architecture -eq 'x86' -and $hive -eq 'HKEY_LOCAL_MACHINE')
            $plan.DetectionText = if ($byVersion) {
                "Intune reads DisplayVersion under the uninstall key $key and treats the app as installed when it is at least $arpVersion."
            } else { "Intune checks that the uninstall key $key exists." }
        }
        else {
            # winget list shows the package version, mapped from what Apps and features says
            $minimum = if ($pinned) { $plan.Version } else { '' }
            $plan.Detect = [ordered]@{ kind = 'winget'; minimumVersion = $minimum }
            $plan.Detection = [ordered]@{ type = 'script'; scriptFile = 'Detect-WinGetApp.ps1' }
            $plan.DetectionText = "Intune asks WinGet on the device whether $($Info.Id) is installed" +
                $(if ($minimum) { ", at version $minimum or later." } else { '.' })
            $why = if (-not $chosen.Scope) { 'the manifest does not say whether the installer installs for every user or per user' }
                   elseif (-not $key) { 'the manifest names no uninstall key to look for' }
                   else { "the uninstall key $key changes from one version to the next" }
            $notes.Add(("Detection asks WinGet (winget list), because $why. WinGet recognises the app the way winget upgrade does, " +
                        'also after it has updated itself. Each check takes a few seconds on the device.'))
        }

        switch ($chosen.Scope) {
            'user' { $notes.Add('Installs per user: Intune runs it as the signed-in user, who does not need administrator rights for it.') }
            'machine' { }
            default {
                $warnings.Add(("The manifest does not say whether this installer installs for every user or only for the account running it. It runs as SYSTEM; " +
                               "if it is a per-user installer it lands in SYSTEM's own profile, where nobody sees it. A test install shows which."))
            }
        }
        if ($chosen.Architecture -eq 'x86') { $notes.Add('A 32-bit app: it installs on 32-bit, 64-bit and ARM64 Windows.') }
        if (-not $Info.ManifestComplete) {
            $warnings.Add(("WinGet's manifest could not be read on this computer, so the installer's architecture, scope and uninstall key are unknown: " +
                           'WinGet on the device picks the installer, and detection asks WinGet. Test it on this computer before publishing.'))
        }
    }

    if ($Info.Source -eq 'winget') {
        if ($pinned) {
            $notes.Add("Pinned to version $($plan.Version): every device gets exactly this version. For the next release, change the version and publish again as an update.")
        }
        else {
            $notes.Add('Not pinned: each device gets whatever version is newest on the day it installs, and Intune does not upgrade it after that.')
        }
        if ($hosts) { $notes.Add("The installer downloads from $($hosts -join ', '); WinGet checks it against the SHA-256 in the manifest before it runs anything.") }
    }
    elseif (-not $storeApp.Count) {
        $notes.Add('The Store keeps only its newest version: each device gets whatever is current on the day it installs, and Intune does not upgrade it after that.')
        if ($hosts) { $notes.Add("The installer comes from the Microsoft Store's own servers ($($hosts -join ', ')) and is checked against its SHA-256.") }
    }
    if ($Info.Source -eq 'msstore' -and (Test-StoreBlockedHere)) {
        $warnings.Add(("The Microsoft Store app is turned off by policy on this computer. If the devices have the same policy, WinGet's command line refuses " +
                       "Store installs there (0x8A15001B). Intune's own Microsoft Store app type is not affected - choose it as the delivery instead."))
    }
    [pscustomobject]$plan
}

function Test-StoreBlockedHere {
    try {
        $policy = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -ErrorAction Stop
        return $policy.RemoveWindowsStore -eq 1
    }
    catch { return $false }
}
#endregion

#region ---- Package folder --------------------------------------------------------------
# A value on the command line Intune runs. Ids, sources and versions never hold a space or a
# quote; an override for the installer may, and is quoted the way a C program splits it again.
function Format-WinGetCommandValue {
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    '"' + [regex]::Replace($escaped, '(\\+)$', '$1$1') + '"'
}

# The install and uninstall commands for a winget block of app.json. The source is on the
# command line on purpose: it is what an administrator sees in the Intune portal, so whether an
# app installs from the Store or from the community repository can be checked without opening
# the package.
function Get-WinGetCommandLine {
    param([Parameter(Mandatory)][Collections.IDictionary]$WinGet)
    $shell = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File'
    $install = [Collections.Generic.List[string]]::new()
    $install.Add("$shell "".\Install-WinGetApp.ps1"" -Id $(Format-WinGetCommandValue $WinGet['id']) -Source $($WinGet['source'])")
    foreach ($pair in @(
        @{ Key = 'version'; Switch = '-Version' }, @{ Key = 'scope'; Switch = '-Scope' }
        @{ Key = 'architecture'; Switch = '-Architecture' }, @{ Key = 'installerType'; Switch = '-InstallerType' }
        @{ Key = 'locale'; Switch = '-Locale' }, @{ Key = 'override'; Switch = '-Override' }, @{ Key = 'custom'; Switch = '-Custom' })) {
        if ("$($WinGet[$pair.Key])".Trim()) { $install.Add("$($pair.Switch) $(Format-WinGetCommandValue "$($WinGet[$pair.Key])".Trim())") }
    }
    $uninstall = [Collections.Generic.List[string]]::new()
    $uninstall.Add("$shell "".\Uninstall-WinGetApp.ps1"" -Id $(Format-WinGetCommandValue $WinGet['id']) -Source $($WinGet['source'])")
    if ("$($WinGet['scope'])".Trim()) { $uninstall.Add("-Scope $($WinGet['scope'])") }
    if ("$($WinGet['productCode'])".Trim()) { $uninstall.Add("-ProductCode $(Format-WinGetCommandValue $WinGet['productCode'])") }
    if ("$($WinGet['packageFamilyName'])".Trim()) { $uninstall.Add("-PackageFamilyName $(Format-WinGetCommandValue $WinGet['packageFamilyName'])") }
    [pscustomobject]@{ Install = $install -join ' '; Uninstall = $uninstall -join ' ' }
}

# The scripts a package with this winget block holds: file name -> content
function Get-WinGetScriptSet {
    param([Parameter(Mandatory)][Collections.IDictionary]$WinGet)
    if ($WinGet['delivery'] -eq 'store') { return [ordered]@{} }
    $values = @{ ID = $WinGet['id']; SOURCELABEL = $script:SourceLabels["$($WinGet['source'])"] }
    $set = [ordered]@{
        'Install-WinGetApp.ps1'   = Format-WinGetTemplate -Template $script:TplInstall -Values $values
        'Uninstall-WinGetApp.ps1' = Format-WinGetTemplate -Template $script:TplUninstall -Values $values
    }
    if ($WinGet['runtime'] -ne 'dependency') {
        $set['Require-WinGetRuntime.ps1'] = Format-WinGetTemplate -Template $script:TplRequire -Values $values
    }
    $detect = $WinGet['detect']
    if ($detect -is [Collections.IDictionary]) {
        switch ($detect['kind']) {
            'appx' {
                $set['Detect-WinGetApp.ps1'] = Format-WinGetTemplate -Template $script:TplDetectAppx -Values ($values + @{ FAMILY = $detect['packageFamilyName'] })
            }
            'msi' {
                $minimum = "$($detect['minimumVersion'])"
                $set['Detect-WinGetApp.ps1'] = Format-WinGetTemplate -Template $script:TplDetectMsi -Values ($values + @{
                    UPGRADECODE = $detect['upgradeCode']; MINVERSION = $minimum
                    VERSIONNOTE = $(if ($minimum) { ", version $minimum or later" } else { '' }) })
            }
            'winget' {
                $minimum = "$($detect['minimumVersion'])"
                $set['Detect-WinGetApp.ps1'] = Format-WinGetTemplate -Template $script:TplDetectWinGet -Values ($values + @{
                    SOURCE = $WinGet['source']; MINVERSION = $minimum
                    VERSIONNOTE = $(if ($minimum) { ", at version $minimum or later" } else { '' }) })
            }
        }
    }
    $set
}

# UTF-8 with a byte order mark: the templates are ASCII, but an app's name in a detection script
# need not be, and without a BOM Windows PowerShell 5.1 reads the file as ANSI - 'Läromedel'
# would be looked for as 'LÃ¤romedel' and never found. Intune recommends the BOM for that reason.
function Write-WinGetScriptFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($true))
}

function Write-WinGetScripts {
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][Collections.IDictionary]$WinGet)
    $set = Get-WinGetScriptSet -WinGet $WinGet
    foreach ($name in $set.Keys) { Write-WinGetScriptFile -Path (Join-Path $Folder $name) -Content $set[$name] }
    @($set.Keys)
}

# app.json for a plan: what Publish-IntuneWinApp sends to Intune, plus the winget block every
# command and script in the folder is written from
function New-WinGetManifest {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Info, $Policy = (Get-PackwrightPolicy))
    $sourceLabel = $script:SourceLabels[$Plan.Source]
    $winget = [ordered]@{
        id                = $Plan.Id
        source            = $Plan.Source
        packageName       = $Info.Name
        version           = $Plan.Version
        scope             = $Plan.Scope
        architecture      = $Plan.Architecture
        installerType     = $Plan.InstallerType
        locale            = ''
        override          = ''
        custom            = ''
        delivery          = $Plan.Delivery
        productCode       = $(if ($Plan.Detect -and $Plan.Detect.kind -eq 'appx') { '' } else { $Plan.ProductCode })
        packageFamilyName = $Plan.PackageFamilyName
        detect            = $Plan.Detect
        runtime           = $Policy.RuntimeLink
        minimumWinGet     = $script:WinGetMinimumVersion
        runner            = $script:WinGetRunnerVersion
    }
    $publisher = if ($Info.Publisher) { $Info.Publisher } elseif ($Info.Author) { $Info.Author } else { 'Unknown' }
    $description = Format-WinGetDescription $Info.Description
    if ($description.Length -gt 9000) { $description = $description.Substring(0, 9000).TrimEnd() + ' …' }
    $manifest = [ordered]@{ displayName = $Info.Name; publisher = $publisher }
    if ($Plan.Label) { $manifest.version = $Plan.Label }
    if ($description) { $manifest.description = $description }
    if ("$($Info.Homepage)" -match '^https?://') { $manifest.informationUrl = $Info.Homepage }
    if ("$($Info.PrivacyUrl)" -match '^https?://') { $manifest.privacyInformationUrl = $Info.PrivacyUrl }
    if ($Info.Author -and $Info.Author -ne $publisher) { $manifest.developer = $Info.Author }
    # The notes are for administrators only, and say where the app comes from in so many words
    $manifest.notes = ("Installed with WinGet from the {0} ({1}): {2}{3}. Packaged by Packwright on {4}." -f
        $sourceLabel, $Plan.Source, $Plan.Id, $(if ($Plan.Version) { " $($Plan.Version)" } else { '' }), (Get-Date -Format 'yyyy-MM-dd'))
    $manifest.runAsAccount = $Plan.RunAs
    $manifest.architecture = $Plan.IntuneArchitecture
    # The scripts need App Installer, which needs Windows 10 1809
    $manifest.minimumWindowsRelease = '1809'
    if ($Plan.Delivery -ne 'store') {
        $commands = Get-WinGetCommandLine -WinGet $winget
        $manifest.installCommandLine = $commands.Install
        $manifest.uninstallCommandLine = $commands.Uninstall
        # The scripts return 3010 and 1641 deliberately; let Intune act on them
        $manifest.restartBehavior = 'basedOnReturnCode'
        if ($Plan.Detection) { $manifest.detection = $Plan.Detection }
        if ($Policy.RuntimeLink -eq 'dependency') {
            # Never both: a requirement that waits for the runtime would keep Intune from ever
            # installing the dependency that provides it
            $manifest.dependencies = @([ordered]@{ displayName = $Policy.RuntimeAppName; autoInstall = $true })
        }
        else {
            $manifest.requirements = @([ordered]@{
                type = 'script'; scriptFile = 'Require-WinGetRuntime.ps1'
                displayName = "WinGet $($script:WinGetMinimumVersion) or later is ready"
                runAsAccount = $Plan.RunAs; detectionType = 'boolean'; operator = 'equal'; detectionValue = 'true'
            })
        }
    }
    $manifest.winget = $winget
    $manifest
}

# A catalog description as the Company Portal shows it: Store text arrives indented and with
# runs of blank lines that were layout on the Store's page
function Format-WinGetDescription {
    param([string]$Text)
    ((("$Text" -split '\r?\n') | ForEach-Object { $_.Trim() }) -join "`n" -replace "`n{3,}", "`n`n").Trim()
}

function Get-WinGetFolderName {
    param([Parameter(Mandatory)]$Plan)
    $name = ('{0} {1}' -f $Plan.Name, $Plan.Version).Trim() -replace '[\\/:*?"<>|]', ''
    if (-not $name) { $name = $Plan.Id -replace '[\\/:*?"<>|]', '' }
    $name.TrimEnd('.', ' ')
}

function Get-DefaultWinGetPackageRoot {
    $settings = Join-Path $env:APPDATA 'Packwright\settings.json'
    try {
        $saved = "$((Get-Content -LiteralPath $settings -Raw -ErrorAction Stop | ConvertFrom-Json).PackageRoot)".Trim()
        if ($saved) { return $saved }
    }
    catch { }
    Join-Path $env:USERPROFILE 'IntunePackages'
}

function New-WinGetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('msstore', 'winget')][string]$Source,
        [string]$Version,
        [switch]$Latest,
        [ValidateSet('win32', 'store')][string]$Delivery,
        [string]$PackageRoot,
        [string]$FolderName,
        # The catalog entry, when the caller has already fetched it (Packwright has)
        $Info,
        # Write into a folder that already holds files
        [switch]$Force,
        # Do not download the installer to take its icon when neither the catalog nor this
        # computer has one
        [switch]$NoIconDownload
    )
    $policy = Get-PackwrightPolicy
    $refusal = Get-WinGetSourceRefusal -Source $Source -Policy $policy
    if ($refusal) { throw $refusal }
    if (-not $Delivery) { $Delivery = if ($Source -eq 'msstore') { $policy.StoreDelivery } else { 'win32' } }
    if (-not $Info) { $Info = Get-WinGetCatalogEntry -Id $Id -Source $Source -Version $Version -Policy $policy }
    $plan = New-WinGetInstallPlan -Info $Info -Latest:$Latest -Delivery $Delivery -Policy $policy
    if ($plan.Blockers.Count) { throw ($plan.Blockers -join ' ') }

    if (-not $PackageRoot) { $PackageRoot = Get-DefaultWinGetPackageRoot }
    if (-not $FolderName) { $FolderName = Get-WinGetFolderName -Plan $plan }
    $folder = Join-Path $PackageRoot $FolderName
    if ((Test-Path -LiteralPath $folder) -and @(Get-ChildItem -LiteralPath $folder -Force).Count -and -not $Force) {
        throw "The folder already exists and is not empty: $folder. Pass -Force to write into it anyway."
    }
    $null = New-Item -ItemType Directory -Path $folder -Force
    $folder = (Resolve-Path -LiteralPath $folder).ProviderPath

    $manifest = New-WinGetManifest -Plan $plan -Info $Info -Policy $policy
    $written = @(Write-WinGetScripts -Folder $folder -WinGet $manifest.winget)
    $icon = Save-WinGetPackageIcon -Info $Info -Plan $plan -Folder $folder -NoDownload:$NoIconDownload
    if ($icon.File) { $manifest.icon = $icon.File }
    ($manifest | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $folder 'app.json') -Encoding UTF8

    [pscustomobject]@{
        Folder   = $folder
        Plan     = $plan
        Manifest = $manifest
        Scripts  = $written
        Setup    = $(if ($Delivery -eq 'store') { $null } else { 'Install-WinGetApp.ps1' })
        Icon     = $icon
    }
}

# How the scripts in a package compare with what this Packwright would write for its app.json:
# current, outdated (written by an older Packwright), edited (changed by hand), or missing.
# A script changed by hand is the way round an organisation's choice of sources - the source is
# a parameter, but the script decides what to do with it - so Packwright says so before publishing.
function Get-WinGetScriptState {
    param([Parameter(Mandatory)][string]$Folder)
    $manifestPath = Join-Path $Folder 'app.json'
    $manifest = $null
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { }
    if ($manifest -isnot [Collections.IDictionary]) { return @() }
    $expected = if ($manifest['winget'] -is [Collections.IDictionary]) { Get-WinGetScriptSet -WinGet $manifest['winget'] }
                elseif ($manifest['wingetRuntime'] -is [Collections.IDictionary]) { Get-WinGetRuntimeScriptSet -Runtime $manifest['wingetRuntime'] }
                else { return @() }
    @(foreach ($name in $expected.Keys) {
        $path = Join-Path $Folder $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [pscustomobject]@{ File = $name; State = 'missing'; Detail = "$name is not in the package." }
            continue
        }
        $actual = ([IO.File]::ReadAllText($path) -replace '\r?\n', "`r`n").TrimEnd() + "`r`n"
        if ($actual -eq $expected[$name]) { [pscustomobject]@{ File = $name; State = 'current'; Detail = '' }; continue }
        $written = if ($actual -match 'Packwright WinGet (?:runner|detection|requirement|runtime(?: detection)?) (\d+(?:\.\d+)+)') { $Matches[1] } else { '' }
        $older = $written -and ([version]$written -lt [version]$script:WinGetRunnerVersion)
        [pscustomobject]@{
            File   = $name
            State  = $(if ($older) { 'outdated' } else { 'edited' })
            Detail = $(if ($older) { "$name was written by WinGet runner $written; this Packwright writes $($script:WinGetRunnerVersion)." }
                       else { "$name has been changed by hand since Packwright wrote it." })
        }
    })
}

function Update-WinGetScript {
    param([Parameter(Mandatory)][string]$Folder)
    $manifest = Get-Content -LiteralPath (Join-Path $Folder 'app.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest['winget'] -is [Collections.IDictionary]) { return Write-WinGetScripts -Folder $Folder -WinGet $manifest['winget'] }
    if ($manifest['wingetRuntime'] -isnot [Collections.IDictionary]) { throw "$Folder holds no WinGet package." }
    $set = Get-WinGetRuntimeScriptSet -Runtime $manifest['wingetRuntime']
    foreach ($name in $set.Keys) { Write-WinGetScriptFile -Path (Join-Path $Folder $name) -Content $set[$name] }
    @($set.Keys)
}
#endregion

#region ---- The WinGet runtime package ------------------------------------------------
# One Win32 app, published once and assigned to every device, that makes winget usable for
# SYSTEM: App Installer from the winget-cli release on GitHub (with the framework packages it
# depends on and the licence that lets it be provisioned offline), and the Visual C++ runtime
# winget.exe looks for in System32 when it is started by its full path. Everything is fetched
# here, on the packaging computer, and checked before it goes into the package: the SHA-256
# GitHub publishes for each release file, and a valid Microsoft signature. The devices download
# nothing from the internet to install it.
$script:RuntimeRelease = 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'
$script:VCRedistUrl = 'https://aka.ms/vc14/vc_redist.{0}.exe'

function Save-VerifiedDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Sha256,
        [switch]$RequireMicrosoftSignature,
        [string]$Activity = 'Downloading'
    )
    Write-Progress -Activity $Activity -Status (Split-Path -Leaf $Destination)
    try { Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop | Out-Null }
    catch { throw "Downloading $Url failed: $($_.Exception.Message)" }
    if ($Sha256) {
        $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        if ($actual -ine $Sha256) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw "$(Split-Path -Leaf $Destination) does not match the SHA-256 it was published with ($Sha256, got $actual). It was deleted."
        }
    }
    if ($RequireMicrosoftSignature) {
        $signature = Get-AuthenticodeSignature -LiteralPath $Destination
        if ($signature.Status -ne 'Valid' -or "$($signature.SignerCertificate.Subject)" -notmatch 'O=Microsoft Corporation') {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw "$(Split-Path -Leaf $Destination) is not validly signed by Microsoft ($($signature.Status), $($signature.SignerCertificate.Subject)). It was deleted."
        }
    }
    Get-Item -LiteralPath $Destination
}

# Name, version and architecture an .appx/.msix/.msixbundle says it is. A bundle has a version
# of its own - App Installer's is a date, 2026.917.151.0 - while what gets installed, and what a
# device reports, is the application package inside it: 1.29.380.0. Compared with the bundle's,
# every device would look out of date for ever and the runtime would reinstall on each
# evaluation. So for a bundle the version is the newest application package in it, leaving out
# the stubs (1.29.379.0 here), which only stand in until the real package is fetched.
function Get-AppPackageIdentity {
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -in 'AppxManifest.xml', 'AppxMetadata/AppxBundleManifest.xml' } | Select-Object -First 1
        if (-not $entry) { throw "$(Split-Path -Leaf $Path) holds no package manifest." }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $identity = $xml.DocumentElement.Identity
        $version = "$($identity.Version)"
        $bundleVersion = ''
        if ($entry.FullName -like 'AppxMetadata/*') {
            $bundleVersion = $version
            $applications = @($xml.DocumentElement.Packages.Package | Where-Object {
                "$($_.Type)" -eq 'application' -and "$($_.FileName)" -notmatch '(^|[\\/])Stub[\\/]' })
            $newest = $applications | Sort-Object { [version]"$($_.Version)" } -Descending | Select-Object -First 1
            if (-not $newest) { throw "$(Split-Path -Leaf $Path) is a bundle with no application package in it." }
            $version = "$($newest.Version)"
        }
        [pscustomobject]@{
            Name = "$($identity.Name)"; Version = $version; BundleVersion = $bundleVersion
            Architecture = "$($identity.ProcessorArchitecture)".ToLowerInvariant()
        }
    }
    finally { $zip.Dispose() }
}

function Get-WinGetRuntimeScriptSet {
    param([Parameter(Mandatory)][Collections.IDictionary]$Runtime)
    $values = @{ APPINSTALLER = $Runtime['appInstaller'] }
    [ordered]@{
        'Install-WinGetRuntime.ps1'   = Format-WinGetTemplate -Template $script:TplRuntimeInstall -Values $values
        'Detect-WinGetRuntime.ps1'    = Format-WinGetTemplate -Template $script:TplRuntimeDetect -Values $values
        'Uninstall-WinGetRuntime.ps1' = Format-WinGetTemplate -Template $script:TplRuntimeUninstall -Values $values
    }
}

function New-WinGetRuntimePackage {
    [CmdletBinding()]
    param(
        [string]$PackageRoot,
        [ValidateSet('x64', 'arm64', 'x86')][string[]]$Architectures = @('x64', 'arm64'),
        [switch]$Force
    )
    $policy = Get-PackwrightPolicy
    if (-not $PackageRoot) { $PackageRoot = Get-DefaultWinGetPackageRoot }
    $activity = 'Building the WinGet runtime package'

    Write-Progress -Activity $activity -Status 'Asking GitHub for the latest winget-cli release'
    try { $release = Invoke-RestMethod -Uri $script:RuntimeRelease -Headers @{ 'User-Agent' = 'Packwright' } -TimeoutSec 30 -ErrorAction Stop }
    catch { throw "GitHub could not be asked for the latest winget-cli release: $($_.Exception.Message)" }
    $asset = {
        param([string]$Pattern)
        $found = @($release.assets | Where-Object { $_.name -like $Pattern }) | Select-Object -First 1
        if (-not $found) { throw "Release $($release.tag_name) of winget-cli has no file like $Pattern." }
        $found
    }
    $bundleAsset  = & $asset 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    $depsAsset    = & $asset 'DesktopAppInstaller_Dependencies.zip'
    $licenseAsset = & $asset '*_License1.xml'
    $digest = { param($Asset) if ("$($Asset.digest)" -match '^sha256:([0-9a-fA-F]{64})$') { $Matches[1] } else { '' } }
    if (-not (& $digest $bundleAsset)) { throw "GitHub gave no SHA-256 for $($bundleAsset.name), so it cannot be checked." }

    $version = ("$($release.tag_name)" -replace '^v', '')
    $folder = Join-Path $PackageRoot ("$($policy.RuntimeAppName) $version" -replace '[\\/:*?"<>|]', '')
    if ((Test-Path -LiteralPath $folder) -and @(Get-ChildItem -LiteralPath $folder -Force).Count -and -not $Force) {
        throw "The folder already exists and is not empty: $folder. Pass -Force to write into it anyway."
    }
    $null = New-Item -ItemType Directory -Path $folder -Force
    $folder = (Resolve-Path -LiteralPath $folder).ProviderPath

    $bundle = Save-VerifiedDownload -Url $bundleAsset.browser_download_url -Destination (Join-Path $folder $bundleAsset.name) `
                  -Sha256 (& $digest $bundleAsset) -RequireMicrosoftSignature -Activity $activity
    $license = Save-VerifiedDownload -Url $licenseAsset.browser_download_url -Destination (Join-Path $folder $licenseAsset.name) `
                   -Sha256 (& $digest $licenseAsset) -Activity $activity
    $depsZip = Join-Path ([IO.Path]::GetTempPath()) ('Packwright-deps-{0}.zip' -f [guid]::NewGuid())
    $null = Save-VerifiedDownload -Url $depsAsset.browser_download_url -Destination $depsZip -Sha256 (& $digest $depsAsset) -Activity $activity
    $bundleIdentity = Get-AppPackageIdentity -Path $bundle.FullName

    # The framework packages, for the architectures this package is for only
    $dependencies = [ordered]@{}
    $unpacked = Join-Path ([IO.Path]::GetTempPath()) ('Packwright-deps-{0}' -f [guid]::NewGuid())
    try {
        Expand-Archive -LiteralPath $depsZip -DestinationPath $unpacked -Force
        foreach ($architecture in $Architectures) {
            $files = @(Get-ChildItem -LiteralPath $unpacked -Recurse -File -Include *.appx, *.msix |
                       Where-Object { $_.FullName.Substring($unpacked.Length) -match "(?i)[\\_.]$architecture[\\_.]" })
            $target = Join-Path $folder "Dependencies\$architecture"
            $null = New-Item -ItemType Directory -Path $target -Force
            $dependencies[$architecture] = @(foreach ($file in $files) {
                $identity = Get-AppPackageIdentity -Path $file.FullName
                if ($identity.Architecture -ne $architecture) { continue }
                $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
                if ($signature.Status -ne 'Valid' -or "$($signature.SignerCertificate.Subject)" -notmatch 'O=Microsoft Corporation') {
                    throw "$($file.Name) in the dependency archive is not validly signed by Microsoft."
                }
                Copy-Item -LiteralPath $file.FullName -Destination $target -Force
                [ordered]@{ file = "Dependencies\$architecture\$($file.Name)"; name = $identity.Name; version = $identity.Version }
            })
        }
    }
    finally {
        Remove-Item -LiteralPath $unpacked -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $depsZip -Force -ErrorAction SilentlyContinue
    }

    # The Visual C++ runtime. aka.ms names the file by its SHA-256 in the address it forwards
    # to, so that is checked too where it is there to check.
    $redists = [ordered]@{}
    foreach ($architecture in $Architectures) {
        $url = $script:VCRedistUrl -f $architecture
        $expected = ''
        try {
            $head = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -ErrorAction Stop
            $final = "$($head.BaseResponse.RequestMessage.RequestUri)"
            if ($final -match '/([0-9A-Fa-f]{64})/[^/]+$') { $expected = $Matches[1] }
        }
        catch { }
        $file = Save-VerifiedDownload -Url $url -Destination (Join-Path $folder "vc_redist.$architecture.exe") `
                    -Sha256 $expected -RequireMicrosoftSignature -Activity $activity
        $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($file.FullName)
        $redists[$architecture] = [ordered]@{
            file = $file.Name
            version = '{0}.{1}.{2}' -f $fileVersion.FileMajorPart, $fileVersion.FileMinorPart, $fileVersion.FileBuildPart
        }
    }

    $runtime = [ordered]@{
        appInstaller = [ordered]@{ file = $bundle.Name; version = $bundleIdentity.Version; license = $license.Name; release = "$($release.tag_name)" }
        dependencies = $dependencies
        vcRedist     = $redists
    }
    ($runtime | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $folder 'runtime.json') -Encoding UTF8

    $marker = [ordered]@{ appInstaller = $bundleIdentity.Version; release = "$($release.tag_name)"; architectures = $Architectures; runner = $script:WinGetRunnerVersion }
    foreach ($script in (Get-WinGetRuntimeScriptSet -Runtime $marker).GetEnumerator()) {
        Write-WinGetScriptFile -Path (Join-Path $folder $script.Key) -Content $script.Value
    }
    $shell = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File'
    $manifest = [ordered]@{
        displayName           = $policy.RuntimeAppName
        publisher             = 'Microsoft Corporation'
        version               = $bundleIdentity.Version
        description           = ("Makes WinGet usable for SYSTEM on this device: App Installer $version with its framework packages, and the Visual C++ " +
                                 'runtime winget.exe needs when it is started by its full path. The apps Packwright installs with WinGet need it.')
        notes                 = ("Packaged by Packwright on {0} from winget-cli release {1} (SHA-256 checked, signed by Microsoft) and the Visual C++ " +
                                 'runtime from aka.ms/vc14. Assign it to all devices; it changes nothing on a device that already has both.') -f
                                (Get-Date -Format 'yyyy-MM-dd'), $release.tag_name
        installCommandLine    = "$shell "".\Install-WinGetRuntime.ps1"""
        uninstallCommandLine  = "$shell "".\Uninstall-WinGetRuntime.ps1"""
        runAsAccount          = 'system'
        restartBehavior       = 'basedOnReturnCode'
        architecture          = $(if ('x86' -in $Architectures) { 'neutral' } else { 'x64' })
        minimumWindowsRelease = '1809'
        detection             = [ordered]@{ type = 'script'; scriptFile = 'Detect-WinGetRuntime.ps1' }
        wingetRuntime         = $marker
    }
    ($manifest | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $folder 'app.json') -Encoding UTF8
    Write-Progress -Activity $activity -Completed
    [pscustomobject]@{ Folder = $folder; Setup = 'Install-WinGetRuntime.ps1'; AppInstaller = $bundleIdentity.Version; Release = "$($release.tag_name)" }
}
#endregion

# Run directly with -Id, -Search or -Runtime; dot-source the file to only load the functions.
if ($MyInvocation.InvocationName -ne '.' -and ($Id -or $Search -or $Runtime)) {
    if ($Runtime) { New-WinGetRuntimePackage -PackageRoot $PackageRoot }
    elseif ($Search) {
        $searchSource = if ($Source) { $Source } else { (Get-PackwrightPolicy).DefaultSource }
        Search-WinGetCatalog -Query $Search -Source $searchSource | Format-Table Id, Name, Version, Publisher, Kind -AutoSize
    }
    else {
        if (-not $Source) { throw 'Say which source the package comes from: -Source msstore or -Source winget.' }
        $created = New-WinGetPackage -Id $Id -Source $Source -Version $Version -Latest:$Latest -Delivery $Delivery -PackageRoot $PackageRoot `
                                     -NoIconDownload:$NoIconDownload
        foreach ($line in @($created.Plan.Notes) + @($created.Plan.Warnings | ForEach-Object { "WARNING: $_" })) { Write-Host $line }
        Write-Host $(if ($created.Icon.File) { "Icon taken from $($created.Icon.From) ($($created.Icon.Size)x$($created.Icon.Size))." }
                     else { "No icon found: $($created.Icon.From). Put an icon.png in the folder and name it in app.json." })
        $created
    }
}
