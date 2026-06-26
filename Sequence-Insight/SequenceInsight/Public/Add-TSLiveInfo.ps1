function Add-TSLiveInfo {
    <#
    .SYNOPSIS
        Annotates runs with live status (IsInProgress, CurrentStep, ElapsedSeconds, PercentComplete).

    .DESCRIPTION
        A run is treated as in-progress when its last step is recent and it has no error. "Recent" is
        capped at -LiveWindowMinutes of -AsOf, but when the task sequence has a known (short) timing
        baseline the window is tightened to that baseline (floored at -MinLiveSeconds) - so a quick TS that
        finished a few minutes ago is not mislabelled as still running, while a long OSD keeps the full
        window. For in-progress runs, PercentComplete is estimated from the task sequence's timing baseline:
        elapsed / total-median-seconds (capped 1..99); if no time baseline exists it falls back to
        steps-done / expected-step-count; otherwise it is left null. This is the synergy between the
        analytics baselines and live monitoring (neither 1.6 nor MDT estimated % this way).

        -AsOf is injectable so the behavior is deterministic and unit-testable. Mutates and returns the
        input runs (adds NoteProperties).

    .PARAMETER Runs
        Run objects (from Get-TSRun).

    .PARAMETER Baseline
        Output of Get-TSStepBaseline (optional; without it, PercentComplete stays null).

    .PARAMETER AsOf
        The reference "now". Defaults to the current time.

    .PARAMETER LiveWindowMinutes
        Upper bound on how recent the last step must be for a run to count as in-progress. Default 30.

    .PARAMETER MinLiveSeconds
        Floor for the baseline-tightened window, so a task sequence with a very short baseline still gets a
        brief in-progress grace period. Default 120.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Runs,
        [object]$Baseline,
        [datetime]$AsOf = (Get-Date),
        [int]$LiveWindowMinutes = 30,
        [int]$MinLiveSeconds = 120
    )

    $asOfUtc = $AsOf.ToUniversalTime()

    foreach ($run in $Runs) {
        $isLive = $false; $current = $null; $elapsed = $null; $pct = $null

        $tsBase = $null
        if ($Baseline) { $tsBase = $Baseline.PerTaskSequence | Where-Object { $_.TaskSequence -eq $run.TaskSequence } | Select-Object -First 1 }

        if ($run.EndedUtc -and $run.Status -ne 'Error') {
            $sinceLastSec = ($asOfUtc - ([datetime]$run.EndedUtc)).TotalSeconds
            # Cap is LiveWindowMinutes; tighten to the TS baseline (floored at MinLiveSeconds) when known,
            # so a quick TS that finished minutes ago is not flagged as still running.
            $threshold = $LiveWindowMinutes * 60
            if ($tsBase -and $tsBase.TotalMedianSeconds -gt 0) {
                $threshold = [math]::Min($threshold, [math]::Max($MinLiveSeconds, $tsBase.TotalMedianSeconds))
            }
            if ($sinceLastSec -ge 0 -and $sinceLastSec -lt $threshold) { $isLive = $true }
        }

        if ($isLive) {
            $current = (@($run.Steps | Sort-Object ExecutionTimeUtc | Select-Object -Last 1)).ActionName
            if ($run.StartedUtc) { $elapsed = [int][math]::Round((($asOfUtc - ([datetime]$run.StartedUtc)).TotalSeconds)) }

            if ($tsBase -and $tsBase.TotalMedianSeconds -gt 0 -and $null -ne $elapsed) {
                $pct = [int][math]::Min(99, [math]::Max(1, [math]::Round($elapsed / $tsBase.TotalMedianSeconds * 100)))
            } elseif ($tsBase -and $tsBase.ExpectedStepCount -gt 0) {
                $pct = [int][math]::Min(99, [math]::Max(1, [math]::Round($run.StepCount / $tsBase.ExpectedStepCount * 100)))
            }
        }

        $run | Add-Member -NotePropertyName IsInProgress    -NotePropertyValue $isLive  -Force
        $run | Add-Member -NotePropertyName CurrentStep     -NotePropertyValue $current -Force
        $run | Add-Member -NotePropertyName ElapsedSeconds  -NotePropertyValue $elapsed -Force
        $run | Add-Member -NotePropertyName PercentComplete -NotePropertyValue $pct     -Force
    }

    return $Runs
}
