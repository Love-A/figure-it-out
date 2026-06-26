function Get-TSStatusFeed {
    <#
    .SYNOPSIS
        Returns a best-effort near-real-time status-message feed for active OSD.

    .DESCRIPTION
        Supplementary signal sourced from the AdminService (SMS_StatusMessage). Returns an empty
        array in DevMode or on any failure - the execution grid remains the source of truth.

    .PARAMETER Context
        Context from Connect-SequenceInsight. Defaults to the module-cached context.

    .PARAMETER SinceMinutes
        Look-back window in minutes. Default 30.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Context,
        [int]$SinceMinutes = 30
    )

    $ctx = Resolve-TSContext -Context $Context
    if ($ctx.DevMode) { return @() }

    return Get-TSStatusMessage -Provider $ctx.Provider -SinceMinutes $SinceMinutes -TrustServerCertificate:$ctx.TrustAdminServiceCert
}
