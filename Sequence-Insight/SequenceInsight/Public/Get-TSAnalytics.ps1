function Get-TSAnalytics {
    <#
    .SYNOPSIS
        Fleet-wide analytics over a set of task-sequence runs (things 1.6 never surfaced).

    .DESCRIPTION
        Aggregates runs into a rich, dependency-free analytics object consumed by the HTML dashboard
        and (a subset) the live UI. Pure over input runs - no I/O - so it is fully unit-testable.

        IN-PROGRESS runs (IsInProgress) and SUPERSEDED runs (an attempt that a later re-image restarted)
        are excluded from every rate/quality metric and reported separately, so neither a still-running
        deployment nor a rapid re-image's abandoned attempts inflate the numbers. "Success" means a
        COMPLETED run whose final action did not error; a run that finished after an earlier non-fatal
        (continue-on-error) step is a "Warnings" run. Root cause is the step a failed run ENDED on.

        Beyond the headline success rate / failure trend, it surfaces:
          * StepHealth        - per-action reliability + timing in one table (seen, failures, fail %, median, p90).
          * RootCauseSteps    - the FIRST failing step of each failed run (the actual blocker, not cascade noise),
                                with a decoded primary exit code and deployment phase.
          * FailureStages     - where in the deployment failures cluster (WinPE/disk, OS, drivers, apps, updates...).
          * DurationByTaskSequence / DurationTrend - how long runs take (median/p90/min/max) and the trend over time.
          * Slowdowns         - steps whose recent median has regressed vs their own history.
          * RetrySummary / RepeatOffenders - re-imaging churn and computers that fail repeatedly.
          * Regressions       - task sequences whose recent success rate has dropped vs the prior window.

    .PARAMETER Runs
        Run objects (from Get-TSRun) with nested Steps.

    .PARAMETER SlowdownFactor
        A step is flagged as a slowdown when its recent median duration is at least this multiple of its
        prior median. Default 1.25 (25% slower).

    .PARAMETER SlowdownMinSamples
        Minimum successful timing samples (with at least 3 in each of the prior/recent windows) before a
        slowdown can be flagged - guards against noise on tiny samples. Default 6.

    .PARAMETER RegressionDropPercentagePoints
        A task sequence is flagged as a regression when its recent-window success rate is at least this many
        percentage points below its prior-window rate. Default 15.

    .PARAMETER RegressionMinRuns
        Minimum completed runs (with at least 3 in each of the prior/recent windows) before a regression can
        be flagged. Default 6.

    .PARAMETER PhaseMap
        Optional ordered list of objects with Phase + Pattern (regex) used to classify failing steps into
        deployment phases. When omitted, the built-in map is used. Lets a site map custom/localized step
        names (config analytics.phasePatterns).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = '"Analytics" is a domain mass-noun, not a pluralized entity.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Runs,
        [double]$SlowdownFactor = 1.25,
        [int]$SlowdownMinSamples = 6,
        [double]$RegressionDropPercentagePoints = 15,
        [int]$RegressionMinRuns = 6,
        [AllowNull()][object[]]$PhaseMap
    )

    # In-progress runs are excluded from every quality/rate metric (they have not finished) and reported
    # separately, so a still-running deployment can never inflate the success rate.
    $allRuns    = @($Runs)
    $total      = $allRuns.Count
    $settled    = @($allRuns | Where-Object { -not $_.IsInProgress })   # finished attempts (incl. superseded); used for churn
    $superseded = @($settled | Where-Object { $_.Superseded }).Count
    $runs       = @($settled | Where-Object { -not $_.Superseded })     # actual deployment outcomes -> drive every rate/quality metric
    $completed  = $runs.Count
    $inProgress = $total - $settled.Count
    $failedRuns = @($runs | Where-Object { $_.Status -eq 'Error' })
    $failed     = $failedRuns.Count
    $warned     = @($runs | Where-Object { $_.Status -eq 'Warnings' }).Count
    $succeeded  = @($runs | Where-Object { $_.Status -eq 'Success' }).Count
    $phaseOrder = @('WinPE & Disk', 'OS Deployment', 'Drivers', 'Applications', 'Software Updates', 'Configuration', 'Finalize & Restart', 'Other')
    $overallCI  = if ($completed) { Get-TSWilsonInterval -Successes ($completed - $failed) -Total $completed } else { $null }

    # ---- Per task sequence success rate ----
    $perTs = foreach ($g in ($runs | Group-Object TaskSequence)) {
        $t = @($g.Group).Count
        $f = @($g.Group | Where-Object { $_.Status -eq 'Error' }).Count
        $w = @($g.Group | Where-Object { $_.Status -eq 'Warnings' }).Count
        $ci = Get-TSWilsonInterval -Successes ($t - $f) -Total $t
        [pscustomobject]@{
            TaskSequence       = $g.Name
            Total              = $t
            Failed             = $f
            Warnings           = $w
            Succeeded          = ($t - $f)        # completed without a fatal error (clean + warnings)
            Clean              = ($t - $f - $w)   # clean successes only
            SuccessRate        = if ($t) { [math]::Round(($t - $f) / $t * 100, 1) } else { $null }
            SuccessRateCILower = if ($ci) { $ci.Lower } else { $null }
            SuccessRateCIUpper = if ($ci) { $ci.Upper } else { $null }
        }
    }

    # ---- Daily trend: failures AND success rate per day ----
    $trend = foreach ($g in ($runs | Where-Object { $_.StartedUtc } | Group-Object { ([datetime]$_.StartedUtc).ToString('yyyy-MM-dd') })) {
        $t = @($g.Group).Count
        $f = @($g.Group | Where-Object { $_.Status -eq 'Error' }).Count
        [pscustomobject]@{
            Date        = $g.Name
            Total       = $t
            Failed      = $f
            Succeeded   = ($t - $f)
            SuccessRate = if ($t) { [math]::Round(($t - $f) / $t * 100, 1) } else { $null }
        }
    }
    $trend = @($trend | Sort-Object Date)

    # ---- Top failing steps (every Error step across all runs - includes continue-on-error noise) ----
    $byFailStep = @{}
    foreach ($run in $runs) {
        foreach ($s in @($run.Steps | Where-Object { $_.Status -eq 'Error' })) {
            $k = [string]$s.ActionName
            if (-not $byFailStep.ContainsKey($k)) { $byFailStep[$k] = New-Object System.Collections.Generic.List[object] }
            $byFailStep[$k].Add($s.ExitCode)
        }
    }
    $topFailing = foreach ($k in $byFailStep.Keys) {
        $codes   = @($byFailStep[$k] | Where-Object { $null -ne $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { $_.Name })
        $primary = if ($codes.Count) { $codes[0] } else { $null }
        [pscustomobject]@{
            ActionName      = $k
            FailCount       = $byFailStep[$k].Count
            CommonExitCodes = ($codes -join ', ')
            PrimaryExitInfo = (Get-TSExitCodeInfo -Code $primary)
        }
    }
    $topFailing = @($topFailing | Sort-Object FailCount -Descending)

    # ---- Root-cause steps: the FIRST failing step of each failed run (the true blocker) ----
    $byRoot = @{}
    $stageTally = @{}
    foreach ($run in $failedRuns) {
        # The step a failed run ENDED on is the real blocker. An earlier error is often non-fatal
        # continue-on-error noise, so take the LAST error step, not the first.
        $orderedSteps = @($run.Steps | Sort-Object @{ Expression = { $_.ExecutionTimeUtc } }, @{ Expression = { [int]$_.Step } })
        $lastErr = $orderedSteps | Where-Object { $_.Status -eq 'Error' } | Select-Object -Last 1
        if (-not $lastErr) { continue }
        $k = [string]$lastErr.ActionName
        if (-not $byRoot.ContainsKey($k)) {
            $byRoot[$k] = [pscustomobject]@{
                Phase = (Get-TSStepPhase -ActionName $lastErr.ActionName -GroupName $lastErr.GroupName -PhaseMap $PhaseMap)
                Codes = (New-Object System.Collections.Generic.List[object])
                Count = 0
            }
        }
        $byRoot[$k].Count++
        $byRoot[$k].Codes.Add($lastErr.ExitCode)
        $phase = $byRoot[$k].Phase
        if (-not $stageTally.ContainsKey($phase)) { $stageTally[$phase] = 0 }
        $stageTally[$phase]++
    }
    $rootCause = foreach ($k in $byRoot.Keys) {
        $codes   = @($byRoot[$k].Codes | Where-Object { $null -ne $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { $_.Name })
        $primary = if ($codes.Count) { $codes[0] } else { $null }
        [pscustomobject]@{
            ActionName      = $k
            Phase           = $byRoot[$k].Phase
            FailCount       = $byRoot[$k].Count
            CommonExitCodes = ($codes -join ', ')
            PrimaryExitInfo = (Get-TSExitCodeInfo -Code $primary)
        }
    }
    $rootCause = @($rootCause | Sort-Object FailCount -Descending)
    # Known phases first in canonical order, then any custom phases from a -PhaseMap override.
    $stageKnown = foreach ($p in $phaseOrder) {
        if ($stageTally.ContainsKey($p)) { [pscustomobject]@{ Phase = $p; FailCount = $stageTally[$p] } }
    }
    $stageExtra = foreach ($p in (@($stageTally.Keys) | Where-Object { $phaseOrder -notcontains $_ } | Sort-Object)) {
        [pscustomobject]@{ Phase = $p; FailCount = $stageTally[$p] }
    }
    $failureStages = @(@($stageKnown) + @($stageExtra))

    # ---- Step health: per-action reliability + timing merged into one table ----
    $health = @{}
    foreach ($run in $runs) {
        foreach ($s in @($run.Steps)) {
            $k = [string]$s.ActionName
            if (-not $health.ContainsKey($k)) {
                $health[$k] = [pscustomobject]@{
                    Seen  = 0
                    Fail  = 0
                    Durs  = (New-Object System.Collections.Generic.List[double])
                    Codes = (New-Object System.Collections.Generic.List[object])
                }
            }
            $h = $health[$k]
            $h.Seen++
            if ($s.Status -eq 'Error') { $h.Fail++; $h.Codes.Add($s.ExitCode) }
            elseif ($s.Status -eq 'Success' -and $null -ne $s.DurationSeconds) { $h.Durs.Add([double]$s.DurationSeconds) }
        }
    }
    $stepHealth = foreach ($k in $health.Keys) {
        $h     = $health[$k]
        $codes = @($h.Codes | Where-Object { $null -ne $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { $_.Name })
        [pscustomobject]@{
            ActionName      = $k
            Seen            = $h.Seen
            Failures        = $h.Fail
            FailRate        = if ($h.Seen) { [math]::Round($h.Fail / $h.Seen * 100, 1) } else { $null }
            MedianSeconds   = if ($h.Durs.Count) { [int][math]::Round((Get-TSMedian -Values $h.Durs.ToArray())) } else { $null }
            P90Seconds      = if ($h.Durs.Count) { [int][math]::Round((Get-TSPercentile -Values $h.Durs.ToArray() -Percentile 90)) } else { $null }
            CommonExitCodes = ($codes -join ', ')
        }
    }
    $stepHealth = @($stepHealth | Sort-Object @{ Expression = 'Failures'; Descending = $true }, @{ Expression = 'FailRate'; Descending = $true }, @{ Expression = 'Seen'; Descending = $true })

    # ---- Duration distribution per task sequence + daily trend (completed runs only) ----
    $durByTs = foreach ($g in ($runs | Group-Object TaskSequence)) {
        $ds = New-Object System.Collections.Generic.List[double]
        foreach ($r in @($g.Group | Where-Object { $_.Status -ne 'Error' })) {
            $d = Get-TSRunDurationSeconds -Run $r
            if ($null -ne $d -and $d -gt 0) { $ds.Add([double]$d) }
        }
        if (-not $ds.Count) { continue }
        $arr = $ds.ToArray()
        [pscustomobject]@{
            TaskSequence  = $g.Name
            Runs          = $arr.Count
            MedianSeconds = [int][math]::Round((Get-TSMedian -Values $arr))
            P90Seconds    = [int][math]::Round((Get-TSPercentile -Values $arr -Percentile 90))
            MinSeconds    = [int](($arr | Measure-Object -Minimum).Minimum)
            MaxSeconds    = [int](($arr | Measure-Object -Maximum).Maximum)
        }
    }
    $durByTs = @($durByTs)

    $durTrend = foreach ($g in ($runs | Where-Object { $_.StartedUtc -and $_.Status -ne 'Error' } | Group-Object { ([datetime]$_.StartedUtc).ToString('yyyy-MM-dd') })) {
        $ds = New-Object System.Collections.Generic.List[double]
        foreach ($r in @($g.Group)) {
            $d = Get-TSRunDurationSeconds -Run $r
            if ($null -ne $d -and $d -gt 0) { $ds.Add([double]$d) }
        }
        if (-not $ds.Count) { continue }
        [pscustomobject]@{ Date = $g.Name; Runs = $ds.Count; MedianSeconds = [int][math]::Round((Get-TSMedian -Values $ds.ToArray())) }
    }
    $durTrend = @($durTrend | Sort-Object Date)

    # ---- Slowdowns: a step's recent median vs its own prior median ----
    $durSeries = @{}
    foreach ($run in $runs) {
        foreach ($s in @($run.Steps)) {
            if ($s.Status -ne 'Success' -or $null -eq $s.DurationSeconds) { continue }
            $key = '{0}|{1}' -f $run.TaskSequence, $s.ActionName
            if (-not $durSeries.ContainsKey($key)) { $durSeries[$key] = New-Object System.Collections.Generic.List[object] }
            $durSeries[$key].Add([pscustomobject]@{ Time = [datetime]$s.ExecutionTimeUtc; Dur = [double]$s.DurationSeconds })
        }
    }
    $slow = New-Object System.Collections.Generic.List[object]
    foreach ($key in $durSeries.Keys) {
        $arr = @($durSeries[$key] | Sort-Object Time)
        $c = $arr.Count
        if ($c -lt $SlowdownMinSamples) { continue }   # need a real history before claiming a regression
        $recentN = [int][math]::Max(3, [math]::Floor($c / 3))
        $priorN  = $c - $recentN
        if ($priorN -lt 3 -or $recentN -lt 3) { continue }
        $recent  = @($arr | Select-Object -Last $recentN | ForEach-Object { $_.Dur })
        $prior   = @($arr | Select-Object -First $priorN | ForEach-Object { $_.Dur })
        $pm = Get-TSMedian -Values $prior
        $rm = Get-TSMedian -Values $recent
        if ($pm -lt 3) { continue }   # ignore trivially short steps - relative noise dominates
        if ($rm -ge $pm * $SlowdownFactor) {
            $parts = $key -split '\|', 2
            $slow.Add([pscustomobject]@{
                TaskSequence  = $parts[0]
                ActionName    = $parts[1]
                PriorMedian   = [int][math]::Round($pm)
                RecentMedian  = [int][math]::Round($rm)
                PctSlower     = [math]::Round(($rm - $pm) / $pm * 100, 1)
                PriorSamples  = $priorN
                RecentSamples = $recentN
            })
        }
    }
    $slowdowns = @($slow | Sort-Object PctSlower -Descending)

    # ---- Retry churn: a computer running the same TS more than once in the window ----
    # Churn = a re-run that FOLLOWS a failed OR superseded attempt of the same TS on the same computer.
    # A successful re-image days apart (a separate, standalone deployment) is not churn and is not counted.
    $retryRuns = 0
    $retryComputers = New-Object System.Collections.Generic.List[object]
    foreach ($g in ($settled | Group-Object Computer, TaskSequence)) {
        $ordered = @($g.Group | Sort-Object { [datetime]$_.StartedUtc })
        $retriesHere = 0
        for ($i = 1; $i -lt $ordered.Count; $i++) {
            if ($ordered[$i - 1].Status -eq 'Error' -or $ordered[$i - 1].Superseded) { $retriesHere++ }
        }
        if ($retriesHere -gt 0) {
            $retryRuns += $retriesHere
            $failedHere     = @($ordered | Where-Object { $_.Status -eq 'Error' }).Count
            $supersededHere = @($ordered | Where-Object { $_.Superseded }).Count
            $retryComputers.Add([pscustomobject]@{ Computer = $ordered[0].Computer; TaskSequence = $ordered[0].TaskSequence; Attempts = $ordered.Count; FailedAttempts = $failedHere; SupersededAttempts = $supersededHere })
        }
    }
    $retrySummary = [pscustomobject]@{
        TotalRuns    = $settled.Count
        RetryRuns    = $retryRuns
        RetryRatePct = if ($settled.Count) { [math]::Round($retryRuns / $settled.Count * 100, 1) } else { $null }
        Computers    = @($retryComputers | Sort-Object @{ Expression = 'SupersededAttempts'; Descending = $true }, @{ Expression = 'FailedAttempts'; Descending = $true })
    }

    # ---- Repeat offenders: computers with 2+ failed runs (likely hardware/driver) ----
    $repeatOffenders = foreach ($g in ($failedRuns | Group-Object Computer)) {
        $fails = @($g.Group).Count
        if ($fails -lt 2) { continue }
        $allForComputer = @($runs | Where-Object { $_.Computer -eq $g.Name }).Count
        $tsList = @($g.Group | ForEach-Object { $_.TaskSequence } | Sort-Object -Unique)
        [pscustomobject]@{ Computer = $g.Name; Failures = $fails; Runs = $allForComputer; TaskSequences = ($tsList -join ', ') }
    }
    $repeatOffenders = @($repeatOffenders | Sort-Object Failures -Descending)

    # ---- Regressions: recent-window success rate dropping vs prior window, per TS ----
    $regressions = foreach ($g in ($runs | Where-Object { $_.StartedUtc } | Group-Object TaskSequence)) {
        $ordered = @($g.Group | Sort-Object { [datetime]$_.StartedUtc })
        $c = $ordered.Count
        if ($c -lt $RegressionMinRuns) { continue }   # too few runs to claim a trend
        $half   = [int][math]::Floor($c / 2)
        $prior  = @($ordered | Select-Object -First $half)
        $recent = @($ordered | Select-Object -Last ($c - $half))
        if ($prior.Count -lt 3 -or $recent.Count -lt 3) { continue }
        $pRate  = [math]::Round((@($prior  | Where-Object { $_.Status -ne 'Error' }).Count) / $prior.Count  * 100, 1)
        $rRate  = [math]::Round((@($recent | Where-Object { $_.Status -ne 'Error' }).Count) / $recent.Count * 100, 1)
        if (($pRate - $rRate) -ge $RegressionDropPercentagePoints) {
            [pscustomobject]@{ TaskSequence = $g.Name; PriorRate = $pRate; RecentRate = $rRate; DeltaPct = [math]::Round($pRate - $rRate, 1); PriorRuns = $prior.Count; RecentRuns = $recent.Count }
        }
    }
    $regressions = @($regressions | Sort-Object DeltaPct -Descending)

    # ---- Timing baseline (powers the slowest-steps chart, unchanged) ----
    $baseline = Get-TSStepBaseline -Runs $runs
    $slowest  = @($baseline.Steps | Sort-Object MedianSeconds -Descending | Select-Object -First 10)

    return [pscustomobject]@{
        TotalRuns              = $total
        Completed              = $completed
        Failed                 = $failed
        Warnings               = $warned
        InProgress             = $inProgress
        Superseded             = $superseded
        Succeeded              = $succeeded
        OverallSuccessRate     = if ($completed) { [math]::Round(($completed - $failed) / $completed * 100, 1) } else { $null }
        OverallSuccessRateCILower = if ($overallCI) { $overallCI.Lower } else { $null }
        OverallSuccessRateCIUpper = if ($overallCI) { $overallCI.Upper } else { $null }
        CleanSuccessRate       = if ($completed) { [math]::Round($succeeded / $completed * 100, 1) } else { $null }
        PerTaskSequence        = @($perTs)
        FailuresPerDay         = $trend
        TopFailingSteps        = $topFailing
        RootCauseSteps         = $rootCause
        FailureStages          = $failureStages
        StepHealth             = $stepHealth
        SlowestSteps           = $slowest
        DurationByTaskSequence = $durByTs
        DurationTrend          = $durTrend
        Slowdowns              = $slowdowns
        RetrySummary           = $retrySummary
        RepeatOffenders        = $repeatOffenders
        Regressions            = $regressions
    }
}
