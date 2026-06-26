# Config.ps1 - configuration loading & validation
# Reuses the JSON-config pattern from Start-OSDForm.ps1 (Read-Config / Confirm-Config /
# Set-DefaultProperty), adapted to the SequenceInsight.config.json schema. No hardcoded site.

function Set-TSDefaultProperty {
    <#
    .SYNOPSIS
        Ensures a property exists on a PSCustomObject or Hashtable without overwriting an existing value.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory default-setter; does not change external/system state.')]
    [CmdletBinding()]
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
        try { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $DefaultValue -Force } catch { Write-Verbose "Add-Member failed for '$Name': $_" }
    }
}

function Get-TSEffectiveConfigPath {
    <#
    .SYNOPSIS
        Resolves which config file to use: explicit path, then env var, then the default next to the tool.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$DefaultDirectory = $PSScriptRoot
    )
    if ($ConfigPath) { return $ConfigPath }
    if ($env:SEQUENCEINSIGHT_CONFIG) { return $env:SEQUENCEINSIGHT_CONFIG }
    return (Join-Path -Path $DefaultDirectory -ChildPath 'SequenceInsight.config.json')
}

function Read-TSConfig {
    <#
    .SYNOPSIS
        Reads and parses a SequenceInsight config JSON file. Returns $null if the path does not exist.

    .DESCRIPTION
        Throws on an unreadable / malformed file so callers can fail fast. A missing file returns
        $null, letting the launcher fall back to demo defaults (-DevMode) or report a clear error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Config is empty: $Path"
    }
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
}

function Confirm-TSConfig {
    <#
    .SYNOPSIS
        Validates a config object and fills in defaults. Returns the (mutated) config object.

    .PARAMETER Config
        The parsed config object. If $null, a fresh default object is created.

    .PARAMETER RequireConnection
        When set (the normal, non-DevMode case), the connection-critical keys must be present:
        provider, siteCode, sql.server, sql.database. Throws a descriptive error otherwise.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Config,
        [switch]$RequireConnection
    )

    if ($null -eq $Config) {
        $Config = [pscustomobject]@{}
    }

    # Top-level optional defaults
    Set-TSDefaultProperty -Object $Config -Name 'provider'               -DefaultValue ''
    Set-TSDefaultProperty -Object $Config -Name 'siteCode'              -DefaultValue ''
    Set-TSDefaultProperty -Object $Config -Name 'refreshIntervalSeconds' -DefaultValue 30
    Set-TSDefaultProperty -Object $Config -Name 'dateDisplay'           -DefaultValue 'local'
    Set-TSDefaultProperty -Object $Config -Name 'theme'                 -DefaultValue 'auto'
    Set-TSDefaultProperty -Object $Config -Name 'defaultTimeWindowHours' -DefaultValue 24
    Set-TSDefaultProperty -Object $Config -Name 'errorsOnlyDefault'     -DefaultValue $false
    Set-TSDefaultProperty -Object $Config -Name 'maxRows'               -DefaultValue 20000

    # adminService block
    if (-not $Config.adminService) {
        $Config | Add-Member -NotePropertyName 'adminService' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    Set-TSDefaultProperty -Object $Config.adminService -Name 'trustServerCertificate' -DefaultValue $false

    # sql block
    if (-not $Config.sql) {
        $Config | Add-Member -NotePropertyName 'sql' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    Set-TSDefaultProperty -Object $Config.sql -Name 'server'                 -DefaultValue ''
    Set-TSDefaultProperty -Object $Config.sql -Name 'database'               -DefaultValue ''
    Set-TSDefaultProperty -Object $Config.sql -Name 'encrypt'                -DefaultValue $true
    Set-TSDefaultProperty -Object $Config.sql -Name 'trustServerCertificate' -DefaultValue $false

    # Live monitoring
    Set-TSDefaultProperty -Object $Config -Name 'liveWindowMinutes' -DefaultValue 30

    # analytics block
    if (-not $Config.analytics) {
        $Config | Add-Member -NotePropertyName 'analytics' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    Set-TSDefaultProperty -Object $Config.analytics -Name 'baselineMinSuccessRuns' -DefaultValue 3
    # Optional per-site override for failure-phase classification: an array of { phase, pattern } (regex),
    # first match wins. Empty = use the built-in map. Lets sites map custom/localized step names.
    Set-TSDefaultProperty -Object $Config.analytics -Name 'phasePatterns' -DefaultValue @()

    # alerts block (local toast only)
    if (-not $Config.alerts) {
        $Config | Add-Member -NotePropertyName 'alerts' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    Set-TSDefaultProperty -Object $Config.alerts -Name 'onFailure' -DefaultValue $true
    Set-TSDefaultProperty -Object $Config.alerts -Name 'toast'     -DefaultValue $true

    # Normalise enums
    if ($Config.dateDisplay -notin @('local', 'utc')) { $Config.dateDisplay = 'local' }
    if ($Config.theme -notin @('light', 'dark', 'auto')) { $Config.theme = 'auto' }

    if ($RequireConnection) {
        $missing = @()
        if ([string]::IsNullOrWhiteSpace([string]$Config.provider))     { $missing += 'provider' }
        if ([string]::IsNullOrWhiteSpace([string]$Config.siteCode))     { $missing += 'siteCode' }
        if ([string]::IsNullOrWhiteSpace([string]$Config.sql.server))   { $missing += 'sql.server' }
        if ([string]::IsNullOrWhiteSpace([string]$Config.sql.database)) { $missing += 'sql.database' }
        if ($missing.Count -gt 0) {
            throw ("Config is missing required keys: {0}. See SequenceInsight.config.sample.json." -f ($missing -join ', '))
        }
    }

    return $Config
}
