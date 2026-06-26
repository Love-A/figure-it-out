# Analytics.ps1 - internal statistics helpers shared by the analytics/live public functions.
# Pure functions over numeric input so they are trivially unit-testable.

function Get-TSMedian {
    <#
    .SYNOPSIS
        Median of a numeric set (interpolated for an even count). Returns $null for an empty set.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][double[]]$Values)
    $v = @($Values | Sort-Object)
    $n = $v.Count
    if ($n -eq 0) { return $null }
    if ($n % 2) { return $v[[int](($n - 1) / 2)] }
    return ((($v[$n / 2 - 1]) + ($v[$n / 2])) / 2)
}

function Get-TSPercentile {
    <#
    .SYNOPSIS
        Nearest-rank percentile of a numeric set. Returns $null for an empty set.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][double[]]$Values,
        [ValidateRange(1, 100)][int]$Percentile = 90
    )
    $v = @($Values | Sort-Object)
    $n = $v.Count
    if ($n -eq 0) { return $null }
    if ($n -eq 1) { return $v[0] }
    $rank = [math]::Ceiling(($Percentile / 100.0) * $n)
    $idx = [math]::Min([math]::Max([int]$rank - 1, 0), $n - 1)
    return $v[$idx]
}

function Get-TSWilsonInterval {
    <#
    .SYNOPSIS
        Wilson score confidence interval for a proportion (success rate), returned as percentages.

    .DESCRIPTION
        Honest uncertainty for a rate: the interval is wide for tiny samples and narrow for large ones,
        so "100% of 2 runs" is not read with the same confidence as "100% of 200". Returns $null for an
        empty sample. Pure.

    .PARAMETER Successes
        Number of successes.

    .PARAMETER Total
        Sample size.

    .PARAMETER Z
        Standard-normal quantile for the confidence level. Default 1.96 (95%).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Successes,
        [Parameter(Mandatory)][int]$Total,
        [double]$Z = 1.96
    )
    if ($Total -le 0) { return $null }
    $p      = $Successes / $Total
    $z2     = $Z * $Z
    $denom  = 1 + $z2 / $Total
    $center = ($p + $z2 / (2 * $Total)) / $denom
    $margin = ($Z * [math]::Sqrt((($p * (1 - $p)) + ($z2 / (4 * $Total))) / $Total)) / $denom
    # Clamp to [0,1] with comparisons - NOT [math]::Max(0,$x), which binds the int overload and rounds the double.
    $lo = $center - $margin; if ($lo -lt 0) { $lo = 0.0 }
    $hi = $center + $margin; if ($hi -gt 1) { $hi = 1.0 }
    return [pscustomobject]@{
        Lower = [math]::Round($lo * 100, 1)
        Upper = [math]::Round($hi * 100, 1)
    }
}

function Get-TSRunDurationSeconds {
    <#
    .SYNOPSIS
        End-to-end duration of a run in seconds (Ended - Started), falling back to a precomputed
        DurationSeconds. Returns $null when neither is available. Pure.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = '"Seconds" is the unit of the returned value, not a pluralized entity.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Run)
    if ($Run.StartedUtc -and $Run.EndedUtc) {
        $d = ([datetime]$Run.EndedUtc - [datetime]$Run.StartedUtc).TotalSeconds
        if ($d -ge 0) { return [double]$d }
    }
    if ($null -ne $Run.DurationSeconds) { return [double]$Run.DurationSeconds }
    return $null
}

