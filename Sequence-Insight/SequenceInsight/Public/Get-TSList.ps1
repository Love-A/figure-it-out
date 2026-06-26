function Get-TSList {
    <#
    .SYNOPSIS
        Returns the available task sequences (PackageID + Name).

    .DESCRIPTION
        DevMode serves demo data. Otherwise the AdminService is queried first (the modern path);
        on failure it falls back to a direct SQL read of v_TaskSequencePackage, so a temporarily
        unavailable AdminService never blocks the operator.

    .PARAMETER Context
        Context from Connect-SequenceInsight. Defaults to the module-cached context.
    #>
    [CmdletBinding()]
    param([hashtable]$Context)

    $ctx = Resolve-TSContext -Context $Context

    if ($ctx.DevMode) {
        return Get-TSDemoPackageList
    }

    try {
        return Get-TSPackageListFromAdminService -Provider $ctx.Provider -TrustServerCertificate:$ctx.TrustAdminServiceCert
    } catch {
        Write-TSLog -Message "AdminService TS list failed, falling back to SQL. $_" -Level WARN
        return Get-TSPackageListFromSql -ConnectionString $ctx.SqlConnectionString
    }
}
