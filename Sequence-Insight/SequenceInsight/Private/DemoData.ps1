# DemoData.ps1 - synthetic data for -DevMode so the UI and report can run with no live ConfigMgr.
# Mirrors the canonical row shape produced by ConvertTo-TSExecutionRow.

function Get-TSDemoPackageList {
    [CmdletBinding()]
    param()
    @(
        [pscustomobject]@{ PackageID = 'DEMO0001'; Name = 'Windows 11 - Bare Metal' }
        [pscustomobject]@{ PackageID = 'DEMO0002'; Name = 'Windows 11 - In-Place Upgrade' }
        [pscustomobject]@{ PackageID = 'DEMO0003'; Name = 'Server 2022 - Build & Capture' }
    )
}

function Get-TSDemoExecution {
    <#
    .SYNOPSIS
        Returns synthetic normalized execution rows for several runs, including a failed run.
    #>
    [CmdletBinding()]
    param()

    $steps = @(
        'Restart in Windows PE', 'Partition Disk 0 - UEFI', 'Apply Operating System',
        'Apply Windows Settings', 'Apply Network Settings', 'Setup Windows and ConfigMgr',
        'Install Application: Microsoft 365 Apps', 'Install Application: Company Portal',
        'Install Software Updates', 'Set Computer Name', 'Restart Computer'
    )

    # Historical runs are spread across the past few days (so they are NOT flagged in-progress and the
    # analytics trend spans multiple days). The single in-progress run is added separately below.
    $runs = @(
        # --- Windows 11 Bare Metal (DEMO0001): a busy, mostly-healthy fleet ---
        @{ Computer = 'WS-AB12CD'; Resource = 16777301; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = -1; WarnAt = 7; StartMin = 2880 }   # finished with a non-fatal step error (Warnings)
        @{ Computer = 'WS-EF34GH'; Resource = 16777302; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = 8;  FailCode = 1603;        StartMin = 7200 }   # fatal: app install (MSI 1603)
        @{ Computer = 'WS-GH56IJ'; Resource = 16777305; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = -1; StartMin = 4320 }
        @{ Computer = 'WS-KL78MN'; Resource = 16777306; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = -1; StartMin = 5760 }
        @{ Computer = 'WS-PR21AA'; Resource = 16777312; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = -1; StartMin = 600 }
        @{ Computer = 'WS-PR22BB'; Resource = 16777313; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = -1; StartMin = 1200 }
        @{ Computer = 'WS-PR23CC'; Resource = 16777314; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = -1; StartMin = 3300 }
        @{ Computer = 'WS-PR24DD'; Resource = 16777315; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = -1; StartMin = 9000 }
        @{ Computer = 'DT-QR90ST'; Resource = 16777304; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = -1; StartMin = 36000 }
        # Repeat offender: the same device fails twice at the disk step (days apart) -> repeat offender + churn.
        @{ Computer = 'WS-BAD001'; Resource = 16777307; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = 2; FailCode = -2147024784; StartMin = 1440 }   # disk full (0x80070070)
        @{ Computer = 'WS-BAD001'; Resource = 16777307; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = 2; FailCode = -2147024784; StartMin = 8640 }
        # Retry after a failure: fails at the disk step, retried ~1h later and succeeds -> churn (not superseded).
        @{ Computer = 'WS-RTY050'; Resource = 16777316; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = 2; FailCode = -2147024784; StartMin = 420 }
        @{ Computer = 'WS-RTY050'; Resource = 16777316; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = -1; StartMin = 360 }
        # Re-imaged twice ~1h apart, both "completed" -> the first attempt was abandoned (Superseded).
        @{ Computer = 'WS-RDO060'; Resource = 16777317; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = -1; StartMin = 300 }
        @{ Computer = 'WS-RDO060'; Resource = 16777317; Pkg = 'DEMO0001'; TS = 'Windows 11 - Bare Metal'; FailAt = -1; StartMin = 240 }

        # --- Windows 11 In-Place Upgrade (DEMO0002): a regression - older runs ok, recent runs failing ---
        @{ Computer = 'LT-IJ56KL'; Resource = 16777303; Pkg = 'DEMO0002'; TS = 'Windows 11 - In-Place Upgrade'; FailAt = -1; StartMin = 21600 }  # prior, ok
        @{ Computer = 'LT-OP12QR'; Resource = 16777308; Pkg = 'DEMO0002'; TS = 'Windows 11 - In-Place Upgrade'; FailAt = -1; StartMin = 20160 }  # prior, ok
        @{ Computer = 'LT-RS34EF'; Resource = 16777318; Pkg = 'DEMO0002'; TS = 'Windows 11 - In-Place Upgrade'; FailAt = -1; StartMin = 18000 }  # prior, ok
        @{ Computer = 'LT-NEW001'; Resource = 16777309; Pkg = 'DEMO0002'; TS = 'Windows 11 - In-Place Upgrade'; FailAt = 9; FailCode = -2145124329; StartMin = 4320 }   # recent: update not applicable (0x80240017)
        @{ Computer = 'LT-NEW002'; Resource = 16777311; Pkg = 'DEMO0002'; TS = 'Windows 11 - In-Place Upgrade'; FailAt = 9; FailCode = -2145124329; StartMin = 2880 }
        @{ Computer = 'LT-NEW003'; Resource = 16777319; Pkg = 'DEMO0002'; TS = 'Windows 11 - In-Place Upgrade'; FailAt = 9; FailCode = -2145124329; StartMin = 1440 }

        # --- Server 2022 Build & Capture (DEMO0003): a small, healthy set ---
        @{ Computer = 'SV-BC0101'; Resource = 16777320; Pkg = 'DEMO0003'; TS = 'Server 2022 - Build & Capture'; FailAt = -1; StartMin = 10080 }
        @{ Computer = 'SV-BC0102'; Resource = 16777321; Pkg = 'DEMO0003'; TS = 'Server 2022 - Build & Capture'; FailAt = -1; StartMin = 12000 }
        @{ Computer = 'SV-BC0103'; Resource = 16777322; Pkg = 'DEMO0003'; TS = 'Server 2022 - Build & Capture'; FailAt = -1; StartMin = 720 }
    )

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($run in $runs) {
        $t = (Get-Date).ToUniversalTime().AddMinutes(-1 * $run.StartMin)
        $stepNo = 1
        foreach ($s in $steps) {
            $t = $t.AddSeconds((Get-Random -Minimum 20 -Maximum 240))
            $failed = ($run.FailAt -ge 0 -and $stepNo -ge $run.FailAt)
            # WarnAt is a non-fatal (continue-on-error) step: it errors but the run keeps going.
            $warn = ($run.WarnAt -and $stepNo -eq $run.WarnAt)
            $exit = if ($failed -and $stepNo -eq $run.FailAt) { if ($run.ContainsKey('FailCode')) { $run.FailCode } else { 16389 } }
                    elseif ($failed) { $null }
                    elseif ($warn) { 1618 }
                    else { 0 }
            if ($failed -and $stepNo -gt $run.FailAt) { break }  # fatal failure stops the run

            $status = if ($null -eq $exit) { 'Unknown' } elseif ($exit -eq 0) { 'Success' } else { 'Error' }
            $isErr = ($status -eq 'Error')
            $rows.Add([pscustomobject]@{
                Computer          = $run.Computer
                ResourceID        = $run.Resource
                TaskSequence      = $run.TS
                PackageID         = $run.Pkg
                AdvertisementID   = ($run.Pkg.Substring(0,4) + '20001')
                Step              = $stepNo
                GroupName         = ''
                ActionName        = $s
                LastStatusMsgID   = if ($isErr) { 11171 } else { 11143 }
                LastStatusMsgName = if ($isErr) { 'The task sequence execution engine failed executing an action' } else { 'The task sequence execution engine successfully completed an action' }
                ExitCode          = $exit
                ActionOutput      = if ($isErr) { "Action failed with exit code $exit. See smsts.log for details." } else { '' }
                ExecutionTimeUtc  = [datetime]::SpecifyKind($t, [System.DateTimeKind]::Utc)
                Status            = $status
                DurationSeconds   = $null
            })
            $stepNo++
        }

        # In CM a late action can be reported as Step 0; make the demo exercise timestamp-first sort.
        if ($run.FailAt -lt 0) {
            $t = $t.AddSeconds((Get-Random -Minimum 5 -Maximum 30))
            $rows.Add([pscustomobject]@{
                Computer          = $run.Computer
                ResourceID        = $run.Resource
                TaskSequence      = $run.TS
                PackageID         = $run.Pkg
                AdvertisementID   = ($run.Pkg.Substring(0,4) + '20001')
                Step              = 0
                GroupName         = ''
                ActionName        = 'Release Task Sequence Servicing Lock'
                LastStatusMsgID   = 11143
                LastStatusMsgName = 'The task sequence execution engine successfully completed an action'
                ExitCode          = 0
                ActionOutput      = ''
                ExecutionTimeUtc  = [datetime]::SpecifyKind($t, [System.DateTimeKind]::Utc)
                Status            = 'Success'
                DurationSeconds   = $null
            })
        }
    }

    # An in-progress run: last step ~2 min ago, no terminal action, no error -> Add-TSLiveInfo flags it
    # live and (with the successful Bare Metal baseline above) estimates a percent complete.
    $liveBase = (Get-Date).ToUniversalTime().AddMinutes(-10)
    $lt = $liveBase
    $ln = 1
    foreach ($s in ($steps | Select-Object -First 5)) {
        $rows.Add([pscustomobject]@{
            Computer          = 'WS-LIVE01'
            ResourceID        = 16777310
            TaskSequence      = 'Windows 11 - Bare Metal'
            PackageID         = 'DEMO0001'
            AdvertisementID   = 'DEMO20001'
            Step              = $ln
            GroupName         = ''
            ActionName        = $s
            LastStatusMsgID   = 11143
            LastStatusMsgName = 'The task sequence execution engine successfully completed an action'
            ExitCode          = 0
            ActionOutput      = ''
            ExecutionTimeUtc  = [datetime]::SpecifyKind($lt, [System.DateTimeKind]::Utc)
            Status            = 'Success'
            DurationSeconds   = $null
        })
        $lt = $lt.AddMinutes(2)
        $ln++
    }

    # Reuse the real duration logic so demo data matches production exactly.
    $arr = $rows.ToArray()
    $groups = $arr | Group-Object Computer, TaskSequence
    foreach ($g in $groups) {
        $ordered = @($g.Group | Sort-Object ExecutionTimeUtc)
        for ($i = 0; $i -lt $ordered.Count - 1; $i++) {
            $delta = ($ordered[$i + 1].ExecutionTimeUtc - $ordered[$i].ExecutionTimeUtc).TotalSeconds
            if ($delta -ge 0) { $ordered[$i].DurationSeconds = [math]::Round($delta, 0) }
        }
    }
    return $arr
}
