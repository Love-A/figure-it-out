function Export-TSReport {
    <#
    .SYNOPSIS
        Writes a standalone HTML report (and optional CSV/JSON) of task-sequence execution.

    .DESCRIPTION
        Fetches normalized rows (or uses the rows you pass in), shapes them into report data, and
        writes a self-contained report.html plus report-data.json (the source for -RebuildReportOnly).
        CSV and JSON exports are opt-in via -Formats.

    .PARAMETER Context
        Context from Connect-SequenceInsight. Defaults to the module-cached context. Not needed with -RebuildReportOnly.

    .PARAMETER OutputDirectory
        Folder to write into (created if missing). Defaults to the current directory.

    .PARAMETER Rows
        Pre-fetched normalized rows (e.g. the set the UI is already showing). If omitted, Get-TSExecution runs.

    .PARAMETER PackageID
        Limit to a single task sequence (passed through to Get-TSExecution).

    .PARAMETER Computer
        Computer name filter, wildcards allowed (passed through to Get-TSExecution).

    .PARAMETER SinceHours
        Look-back window in hours (passed through to Get-TSExecution).

    .PARAMETER ErrorsOnly
        Only include error rows.

    .PARAMETER Formats
        Which artifacts to write. Any of Html, Csv, Json. Default Html.

    .PARAMETER RebuildReportOnly
        Rebuild report.html from an existing report-data.json in OutputDirectory. No data fetch, no Context.

    .EXAMPLE
        Export-TSReport -OutputDirectory .\out -Formats Html,Csv

    .EXAMPLE
        Export-TSReport -OutputDirectory .\out -RebuildReportOnly
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Context,
        [string]$OutputDirectory = '.',
        [object[]]$Rows,
        [string]$PackageID,
        [string]$Computer,
        [int]$SinceHours,
        [switch]$ErrorsOnly,
        [ValidateSet('Html', 'Csv', 'Json')][string[]]$Formats = @('Html'),
        [switch]$RebuildReportOnly
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    $outDir   = (Resolve-Path -LiteralPath $OutputDirectory).Path
    $dataPath = Join-Path $outDir 'report-data.json'
    $htmlPath = Join-Path $outDir 'report.html'

    if ($RebuildReportOnly) {
        if (-not (Test-Path -LiteralPath $dataPath)) {
            throw "RebuildReportOnly needs an existing report-data.json in $outDir."
        }
        $reportData = Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json
        ConvertTo-TSReportHtml -ReportData $reportData | Out-File -FilePath $htmlPath -Encoding utf8
        Write-TSLog -Message "Rebuilt report.html from report-data.json in $outDir." -Level INFO
        return $htmlPath
    }

    $ctx = Resolve-TSContext -Context $Context

    if (-not $PSBoundParameters.ContainsKey('Rows')) {
        # A standalone report should be complete, so fetch the full action output here.
        $execParams = @{ Context = $ctx; IncludeOutput = $true }
        if ($PackageID) { $execParams['PackageID'] = $PackageID }
        if ($Computer)  { $execParams['Computer'] = $Computer }
        if ($PSBoundParameters.ContainsKey('SinceHours')) { $execParams['SinceHours'] = $SinceHours }
        if ($ErrorsOnly) { $execParams['ErrorsOnly'] = $true }
        $Rows = Get-TSExecution @execParams
    }
    $Rows = @($Rows)

    $windowHours = if ($PSBoundParameters.ContainsKey('SinceHours')) { $SinceHours } else { [int]$ctx.Config.defaultTimeWindowHours }
    $maxRowsVal  = [int]$ctx.MaxRows
    $liveWin     = if ($ctx.Config.liveWindowMinutes) { [int]$ctx.Config.liveWindowMinutes } else { 30 }
    $phaseMap    = if ($ctx.Config.analytics.phasePatterns) { @($ctx.Config.analytics.phasePatterns) } else { $null }
    $reportData  = ConvertTo-TSReportData -Rows $Rows -DateDisplay $ctx.DateDisplay -Theme $ctx.Config.theme -WindowHours $windowHours -MaxRows $maxRowsVal -LiveWindowMinutes $liveWin -PhaseMap $phaseMap -DevMode $ctx.DevMode

    $reportData | ConvertTo-Json -Depth 25 | Out-File -FilePath $dataPath -Encoding utf8

    $written = @($dataPath)
    if ($Formats -contains 'Html') {
        ConvertTo-TSReportHtml -ReportData $reportData | Out-File -FilePath $htmlPath -Encoding utf8
        $written += $htmlPath
    }
    if ($Formats -contains 'Json') {
        $jsonPath = Join-Path $outDir 'execution-rows.json'
        $Rows | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding utf8
        $written += $jsonPath
    }
    if ($Formats -contains 'Csv') {
        $csvPath = Join-Path $outDir 'execution-rows.csv'
        $Rows |
            Select-Object Computer, TaskSequence, PackageID, Step, GroupName, ActionName, Status, ExitCode, DurationSeconds, ExecutionTimeUtc, LastStatusMsgName |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        $written += $csvPath
    }

    Write-TSLog -Message ("Report written: {0} runs, {1} steps -> {2}" -f $reportData.runCount, $reportData.stepCount, $htmlPath) -Level INFO
    if ($Formats -contains 'Html') { return $htmlPath } else { return $written }
}
