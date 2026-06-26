# AdminService.ps1 - ConfigMgr AdminService (REST) provider.
# Modern replacement for the MDT web service: task-sequence list, device-name resolution,
# and a best-effort status-message feed. Uses integrated Windows auth (Negotiate) over HTTPS.

function Get-TSAdminServiceBaseUri {
    <#
    .SYNOPSIS
        Builds the AdminService base URI from a provider host name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider)
    $uriHost = $Provider.Trim().TrimEnd('/')
    if ($uriHost -notmatch '^https?://') { $uriHost = "https://$uriHost" }
    if ($uriHost -notmatch '/AdminService$') { $uriHost = "$uriHost/AdminService" }
    return $uriHost
}

function Invoke-TSRestMethod {
    <#
    .SYNOPSIS
        Invoke-RestMethod wrapper that adds integrated auth and version-aware certificate handling.

    .DESCRIPTION
        On PowerShell 7+ uses -SkipCertificateCheck when TrustServerCertificate is set.
        On Windows PowerShell 5.1 installs a ServerCertificateValidationCallback for the call and
        forces TLS 1.2. Always uses the caller's Windows credentials (-UseDefaultCredentials).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [switch]$TrustServerCertificate
    )

    $isCore = $PSVersionTable.PSVersion.Major -ge 6
    $params = @{
        Uri                = $Uri
        Method             = 'Get'
        UseDefaultCredentials = $true
        ErrorAction        = 'Stop'
    }

    if ($isCore) {
        if ($TrustServerCertificate) { $params['SkipCertificateCheck'] = $true }
        return Invoke-RestMethod @params
    }

    # Windows PowerShell 5.1 path
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { Write-Verbose "Could not set TLS 1.2: $_" }
    $previousCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        if ($TrustServerCertificate) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
        return Invoke-RestMethod @params
    } finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
    }
}

function Get-TSPackageListFromAdminService {
    <#
    .SYNOPSIS
        Returns DEPLOYED task sequences (PackageID + Name) from the AdminService.

    .DESCRIPTION
        Sourced from SMS_DeploymentSummary filtered to FeatureType 7 (Task Sequence), so task
        sequences without any deployment are not listed (they are not monitorable and selecting one
        only yields an empty/erroring view). Deduplicated by PackageID across multiple deployments.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Provider,
        [switch]$TrustServerCertificate
    )
    $base   = Get-TSAdminServiceBaseUri -Provider $Provider
    $filter = [uri]::EscapeDataString('FeatureType eq 7')
    $uri    = "$base/wmi/SMS_DeploymentSummary?`$filter=$filter&`$select=PackageID,SoftwareName"
    $resp   = Invoke-TSRestMethod -Uri $uri -TrustServerCertificate:$TrustServerCertificate
    return ConvertFrom-TSAdminServiceValue -Response $resp |
        Where-Object { $_.PackageID } |
        Group-Object PackageID |
        ForEach-Object { [pscustomobject]@{ PackageID = $_.Name; Name = [string]$_.Group[0].SoftwareName } } |
        Sort-Object Name
}

function Resolve-TSDeviceName {
    <#
    .SYNOPSIS
        Resolves a ResourceID to a device name via the AdminService (replaces MDT unknown-name lookup).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][int]$ResourceID,
        [switch]$TrustServerCertificate
    )
    $base = Get-TSAdminServiceBaseUri -Provider $Provider
    $uri  = "$base/wmi/SMS_R_System($ResourceID)?`$select=Name,NetbiosName"
    try {
        $resp = Invoke-TSRestMethod -Uri $uri -TrustServerCertificate:$TrustServerCertificate
        $rec  = ConvertFrom-TSAdminServiceValue -Response $resp | Select-Object -First 1
        if ($rec) {
            if ($rec.Name) { return [string]$rec.Name }
            if ($rec.NetbiosName) { return [string]$rec.NetbiosName }
        }
    } catch {
        Write-TSLog -Message "Resolve-TSDeviceName failed for ResourceID $ResourceID. $_" -Level WARN -NoConsole
    }
    return $null
}

function Get-TSStatusMessage {
    <#
    .SYNOPSIS
        Best-effort near-real-time status-message feed from the AdminService.

    .DESCRIPTION
        Queries SMS_StatusMessage filtered by time. Insertion strings are not resolved to full
        text (that needs the message DLLs), but MessageID + component + time + machine is a useful
        live signal during OSD. Returns an empty array on any failure - it is supplementary, not
        on the critical path (the execution grid is the source of truth).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Provider,
        [int]$SinceMinutes = 30,
        [switch]$TrustServerCertificate
    )
    try {
        $base  = Get-TSAdminServiceBaseUri -Provider $Provider
        $sinceUtc = (Get-Date).ToUniversalTime().AddMinutes(-1 * [math]::Abs($SinceMinutes))
        $stamp = $sinceUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $filter = [uri]::EscapeDataString("Time ge $stamp and Component eq 'Task Sequence Engine'")
        $uri = "$base/wmi/SMS_StatusMessage?`$filter=$filter&`$select=RecordID,Time,MachineName,Component,Severity,MessageID&`$orderby=Time desc"
        $resp = Invoke-TSRestMethod -Uri $uri -TrustServerCertificate:$TrustServerCertificate
        return ConvertFrom-TSAdminServiceValue -Response $resp
    } catch {
        Write-TSLog -Message "Get-TSStatusMessage unavailable (continuing without live feed). $_" -Level DEBUG -NoConsole
        return @()
    }
}

function ConvertFrom-TSAdminServiceValue {
    <#
    .SYNOPSIS
        Normalises an AdminService response into a flat array of records.

    .DESCRIPTION
        The /wmi/ endpoints wrap collections in a 'value' array and single objects in a 'value'
        object. This returns a consistent array regardless. Kept as a separate function so it can
        be unit-tested against canned responses without a live site.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Response)
    if ($null -eq $Response) { return @() }
    if ($Response.PSObject.Properties.Name -contains 'value') {
        $val = $Response.value
        if ($null -eq $val) { return @() }
        return @($val)
    }
    return @($Response)
}
