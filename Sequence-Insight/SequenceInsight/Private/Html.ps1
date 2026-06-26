# Html.ps1 - run grouping, report-data shaping and the standalone HTML report.
# Reuses the Export-IntuneKioskConfig.ps1 report pattern: a __DATA__ placeholder (with '<' escaped)
# embedded into a single self-contained file with inline CSS (CSS variables -> dark mode) + vanilla JS.

function Format-TSTime {
    <#
    .SYNOPSIS
        Formats a UTC DateTime as a display string in local or UTC per the requested mode.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Utc,
        [ValidateSet('local', 'utc')][string]$DateDisplay = 'local'
    )
    if (-not $Utc) { return '' }
    $dt = [datetime]$Utc
    if ($DateDisplay -eq 'utc') {
        return ([datetime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)).ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
    }
    return ([datetime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
}

function ConvertTo-TSRun {
    <#
    .SYNOPSIS
        Groups normalized execution rows into runs (Computer + TaskSequence), splitting on large
        time gaps so re-deployments become separate runs.

    .DESCRIPTION
        Pure function over input rows (no I/O) so it is fully unit-testable. A new run starts when either
        (1) the gap between consecutive steps exceeds GapHours, or (2) the sequence restarts from its first
        action - the lowest step ordinal recurs after the run has already progressed past it. The restart
        rule separates re-image attempts that are closer together than GapHours (step 0 is the engine's
        late-reported actions and is ignored for restart detection).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [int]$GapHours = 6
    )

    $runs = New-Object System.Collections.Generic.List[object]
    $groups = $Rows | Group-Object Computer, TaskSequence
    foreach ($g in $groups) {
        $ordered = @($g.Group | Sort-Object ExecutionTimeUtc)
        if ($ordered.Count -eq 0) { continue }

        $segments = New-Object System.Collections.Generic.List[object]
        $current  = New-Object System.Collections.Generic.List[object]
        $prev = $null
        $segMinStep = $null; $segMaxStep = $null
        foreach ($row in $ordered) {
            $gapSplit = $false; $seqRestart = $false
            $s = if ($null -ne $row.Step) { [int]$row.Step } else { $null }

            if ($prev) {
                # 1) A large time gap between steps starts a new run (a separate, standalone re-deployment).
                if ($row.ExecutionTimeUtc -and $prev.ExecutionTimeUtc -and ($row.ExecutionTimeUtc - $prev.ExecutionTimeUtc).TotalHours -gt $GapHours) {
                    $gapSplit = $true
                }
                # 2) The sequence restarting from its first action (the lowest step ordinal recurs after we
                #    have progressed past it) starts a new run - catches re-image attempts closer together
                #    than GapHours. Step 0 = the engine's late-reported actions, so ignore it here.
                elseif ($null -ne $s -and $s -ge 1 -and $null -ne $segMinStep -and $s -le $segMinStep -and $segMaxStep -gt $segMinStep) {
                    $seqRestart = $true
                }
            }

            if ($gapSplit -or $seqRestart) {
                # A segment closed by a sequence-restart was superseded by the next attempt (a rapid
                # re-image of the same effort); one closed by a long gap is its own standalone deployment.
                $segments.Add([pscustomobject]@{ Rows = $current.ToArray(); SupersededByNext = $seqRestart })
                $current = New-Object System.Collections.Generic.List[object]
                $segMinStep = $null; $segMaxStep = $null
            }

            $current.Add($row)
            if ($null -ne $s -and $s -ge 1) {
                if ($null -eq $segMinStep -or $s -lt $segMinStep) { $segMinStep = $s }
                if ($null -eq $segMaxStep -or $s -gt $segMaxStep) { $segMaxStep = $s }
            }
            $prev = $row
        }
        if ($current.Count -gt 0) { $segments.Add([pscustomobject]@{ Rows = $current.ToArray(); SupersededByNext = $false }) }

        foreach ($seg in $segments) {
            # Canonical execution order: timestamp first (so an action reported with Step 0 still lands
            # at its real position), Step as a tiebreaker for rows sharing the same millisecond.
            $steps = @($seg.Rows | Sort-Object @{ Expression = { $_.ExecutionTimeUtc } }, @{ Expression = { [int]$_.Step } })
            $errCount = @($steps | Where-Object { $_.Status -eq 'Error' }).Count
            $started = ($steps | Select-Object -First 1).ExecutionTimeUtc
            $ended   = ($steps | Select-Object -Last 1).ExecutionTimeUtc
            $duration = $null
            if ($started -and $ended) { $duration = [math]::Round(($ended - $started).TotalSeconds, 0) }
            # Outcome from the LAST recorded action: a failed final action means the task sequence
            # aborted (Error); an earlier error but a successful final action means it continued
            # (continue-on-error) and finished (Warnings); otherwise a clean Success.
            $lastStatus = ($steps | Select-Object -Last 1).Status
            $status = if ($lastStatus -eq 'Error') { 'Error' } elseif ($errCount -gt 0) { 'Warnings' } else { 'Success' }
            # Superseded: this attempt was restarted by a later one (rapid re-image), so its "Success" is
            # really an abandoned attempt - not a deployment outcome. A genuinely failed attempt keeps Error.
            $superseded = ($seg.SupersededByNext -and $status -ne 'Error')

            $runs.Add([pscustomobject]@{
                Computer        = $steps[0].Computer
                TaskSequence    = $steps[0].TaskSequence
                PackageID       = $steps[0].PackageID
                ResourceID      = $steps[0].ResourceID
                StartedUtc      = $started
                EndedUtc        = $ended
                DurationSeconds = $duration
                Status          = $status
                Superseded      = $superseded
                ErrorCount      = $errCount
                StepCount       = $steps.Count
                Steps           = $steps
            })
        }
    }

    # Most recently active run first (last step time; fall back to start time).
    return @($runs | Sort-Object -Property @{ Expression = { if ($_.EndedUtc) { $_.EndedUtc } else { $_.StartedUtc } } } -Descending)
}

