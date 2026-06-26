function Connect-SequenceInsight {
    <#
    .SYNOPSIS
        Builds a SequenceInsight context (from a config object, a config file, or demo mode) and caches it.

    .DESCRIPTION
        Validates configuration, pre-computes the SQL connection string and AdminService settings, and
        returns a context hashtable that the Get-TS* / Export-TSReport functions accept via -Context.
        The context is also cached module-wide so interactive callers and the UI can omit -Context.

    .PARAMETER Config
        A parsed config object (see the sample config). Validated as a live connection config.

    .PARAMETER ConfigPath
        Path to a SequenceInsight.config.json. Falls back to env SEQUENCEINSIGHT_CONFIG, then
        <DefaultConfigDirectory>\SequenceInsight.config.json. Used when -Config is not supplied.

    .PARAMETER DefaultConfigDirectory
        Directory to look in for the default config file name. Defaults to the module folder.

    .PARAMETER DevMode
        Skip connection validation and serve synthetic demo data. Lets the tool run with no live site.

    .EXAMPLE
        $ctx = Connect-SequenceInsight -ConfigPath .\SequenceInsight.config.json

    .EXAMPLE
        $ctx = Connect-SequenceInsight -DevMode
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(ParameterSetName = 'Config')][AllowNull()][object]$Config,
        [Parameter(ParameterSetName = 'Path')][string]$ConfigPath,
        [Parameter(ParameterSetName = 'Path')][string]$DefaultConfigDirectory = $PSScriptRoot,
        [switch]$DevMode
    )

    if ($DevMode) {
        $cfg = Confirm-TSConfig -Config $null
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Config' -and $Config) {
        $cfg = Confirm-TSConfig -Config $Config -RequireConnection
    }
    else {
        $path = Get-TSEffectiveConfigPath -ConfigPath $ConfigPath -DefaultDirectory $DefaultConfigDirectory
        $raw  = Read-TSConfig -Path $path
        if ($null -eq $raw) {
            throw "Config not found at '$path'. Copy config\SequenceInsight.config.sample.json and edit it, or use -DevMode."
        }
        $cfg = Confirm-TSConfig -Config $raw -RequireConnection
    }

    $context = @{
        DevMode               = [bool]$DevMode
        Config                = $cfg
        Provider              = [string]$cfg.provider
        SiteCode              = [string]$cfg.siteCode
        DateDisplay           = [string]$cfg.dateDisplay
        TrustAdminServiceCert = [bool]$cfg.adminService.trustServerCertificate
        MaxRows               = [int]$cfg.maxRows
        SqlConnectionString   = $null
    }

    if (-not $DevMode) {
        $context.SqlConnectionString = Get-TSSqlConnectionString -Server $cfg.sql.server -Database $cfg.sql.database -Encrypt ([bool]$cfg.sql.encrypt) -TrustServerCertificate ([bool]$cfg.sql.trustServerCertificate)
        Write-TSLog -Message ("Connected context: site {0}, provider {1}, SQL {2}/{3}" -f $cfg.siteCode, $cfg.provider, $cfg.sql.server, $cfg.sql.database) -Level INFO
    } else {
        Write-TSLog -Message 'Connected context in DevMode (synthetic data).' -Level INFO
    }

    $script:SequenceInsightContext = $context
    return $context
}

function Resolve-TSContext {
    <#
    .SYNOPSIS
        Returns the supplied context or the module-cached one; throws if neither exists.
    #>
    [CmdletBinding()]
    param([AllowNull()][hashtable]$Context)
    if ($Context) { return $Context }
    if ($script:SequenceInsightContext) { return $script:SequenceInsightContext }
    throw 'No SequenceInsight context. Call Connect-SequenceInsight first.'
}