function Get-TSExitCodeInfo {
    <#
    .SYNOPSIS
        Decodes a task-sequence/Windows exit code into friendly text (so an operator does not have to
        look up "-2147467259" in smsts.log). Known codes are mapped; unknown HRESULT-style negatives
        are rendered in hex; everything else is labelled unknown. Pure - just a lookup.

    .PARAMETER Code
        The exit code (int, or a string that parses to int). $null/empty returns an empty string.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Code)
    if ($null -eq $Code -or "$Code" -eq '') { return '' }
    $n = 0
    if (-not [int]::TryParse([string]$Code, [ref]$n)) { return [string]$Code }

    # Curated set of codes a ConfigMgr OSD operator actually sees. Honest by design: only well-known
    # values get a meaning; anything else is surfaced as hex/unknown rather than guessed at.
    $map = @{
        0           = 'Success'
        1           = 'Generic failure'
        2           = 'File not found'
        3           = 'Path not found'
        5           = 'Access denied'
        13          = 'Invalid data'
        50          = 'Request not supported'
        87          = 'Invalid parameter'
        112         = 'Not enough disk space'
        1326        = 'Logon failure: bad user name or password'
        1460        = 'Operation timed out'
        1603        = 'Fatal error during installation (MSI 1603)'
        1605        = 'Product is not installed (MSI 1605)'
        1612        = 'Installation source unavailable (MSI 1612)'
        1618        = 'Another installation is already in progress (MSI 1618)'
        1619        = 'Installation package could not be opened (MSI 1619)'
        1620        = 'Installation package could not be opened (MSI 1620)'
        1622        = 'Error opening installation log file (MSI 1622)'
        1624        = 'Error applying transforms (MSI 1624)'
        1625        = 'Installation forbidden by system policy (MSI 1625)'
        1635        = 'Patch package could not be opened (MSI 1635)'
        1638        = 'Another version of this product is already installed (MSI 1638)'
        1641        = 'Success - reboot initiated'
        3010        = 'Success - reboot required'
        2359302     = 'Update already installed (0x240006)'
        -2145124329 = 'Update not applicable to this computer (0x80240017)'
        -2147023436 = 'Operation timed out (0x800705B4)'
        -2147024784 = 'Not enough disk space (0x80070070)'
        -2147024864 = 'File in use / sharing violation (0x80070020)'
        -2147024891 = 'Access denied (0x80070005)'
        -2147024893 = 'Path not found (0x80070003)'
        -2147024894 = 'File not found (0x80070002)'
        -2147467259 = 'Unspecified error (0x80004005)'
        -2147467260 = 'Operation aborted (0x80004004)'
        -2147467261 = 'Invalid pointer (0x80004003)'
    }
    if ($map.ContainsKey($n)) { return $map[$n] }

    if ($n -lt 0) {
        $u = [uint32]([int64]$n -band 0xFFFFFFFFL)
        return ('0x{0:X8} (unknown - see smsts.log)' -f $u)
    }
    return ('Exit code {0} (unknown - see smsts.log)' -f $n)
}

function Get-TSDefaultPhaseMap {
    <#
    .SYNOPSIS
        The built-in, ordered phase-classification map (first match wins). Each entry is a phase name and a
        regex tested against the group/action name. Override per-site via config analytics.phasePatterns.
    #>
    [CmdletBinding()]
    param()
    @(
        [pscustomobject]@{ Phase = 'WinPE & Disk';       Pattern = '(?i)(WinPE|Windows PE|Partition|Diskpart|Format|Pre-?provision|Disk 0)' }
        [pscustomobject]@{ Phase = 'OS Deployment';      Pattern = '(?i)(Apply Operating System|Apply Data Image|Apply Windows Settings|Apply Network|Setup Windows and ConfigMgr|Setup Windows)' }
        [pscustomobject]@{ Phase = 'Drivers';            Pattern = '(?i)(Driver)' }
        [pscustomobject]@{ Phase = 'Applications';       Pattern = '(?i)(Install Application|Install Package|Install Software(?! Updates))' }
        [pscustomobject]@{ Phase = 'Software Updates';   Pattern = '(?i)(Software Updates|Windows Update|Install Updates)' }
        [pscustomobject]@{ Phase = 'Configuration';      Pattern = '(?i)(Domain|Join|Set |Run Command|Run PowerShell|Configure|Settings|Enable|Gather|BitLocker)' }
        [pscustomobject]@{ Phase = 'Finalize & Restart'; Pattern = '(?i)(Restart|Reboot|Release|Reset|Cleanup|Finali[sz]e)' }
    )
}

function Get-TSStepPhase {
    <#
    .SYNOPSIS
        Classifies a task-sequence step into a deployment phase (WinPE & Disk, OS Deployment, Drivers,
        Applications, Software Updates, Configuration, Finalize & Restart, Other).

    .DESCRIPTION
        Heuristic. Classifies on the GROUP name first - in ConfigMgr, groups are the phases the task-sequence
        author defined, so they are far more reliable than guessing from an action name - and falls back to
        the action name only when the group is absent or unrecognised. The pattern set can be overridden
        per-site via -PhaseMap (config analytics.phasePatterns) for custom or localized step names. Pure.

    .PARAMETER ActionName
        The step's action name.

    .PARAMETER GroupName
        The step's group name (the preferred signal when present).

    .PARAMETER PhaseMap
        Optional ordered list of objects with Phase + Pattern (regex); first match wins. When omitted, the
        built-in Get-TSDefaultPhaseMap is used.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ActionName,
        [AllowNull()][string]$GroupName,
        [AllowNull()][object[]]$PhaseMap
    )
    $patterns = if ($PhaseMap) { @($PhaseMap) } else { Get-TSDefaultPhaseMap }
    # Group name first (author-defined phase), then the action name. A malformed custom regex is skipped
    # rather than allowed to throw and break analytics.
    foreach ($candidate in @($GroupName, $ActionName)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        foreach ($p in $patterns) {
            try { if ($candidate -match $p.Pattern) { return [string]$p.Phase } } catch { Write-Verbose "Skipping invalid phase pattern '$($p.Pattern)': $_" }
        }
    }
    return 'Other'
}
