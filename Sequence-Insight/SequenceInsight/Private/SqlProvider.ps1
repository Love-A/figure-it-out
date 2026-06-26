# SqlProvider.ps1 - direct (read-only) SQL provider for task-sequence execution history.
# vSMS_TaskSequenceExecutionStatus is a SQL view with no equivalent WMI class, so the deep
# step-level history is sourced here. Queries are parameterised; least privilege is db_datareader.

function Get-TSSqlConnectionString {
    <#
    .SYNOPSIS
        Builds a SQL Server connection string from the config 'sql' block. Integrated auth only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Database,
        [bool]$Encrypt = $true,
        [bool]$TrustServerCertificate = $false,
        [int]$ConnectTimeout = 30
    )
    $parts = @(
        "Server=$Server"
        "Database=$Database"
        'Integrated Security=SSPI'
        "Encrypt=$($Encrypt.ToString().ToLower())"
        "TrustServerCertificate=$($TrustServerCertificate.ToString().ToLower())"
        "Connect Timeout=$ConnectTimeout"
        'Application Name=Sequence Insight'
    )
    return ($parts -join ';')
}

# The core query template. Parameters: @StartTime (UTC), @PackageID (NULL=all), @Computer (NULL=all,
# LIKE), @MaxRows. LEFT JOINs so a missing package/name match never drops rows. The __OUTPUTCOL__
# token is the (large) ActionOutput column - excluded for list views (perf) and loaded on demand.
$script:TSExecutionQueryTemplate = @'
SELECT TOP (@MaxRows)
       tse.ExecutionTime,
       tse.ResourceID,
       sys.Name0            AS Computer,
       COALESCE(tsp.Name, tse.PackageID) AS TaskSequence,
       tse.PackageID,
       tse.AdvertisementID,
       tse.Step,
       tse.ActionName,
       tse.GroupName,
       tse.LastStatusMsgID,
       tse.LastStatusMsgName,
       tse.ExitCode,
       __OUTPUTCOL__
FROM   vSMS_TaskSequenceExecutionStatus tse
       LEFT JOIN v_R_System sys ON tse.ResourceID = sys.ResourceID
       LEFT JOIN v_TaskSequencePackage tsp ON tse.PackageID = tsp.PackageID
WHERE  tse.ExecutionTime >= @StartTime
       AND (@PackageID IS NULL OR tse.PackageID = @PackageID)
       AND (@Computer IS NULL OR sys.Name0 LIKE @Computer)
ORDER BY tse.ExecutionTime DESC, tse.Step DESC
'@

function Get-TSExecutionQueryText {
    <#
    .SYNOPSIS
        Returns the execution query with ActionOutput either included (full) or stubbed (list/perf).
    #>
    [CmdletBinding()]
    param([switch]$IncludeOutput)
    $outCol = if ($IncludeOutput) { 'tse.ActionOutput' } else { "CAST(NULL AS nvarchar(1)) AS ActionOutput" }
    return $script:TSExecutionQueryTemplate -replace '__OUTPUTCOL__', $outCol
}

function Invoke-TSSqlQuery {
    <#
    .SYNOPSIS
        Runs the parameterised execution-status query and returns raw rows as PSCustomObjects.

    .DESCRIPTION
        Uses System.Data.SqlClient (built into Windows PowerShell 5.1; loaded on demand under
        PowerShell 7). Throws a clear, actionable error if the SqlClient type cannot be loaded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConnectionString,
        [Parameter(Mandatory)][datetime]$StartTimeUtc,
        [string]$PackageID,
        [string]$ComputerLike,
        [int]$MaxRows = 5000,
        [switch]$IncludeOutput
    )

    $null = Confirm-TSSqlClientAvailable

    $conn = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = Get-TSExecutionQueryText -IncludeOutput:$IncludeOutput
        $cmd.CommandTimeout = 60

        [void]$cmd.Parameters.AddWithValue('@MaxRows', [int]$MaxRows)
        $p = $cmd.Parameters.Add('@StartTime', [System.Data.SqlDbType]::DateTime)
        $p.Value = $StartTimeUtc
        [void]$cmd.Parameters.AddWithValue('@PackageID', $(if ([string]::IsNullOrWhiteSpace($PackageID)) { [DBNull]::Value } else { $PackageID }))
        [void]$cmd.Parameters.AddWithValue('@Computer', $(if ([string]::IsNullOrWhiteSpace($ComputerLike)) { [DBNull]::Value } else { $ComputerLike }))

        $reader = $cmd.ExecuteReader()
        try {
            $cols = @(for ($i = 0; $i -lt $reader.FieldCount; $i++) { $reader.GetName($i) })
            while ($reader.Read()) {
                $o = [ordered]@{}
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $val = $reader.GetValue($i)
                    if ($val -is [DBNull]) { $val = $null }
                    $o[$cols[$i]] = $val
                }
                $rows.Add([pscustomobject]$o)
            }
        } finally {
            $reader.Dispose()
        }
    } finally {
        $conn.Dispose()
    }
    return $rows.ToArray()
}

function Get-TSStepOutputFromSql {
    <#
    .SYNOPSIS
        Loads a single step's ActionOutput on demand (keyed by ResourceID + Step + a small time window),
        so list views can skip the large output column and fetch it only when a step is opened.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConnectionString,
        [Parameter(Mandatory)][int]$ResourceID,
        [Parameter(Mandatory)][int]$Step,
        [Parameter(Mandatory)][datetime]$ExecutionTimeUtc
    )
    $null = Confirm-TSSqlClientAvailable
    $conn = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @'
