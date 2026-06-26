function Get-TSStepOutput {
    <#
    .SYNOPSIS
        Loads a single step's action output on demand (so list views can skip the large output column).

    .DESCRIPTION
        Returns the ActionOutput text for one step, identified by ResourceID + Step + its execution time.
        DevMode returns '' (demo rows already carry their output in memory). This backs the UI's
        lazy-load: the runs/steps lists are fetched without ActionOutput, and the output is retrieved
        only when a step is opened.

    .PARAMETER Context
        Context from Connect-SequenceInsight. Defaults to the module-cached context.

    .PARAMETER ResourceID
        The device ResourceID of the step.

    .PARAMETER Step
        The step number.

    .PARAMETER ExecutionTimeUtc
        The step's execution time (UTC); matched within a +/-1s window.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Context,
        [Parameter(Mandatory)][int]$ResourceID,
        [Parameter(Mandatory)][int]$Step,
        [Parameter(Mandatory)][datetime]$ExecutionTimeUtc
    )
    $ctx = Resolve-TSContext -Context $Context
    if ($ctx.DevMode) { return '' }
    return Get-TSStepOutputFromSql -ConnectionString $ctx.SqlConnectionString -ResourceID $ResourceID -Step $Step -ExecutionTimeUtc $ExecutionTimeUtc
}