function ConvertTo-TSReportData {
    <#
    .SYNOPSIS
        Builds the serializable report-data object from normalized rows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [ValidateSet('local', 'utc')][string]$DateDisplay = 'local',
        [ValidateSet('light', 'dark', 'auto')][string]$Theme = 'auto',
        [int]$WindowHours = 168,
        [int]$MaxRows = 0,
        [int]$LiveWindowMinutes = 30,
        [AllowNull()][object[]]$PhaseMap,
        [bool]$DevMode = $false
    )

    $runObjs = ConvertTo-TSRun -Rows $Rows
    # Flag runs still in progress at generation time so analytics can exclude them from the rates
    # (a still-running deployment must never count as a success).
    $runObjs = Add-TSLiveInfo -Runs $runObjs -Baseline (Get-TSStepBaseline -Runs $runObjs) -LiveWindowMinutes $LiveWindowMinutes
    $reportRuns = foreach ($r in $runObjs) {
        [pscustomobject]@{
            computer     = $r.Computer
            taskSequence = $r.TaskSequence
            packageID    = $r.PackageID
            status       = $r.Status
            inProgress   = [bool]$r.IsInProgress
            superseded   = [bool]$r.Superseded
            errorCount   = $r.ErrorCount
            stepCount    = $r.StepCount
            started      = Format-TSTime -Utc $r.StartedUtc -DateDisplay $DateDisplay
            ended        = Format-TSTime -Utc $r.EndedUtc -DateDisplay $DateDisplay
            duration     = Format-TSDuration -Seconds $r.DurationSeconds
            steps        = @(foreach ($s in $r.Steps) {
                    [pscustomobject]@{
                        step      = $s.Step
                        group     = $s.GroupName
                        action    = $s.ActionName
                        status    = $s.Status
                        exitCode  = $s.ExitCode
                        time      = Format-TSTime -Utc $s.ExecutionTimeUtc -DateDisplay $DateDisplay
                        duration  = Format-TSDuration -Seconds $s.DurationSeconds
                        message   = $s.LastStatusMsgName
                        output    = $s.ActionOutput
                    }
                })
        }
    }
    $reportRuns = @($reportRuns)

    # Fleet analytics, re-projected to camelCase to match the rest of the embedded data.
    $an = Get-TSAnalytics -Runs $runObjs -PhaseMap $PhaseMap
    $analytics = [pscustomobject]@{
        totalRuns          = $an.TotalRuns
        completed          = $an.Completed
        failed             = $an.Failed
        warnings           = $an.Warnings
        inProgress         = $an.InProgress
        superseded         = $an.Superseded
        succeeded          = $an.Succeeded
        overallSuccessRate = $an.OverallSuccessRate
        overallSuccessRateCILower = $an.OverallSuccessRateCILower
        overallSuccessRateCIUpper = $an.OverallSuccessRateCIUpper
        cleanSuccessRate   = $an.CleanSuccessRate
        perTaskSequence    = @(foreach ($t in $an.PerTaskSequence) {
                [pscustomobject]@{ taskSequence = $t.TaskSequence; total = $t.Total; failed = $t.Failed; warnings = $t.Warnings; clean = $t.Clean; succeeded = $t.Succeeded; successRate = $t.SuccessRate; successRateCILower = $t.SuccessRateCILower; successRateCIUpper = $t.SuccessRateCIUpper }
            })
        failuresPerDay     = @(foreach ($d in $an.FailuresPerDay) {
                [pscustomobject]@{ date = $d.Date; total = $d.Total; failed = $d.Failed; succeeded = $d.Succeeded; successRate = $d.SuccessRate }
            })
        topFailingSteps    = @(foreach ($s in $an.TopFailingSteps) {
                [pscustomobject]@{ actionName = $s.ActionName; failCount = $s.FailCount; commonExitCodes = $s.CommonExitCodes; exitInfo = $s.PrimaryExitInfo }
            })
        rootCauseSteps     = @(foreach ($s in $an.RootCauseSteps) {
                [pscustomobject]@{ actionName = $s.ActionName; phase = $s.Phase; failCount = $s.FailCount; commonExitCodes = $s.CommonExitCodes; exitInfo = $s.PrimaryExitInfo }
            })
        failureStages      = @(foreach ($s in $an.FailureStages) {
                [pscustomobject]@{ phase = $s.Phase; failCount = $s.FailCount }
            })
        stepHealth         = @(foreach ($s in $an.StepHealth) {
                [pscustomobject]@{ actionName = $s.ActionName; seen = $s.Seen; failures = $s.Failures; failRate = $s.FailRate; medianSeconds = $s.MedianSeconds; p90Seconds = $s.P90Seconds; commonExitCodes = $s.CommonExitCodes }
            })
        slowestSteps       = @(foreach ($s in $an.SlowestSteps) {
                [pscustomobject]@{ actionName = $s.ActionName; medianSeconds = $s.MedianSeconds; p90Seconds = $s.P90Seconds }
            })
        durationByTaskSequence = @(foreach ($s in $an.DurationByTaskSequence) {
                [pscustomobject]@{ taskSequence = $s.TaskSequence; runs = $s.Runs; medianSeconds = $s.MedianSeconds; p90Seconds = $s.P90Seconds; minSeconds = $s.MinSeconds; maxSeconds = $s.MaxSeconds }
            })
        durationTrend      = @(foreach ($s in $an.DurationTrend) {
                [pscustomobject]@{ date = $s.Date; runs = $s.Runs; medianSeconds = $s.MedianSeconds }
            })
        slowdowns          = @(foreach ($s in $an.Slowdowns) {
                [pscustomobject]@{ taskSequence = $s.TaskSequence; actionName = $s.ActionName; priorMedian = $s.PriorMedian; recentMedian = $s.RecentMedian; pctSlower = $s.PctSlower; priorSamples = $s.PriorSamples; recentSamples = $s.RecentSamples }
            })
        retrySummary       = [pscustomobject]@{
            totalRuns    = $an.RetrySummary.TotalRuns
            retryRuns    = $an.RetrySummary.RetryRuns
            retryRatePct = $an.RetrySummary.RetryRatePct
            computers    = @(foreach ($c in $an.RetrySummary.Computers) {
                    [pscustomobject]@{ computer = $c.Computer; taskSequence = $c.TaskSequence; attempts = $c.Attempts; failedAttempts = $c.FailedAttempts; supersededAttempts = $c.SupersededAttempts }
                })
        }
        repeatOffenders    = @(foreach ($s in $an.RepeatOffenders) {
                [pscustomobject]@{ computer = $s.Computer; failures = $s.Failures; runs = $s.Runs; taskSequences = $s.TaskSequences }
            })
        regressions        = @(foreach ($s in $an.Regressions) {
                [pscustomobject]@{ taskSequence = $s.TaskSequence; priorRate = $s.PriorRate; recentRate = $s.RecentRate; deltaPct = $s.DeltaPct; priorRuns = $s.PriorRuns; recentRuns = $s.RecentRuns }
            })
    }

    [pscustomobject]@{
        generated   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        devMode     = [bool]$DevMode
        dateDisplay = $DateDisplay
        theme       = $Theme
        windowHours = $WindowHours
        maxRows     = $MaxRows
        truncated   = ($MaxRows -gt 0 -and @($Rows).Count -ge $MaxRows)
        runCount    = $reportRuns.Count
        stepCount   = @($Rows).Count
        errorCount  = @($Rows | Where-Object { $_.Status -eq 'Error' }).Count
        runs        = $reportRuns
        analytics   = $analytics
    }
}