SELECT TOP (1) tse.ActionOutput
FROM   vSMS_TaskSequenceExecutionStatus tse
WHERE  tse.ResourceID = @ResourceID AND tse.Step = @Step
       AND tse.ExecutionTime >= @T0 AND tse.ExecutionTime < @T1
'@
        $cmd.CommandTimeout = 30
        [void]$cmd.Parameters.AddWithValue('@ResourceID', [int]$ResourceID)
        [void]$cmd.Parameters.AddWithValue('@Step', [int]$Step)
        $p0 = $cmd.Parameters.Add('@T0', [System.Data.SqlDbType]::DateTime); $p0.Value = $ExecutionTimeUtc.AddSeconds(-1)
        $p1 = $cmd.Parameters.Add('@T1', [System.Data.SqlDbType]::DateTime); $p1.Value = $ExecutionTimeUtc.AddSeconds(1)
        $val = $cmd.ExecuteScalar()
        if ($null -eq $val -or $val -is [DBNull]) { return '' }
        return [string]$val
    } finally {
        $conn.Dispose()
    }
}

function Confirm-TSSqlClientAvailable {
    <#
    .SYNOPSIS
        Ensures System.Data.SqlClient.SqlConnection can be instantiated; throws guidance if not.
    #>
    [CmdletBinding()]
    param()
    if ('System.Data.SqlClient.SqlConnection' -as [type]) { return $true }
    try { Add-Type -AssemblyName System.Data -ErrorAction Stop } catch { Write-Verbose "System.Data load attempt: $_" }
    if ('System.Data.SqlClient.SqlConnection' -as [type]) { return $true }
    throw ('System.Data.SqlClient is not available in this PowerShell host. Run the SQL path on ' +
        'Windows PowerShell 5.1, or install the SqlServer module / System.Data.SqlClient package for PowerShell 7.')
}

function Get-TSPackageListFromSql {
    <#
    .SYNOPSIS
        Fallback list of DEPLOYED task sequences when the AdminService is unavailable.

    .DESCRIPTION
        Sourced from v_DeploymentSummary (FeatureType 7 = Task Sequence) so undeployed task sequences
        are excluded, matching the AdminService path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConnectionString)

    $null = Confirm-TSSqlClientAvailable
    $conn = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    $list = New-Object System.Collections.Generic.List[object]
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        # Constant query, no user input -> no injection surface. FeatureType 7 = Task Sequence.
        $cmd.CommandText = 'SELECT DISTINCT PackageID, SoftwareName AS Name FROM v_DeploymentSummary WHERE FeatureType = 7 ORDER BY Name'
        $cmd.CommandTimeout = 60
        $reader = $cmd.ExecuteReader()
        try {
            while ($reader.Read()) {
                $list.Add([pscustomobject]@{
                    PackageID = [string]$reader['PackageID']
                    Name      = [string]$reader['Name']
                })
            }
        } finally { $reader.Dispose() }
    } finally { $conn.Dispose() }
    return $list.ToArray()
}

function ConvertTo-TSExecutionRow {
    <#
    .SYNOPSIS
        Normalises raw SQL rows into the canonical execution-row shape used by the UI and report.

    .DESCRIPTION
        Derives Status from ExitCode, marks ExecutionTime as UTC, and computes a per-step duration
        within each (Computer + TaskSequence) run by diffing consecutive step timestamps. Pure
        function over input objects so it is fully unit-testable without a database.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][AllowEmptyCollection()][object[]]$Rows
    )
    begin { $all = New-Object System.Collections.Generic.List[object] }
    process { foreach ($r in $Rows) { if ($null -ne $r) { $all.Add($r) } } }
    end {
        $normalized = foreach ($r in $all) {
            $exit = $null
            if ($null -ne $r.ExitCode -and "$($r.ExitCode)" -ne '') { $exit = [int]$r.ExitCode }

            $status = 'Unknown'
            if ($null -ne $exit) { $status = if ($exit -eq 0) { 'Success' } else { 'Error' } }

            $time = $null
            if ($r.ExecutionTime) {
                $dt = [datetime]$r.ExecutionTime
                $time = [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)
            }

            [pscustomobject]@{
                Computer          = [string]$r.Computer
                ResourceID        = $r.ResourceID
                TaskSequence      = [string]$r.TaskSequence
                PackageID         = [string]$r.PackageID
                AdvertisementID   = [string]$r.AdvertisementID
                Step              = $(if ($null -ne $r.Step) { [int]$r.Step } else { $null })
                GroupName         = [string]$r.GroupName
                ActionName        = [string]$r.ActionName
                LastStatusMsgID   = $r.LastStatusMsgID
                LastStatusMsgName = [string]$r.LastStatusMsgName
                ExitCode          = $exit
                ActionOutput      = [string]$r.ActionOutput
                ExecutionTimeUtc  = $time
                Status            = $status
                DurationSeconds   = $null
            }
        }

        # Per-step duration: within each run, ordered ascending by time, diff to the next step.
        $groups = $normalized | Group-Object Computer, TaskSequence
        foreach ($g in $groups) {
            $ordered = @($g.Group | Where-Object { $_.ExecutionTimeUtc } | Sort-Object ExecutionTimeUtc)
            for ($i = 0; $i -lt $ordered.Count - 1; $i++) {
                $delta = ($ordered[$i + 1].ExecutionTimeUtc - $ordered[$i].ExecutionTimeUtc).TotalSeconds
                if ($delta -ge 0) { $ordered[$i].DurationSeconds = [math]::Round($delta, 0) }
            }
        }

        return $normalized
    }
}
