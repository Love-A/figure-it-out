#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pester v5 tests for the SequenceInsight data layer. No live ConfigMgr, SQL or network required:
    private + public functions are dot-sourced, and DevMode / pure functions are exercised.
#>

BeforeAll {
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $moduleRoot  = Join-Path $projectRoot 'SequenceInsight'
    Get-ChildItem -Path (Join-Path $moduleRoot 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    Get-ChildItem -Path (Join-Path $moduleRoot 'Public')  -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    # Deterministic run builder for analytics/live tests. Times are treated as UTC.
    function New-Run {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory test data builder; no system state change.')]
        param([string]$Computer, [string]$Ts, [string]$Status, [string]$Started, [object[]]$Steps)
        $stepObjs = foreach ($s in $Steps) {
            [pscustomobject]@{
                Step             = $s.Step
                ActionName       = $s.Action
                Status           = $s.Status
                ExitCode         = $s.Exit
                DurationSeconds  = $s.Dur
                GroupName        = ''
                ActionOutput     = ''
                LastStatusMsgName = ''
                ExecutionTimeUtc = [datetime]::SpecifyKind((Get-Date $s.Time), [System.DateTimeKind]::Utc)
            }
        }
        [pscustomobject]@{
            Computer        = $Computer
            TaskSequence    = $Ts
            PackageID       = 'P1'
            ResourceID      = 1
            StartedUtc      = [datetime]::SpecifyKind((Get-Date $Started), [System.DateTimeKind]::Utc)
            EndedUtc        = [datetime]::SpecifyKind((Get-Date $Steps[-1].Time), [System.DateTimeKind]::Utc)
            DurationSeconds = 0
            Status          = $Status
            ErrorCount      = @($Steps | Where-Object { $_.Status -eq 'Error' }).Count
            StepCount       = $Steps.Count
            Steps           = @($stepObjs)
        }
    }
}

Describe 'Confirm-TSConfig' {
    It 'fills defaults on an empty config' {
        $c = Confirm-TSConfig -Config $null
        $c.refreshIntervalSeconds | Should -Be 30
        $c.theme                  | Should -Be 'auto'
        $c.sql.encrypt            | Should -BeTrue
        $c.adminService.trustServerCertificate | Should -BeFalse
        @($c.analytics.phasePatterns).Count    | Should -Be 0
    }

    It 'normalizes invalid enum values' {
        $c = Confirm-TSConfig -Config ([pscustomobject]@{ theme = 'neon'; dateDisplay = 'martian' })
        $c.theme       | Should -Be 'auto'
        $c.dateDisplay | Should -Be 'local'
    }

    It 'throws when required connection keys are missing' {
        { Confirm-TSConfig -Config $null -RequireConnection } | Should -Throw
    }

    It 'passes when required connection keys are present' {
        $cfg = [pscustomobject]@{
            provider = 'cm.contoso.com'; siteCode = 'ABC'
            sql = [pscustomobject]@{ server = 'sql.contoso.com'; database = 'CM_ABC' }
        }
        { Confirm-TSConfig -Config $cfg -RequireConnection } | Should -Not -Throw
    }
}

Describe 'AdminService helpers' {
    It 'builds the AdminService base URI from a bare host' {
        Get-TSAdminServiceBaseUri -Provider 'cm.contoso.com' | Should -Be 'https://cm.contoso.com/AdminService'
    }
    It 'does not double up scheme or suffix' {
        Get-TSAdminServiceBaseUri -Provider 'https://cm.contoso.com/AdminService' | Should -Be 'https://cm.contoso.com/AdminService'
    }
    It 'flattens a value-array response' {
        $resp = [pscustomobject]@{ value = @([pscustomobject]@{ Name = 'a' }, [pscustomobject]@{ Name = 'b' }) }
        (ConvertFrom-TSAdminServiceValue -Response $resp).Count | Should -Be 2
    }
    It 'wraps a single object response' {
        $resp = [pscustomobject]@{ value = [pscustomobject]@{ Name = 'a' } }
        @(ConvertFrom-TSAdminServiceValue -Response $resp).Count | Should -Be 1
    }
    It 'returns empty for null' {
        @(ConvertFrom-TSAdminServiceValue -Response $null).Count | Should -Be 0
    }
}

Describe 'Get-TSSqlConnectionString' {
    It 'builds an integrated-auth connection string with encryption flags' {
        $cs = Get-TSSqlConnectionString -Server 'sql1' -Database 'CM_ABC' -Encrypt $true -TrustServerCertificate $false
        $cs | Should -Match 'Server=sql1'
        $cs | Should -Match 'Database=CM_ABC'
        $cs | Should -Match 'Integrated Security=SSPI'
        $cs | Should -Match 'Encrypt=true'
        $cs | Should -Match 'TrustServerCertificate=false'
    }
}

Describe 'SQL execution query (real-data path)' {
    It 'filters by the time window and parameterizes package/computer' {
        (Get-TSExecutionQueryText) | Should -Match 'tse\.ExecutionTime\s*>=\s*@StartTime'
        (Get-TSExecutionQueryText) | Should -Match '@PackageID'
        (Get-TSExecutionQueryText) | Should -Match '@Computer'
    }
    It 'excludes the large ActionOutput column by default and includes it on demand' {
        (Get-TSExecutionQueryText)                | Should -Not -Match 'tse\.ActionOutput'
        (Get-TSExecutionQueryText -IncludeOutput) | Should -Match 'tse\.ActionOutput'
    }
}

Describe 'ConvertTo-TSExecutionRow' {
    It 'derives Status from ExitCode and marks time UTC' {
        $raw = @(
            [pscustomobject]@{ Computer='PC1'; TaskSequence='TS'; PackageID='P1'; Step=1; ActionName='A'; ExitCode=0;  ExecutionTime=(Get-Date '2026-01-01T10:00:00') }
            [pscustomobject]@{ Computer='PC1'; TaskSequence='TS'; PackageID='P1'; Step=2; ActionName='B'; ExitCode=16389; ExecutionTime=(Get-Date '2026-01-01T10:05:00') }
        )
        $rows = ConvertTo-TSExecutionRow -Rows $raw
        ($rows | Where-Object Step -eq 1).Status | Should -Be 'Success'
        ($rows | Where-Object Step -eq 2).Status | Should -Be 'Error'
        ($rows | Where-Object Step -eq 1).ExecutionTimeUtc.Kind | Should -Be 'Utc'
    }

    It 'computes per-step duration within a run' {
        $raw = @(
            [pscustomobject]@{ Computer='PC1'; TaskSequence='TS'; Step=1; ExitCode=0; ExecutionTime=(Get-Date '2026-01-01T10:00:00') }
            [pscustomobject]@{ Computer='PC1'; TaskSequence='TS'; Step=2; ExitCode=0; ExecutionTime=(Get-Date '2026-01-01T10:01:30') }
        )
        $rows = ConvertTo-TSExecutionRow -Rows $raw
        ($rows | Where-Object Step -eq 1).DurationSeconds | Should -Be 90
    }
}

Describe 'Demo data' {
    It 'produces rows including at least one error' {
        $rows = Get-TSDemoExecution
        $rows.Count | Should -BeGreaterThan 0
        (@($rows | Where-Object Status -eq 'Error').Count) | Should -BeGreaterThan 0
    }
    It 'lists demo task sequences' {
        (Get-TSDemoPackageList).Count | Should -BeGreaterThan 0
    }
}

Describe 'ConvertTo-TSRun' {
    It 'groups rows into one run per computer+TS and counts errors' {
        $rows = Get-TSDemoExecution
        $runs = ConvertTo-TSRun -Rows $rows
        $runs.Count | Should -BeGreaterThan 0
        ($runs | Where-Object Status -eq 'Error').Count | Should -BeGreaterThan 0
    }

    It 'splits a run on a large time gap' {
        $rows = @(
            [pscustomobject]@{ Computer='PC1'; TaskSequence='TS'; Step=1; Status='Success'; ExitCode=0; GroupName=''; ActionName='A'; ActionOutput=''; PackageID='P1'; ResourceID=1; LastStatusMsgName=''; DurationSeconds=0; ExecutionTimeUtc=[datetime]::SpecifyKind((Get-Date '2026-01-01T10:00:00'),'Utc') }
            [pscustomobject]@{ Computer='PC1'; TaskSequence='TS'; Step=1; Status='Success'; ExitCode=0; GroupName=''; ActionName='A'; ActionOutput=''; PackageID='P1'; ResourceID=1; LastStatusMsgName=''; DurationSeconds=0; ExecutionTimeUtc=[datetime]::SpecifyKind((Get-Date '2026-01-02T10:00:00'),'Utc') }
        )
        $g = ConvertTo-TSRun -Rows $rows -GapHours 6
        $g.Count | Should -Be 2
        @($g | Where-Object Superseded).Count | Should -Be 0   # a long gap = separate deployments, not superseded
    }

    It 'splits two re-image attempts (sequence restart) closer together than the gap threshold' {
        $mk = {
            param($step, $action, $time)
            [pscustomobject]@{ Computer='PC1'; TaskSequence='TS'; PackageID='P1'; ResourceID=1; Step=$step
                Status='Success'; ExitCode=0; GroupName=''; ActionName=$action; ActionOutput=''
                LastStatusMsgName=''; DurationSeconds=0
                ExecutionTimeUtc=[datetime]::SpecifyKind((Get-Date $time), 'Utc') }
        }
        $rows = @(
            (& $mk 1 'Init'  '2026-01-01T10:00:00')
            (& $mk 2 'Apply' '2026-01-01T10:05:00')
            (& $mk 3 'Done'  '2026-01-01T10:10:00')
            # second attempt only 2h later (well within GapHours) - it restarts from step 1
            (& $mk 1 'Init'  '2026-01-01T12:00:00')
            (& $mk 2 'Apply' '2026-01-01T12:05:00')
            (& $mk 3 'Done'  '2026-01-01T12:10:00')
        )
        $runs = ConvertTo-TSRun -Rows $rows -GapHours 6
        $runs.Count            | Should -Be 2
        @($runs)[0].StepCount  | Should -Be 3
        @($runs)[1].StepCount  | Should -Be 3
        # Output is sorted most-recent first: the later attempt is the real one, the earlier was superseded.
        @($runs)[0].Superseded | Should -BeFalse
        @($runs)[1].Superseded | Should -BeTrue
    }

    It 'orders a late Step=0 action by timestamp, not by step number' {
        $mk = {
            param($step, $action, $time)
            [pscustomobject]@{ Computer='PC1'; TaskSequence='TS'; PackageID='P1'; ResourceID=1; Step=$step
                Status='Success'; ExitCode=0; GroupName=''; ActionName=$action; ActionOutput=''
                LastStatusMsgName=''; DurationSeconds=0
                ExecutionTimeUtc=[datetime]::SpecifyKind((Get-Date $time), 'Utc') }
        }
        $rows = @(
            (& $mk 1 'First'           '2026-01-01T10:00:00')
            (& $mk 2 'Second'          '2026-01-01T10:01:00')
            (& $mk 0 'LateButStepZero' '2026-01-01T10:02:00')
        )
        $run = ConvertTo-TSRun -Rows $rows
        $actions = @($run[0].Steps | ForEach-Object ActionName)
        $actions[0]  | Should -Be 'First'
        $actions[-1] | Should -Be 'LateButStepZero'
    }

    It 'is Warnings when a step failed but the run finished, and Error when the last step failed' {
        $mk = {
            param($step, $action, $status, $exit, $time)
            [pscustomobject]@{ Computer='PC1'; TaskSequence='TS'; PackageID='P1'; ResourceID=1; Step=$step
                Status=$status; ExitCode=$exit; GroupName=''; ActionName=$action; ActionOutput=''
                LastStatusMsgName=''; DurationSeconds=0
                ExecutionTimeUtc=[datetime]::SpecifyKind((Get-Date $time), 'Utc') }
        }
        $finishedWithError = @(
            (& $mk 1 'A' 'Success' 0 '2026-01-01T10:00:00')
            (& $mk 2 'B' 'Error'   1 '2026-01-01T10:01:00')
            (& $mk 3 'C' 'Success' 0 '2026-01-01T10:02:00')
        )
        (ConvertTo-TSRun -Rows $finishedWithError)[0].Status | Should -Be 'Warnings'

        $abortedAtLastStep = @(
            (& $mk 1 'A' 'Success' 0 '2026-01-01T10:00:00')
            (& $mk 2 'B' 'Error'   1 '2026-01-01T10:01:00')
        )
        (ConvertTo-TSRun -Rows $abortedAtLastStep)[0].Status | Should -Be 'Error'
    }
}

Describe 'ConvertTo-TSReportHtml' {
    BeforeAll {
        $data = ConvertTo-TSReportData -Rows (Get-TSDemoExecution) -DateDisplay 'local' -Theme 'auto' -WindowHours 168 -DevMode $true
        $script:html = ConvertTo-TSReportHtml -ReportData $data
    }
    It 'replaces the __DATA__ placeholder' {
        $script:html | Should -Not -Match '__DATA__'
        $script:html | Should -Match 'const DATA ='
    }
    It 'includes a demo computer name' {
        $script:html | Should -Match 'WS-AB12CD'
    }
    It 'includes the analytics dashboard (nav + charts)' {
        $script:html | Should -Match 'navAnalytics'
        $script:html | Should -Match 'function renderAnalytics'
        $script:html | Should -Match 'Failures per day'
    }
    It 'includes the enriched analytics sections and drill-down wiring' {
        $script:html | Should -Match 'Where deployments break'
        $script:html | Should -Match 'Step health'
        $script:html | Should -Match 'Repeat offenders'
        $script:html | Should -Match 'Recent regressions'
        $script:html | Should -Match 'function drill'
        $script:html | Should -Match 'data-drill'
        $script:html | Should -Match 'Copy exec summary'
        $script:html | Should -Match 'function buildExecSummary'
        $script:html | Should -Match 'Task sequence scorecard'
    }
    It 'escapes < in the embedded data so it cannot break out of the script block' {
        $row = [pscustomobject]@{
            Computer='PC1'; TaskSequence='TS'; PackageID='P1'; ResourceID=1; Step=1; GroupName=''
            ActionName='Evil'; Status='Error'; ExitCode=1; LastStatusMsgName=''; DurationSeconds=0
            ActionOutput='<script>alert(1)</script>'
            ExecutionTimeUtc=[datetime]::SpecifyKind((Get-Date '2026-01-01T10:00:00'),'Utc')
        }
        $d = ConvertTo-TSReportData -Rows @($row) -DateDisplay 'utc' -Theme 'auto' -WindowHours 1 -DevMode $true
        $h = ConvertTo-TSReportHtml -ReportData $d
        # Isolate the embedded data line: 'const DATA = {...};'
        $dataLine = ($h -split "`n" | Where-Object { $_ -match 'const DATA = \{' })
        $dataLine | Should -Match '\\u003cscript'   # the payload's '<' was escaped
        $dataLine | Should -Not -Match '<script'     # no raw '<' survives in the data region
    }
}

Describe 'Export-TSReport (DevMode, temp dir)' {
    BeforeAll {
        $script:ctx = Connect-SequenceInsight -DevMode
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('tsm-' + [guid]::NewGuid().ToString('N'))
    }
    AfterAll {
        if (Test-Path $script:tmp) { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'writes report.html and report-data.json' {
        $out = Export-TSReport -Context $script:ctx -OutputDirectory $script:tmp -Formats Html, Csv, Json
        Test-Path (Join-Path $script:tmp 'report.html')        | Should -BeTrue
        Test-Path (Join-Path $script:tmp 'report-data.json')   | Should -BeTrue
        Test-Path (Join-Path $script:tmp 'execution-rows.csv') | Should -BeTrue
        $out | Should -Match 'report\.html$'
    }
    It 'rebuilds report.html from report-data.json without a context' {
        Remove-Item (Join-Path $script:tmp 'report.html') -Force
        Export-TSReport -OutputDirectory $script:tmp -RebuildReportOnly | Out-Null
        Test-Path (Join-Path $script:tmp 'report.html') | Should -BeTrue
    }
}

Describe 'Analytics helpers' {
    It 'computes median for odd and even sets' {
        Get-TSMedian -Values @(10, 20, 30) | Should -Be 20
        Get-TSMedian -Values @(10, 20)     | Should -Be 15
    }
    It 'computes nearest-rank p90' {
        Get-TSPercentile -Values (1..10) -Percentile 90 | Should -Be 9
    }
    It 'computes a Wilson interval that is wider for tiny samples (honest about uncertainty)' {
        Get-TSWilsonInterval -Successes 0 -Total 0 | Should -BeNullOrEmpty
        $big = Get-TSWilsonInterval -Successes 95 -Total 100
        $big.Lower | Should -BeLessThan 95
        $big.Upper | Should -BeGreaterThan 95
        $big.Upper | Should -BeLessOrEqual 100
        $small = Get-TSWilsonInterval -Successes 1 -Total 2
        ($small.Upper - $small.Lower) | Should -BeGreaterThan ($big.Upper - $big.Lower)
    }
}

Describe 'Get-TSStepBaseline' {
    It 'computes per-step medians and a trusted per-TS total from successful runs' {
        $runs = @(
            New-Run -Computer PC1 -Ts 'Bare Metal' -Status Success -Started '2026-01-01T10:00:00' -Steps @(
                @{ Step = 1; Action = 'Apply OS'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-01-01T10:00:10' }
                @{ Step = 2; Action = 'Reboot';   Status = 'Success'; Exit = 0; Dur = 5;  Time = '2026-01-01T10:00:20' }
            )
            New-Run -Computer PC2 -Ts 'Bare Metal' -Status Success -Started '2026-01-01T11:00:00' -Steps @(
                @{ Step = 1; Action = 'Apply OS'; Status = 'Success'; Exit = 0; Dur = 20; Time = '2026-01-01T11:00:20' }
                @{ Step = 2; Action = 'Reboot';   Status = 'Success'; Exit = 0; Dur = 5;  Time = '2026-01-01T11:00:30' }
            )
            New-Run -Computer PC3 -Ts 'Bare Metal' -Status Success -Started '2026-01-01T12:00:00' -Steps @(
                @{ Step = 1; Action = 'Apply OS'; Status = 'Success'; Exit = 0; Dur = 30; Time = '2026-01-01T12:00:30' }
                @{ Step = 2; Action = 'Reboot';   Status = 'Success'; Exit = 0; Dur = 5;  Time = '2026-01-01T12:00:40' }
            )
        )
        $b = Get-TSStepBaseline -Runs $runs
        (($b.Steps | Where-Object { $_.ActionName -eq 'Apply OS' }).MedianSeconds) | Should -Be 20
        $ts = $b.PerTaskSequence | Where-Object { $_.TaskSequence -eq 'Bare Metal' }
        $ts.TotalMedianSeconds | Should -Be 25
        $ts.Trusted            | Should -BeTrue
    }
}

Describe 'Get-TSAnalytics' {
    It 'computes success rate, trend and top failing step' {
        $okSteps = @(@{ Step = 1; Action = 'Apply OS'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-01-01T10:00:10' })
        $runs = @(
            New-Run -Computer PC1 -Ts 'X' -Status Success -Started '2026-01-01T10:00:00' -Steps $okSteps
            New-Run -Computer PC2 -Ts 'X' -Status Success -Started '2026-01-01T11:00:00' -Steps $okSteps
            New-Run -Computer PC3 -Ts 'X' -Status Error   -Started '2026-01-02T10:00:00' -Steps @(
                @{ Step = 1; Action = 'Apply OS';    Status = 'Success'; Exit = 0;     Dur = 10; Time = '2026-01-02T10:00:10' }
                @{ Step = 2; Action = 'Install App'; Status = 'Error';   Exit = 16389; Dur = 5;  Time = '2026-01-02T10:00:20' }
            )
        )
        $a = Get-TSAnalytics -Runs $runs
        $a.TotalRuns           | Should -Be 3
        $a.Failed              | Should -Be 1
        $a.OverallSuccessRate  | Should -Be 66.7
        ($a.TopFailingSteps)[0].ActionName | Should -Be 'Install App'
        $a.FailuresPerDay.Count | Should -Be 2
        $a.OverallSuccessRateCILower | Should -BeLessThan 66.7
        $a.OverallSuccessRateCIUpper | Should -BeGreaterThan 66.7
        ($a.PerTaskSequence | Where-Object TaskSequence -eq 'X').SuccessRateCILower | Should -Not -BeNullOrEmpty
    }
}

Describe 'Add-TSLiveInfo' {
    BeforeAll {
        $script:asof = [datetime]::SpecifyKind((Get-Date '2026-01-01T12:00:00'), [System.DateTimeKind]::Utc)
        $script:base = [pscustomobject]@{
            Steps = @()
            PerTaskSequence = @([pscustomobject]@{ TaskSequence = 'Y'; SuccessfulRuns = 3; TotalMedianSeconds = 600; ExpectedStepCount = 10; Trusted = $true })
        }
    }
    It 'flags an in-progress run and estimates percent from the baseline' {
        $run = New-Run -Computer PC1 -Ts 'Y' -Status Success -Started '2026-01-01T11:55:00' -Steps @(
            @{ Step = 1; Action = 'Step A'; Status = 'Success'; Exit = 0; Dur = 60; Time = '2026-01-01T11:58:00' }
        )
        Add-TSLiveInfo -Runs @($run) -Baseline $script:base -AsOf $script:asof -LiveWindowMinutes 30 | Out-Null
        $run.IsInProgress    | Should -BeTrue
        $run.CurrentStep     | Should -Be 'Step A'
        $run.PercentComplete | Should -Be 50   # elapsed 300s / baseline 600s
    }
    It 'does not flag a completed (old) run as in-progress' {
        $done = New-Run -Computer PC2 -Ts 'Y' -Status Success -Started '2026-01-01T10:00:00' -Steps @(
            @{ Step = 1; Action = 'X'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-01-01T11:00:00' }
        )
        Add-TSLiveInfo -Runs @($done) -Baseline $script:base -AsOf $script:asof -LiveWindowMinutes 30 | Out-Null
        $done.IsInProgress | Should -BeFalse
    }
    It 'tightens the live window to a short TS baseline (no false in-progress on quick task sequences)' {
        $base = [pscustomobject]@{ Steps = @(); PerTaskSequence = @([pscustomobject]@{ TaskSequence = 'Quick'; SuccessfulRuns = 5; TotalMedianSeconds = 10; ExpectedStepCount = 3; Trusted = $true }) }
        # Last step 15 min ago: inside the 30-min window, but far past the 10s baseline (+120s floor) -> done.
        $old = New-Run -Computer PC1 -Ts 'Quick' -Status Success -Started '2026-01-01T11:44:50' -Steps @(
            @{ Step = 1; Action = 'A'; Status = 'Success'; Exit = 0; Dur = 5; Time = '2026-01-01T11:45:00' }
        )
        Add-TSLiveInfo -Runs @($old) -Baseline $base -AsOf $script:asof -LiveWindowMinutes 30 | Out-Null
        $old.IsInProgress | Should -BeFalse
        # Last step 30s ago: within the 120s floor -> genuinely in progress.
        $now = New-Run -Computer PC2 -Ts 'Quick' -Status Success -Started '2026-01-01T11:59:25' -Steps @(
            @{ Step = 1; Action = 'A'; Status = 'Success'; Exit = 0; Dur = 5; Time = '2026-01-01T11:59:30' }
        )
        Add-TSLiveInfo -Runs @($now) -Baseline $base -AsOf $script:asof -LiveWindowMinutes 30 | Out-Null
        $now.IsInProgress | Should -BeTrue
    }
}

Describe 'Get-TSNewFailure' {
    It 'reports newly failed runs and tracks all failed keys' {
        $runs = @(
            New-Run -Computer PC1 -Ts 'X' -Status Error   -Started '2026-01-01T10:00:00' -Steps @(@{ Step = 1; Action = 'A'; Status = 'Error';   Exit = 1; Dur = 1; Time = '2026-01-01T10:00:01' })
            New-Run -Computer PC2 -Ts 'X' -Status Success -Started '2026-01-01T10:00:00' -Steps @(@{ Step = 1; Action = 'A'; Status = 'Success'; Exit = 0; Dur = 1; Time = '2026-01-01T10:00:01' })
        )
        $first = Get-TSNewFailure -Current $runs
        $first.NewFailures.Count   | Should -Be 1
        $first.AllFailedKeys.Count | Should -Be 1

        $second = Get-TSNewFailure -PreviousFailedKeys $first.AllFailedKeys -Current $runs
        $second.NewFailures.Count | Should -Be 0
    }
}

Describe 'Get-TSExitCodeInfo' {
    It 'maps success and a known MSI code' {
        Get-TSExitCodeInfo -Code 0    | Should -Be 'Success'
        Get-TSExitCodeInfo -Code 1603 | Should -Match 'MSI 1603'
    }
    It 'gives friendly text for a known HRESULT' {
        Get-TSExitCodeInfo -Code -2147467259 | Should -Match '0x80004005'
    }
    It 'renders an unknown negative as a hex HRESULT' {
        Get-TSExitCodeInfo -Code -559038737 | Should -Match '0xDEADBEEF'
    }
    It 'returns empty for null/blank' {
        Get-TSExitCodeInfo -Code $null | Should -Be ''
        Get-TSExitCodeInfo -Code ''    | Should -Be ''
    }
}

Describe 'Get-TSStepPhase' {
    It 'classifies steps into deployment phases' {
        Get-TSStepPhase -ActionName 'Apply Operating System'                | Should -Be 'OS Deployment'
        Get-TSStepPhase -ActionName 'Partition Disk 0 - UEFI'               | Should -Be 'WinPE & Disk'
        Get-TSStepPhase -ActionName 'Install Application: Microsoft 365'    | Should -Be 'Applications'
        Get-TSStepPhase -ActionName 'Install Software Updates'              | Should -Be 'Software Updates'
        Get-TSStepPhase -ActionName 'Restart Computer'                      | Should -Be 'Finalize & Restart'
        Get-TSStepPhase -ActionName 'Something Bespoke'                     | Should -Be 'Other'
    }
    It 'prefers the group name over the action name' {
        # Action alone classifies as Configuration (Run Command Line); the group says Applications.
        Get-TSStepPhase -GroupName 'Install Applications' -ActionName 'Run Command Line' | Should -Be 'Applications'
    }
    It 'honors a custom phase map' {
        $map = @([pscustomobject]@{ Phase = 'Custom Capture'; Pattern = '(?i)capture' })
        Get-TSStepPhase -ActionName 'Capture the Reference Image' -PhaseMap $map | Should -Be 'Custom Capture'
        Get-TSStepPhase -ActionName 'Apply Operating System'      -PhaseMap $map | Should -Be 'Other'
    }
}

Describe 'Get-TSAnalytics - failure insight (A)' {
    BeforeAll {
        $runs = @(
            New-Run -Computer PC1 -Ts 'Bare Metal' -Status Success -Started '2026-01-01T10:00:00' -Steps @(
                @{ Step = 1; Action = 'Apply Operating System'; Status = 'Success'; Exit = 0; Dur = 50; Time = '2026-01-01T10:00:50' }
            )
            New-Run -Computer PC2 -Ts 'Bare Metal' -Status Error -Started '2026-01-02T10:00:00' -Steps @(
                @{ Step = 1; Action = 'Apply Operating System';     Status = 'Success'; Exit = 0;    Dur = 50; Time = '2026-01-02T10:00:50' }
                @{ Step = 2; Action = 'Install Application: M365';  Status = 'Error';   Exit = 1603; Dur = 5;  Time = '2026-01-02T10:01:00' }
            )
            New-Run -Computer PC3 -Ts 'Bare Metal' -Status Error -Started '2026-01-03T10:00:00' -Steps @(
                @{ Step = 1; Action = 'Partition Disk 0'; Status = 'Error'; Exit = -2147024784; Dur = 3; Time = '2026-01-03T10:00:03' }
            )
        )
        $script:a = Get-TSAnalytics -Runs $runs
    }
    It 'identifies the root-cause step (first failure) with phase and decoded exit code' {
        $rc = $script:a.RootCauseSteps
        ($rc | Where-Object ActionName -eq 'Install Application: M365').Phase           | Should -Be 'Applications'
        ($rc | Where-Object ActionName -eq 'Install Application: M365').PrimaryExitInfo | Should -Match 'MSI 1603'
        ($rc | Where-Object ActionName -eq 'Partition Disk 0').Phase                    | Should -Be 'WinPE & Disk'
    }
    It 'buckets failures by phase in canonical order' {
        $stages = $script:a.FailureStages
        ($stages | Where-Object Phase -eq 'Applications').FailCount  | Should -Be 1
        ($stages | Where-Object Phase -eq 'WinPE & Disk').FailCount  | Should -Be 1
        $names = @($stages | ForEach-Object Phase)
        [array]::IndexOf($names, 'WinPE & Disk') | Should -BeLessThan ([array]::IndexOf($names, 'Applications'))
    }
    It 'merges per-action reliability into a step-health table' {
        $sh = $script:a.StepHealth
        ($sh | Where-Object ActionName -eq 'Apply Operating System').Seen      | Should -Be 2
        ($sh | Where-Object ActionName -eq 'Apply Operating System').Failures  | Should -Be 0
        ($sh | Where-Object ActionName -eq 'Install Application: M365').FailRate | Should -Be 100
    }
}

Describe 'Get-TSAnalytics - duration & slowdowns (B)' {
    BeforeAll {
        $runs = @(
            New-Run -Computer PC1 -Ts 'Dur' -Status Success -Started '2026-01-01T10:00:00' -Steps @(@{ Step = 1; Action = 'Apply Operating System'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-01-01T10:01:40' })
            New-Run -Computer PC2 -Ts 'Dur' -Status Success -Started '2026-01-02T10:00:00' -Steps @(@{ Step = 1; Action = 'Apply Operating System'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-01-02T10:03:20' })
            New-Run -Computer PC3 -Ts 'Dur' -Status Success -Started '2026-01-03T10:00:00' -Steps @(@{ Step = 1; Action = 'Apply Operating System'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-01-03T10:05:00' })
            # Slow: 6 samples, 3 prior @10s then 3 recent @30s -> a real, large-enough-sample slowdown.
            New-Run -Computer S1 -Ts 'Slow' -Status Success -Started '2026-02-01T10:00:00' -Steps @(@{ Step = 1; Action = 'Apply OS'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-02-01T10:00:10' })
            New-Run -Computer S2 -Ts 'Slow' -Status Success -Started '2026-02-02T10:00:00' -Steps @(@{ Step = 1; Action = 'Apply OS'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-02-02T10:00:10' })
            New-Run -Computer S3 -Ts 'Slow' -Status Success -Started '2026-02-03T10:00:00' -Steps @(@{ Step = 1; Action = 'Apply OS'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-02-03T10:00:10' })
            New-Run -Computer S4 -Ts 'Slow' -Status Success -Started '2026-02-04T10:00:00' -Steps @(@{ Step = 1; Action = 'Apply OS'; Status = 'Success'; Exit = 0; Dur = 30; Time = '2026-02-04T10:00:30' })
            New-Run -Computer S5 -Ts 'Slow' -Status Success -Started '2026-02-05T10:00:00' -Steps @(@{ Step = 1; Action = 'Apply OS'; Status = 'Success'; Exit = 0; Dur = 30; Time = '2026-02-05T10:00:30' })
            New-Run -Computer S6 -Ts 'Slow' -Status Success -Started '2026-02-06T10:00:00' -Steps @(@{ Step = 1; Action = 'Apply OS'; Status = 'Success'; Exit = 0; Dur = 30; Time = '2026-02-06T10:00:30' })
            # Stable: 6 samples all @10s -> must NOT be flagged as a slowdown.
            New-Run -Computer T1 -Ts 'Stable' -Status Success -Started '2026-02-01T10:00:00' -Steps @(@{ Step = 1; Action = 'Steady'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-02-01T10:00:10' })
            New-Run -Computer T2 -Ts 'Stable' -Status Success -Started '2026-02-02T10:00:00' -Steps @(@{ Step = 1; Action = 'Steady'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-02-02T10:00:10' })
            New-Run -Computer T3 -Ts 'Stable' -Status Success -Started '2026-02-03T10:00:00' -Steps @(@{ Step = 1; Action = 'Steady'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-02-03T10:00:10' })
            New-Run -Computer T4 -Ts 'Stable' -Status Success -Started '2026-02-04T10:00:00' -Steps @(@{ Step = 1; Action = 'Steady'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-02-04T10:00:10' })
            New-Run -Computer T5 -Ts 'Stable' -Status Success -Started '2026-02-05T10:00:00' -Steps @(@{ Step = 1; Action = 'Steady'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-02-05T10:00:10' })
            New-Run -Computer T6 -Ts 'Stable' -Status Success -Started '2026-02-06T10:00:00' -Steps @(@{ Step = 1; Action = 'Steady'; Status = 'Success'; Exit = 0; Dur = 10; Time = '2026-02-06T10:00:10' })
        )
        $script:a = Get-TSAnalytics -Runs $runs
    }
    It 'computes a per-task-sequence run-duration distribution' {
        $d = $script:a.DurationByTaskSequence | Where-Object TaskSequence -eq 'Dur'
        $d.Runs          | Should -Be 3
        $d.MedianSeconds | Should -Be 200
        $d.MinSeconds    | Should -Be 100
        $d.MaxSeconds    | Should -Be 300
    }
    It 'flags a step whose recent median has regressed, with the sample sizes it used' {
        $sd = $script:a.Slowdowns | Where-Object { $_.TaskSequence -eq 'Slow' -and $_.ActionName -eq 'Apply OS' }
        $sd.PriorMedian   | Should -Be 10
        $sd.RecentMedian  | Should -Be 30
        $sd.PctSlower     | Should -Be 200
        $sd.PriorSamples  | Should -Be 3
        $sd.RecentSamples | Should -Be 3
    }
    It 'does not flag a stable step as a slowdown' {
        ($script:a.Slowdowns | Where-Object ActionName -eq 'Steady') | Should -BeNullOrEmpty
    }
}

Describe 'Get-TSAnalytics - correctness (P1)' {
    It 'attributes a failed run to its LAST error step, not an earlier continue-on-error one' {
        $runs = @(
            New-Run -Computer PC1 -Ts 'TS' -Status Error -Started '2026-01-01T10:00:00' -Steps @(
                @{ Step = 1; Action = 'Flaky Pre-step';  Status = 'Error';   Exit = 1;    Dur = 2; Time = '2026-01-01T10:00:02' }
                @{ Step = 2; Action = 'Apply OS';        Status = 'Success'; Exit = 0;    Dur = 5; Time = '2026-01-01T10:00:07' }
                @{ Step = 3; Action = 'Install Updates'; Status = 'Error';   Exit = 1603; Dur = 3; Time = '2026-01-01T10:00:10' }
            )
        )
        $a = Get-TSAnalytics -Runs $runs
        $a.RootCauseSteps.Count          | Should -Be 1
        $a.RootCauseSteps[0].ActionName  | Should -Be 'Install Updates'
    }
    It 'excludes in-progress runs from the success rate denominator' {
        $ok   = New-Run -Computer PC1 -Ts 'TS' -Status Success -Started '2026-01-01T10:00:00' -Steps @(@{ Step = 1; Action = 'A'; Status = 'Success'; Exit = 0; Dur = 1; Time = '2026-01-01T10:00:01' })
        $bad  = New-Run -Computer PC2 -Ts 'TS' -Status Error   -Started '2026-01-01T10:00:00' -Steps @(@{ Step = 1; Action = 'A'; Status = 'Error';   Exit = 1; Dur = 1; Time = '2026-01-01T10:00:01' })
        $live = New-Run -Computer PC3 -Ts 'TS' -Status Success -Started '2026-01-01T10:00:00' -Steps @(@{ Step = 1; Action = 'A'; Status = 'Success'; Exit = 0; Dur = 1; Time = '2026-01-01T10:00:01' })
        $live | Add-Member -NotePropertyName IsInProgress -NotePropertyValue $true -Force
        $a = Get-TSAnalytics -Runs @($ok, $bad, $live)
        $a.TotalRuns          | Should -Be 3
        $a.Completed          | Should -Be 2
        $a.InProgress         | Should -Be 1
        $a.Failed             | Should -Be 1
        $a.OverallSuccessRate | Should -Be 50   # 1 of 2 completed, not 2 of 3
    }
    It 'buckets superseded re-image attempts out of the rates and counts them as churn' {
        $mkStep = { param($t) @(@{ Step = 1; Action = 'A'; Status = 'Success'; Exit = 0; Dur = 1; Time = $t }) }
        $sup1  = New-Run -Computer PC1 -Ts 'TS' -Status Success -Started '2026-01-01T10:00:00' -Steps (& $mkStep '2026-01-01T10:00:01')
        $sup2  = New-Run -Computer PC1 -Ts 'TS' -Status Success -Started '2026-01-01T10:30:00' -Steps (& $mkStep '2026-01-01T10:30:01')
        $final = New-Run -Computer PC1 -Ts 'TS' -Status Success -Started '2026-01-01T11:00:00' -Steps (& $mkStep '2026-01-01T11:00:01')
        $sup1 | Add-Member -NotePropertyName Superseded -NotePropertyValue $true -Force
        $sup2 | Add-Member -NotePropertyName Superseded -NotePropertyValue $true -Force
        $standalone = New-Run -Computer PC2 -Ts 'TS' -Status Success -Started '2026-01-01T10:00:00' -Steps (& $mkStep '2026-01-01T10:00:01')
        $a = Get-TSAnalytics -Runs @($sup1, $sup2, $final, $standalone)
        $a.TotalRuns              | Should -Be 4
        $a.Superseded             | Should -Be 2
        $a.Completed              | Should -Be 2     # final + standalone; the 2 abandoned attempts are excluded
        $a.OverallSuccessRate     | Should -Be 100
        $a.RetrySummary.RetryRuns | Should -Be 2     # sup1->sup2 and sup2->final are both churn
        ($a.PerTaskSequence | Where-Object TaskSequence -eq 'TS').Total | Should -Be 2
    }
}

Describe 'Get-TSAnalytics - configurable phase classification (P2)' {
    It 'classifies failure phases with a custom phase map, surfacing the custom phase' {
        $runs = @(
            New-Run -Computer PC1 -Ts 'TS' -Status Error -Started '2026-01-01T10:00:00' -Steps @(
                @{ Step = 1; Action = 'Capture the Reference Image'; Status = 'Error'; Exit = 1; Dur = 1; Time = '2026-01-01T10:00:01' }
            )
        )
        $map = @([pscustomobject]@{ Phase = 'Capture'; Pattern = '(?i)capture' })
        $a = Get-TSAnalytics -Runs $runs -PhaseMap $map
        $a.RootCauseSteps[0].Phase | Should -Be 'Capture'
        ($a.FailureStages | Where-Object Phase -eq 'Capture').FailCount | Should -Be 1
    }
}

Describe 'Get-TSAnalytics - reliability & fleet (C)' {
    BeforeAll {
        $okStep  = @(@{ Step = 1; Action = 'A'; Status = 'Success'; Exit = 0; Dur = 1; Time = '2026-03-01T10:00:01' })
        $badStep = @(@{ Step = 1; Action = 'A'; Status = 'Error';   Exit = 1; Dur = 1; Time = '2026-03-01T10:00:01' })
        $runs = @(
            # Upgrade: 6 runs (3 clean prior, 3 failed recent) -> a genuine, large-enough-sample regression.
            New-Run -Computer PC20 -Ts 'Upgrade' -Status Success -Started '2026-03-01T10:00:00' -Steps $okStep
            New-Run -Computer PC21 -Ts 'Upgrade' -Status Success -Started '2026-03-02T10:00:00' -Steps $okStep
            New-Run -Computer PC22 -Ts 'Upgrade' -Status Success -Started '2026-03-03T10:00:00' -Steps $okStep
            New-Run -Computer PC23 -Ts 'Upgrade' -Status Error   -Started '2026-03-04T10:00:00' -Steps $badStep
            New-Run -Computer PC24 -Ts 'Upgrade' -Status Error   -Started '2026-03-05T10:00:00' -Steps $badStep
            New-Run -Computer PC25 -Ts 'Upgrade' -Status Error   -Started '2026-03-06T10:00:00' -Steps $badStep
            # Mini: only 4 runs -> below the regression min-sample guard, must NOT be flagged.
            New-Run -Computer PC40 -Ts 'Mini' -Status Success -Started '2026-03-01T10:00:00' -Steps $okStep
            New-Run -Computer PC41 -Ts 'Mini' -Status Success -Started '2026-03-02T10:00:00' -Steps $okStep
            New-Run -Computer PC42 -Ts 'Mini' -Status Error   -Started '2026-03-03T10:00:00' -Steps $badStep
            New-Run -Computer PC43 -Ts 'Mini' -Status Error   -Started '2026-03-04T10:00:00' -Steps $badStep
            # PC30 fails twice -> a retry-after-failure + a repeat offender.
            New-Run -Computer PC30 -Ts 'Bare Metal' -Status Error -Started '2026-03-05T10:00:00' -Steps $badStep
            New-Run -Computer PC30 -Ts 'Bare Metal' -Status Error -Started '2026-03-06T10:00:00' -Steps $badStep
            # PC50 re-imaged twice SUCCESSFULLY -> not churn, must NOT count as a retry.
            New-Run -Computer PC50 -Ts 'Bare Metal' -Status Success -Started '2026-03-05T10:00:00' -Steps $okStep
            New-Run -Computer PC50 -Ts 'Bare Metal' -Status Success -Started '2026-03-06T10:00:00' -Steps $okStep
        )
        $script:a = Get-TSAnalytics -Runs $runs
    }
    It 'detects a recent success-rate regression per task sequence' {
        ($script:a.Regressions | Where-Object TaskSequence -eq 'Upgrade').DeltaPct   | Should -Be 100
        ($script:a.Regressions | Where-Object TaskSequence -eq 'Upgrade').PriorRuns  | Should -Be 3
        ($script:a.Regressions | Where-Object TaskSequence -eq 'Upgrade').RecentRuns | Should -Be 3
    }
    It 'does not flag a regression below the minimum sample size' {
        ($script:a.Regressions | Where-Object TaskSequence -eq 'Mini') | Should -BeNullOrEmpty
    }
    It 'counts only re-runs that follow a failed attempt as churn' {
        $script:a.RetrySummary.RetryRuns | Should -Be 1
        ($script:a.RetrySummary.Computers | Where-Object Computer -eq 'PC30').FailedAttempts | Should -Be 2
        ($script:a.RetrySummary.Computers | Where-Object Computer -eq 'PC50') | Should -BeNullOrEmpty
    }
    It 'lists computers that fail repeatedly' {
        ($script:a.RepeatOffenders | Where-Object Computer -eq 'PC30').Failures | Should -Be 2
    }
}