function Format-TSDuration {
    <#
    .SYNOPSIS
        Formats a duration in seconds as a compact h/m/s string.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Seconds)
    if ($null -eq $Seconds -or "$Seconds" -eq '') { return '' }
    $s = [int]$Seconds
    if ($s -lt 0) { return '' }
    $ts = [timespan]::FromSeconds($s)
    if ($ts.TotalHours -ge 1) { return ('{0}h {1}m' -f [int]$ts.TotalHours, $ts.Minutes) }
    if ($ts.TotalMinutes -ge 1) { return ('{0}m {1}s' -f [int]$ts.TotalMinutes, $ts.Seconds) }
    return ('{0}s' -f $ts.Seconds)
}

function ConvertTo-TSReportHtml {
    <#
    .SYNOPSIS
        Renders the report-data object into a single self-contained HTML string.

    .DESCRIPTION
        JSON is embedded via a __DATA__ placeholder with '<' escaped to < so the data can never
        break out of the script block (same safety technique as Export-IntuneKioskConfig.ps1).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ReportData)

    $reportJson = ($ReportData | ConvertTo-Json -Depth 25 -Compress).Replace('<', ([char]0x5C + 'u003c'))

    $htmlTemplate = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sequence Insight - Report</title>
<style>
:root { --bg:#f6f7f9; --panel:#fff; --ink:#1f2430; --muted:#6b7280; --line:#e5e7eb; --accent:#2563eb;
        --chip:#eef2ff; --ok:#166534; --okbg:#dcfce7; --err:#991b1b; --errbg:#fee2e2; --rowerr:#fef2f2; }
:root[data-theme="dark"] { --bg:#0f1117; --panel:#171a21; --ink:#e6e8ee; --muted:#9aa3b2; --line:#262b36;
        --accent:#6ea8fe; --chip:#1e2533; --ok:#86efac; --okbg:#16361f; --err:#fca5a5; --errbg:#3a1d1d; --rowerr:#241417; }
* { box-sizing:border-box; }
body { margin:0; font:14px/1.5 -apple-system,Segoe UI,Roboto,Arial,sans-serif; color:var(--ink); background:var(--bg); }
header { padding:12px 18px; background:var(--panel); border-bottom:1px solid var(--line); position:sticky; top:0; z-index:5;
         display:flex; align-items:center; gap:14px; }
header h1 { margin:0; font-size:16px; }
header .meta { color:var(--muted); font-size:12px; }
header .spacer { flex:1; }
header .warn { padding:2px 8px; border-radius:10px; background:#fef3c7; color:#92400e; font-size:12px; }
button.theme { font:inherit; padding:5px 10px; border:1px solid var(--line); border-radius:8px; background:var(--bg); color:var(--ink); cursor:pointer; }
.layout { display:flex; height:calc(100vh - 56px); }
aside { width:340px; min-width:250px; border-right:1px solid var(--line); background:var(--panel); overflow:auto; }
aside .search { padding:10px; position:sticky; top:0; background:var(--panel); border-bottom:1px solid var(--line); }
aside input { width:100%; padding:7px 9px; border:1px solid var(--line); border-radius:8px; font:inherit; background:var(--bg); color:var(--ink); }
.item { padding:9px 12px; cursor:pointer; border-left:3px solid transparent; border-bottom:1px solid var(--line); }
.item:hover { background:var(--bg); }
.item.active { background:var(--chip); border-left-color:var(--accent); }
.item .nm { font-weight:600; }
.item .ty { font-size:12px; color:var(--muted); }
.dot { display:inline-block; width:8px; height:8px; border-radius:50%; margin-right:6px; vertical-align:middle; }
.dot.ok { background:#22c55e; } .dot.err { background:#ef4444; } .dot.warn { background:#f59e0b; }
main { flex:1; overflow:auto; padding:18px 22px; }
.card { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:18px 20px; }
.card h2 { margin:0 0 4px; font-size:19px; word-break:break-word; }
.badges { margin:6px 0 14px; }
.badge { display:inline-block; padding:2px 9px; border-radius:10px; background:var(--chip); font-size:12px; margin:0 6px 4px 0; }
.badge.ok { background:var(--okbg); color:var(--ok); font-weight:600; }
.badge.err { background:var(--errbg); color:var(--err); font-weight:600; }
.badge.warn { background:#fef3c7; color:#92400e; font-weight:600; }
table { width:100%; border-collapse:collapse; font-size:13px; }
th, td { text-align:left; padding:6px 8px; border-bottom:1px solid var(--line); vertical-align:top; }
th { color:var(--muted); font-weight:600; position:sticky; top:0; background:var(--panel); }
tr.err td { background:var(--rowerr); }
tr.step { cursor:pointer; }
td.ec.bad { color:var(--err); font-weight:700; }
.output { white-space:pre-wrap; font:12px/1.45 Consolas,Menlo,monospace; background:var(--bg); border:1px solid var(--line);
          border-radius:8px; padding:10px; margin:6px 0 0; display:none; }
.empty { color:var(--muted); padding:40px; text-align:center; }
.muted { color:var(--muted); }
button.nav { font:inherit; padding:5px 12px; border:1px solid var(--line); border-radius:8px; background:var(--bg); color:var(--ink); cursor:pointer; }
button.nav.active { background:var(--accent); color:#fff; border-color:var(--accent); }
#viewAnalytics { height:calc(100vh - 56px); overflow:auto; padding:18px 22px; }
.apage { max-width:1000px; }
.acards { display:flex; gap:14px; margin-bottom:18px; flex-wrap:wrap; }
.acard { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:14px 18px; min-width:140px; }
.acard .anum { font-size:26px; font-weight:700; }
.acard .anum.err { color:var(--err); }
.acard .alab { color:var(--muted); font-size:12px; }
.asec { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:14px 18px; margin-bottom:16px; }
.asec h3 { margin:0 0 10px; font-size:13px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); }
.hbar { display:flex; align-items:center; gap:10px; margin:5px 0; }
.hbar-lab { width:240px; font-size:12px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.hbar-track { flex:1; background:var(--bg); border:1px solid var(--line); border-radius:6px; height:16px; overflow:hidden; }
.hbar-fill { height:100%; background:var(--accent); }
.hbar-fill.ok { background:#22c55e; } .hbar-fill.warn { background:#f59e0b; }
.hbar-val { width:140px; text-align:right; font-size:12px; color:var(--muted); }
.pill { display:inline-block; padding:1px 8px; border-radius:10px; background:var(--chip); font-size:11px; color:var(--muted); white-space:nowrap; }
.drill, .hbar.drill, svg rect.drill { cursor:pointer; }
tr.drill:hover td { background:var(--chip); }
.hbar.drill:hover .hbar-lab { text-decoration:underline; }
td.fr.bad { color:var(--err); font-weight:700; }
td.fr.warn { color:#b45309; font-weight:600; }
:root[data-theme="dark"] td.fr.warn { color:#fbbf24; }
.acard .anum.warn { color:#b45309; }
:root[data-theme="dark"] .acard .anum.warn { color:#fbbf24; }
.hint { margin:0 0 14px; font-size:12px; }
.acard .asub { color:var(--muted); font-size:11px; margin-top:2px; }
.caveat { background:var(--chip); border:1px solid var(--line); border-radius:10px; padding:8px 12px; margin:0 0 14px; font-size:12px; color:var(--muted); line-height:1.5; }
.note { color:var(--muted); font-size:11px; margin-top:6px; }
.execsum { white-space:pre-wrap; font:12px/1.5 Consolas,Menlo,monospace; background:var(--bg); border:1px solid var(--line); border-radius:8px; padding:12px; margin:0 0 16px; max-height:340px; overflow:auto; }
@media (max-width:760px){ aside{width:200px;min-width:160px} main{padding:12px} .hbar-lab{width:120px} }
</style>
</head>
<body>
<header>
  <h1>Sequence Insight</h1>
  <button class="nav active" id="navRuns" type="button">Runs</button>
  <button class="nav" id="navAnalytics" type="button">Analytics</button>
  <div class="meta" id="meta"></div>
  <div id="warnbox"></div>
  <div class="spacer"></div>
  <button class="theme" id="themeBtn" type="button">Toggle theme</button>
</header>
<div class="layout" id="viewRuns">
  <aside>
    <div class="search"><input id="q" type="search" placeholder="Filter by computer, task sequence, action..." autocomplete="off"></div>
    <div id="list"></div>
  </aside>
  <main><div id="detail" class="empty">Select a run on the left.</div></main>
</div>
<div id="viewAnalytics" style="display:none"></div>
<script>
const DATA = __DATA__;
const arr = x => Array.isArray(x) ? x : (x == null ? [] : [x]);
const esc = s => String(s == null ? '' : s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
const runs = arr(DATA.runs);

document.getElementById('meta').textContent =
  'Generated ' + DATA.generated + (DATA.devMode ? ' (demo data)' : '') + ' | ' +
  DATA.runCount + ' runs | ' + DATA.stepCount + ' steps | ' + DATA.errorCount + ' errors | last ' + DATA.windowHours + 'h';
if (DATA.devMode) {
  document.getElementById('warnbox').innerHTML = '<span class="warn">Demo data - not a live ConfigMgr query</span>';
}

function matches(r, f) {
  if (!f) return true;
  if ((r.computer||'').toLowerCase().includes(f)) return true;
  if ((r.taskSequence||'').toLowerCase().includes(f)) return true;
  if ((r.started||'').toLowerCase().includes(f)) return true;
  return arr(r.steps).some(s => (s.action||'').toLowerCase().includes(f));
}
function show(i) {
  const r = runs[i];
  document.querySelectorAll('.item').forEach(el => el.classList.toggle('active', Number(el.dataset.i) === i));
  const stClass = r.superseded ? 'warn' : (r.status === 'Error' ? 'err' : (r.status === 'Success' ? 'ok' : 'warn'));
  const stTxt = r.superseded ? ('Superseded (' + r.status + ')') : r.status;
  const rows = arr(r.steps).map(function (s, j) {
    const bad = s.status === 'Error';
    const ec = (s.exitCode === null || s.exitCode === undefined) ? '' : s.exitCode;
    return '<tr class="step ' + (bad ? 'err' : '') + '" onclick="document.getElementById(\'o' + j + '\').style.display=(document.getElementById(\'o' + j + '\').style.display===\'block\'?\'none\':\'block\')">' +
      '<td>' + esc(s.step) + '</td>' +
      '<td>' + esc(s.action) + (s.output ? '<div class="output" id="o' + j + '">' + esc(s.output) + '</div>' : '') + '</td>' +
      '<td class="ec ' + (bad ? 'bad' : '') + '">' + esc(ec) + '</td>' +
      '<td>' + esc(s.duration) + '</td>' +
      '<td class="muted">' + esc(s.time) + '</td></tr>';
  }).join('');
  const det = document.getElementById('detail');
  det.className = '';
  det.innerHTML =
    '<div class="card"><h2>' + esc(r.computer) + '</h2>' +
    '<div class="badges">' +
      '<span class="badge ' + stClass + '">' + esc(stTxt) + '</span>' +
      '<span class="badge">' + esc(r.taskSequence) + '</span>' +
      (r.packageID ? '<span class="badge">' + esc(r.packageID) + '</span>' : '') +
      '<span class="badge">' + esc(r.errorCount) + ' errors</span>' +
      (r.duration ? '<span class="badge">' + esc(r.duration) + '</span>' : '') +
    '</div>' +
    '<div class="muted">Started ' + esc(r.started) + (r.ended ? ' | last step ' + esc(r.ended) : '') + '</div>' +
    '<table><thead><tr><th>#</th><th>Action (click for output)</th><th>Exit</th><th>Duration</th><th>Time</th></tr></thead>' +
    '<tbody>' + rows + '</tbody></table></div>';
}
function buildList(filter) {
  const f = (filter || '').toLowerCase();
  const list = document.getElementById('list');
  list.innerHTML = '';
  let shown = 0;
  runs.forEach(function (r, i) {
    if (!matches(r, f)) return;
    shown++;
    const d = document.createElement('div');
    d.className = 'item'; d.dataset.i = i;
    const cls = r.superseded ? 'warn' : (r.status === 'Error' ? 'err' : (r.status === 'Success' ? 'ok' : 'warn'));
    d.innerHTML = '<div class="nm"><span class="dot ' + cls + '"></span>' + esc(r.computer) + (r.superseded ? ' <span class="muted">(superseded)</span>' : '') + '</div>' +
                  '<div class="ty">' + esc(r.taskSequence) + ' | ' + esc(r.errorCount) + ' err | ' + esc(r.started) + '</div>';
    d.onclick = () => show(i);
    list.appendChild(d);
  });
  if (!shown) { list.innerHTML = '<div class="empty">No matching runs.</div>'; }
}
(function () {
  const sysDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
  const want = DATA.theme === 'dark' || (DATA.theme === 'auto' && sysDark) ? 'dark' : 'light';
  if (want === 'dark') document.documentElement.setAttribute('data-theme', 'dark');
})();
document.getElementById('themeBtn').addEventListener('click', function () {
  const cur = document.documentElement.getAttribute('data-theme');
  if (cur === 'dark') document.documentElement.removeAttribute('data-theme');
  else document.documentElement.setAttribute('data-theme', 'dark');
});
document.getElementById('q').addEventListener('input', e => buildList(e.target.value));
buildList('');
if (runs.length) show(0);

// ---- Analytics dashboard (inline SVG + bars + tables, dependency-free) ----
const A = DATA.analytics || {};
const escAttr = s => esc(s).replace(/"/g, '&quot;');
function fmtDur(sec) {
  sec = Math.round(Number(sec) || 0);
  if (sec <= 0) return '-';
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
  if (h > 0) return h + 'h ' + m + 'm';
  if (m > 0) return m + 'm ' + s + 's';
  return s + 's';
}
function frClass(fr) { return fr >= 50 ? 'bad' : (fr > 0 ? 'warn' : ''); }
function card(num, lab, cls, sub) { return '<div class="acard"><div class="anum ' + (cls || '') + '">' + esc(num) + '</div><div class="alab">' + esc(lab) + '</div>' + (sub ? '<div class="asub">' + esc(sub) + '</div>' : '') + '</div>'; }
function sec(title, body) { return '<div class="asec"><h3>' + title + '</h3>' + body + '</div>'; }
function buildExecSummary() {
  const A2 = DATA.analytics || {};
  const completed = (A2.completed != null ? A2.completed : (A2.totalRuns || 0));
  const L = [];
  L.push('# Task sequence deployments - last ' + DATA.windowHours + 'h');
  L.push('Generated ' + DATA.generated + (DATA.devMode ? ' (demo data)' : ''));
  L.push('');
  L.push('- Runs: ' + (A2.totalRuns || 0) + ' (' + completed + ' completed, ' + (A2.inProgress || 0) + ' in progress)');
  const ci = (A2.overallSuccessRateCILower != null) ? (' (95% CI ' + A2.overallSuccessRateCILower + '-' + A2.overallSuccessRateCIUpper + '%, n=' + completed + ')') : '';
  L.push('- Success rate: ' + (A2.overallSuccessRate != null ? A2.overallSuccessRate + '%' : 'n/a') + ci);
  L.push('- Outcome: ' + (A2.succeeded || 0) + ' clean, ' + (A2.warnings || 0) + ' warnings, ' + (A2.failed || 0) + ' failed');
  if (A2.superseded) L.push('- Superseded re-image attempts (excluded from rates): ' + A2.superseded);
  if (DATA.truncated) L.push('- NOTE: data capped at ' + DATA.maxRows + ' rows - older runs may be missing');
  L.push('');
  L.push('## Top failure reasons');
  const rc = arr(A2.rootCauseSteps).slice(0, 3);
  if (!rc.length) L.push('- none in this window');
  else rc.forEach((r, i) => L.push((i + 1) + '. ' + r.actionName + ' - ' + r.failCount + ' run(s) [' + r.phase + '; ' + (r.exitInfo || r.commonExitCodes || '') + ']'));
  L.push('');
  L.push('## Needs attention');
  const off = arr(A2.repeatOffenders).slice(0, 5);
  L.push('- Repeat offenders: ' + (off.length ? off.map(o => o.computer + ' (' + o.failures + ' fails)').join(', ') : 'none'));
  const rg = arr(A2.regressions).slice(0, 5);
  L.push('- Recent regressions: ' + (rg.length ? rg.map(r => r.taskSequence + ' ' + r.priorRate + '%->' + r.recentRate + '%').join(', ') : 'none'));
  const rr = (A2.retrySummary && A2.retrySummary.retryRuns) ? A2.retrySummary.retryRuns : 0;
  L.push('- Retry churn (re-runs after a failed/superseded attempt): ' + rr);
  L.push('');
  L.push('Definition: success = a completed run whose final action did not error; in-progress runs are excluded from rates.');
  return L.join('\n');
}
function tbl(headers, rows) {
  if (!rows.length) return '<div class="muted">No data.</div>';
  return '<table><thead><tr>' + headers.map(h => '<th>' + h + '</th>').join('') + '</tr></thead><tbody>' + rows.join('') + '</tbody></table>';
}
function drill(term) {
  const q = document.getElementById('q');
  q.value = term || '';
  buildList(q.value);
  showView('runs');
  const m = document.querySelector('main'); if (m) m.scrollTop = 0;
}
function hbars(items, max) {
  items = arr(items);
  if (!items.length) return '<div class="muted">No data.</div>';
  const m = max || Math.max.apply(null, items.map(i => Number(i.value) || 0).concat([1]));
  return items.map(function (it) {
    const w = Math.max(1, Math.round(((Number(it.value) || 0) / m) * 100));
    const dr = it.drill != null ? ' data-drill="' + escAttr(it.drill) + '"' : '';
    const cl = it.drill != null ? 'hbar drill' : 'hbar';
    return '<div class="' + cl + '"' + dr + '><div class="hbar-lab" title="' + escAttr(it.label) + '">' + esc(it.label) + '</div>' +
      '<div class="hbar-track"><div class="hbar-fill ' + (it.cls || '') + '" style="width:' + w + '%"></div></div>' +
      '<div class="hbar-val">' + esc(it.sub != null ? it.sub : it.value) + '</div></div>';
  }).join('');
}
function columns(rows) {
  rows = arr(rows);
  if (!rows.length) return '<div class="muted">No data.</div>';
  const H = 150, base = H - 16, top = 8, step = 34, bw = 22, pad = 6;
  const W = Math.max(rows.length * step + pad, 120);
  const max = Math.max.apply(null, rows.map(r => r.total).concat([1]));
  let s = '';
  rows.forEach(function (r, i) {
    const x = pad + i * step;
    const th = Math.round((base - top) * (r.total / max));
    const fh = Math.round((base - top) * (r.failed / max));
    s += '<rect x="' + x + '" y="' + (base - th) + '" width="' + bw + '" height="' + th + '" fill="var(--accent)" opacity="0.35"/>';
    if (r.failed > 0) s += '<rect x="' + x + '" y="' + (base - fh) + '" width="' + bw + '" height="' + fh + '" fill="#ef4444"/>';
    s += '<rect class="drill" data-drill="' + escAttr(r.date) + '" x="' + x + '" y="' + top + '" width="' + bw + '" height="' + (base - top) + '" fill="transparent"><title>' + esc(r.date) + ' - ' + esc(r.total) + ' runs, ' + esc(r.failed) + ' failed</title></rect>';
    s += '<text x="' + (x + bw / 2) + '" y="' + (H - 3) + '" font-size="9" text-anchor="middle" fill="var(--muted)">' + esc(String(r.date).slice(5)) + '</text>';
    s += '<text x="' + (x + bw / 2) + '" y="' + (base - th - 3) + '" font-size="9" text-anchor="middle" fill="var(--muted)">' + esc(r.total) + '</text>';
  });
  return '<svg viewBox="0 0 ' + W + ' ' + H + '" width="100%" height="' + H + '" preserveAspectRatio="xMinYMid meet">' + s + '</svg>';
}
function renderAnalytics() {
  const totalRuns = (A.totalRuns != null ? A.totalRuns : runs.length);
  const completed = (A.completed != null ? A.completed : totalRuns);
  const srSub = (A.overallSuccessRateCILower != null)
    ? ('95% CI ' + A.overallSuccessRateCILower + '-' + A.overallSuccessRateCIUpper + '% (n=' + completed + ')')
    : ('of ' + completed + ' completed');
  const cards = '<div class="acards">' +
    card(totalRuns, 'runs') +
    card(A.overallSuccessRate != null ? A.overallSuccessRate + '%' : '-', 'success rate', '', srSub) +
    card(A.succeeded != null ? A.succeeded : '-', 'clean', 'ok') +
    card(A.warnings != null ? A.warnings : 0, 'warnings', 'warn') +
    card(A.failed != null ? A.failed : '-', 'failed', 'err') +
    card(A.inProgress != null ? A.inProgress : 0, 'in progress') +
    (A.superseded ? card(A.superseded, 'superseded', 'warn') : '') +
    (A.retrySummary && A.retrySummary.retryRatePct != null ? card(A.retrySummary.retryRatePct + '%', 'retry rate') : '') +
    '</div>';
  const caveat =
    'Window: last ' + esc(DATA.windowHours) + 'h | ' + esc(DATA.stepCount) + ' step-rows' +
    (DATA.truncated ? ' (capped at ' + esc(DATA.maxRows) + ' - older runs may be truncated)' : '') +
    ' | ' + completed + ' of ' + totalRuns + ' runs completed' +
    (A.inProgress ? ', ' + A.inProgress + ' in progress' : '') +
    (A.superseded ? ', ' + A.superseded + ' superseded (re-image attempts)' : '') +
    ((A.inProgress || A.superseded) ? ' (excluded from rates)' : '') +
    ' | Success = a completed run whose final action did not error; warnings = completed with a non-fatal step error | times in ' + esc(DATA.dateDisplay) + '.';

  // A - root cause, failure stages, step health
  const rcTable = tbl(['Root-cause step', 'Phase', 'Failed runs', 'Exit code'], arr(A.rootCauseSteps).slice(0, 15).map(r =>
    '<tr class="drill" data-drill="' + escAttr(r.actionName) + '"><td>' + esc(r.actionName) + '</td>' +
    '<td><span class="pill">' + esc(r.phase) + '</span></td><td>' + esc(r.failCount) + '</td>' +
    '<td class="muted">' + esc(r.exitInfo || r.commonExitCodes || '') + '</td></tr>'));
  const stages = hbars(arr(A.failureStages).map(s => ({ label: s.phase, value: s.failCount, sub: s.failCount + ' failed', cls: 'warn' })));
  const shTable = tbl(['Action', 'Runs', 'Fail', 'Fail %', 'Median (elapsed)', 'P90 (elapsed)'], arr(A.stepHealth).slice(0, 25).map(s =>
    '<tr class="drill" data-drill="' + escAttr(s.actionName) + '"><td>' + esc(s.actionName) + '</td>' +
    '<td>' + esc(s.seen) + '</td><td>' + esc(s.failures) + '</td>' +
    '<td class="fr ' + frClass(s.failRate) + '">' + (s.failRate == null ? '-' : esc(s.failRate) + '%') + '</td>' +
    '<td>' + (s.medianSeconds == null ? '-' : fmtDur(s.medianSeconds)) + '</td>' +
    '<td class="muted">' + (s.p90Seconds == null ? '-' : fmtDur(s.p90Seconds)) + '</td></tr>'));

  // B - duration & slowdowns
  const durTs = tbl(['Task sequence', 'Runs', 'Median', 'P90', 'Fastest', 'Slowest'], arr(A.durationByTaskSequence).map(d =>
    '<tr class="drill" data-drill="' + escAttr(d.taskSequence) + '"><td>' + esc(d.taskSequence) + '</td>' +
    '<td>' + esc(d.runs) + '</td><td>' + fmtDur(d.medianSeconds) + '</td><td>' + fmtDur(d.p90Seconds) + '</td>' +
    '<td class="muted">' + fmtDur(d.minSeconds) + '</td><td class="muted">' + fmtDur(d.maxSeconds) + '</td></tr>'));
  const durTrend = hbars(arr(A.durationTrend).map(d => ({ label: d.date, value: d.medianSeconds, sub: fmtDur(d.medianSeconds) })));
  const slowdowns = tbl(['Step', 'Task sequence', 'Prior', 'Recent', 'Slower', 'Samples (prior/recent)'], arr(A.slowdowns).slice(0, 15).map(s =>
    '<tr class="drill" data-drill="' + escAttr(s.actionName) + '"><td>' + esc(s.actionName) + '</td>' +
    '<td class="muted">' + esc(s.taskSequence) + '</td><td>' + fmtDur(s.priorMedian) + '</td><td>' + fmtDur(s.recentMedian) + '</td>' +
    '<td class="ec bad">+' + esc(s.pctSlower) + '%</td>' +
    '<td class="muted">' + esc(s.priorSamples) + ' / ' + esc(s.recentSamples) + '</td></tr>'));

  // C - reliability, regressions, fleet churn
  const perTs = tbl(['Task sequence', 'Runs', 'Success rate', '95% CI', 'Clean', 'Warn', 'Failed'], arr(A.perTaskSequence).map(t =>
    '<tr class="drill" data-drill="' + escAttr(t.taskSequence) + '"><td>' + esc(t.taskSequence) + '</td>' +
    '<td>' + esc(t.total) + '</td>' +
    '<td>' + (t.successRate == null ? '-' : esc(t.successRate) + '%') + '</td>' +
    '<td class="muted">' + (t.successRateCILower == null ? '-' : esc(t.successRateCILower) + '-' + esc(t.successRateCIUpper) + '%') + '</td>' +
    '<td>' + esc(t.clean) + '</td>' +
    '<td class="' + (t.warnings ? 'fr warn' : 'muted') + '">' + esc(t.warnings) + '</td>' +
    '<td class="' + (t.failed ? 'ec bad' : 'muted') + '">' + esc(t.failed) + '</td></tr>'));
  const regr = tbl(['Task sequence', 'Prior', 'Recent', 'Drop', 'Runs (prior/recent)'], arr(A.regressions).map(r =>
    '<tr class="drill" data-drill="' + escAttr(r.taskSequence) + '"><td>' + esc(r.taskSequence) + '</td>' +
    '<td>' + esc(r.priorRate) + '%</td><td class="ec bad">' + esc(r.recentRate) + '%</td>' +
    '<td class="ec bad">-' + esc(r.deltaPct) + ' pts</td>' +
    '<td class="muted">' + esc(r.priorRuns) + ' / ' + esc(r.recentRuns) + '</td></tr>'));
  const retryTable = tbl(['Computer', 'Task sequence', 'Attempts', 'Failed'], arr(A.retrySummary ? A.retrySummary.computers : []).slice(0, 15).map(c =>
    '<tr class="drill" data-drill="' + escAttr(c.computer) + '"><td>' + esc(c.computer) + '</td>' +
    '<td class="muted">' + esc(c.taskSequence) + '</td><td>' + esc(c.attempts) + '</td>' +
    '<td class="ec bad">' + esc(c.failedAttempts) + '</td></tr>'));
  const offenders = tbl(['Computer', 'Failures', 'Runs', 'Task sequences'], arr(A.repeatOffenders).slice(0, 15).map(o =>
    '<tr class="drill" data-drill="' + escAttr(o.computer) + '"><td>' + esc(o.computer) + '</td>' +
    '<td class="ec bad">' + esc(o.failures) + '</td><td>' + esc(o.runs) + '</td>' +
    '<td class="muted">' + esc(o.taskSequences) + '</td></tr>'));

  const elapsedNote = '<div class="note">Step timing is elapsed wall-clock between status messages (includes reboots and waits), not pure step execution time.</div>';
  const phaseNote = '<div class="note">Phase is inferred from group/action names (heuristic) &ndash; customize the patterns via analytics.phasePatterns in config.</div>';
  document.getElementById('viewAnalytics').innerHTML =
    '<div class="apage">' + cards +
    '<div class="caveat">' + caveat + '</div>' +
    '<div class="hint muted">Tip: click any row, bar or column to jump to the matching runs.</div>' +
    '<div style="margin:0 0 14px"><button class="nav" id="execBtn" type="button">Copy exec summary</button> <span class="muted" id="execMsg" style="font-size:12px"></span></div>' +
    '<pre class="execsum" id="execsumOut" style="display:none"></pre>' +
    sec('Where deployments break (terminal failing step)', rcTable) +
    sec('Failures by phase', stages + phaseNote) +
    sec('Step health &ndash; reliability &amp; timing', shTable + elapsedNote) +
    sec('Failures per day', columns(A.failuresPerDay)) +
    sec('Task sequence scorecard', perTs) +
    sec('Recent regressions', regr + '<div class="note">Signal to verify, not a verdict &ndash; based on small samples; confirm against the underlying runs before reporting.</div>') +
    sec('Duration per task sequence', durTs) +
    sec('Median duration per day', durTrend) +
    sec('Steps slowing down', slowdowns + elapsedNote) +
    sec('Retry churn (re-runs after a failed attempt)', retryTable) +
    sec('Repeat offenders', offenders) +
    '</div>';
}
function showView(v) {
  document.getElementById('viewRuns').style.display = (v === 'runs') ? 'flex' : 'none';
  document.getElementById('viewAnalytics').style.display = (v === 'analytics') ? 'block' : 'none';
  document.getElementById('navRuns').classList.toggle('active', v === 'runs');
  document.getElementById('navAnalytics').classList.toggle('active', v === 'analytics');
}
document.getElementById('navRuns').addEventListener('click', () => showView('runs'));
document.getElementById('navAnalytics').addEventListener('click', () => { renderAnalytics(); showView('analytics'); });
document.getElementById('viewAnalytics').addEventListener('click', function (e) {
  if (e.target && e.target.id === 'execBtn') {
    const out = document.getElementById('execsumOut');
    const txt = buildExecSummary();
    out.textContent = txt;
    out.style.display = 'block';
    const msg = document.getElementById('execMsg');
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(txt).then(function () { if (msg) msg.textContent = 'copied to clipboard'; }, function () { if (msg) msg.textContent = 'select the text below and copy'; });
    } else if (msg) { msg.textContent = 'select the text below and copy'; }
    return;
  }
  const t = e.target.closest('[data-drill]');
  if (t) drill(t.getAttribute('data-drill'));
});
</script>
</body>
</html>
'@

    return $htmlTemplate.Replace('__DATA__', $reportJson)
}
