function Get-TSRun {
    <#
    .SYNOPSIS
        Returns task-sequence runs (grouped execution rows with nested steps).

    .DESCRIPTION
        Convenience wrapper over Get-TSExecution + run grouping for the UI and callers who want a
        run-centric view (one object per Computer+TaskSequence run, splitting on large time gaps).
        Each run exposes Computer, TaskSequence, Status, ErrorCount, StepCount, StartedUtc, EndedUtc,
        DurationSeconds and a Steps collection of the normalized rows.

    .PARAMETER Context
        Context from Connect-SequenceInsight. Defaults to the module-cached context.

    .PARAMETER PackageID
        Limit to a single task sequence by PackageID.

    .PARAMETER Computer
        Computer name filter (wildcards allowed).

    .PARAMETER SinceHours
        Look-back window in hours. Defaults to the config's defaultTimeWindowHours.

    .PARAMETER ErrorsOnly
        Keep only runs that contain at least one error.

    .PARAMETER GapHours
        A gap larger than this (hours) between consecutive steps starts a new run. Default 6.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Context,
        [string]$PackageID,
        [string]$Computer,
        [int]$SinceHours,
        [switch]$ErrorsOnly,
        [int]$GapHours = 6
    )

    $execParams = @{}
    if ($Context) { $execParams['Context'] = $Context }
    if ($PackageID) { $execParams['PackageID'] = $PackageID }
    if ($Computer) { $execParams['Computer'] = $Computer }
    if ($PSBoundParameters.ContainsKey('SinceHours')) { $execParams['SinceHours'] = $SinceHours }

    $rows = Get-TSExecution @execParams
    $runs = ConvertTo-TSRun -Rows @($rows) -GapHours $GapHours

    if ($ErrorsOnly) { $runs = $runs | Where-Object { $_.ErrorCount -gt 0 } }
    return @($runs)
}
