function Get-TSExecution {
    <#
    .SYNOPSIS
        Returns normalized task-sequence execution rows (one per step per run).

    .DESCRIPTION
        The facade the UI and report call. DevMode serves synthetic data; otherwise the parameterised
        SQL view query runs and the rows are normalized (Status, UTC time, per-step duration). Filtering
        by package, computer (wildcard) and "errors only" is applied consistently across both paths.

    .PARAMETER Context
        Context from Connect-SequenceInsight. Defaults to the module-cached context.

    .PARAMETER PackageID
        Limit to a single task sequence by PackageID. Omit for all.

    .PARAMETER Computer
        Computer name filter. Supports SQL/PowerShell wildcards (* or %). Omit for all.

    .PARAMETER SinceHours
        Look-back window in hours. Defaults to the config's defaultTimeWindowHours.

    .PARAMETER MaxRows
        Row cap. Defaults to the context MaxRows.

    .PARAMETER ErrorsOnly
        Return only rows whose Status is 'Error'.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Context,
        [string]$PackageID,
        [string]$Computer,
        [int]$SinceHours,
        [int]$MaxRows,
        [switch]$ErrorsOnly,
        [switch]$IncludeOutput
    )

    $ctx = Resolve-TSContext -Context $Context
    if (-not $PSBoundParameters.ContainsKey('SinceHours')) { $SinceHours = [int]$ctx.Config.defaultTimeWindowHours }
    if (-not $PSBoundParameters.ContainsKey('MaxRows'))    { $MaxRows = [int]$ctx.MaxRows }
    if ($SinceHours -le 0) { $SinceHours = 168 }

    if ($ctx.DevMode) {
        # Apply the same time-window filter the SQL path uses, so -SinceHours behaves identically in demo.
        $startUtc = (Get-Date).ToUniversalTime().AddHours(-1 * [math]::Abs($SinceHours))
        $rows = Get-TSDemoExecution | Where-Object { $_.ExecutionTimeUtc -ge $startUtc }
        if ($PackageID) { $rows = $rows | Where-Object { $_.PackageID -eq $PackageID } }
        if ($Computer)  { $rows = $rows | Where-Object { $_.Computer -like ($Computer -replace '%', '*') } }
    } else {
        $startUtc = (Get-Date).ToUniversalTime().AddHours(-1 * [math]::Abs($SinceHours))
        # Normalise wildcard for SQL LIKE: '*' (PowerShell) -> '%' (SQL).
        $like = $null
        if ($Computer) { $like = ($Computer -replace '\*', '%'); if ($like -notmatch '%') { $like = "%$like%" } }

        $raw = Invoke-TSSqlQuery -ConnectionString $ctx.SqlConnectionString -StartTimeUtc $startUtc -PackageID $PackageID -ComputerLike $like -MaxRows $MaxRows -IncludeOutput:$IncludeOutput
        $rows = ConvertTo-TSExecutionRow -Rows $raw
    }

    if ($ErrorsOnly) { $rows = $rows | Where-Object { $_.Status -eq 'Error' } }
    return @($rows)
}
