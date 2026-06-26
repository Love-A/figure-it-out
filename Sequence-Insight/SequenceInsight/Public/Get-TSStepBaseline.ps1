function Get-TSStepBaseline {
    <#
    .SYNOPSIS
        Per-step timing baselines computed from successful runs (powers slowest-step analytics and
        live %-complete estimation).

    .DESCRIPTION
        From runs whose Status is 'Success', groups steps by (TaskSequence, ActionName) and computes
        SuccessCount, MedianSeconds, P90Seconds and MaxSeconds. Also returns a per-task-sequence summary
        with the total median duration (sum of step medians) and the expected step count, marking a
        baseline as Trusted once at least -MinRuns successful runs back it. Pure over input runs.

    .PARAMETER Runs
        Run objects (from Get-TSRun) with nested Steps.

    .PARAMETER MinRuns
        Minimum successful runs for a task sequence's baseline to be considered trustworthy. Default 3.

    .OUTPUTS
        [pscustomobject] with Steps (array) and PerTaskSequence (array).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Runs,
        [int]$MinRuns = 3
    )

    $successRuns = @($Runs | Where-Object { $_.Status -eq 'Success' })

    $byStep = @{}
    foreach ($run in $successRuns) {
        foreach ($s in @($run.Steps)) {
            if ($null -eq $s.DurationSeconds) { continue }
            $key = '{0}|{1}' -f $run.TaskSequence, $s.ActionName
            if (-not $byStep.ContainsKey($key)) { $byStep[$key] = New-Object System.Collections.Generic.List[double] }
            $byStep[$key].Add([double]$s.DurationSeconds)
        }
    }

    $steps = foreach ($key in $byStep.Keys) {
        $parts = $key -split '\|', 2
        $vals  = $byStep[$key].ToArray()
        [pscustomobject]@{
            TaskSequence  = $parts[0]
            ActionName    = $parts[1]
            SuccessCount  = $vals.Count
            MedianSeconds = [int][math]::Round((Get-TSMedian -Values $vals))
            P90Seconds    = [int][math]::Round((Get-TSPercentile -Values $vals -Percentile 90))
            MaxSeconds    = [int][math]::Round((($vals | Measure-Object -Maximum).Maximum))
        }
    }
    $steps = @($steps)

    $perTs = foreach ($g in ($successRuns | Group-Object TaskSequence)) {
        $tsName  = $g.Name
        $tsRuns  = @($g.Group)
        $tsSteps = @($steps | Where-Object { $_.TaskSequence -eq $tsName })
        $totalMedian = ($tsSteps | Measure-Object MedianSeconds -Sum).Sum
        $expected = Get-TSMedian -Values (@($tsRuns | ForEach-Object { [double]$_.StepCount }))
        [pscustomobject]@{
            TaskSequence       = $tsName
            SuccessfulRuns     = $tsRuns.Count
            TotalMedianSeconds = [int]$totalMedian
            ExpectedStepCount  = if ($null -ne $expected) { [int][math]::Round($expected) } else { 0 }
            Trusted            = ($tsRuns.Count -ge $MinRuns)
        }
    }

    return [pscustomobject]@{
        Steps           = $steps
        PerTaskSequence = @($perTs)
    }
}
