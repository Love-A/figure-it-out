<#
.SYNOPSIS
    Retrieves Microsoft 365 license status and sends Teams notification via webhook.

.DESCRIPTION
    Categorizes license status, exports HTML/CSV reports, caches previous state to JSON,
    and sends Teams notification only on changes. Includes -TestMode for simulating changes.

.PARAMETER AppId
    Required. Client ID of the app registration used for certificate-based
    (client credentials) authentication to Microsoft Graph.

.PARAMETER TenantId
    Required. Directory (tenant) ID to authenticate against.

.PARAMETER Thumbprint
    Required. Thumbprint of the authentication certificate. Must be readable by the
    account running the script - for a SYSTEM scheduled task that means Cert:\LocalMachine\My.

.PARAMETER htmlPath
    Required. Full path (local or UNC) where the HTML report is published, e.g.
    "\\server\share\Reports\AzureLicenseSummary.html". The report is always written to a
    local copy under .\AzureLicenseAudit\ first and then published to this path; if
    publishing fails the run continues, the failure is logged as ERROR, and the Teams
    notification is marked with a stale-report warning.

.PARAMETER WebhookUrl
    Optional. Power Automate Workflow endpoint URL for Teams notifications.

.PARAMETER NotifySku
    Optional. Array of SKU names to filter notifications (e.g. "SPE_E5", "VISIOCLIENT").

.PARAMETER TestMode
    Optional switch. If set, sends a simulated test notification and exits without
    running diff detection or updating the cache.

.PARAMETER AuditDisabledUsers
    Optional switch. Audits disabled accounts that still have licenses assigned
    (reclaimable licenses). Adds a section to the HTML report, exports
    DisabledLicensedUsers.csv and includes a summary line in the Teams notification.
    Requires the app registration to have User.Read.All (application) permission.

.PARAMETER AuditInactiveUsers
    Optional switch. Audits enabled accounts with licenses that have not signed in
    successfully for -InactiveDays days. Adds a section to the HTML report, exports
    InactiveLicensedUsers.csv and includes a summary line in the Teams notification.
    Requires User.Read.All and AuditLog.Read.All (application) permissions.

.PARAMETER InactiveDays
    Optional. Days without a successful sign-in before a licensed account is
    considered inactive. Default: 90.

.PARAMETER Language
    Optional. Language for the HTML report labels: 'sv' (default) or 'en'.
    Run twice with different -htmlPath/-Language to produce both. Does not
    affect the Teams notification or log (those stay English).

.PARAMETER TrendRetentionDays
    Optional. How many days of history to keep in LicenseTrend.csv. Rows older than this
    are pruned on each run so the file cannot grow without bound. Default: 400 (keeps a
    full year plus margin). Set to 0 to disable pruning.

.PARAMETER MaxLogSizeMB
    Optional. When AzureLicenseAudit.log exceeds this size it is archived as
    AzureLicenseAudit.<yyyyMMdd-HHmmss>.log and a fresh log is started. Default: 5.
    Set to 0 to disable rotation.

.PARAMETER LogHistoryCount
    Optional. Number of archived log files to keep. Older archives are deleted. Default: 5.

.PARAMETER UnlimitedSeatThreshold
    Optional. SKUs with at least this many purchased seats are treated as free/unlimited
    (Microsoft Stream, Power BI Standard, viral SKUs and similar). They are still shown in
    the report but never raise an alert. Default: 10000.

.PARAMETER MinSeatsForAlert
    Optional. SKUs with fewer purchased seats than this are treated as trials and never
    raise an alert - a fully consumed 1-seat evaluation SKU is not an incident.
    Default: 5.

.PARAMETER HeartbeatDays
    Optional. If no Teams notification has been sent for this many days, a heartbeat digest
    is sent instead: current watch list, upcoming depletions, subscription health. Proves
    the scheduled task is still alive. Default: 7. Set to 0 to disable.

.PARAMETER ForecastMinPoints
    Optional. Minimum number of trend samples required before a depletion forecast is
    produced for a SKU. Below this the report states that history is insufficient rather
    than extrapolating from noise. Default: 5.

.PARAMETER ForecastMinSpanDays
    Optional. Minimum number of days the trend samples must span before a forecast is
    produced. Default: 7.

.PARAMETER ForecastWarnDays
    Optional. SKUs forecast to run out within this many days are highlighted in the log and
    in the heartbeat digest, including SKUs that are still healthy today. Default: 60.

.PARAMETER ForecastWindowDays
    Optional. How far back in LicenseTrend.csv the forecast looks. Default: 30.

.PARAMETER WebhookRetryCount
    Optional. Number of attempts when posting to the webhook, with increasing backoff.
    Default: 3. The state cache is only advanced once a post succeeds.

.EXAMPLE
    Get-AzureLicenseStatus -WebhookUrl "https://..." -NotifySku "SPE_E5","VISIOCLIENT" -AppId "your-app-id" -TenantId "your-tenant-id" -Thumbprint "your-cert-thumbprint" -htmlPath "\\UNCPATH\Directory\licensereport.html"

.EXAMPLE
    Simulated test run
    Get-AzureLicenseStatus -WebhookUrl "https://..." -NotifySku "SPE_E5" -AppId "your-app-id" -TenantId "your-tenant-id" -Thumbprint "your-cert-thumbprint" -TestMode

.NOTES
    Author     : Love A
    Updated    : 2026-09-09

.VERSION
    2025-06-10 - 1.0 - Initial version  
    2025-06-10 - 1.1 - Added HTML and Teams export  
    2025-06-10 - 1.2 - Azure AD App authentication  
    2025-06-18 - 1.3 - JSON-caching, diff detection, Teams diff reporting  
    2025-06-18 - 1.4 - Added TestMode simulation support
    2026-06-12 - 1.5 - Bug fixes (diff text, logging, single-item arrays), mandatory params,
                       stricter error handling, TestMode no longer runs real diff,
                       new -AuditDisabledUsers feature for reclaimable licenses
    2026-06-12 - 1.6 - Trend logging (LicenseTrend.csv), depletion forecast in Teams
                       notification, new -AuditInactiveUsers/-InactiveDays feature
    2026-06-15 - 1.7 - Redesigned HTML report (cards, styled tables, charset), added
                       per-license aggregation of disabled/inactive holdings
    2026-06-15 - 1.8 - Bilingual HTML report via -Language (sv/en)
    2026-09-09 - 1.9 - Reliability release. The state cache is now only written once the
                       Teams notification has actually been delivered, so a failed webhook
                       no longer swallows the change permanently. The HTML report is
                       written locally and published atomically, and a publishing failure
                       is reported instead of silently logged as success. The cache now
                       tracks every monitored SKU (schema 2) so recovery is reported as
                       recovery instead of "removed SKU", and purchases/cancellations are
                       detected. Write-Log no longer pollutes the pipeline (this was
                       injecting phantom rows into the Teams change table). Log rotation
                       and trend-history retention added. Comment-based help completed.
    2026-09-14 - 1.9.5 - Signal quality. Alert eligibility is now separated from license
                       status: unlimited, unused and trial SKUs are still classified and
                       reported, but no longer raise alerts, which on a typical tenant removes
                       most of the alerting noise. The depletion
                       forecast uses least-squares regression over the window, requires a
                       minimum number of samples and span, runs on every SKU rather than
                       only the warned ones, and states insufficient history instead of
                       guessing. Added a heartbeat digest so silence no longer means
                       "nothing changed" and "the task died" at the same time, subscription
                       health (capabilityStatus / units in grace period), an optional
                       .webhook file, and a created-date guard that stops new accounts from
                       being reported as inactive. SKU display names moved out to
                       skunames.json - a per-tenant inventory is data, not code -
                       loaded through a reusable Import-DataFile
                       helper that degrades instead of failing, and SKUs missing from the map
                       are now logged instead of silently rendering as part numbers.
                       Cache schema is unchanged (still 2).
#>

function Get-AzureLicenseStatus {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Console echo for interactive and scheduled runs. Write-Log must not emit to the success stream - doing so contaminated collections built with "$x = foreach {...}".')]
    param (
        [string]$WebhookUrl,
        [string[]]$NotifySku,
        [switch]$TestMode,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AppId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TenantId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$htmlPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Thumbprint,
        [switch]$AuditDisabledUsers,
        [switch]$AuditInactiveUsers,
        [ValidateRange(1, 3650)][int]$InactiveDays = 90,
        [ValidateSet('sv', 'en')][string]$Language = 'sv',
        [ValidateRange(0, 36500)][int]$TrendRetentionDays = 400,
        [ValidateRange(0, 1024)][int]$MaxLogSizeMB = 5,
        [ValidateRange(1, 100)][int]$LogHistoryCount = 5,
        [ValidateRange(1, [int]::MaxValue)][int]$UnlimitedSeatThreshold = 10000,
        [ValidateRange(0, 10000)][int]$MinSeatsForAlert = 5,
        [ValidateRange(0, 3650)][int]$HeartbeatDays = 7,
        [ValidateRange(2, 1000)][int]$ForecastMinPoints = 5,
        [ValidateRange(1, 3650)][int]$ForecastMinSpanDays = 7,
        [ValidateRange(1, 3650)][int]$ForecastWarnDays = 60,
        [ValidateRange(2, 3650)][int]$ForecastWindowDays = 30,
        [ValidateRange(1, 10)][int]$WebhookRetryCount = 3
    )

    $foldername = "AzureLicenseAudit"
    $logFile = "$PSScriptRoot\$foldername.log"
    $csvPath = "$PSScriptRoot\$foldername\AzureLicenseSummary.csv"
    $jsonPath = "$PSScriptRoot\$foldername\LastLicenseStatus.json"
    $runStatePath = "$PSScriptRoot\$foldername\LastRun.json"

    # Schema of LastLicenseStatus.json. Bump when the cached shape changes; an older or
    # unreadable cache is treated as a baseline run instead of a wall of false "new SKU".
    $cacheSchemaVersion = 2

    if (-not (Test-Path -Path "$PSScriptRoot\$foldername")) {
        New-Item -ItemType Directory -Path "$PSScriptRoot\$foldername" | Out-Null
    }

    # Writes to the log file and the host. Deliberately NOT Write-Output: this function is
    # called from inside foreach loops whose result is assigned to a variable, and emitting
    # to the success stream contaminated those collections (phantom rows in the Teams table).
    function Write-Log {
        param (
            [Parameter(Mandatory = $true)][string]$Message,
            [string]$LogFile = $logFile,
            [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
        )
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logMessage = "[$timestamp] [$Level] $Message"
        try { Add-Content -Path $LogFile -Value $logMessage -ErrorAction Stop }
        catch { Write-Host "[LOG WRITE FAILED: $($_.Exception.Message)]" }
        Write-Host $logMessage
    }

    # Parses the fixed trend/cache timestamp format regardless of the host's culture.
    # A scheduled task running as SYSTEM does not necessarily use the interactive culture.
    function ConvertFrom-AuditTimestamp {
        param ([string]$Value)
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($Value, 'yyyy-MM-dd HH:mm:ss', $inv, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed
        }
        if ([datetime]::TryParse($Value, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed
        }
        return $null
    }

    # Loads an optional JSON sidecar from next to the script. Every failure mode - file
    # missing, empty, malformed, wrong shape - is logged and degrades to $Fallback rather
    # than stopping the run. A scheduled task must not die because a data file was forgotten
    # when the folder was copied to the server. The 2.0 configuration file is expected to
    # load through this same helper, so the pattern is designed once here.
    # Keys starting with "_" are treated as comments and skipped (repo convention).
    function Import-DataFile {
        param (
            [Parameter(Mandatory)][string]$FileName,
            [string]$Description = $FileName,
            $Fallback = $null,
            [switch]$AsHashtable
        )
        $dataPath = Join-Path $PSScriptRoot $FileName
        if (-not (Test-Path -LiteralPath $dataPath)) {
            Write-Log -Message "$Description not found ($FileName) - continuing without it." -Level "WARN"
            return $Fallback
        }
        try {
            $raw = Get-Content -LiteralPath $dataPath -Raw -Encoding UTF8 -ErrorAction Stop
            if (-not $raw -or -not $raw.Trim()) { throw "file is empty" }
            $data = $raw | ConvertFrom-Json -ErrorAction Stop
            if (-not $AsHashtable) {
                Write-Log -Message "$Description loaded from $FileName." -Level "INFO"
                return $data
            }
            # ConvertFrom-Json -AsHashtable is PowerShell 6+; this keeps 5.1 working.
            $table = @{}
            foreach ($property in $data.PSObject.Properties) {
                if ($property.Name.StartsWith('_')) { continue }
                $table[$property.Name] = [string]$property.Value
            }
            Write-Log -Message "$Description loaded from $FileName ($($table.Count) entries)." -Level "INFO"
            return $table
        }
        catch {
            Write-Log -Message "$Description could not be read from ${FileName}: $($_.Exception.Message). Continuing without it." -Level "WARN"
            return $Fallback
        }
    }

    # Least-squares slope of assigned licenses per day. Using the first and last sample
    # instead (as 1.6-1.9 did) makes the forecast hostage to a single outlier: one
    # assignment an hour before the run produced a rate of +24/day and a nonsense "1 day
    # left". Returns $null when the samples are too few, too closely spaced, or flat.
    function Get-AssignmentRatePerDay {
        param (
            [object[]]$History,
            [int]$MinPoints,
            [int]$MinSpanDays
        )
        $points = @(foreach ($h in $History) {
                $ts = ConvertFrom-AuditTimestamp $h.Timestamp
                if ($ts) { [PSCustomObject]@{ Time = $ts; Assigned = [double]$h.AssignedLicenses } }
            })
        if ($points.Count -lt $MinPoints) { return $null }

        $first = ($points | Sort-Object Time | Select-Object -First 1).Time
        $last = ($points | Sort-Object Time | Select-Object -Last 1).Time
        $spanDays = ($last - $first).TotalDays
        if ($spanDays -lt $MinSpanDays) { return $null }

        # x = days since the first sample, y = assigned licenses
        $n = $points.Count
        $sumX = 0.0; $sumY = 0.0; $sumXY = 0.0; $sumXX = 0.0
        foreach ($p in $points) {
            $x = ($p.Time - $first).TotalDays
            $sumX += $x; $sumY += $p.Assigned
            $sumXY += $x * $p.Assigned; $sumXX += $x * $x
        }
        $denominator = ($n * $sumXX) - ($sumX * $sumX)
        if ([math]::Abs($denominator) -lt 1e-9) { return $null }

        [PSCustomObject]@{
            RatePerDay = (($n * $sumXY) - ($sumX * $sumY)) / $denominator
            Samples    = $n
            SpanDays   = [math]::Round($spanDays, 1)
        }
    }

    # ========== LOG ROTATION ==========
    # Runs before the first Write-Log so the new log starts clean.
    if ($MaxLogSizeMB -gt 0 -and (Test-Path $logFile)) {
        try {
            if ((Get-Item $logFile).Length -gt ($MaxLogSizeMB * 1MB)) {
                $archiveName = "$foldername.$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
                Move-Item -Path $logFile -Destination "$PSScriptRoot\$archiveName" -Force -ErrorAction Stop
                $archives = @(Get-ChildItem -Path $PSScriptRoot -Filter "$foldername.*.log" -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne "$foldername.log" } |
                    Sort-Object Name -Descending)
                if ($archives.Count -gt $LogHistoryCount) {
                    $archives | Select-Object -Skip $LogHistoryCount | Remove-Item -Force -ErrorAction SilentlyContinue
                }
                Write-Log -Message "Log rotated to $archiveName (previous log exceeded $MaxLogSizeMB MB)." -Level "INFO"
            }
        }
        catch {
            # Rotation is housekeeping - never let it stop the run.
            Write-Host "Log rotation failed: $($_.Exception.Message)"
        }
    }

    # ========== WEBHOOK URL ==========
    # -WebhookUrl wins; otherwise fall back to a gitignored '.webhook' file next to the
    # script, which keeps the URL out of the scheduled task's arguments.
    # First non-blank, non-comment line is used, so prod and test URLs can both live there
    # with one commented out. This keeps the URL out of the scheduled task's arguments.
    if (-not $WebhookUrl) {
        $webhookFile = Join-Path $PSScriptRoot '.webhook'
        if (Test-Path -LiteralPath $webhookFile) {
            try {
                $line = Get-Content -LiteralPath $webhookFile -ErrorAction Stop |
                    Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } |
                    Select-Object -First 1
                if ($line) {
                    $WebhookUrl = $line.Trim()
                    Write-Log -Message "Webhook URL read from .webhook file." -Level "INFO"
                }
            }
            catch {
                Write-Log -Message "Could not read .webhook file: $($_.Exception.Message)" -Level "WARN"
            }
        }
    }

    # Builds a styled HTML table with a proper header row and HTML-encoded values.
    function ConvertTo-StyledTable {
        param (
            [object[]]$Data,
            [string[]]$Columns,
            [hashtable]$Headers,
            [string]$RowClass = "",
            [string]$EmptyText = "–"
        )
        if (-not $Data -or @($Data).Count -eq 0) { return "<p class='empty'>$EmptyText</p>" }
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("<table><thead><tr>")
        foreach ($c in $Columns) {
            $h = if ($Headers -and $Headers.ContainsKey($c)) { $Headers[$c] } else { $c }
            [void]$sb.Append("<th>$([System.Net.WebUtility]::HtmlEncode([string]$h))</th>")
        }
        [void]$sb.Append("</tr></thead><tbody>")
        $cls = if ($RowClass) { " class=`"$RowClass`"" } else { "" }
        foreach ($row in @($Data)) {
            [void]$sb.Append("<tr$cls>")
            foreach ($c in $Columns) {
                [void]$sb.Append("<td>$([System.Net.WebUtility]::HtmlEncode([string]$row.$c))</td>")
            }
            [void]$sb.Append("</tr>")
        }
        [void]$sb.Append("</tbody></table>")
        $sb.ToString()
    }

    try {
        if ($NotifySku) {
            if ($NotifySku -isnot [array]) {
                $NotifySku = @($NotifySku)
            }
            $NotifySku = $NotifySku | ForEach-Object { $_.Trim().ToUpper() }
        }

        Write-Log -Message "Connecting to Microsoft Graph..." -Level "INFO"
        Connect-MgGraph -TenantId $tenantid -AppId $appid -CertificateThumbprint $thumbprint -NoWelcome -ErrorAction Stop
        Write-Log -Message "Connected to Microsoft Graph." -Level "INFO"

        $licenses = Get-MgSubscribedSku

        $summary = foreach ($lic in $licenses) {
            [PSCustomObject]@{
                SkuPartNumber     = $lic.SkuPartNumber
                TotalLicenses     = $lic.PrepaidUnits.Enabled
                AssignedLicenses  = $lic.ConsumedUnits
                AvailableLicenses = $lic.PrepaidUnits.Enabled - $lic.ConsumedUnits
                # Subscription health, free of charge in the same call. Anything other than
                # Enabled means the subscription is expiring, in its grace period or already
                # suspended - more urgent than a seat count, and previously invisible.
                CapabilityStatus  = $lic.CapabilityStatus
                WarningUnits      = [int]$lic.PrepaidUnits.Warning
                SuspendedUnits    = [int]$lic.PrepaidUnits.Suspended
            }
        }

        # Display names live in skunames.json next to the script: the map was a 1:1 snapshot
        # of this tenant's portfolio, which is data, not code. A missing or broken file is not
        # fatal - every SKU then renders as its raw part number, exactly as an unmapped SKU
        # already did - so the file is safe to forget during a deployment copy.
        $friendlyNames = Import-DataFile -FileName 'skunames.json' -Description 'SKU display names' -AsHashtable -Fallback @{}

        $unmappedSkus = @()
        $summary | ForEach-Object {
            $displayName = $friendlyNames[$_.SkuPartNumber]
            if (-not $displayName) {
                $displayName = $_.SkuPartNumber
                $unmappedSkus += $_.SkuPartNumber
            }
            $_ | Add-Member -MemberType NoteProperty -Name DisplayName -Value $displayName -Force
        }
        # Without this the map drifts silently: a newly purchased SKU just renders as
        # MICROSOFT_365_SOMETHING_F3 in the report and nobody notices for a year.
        if ($unmappedSkus.Count -gt 0) {
            Write-Log -Message "$($unmappedSkus.Count) SKU(s) missing from skunames.json, shown as raw part numbers: $($unmappedSkus -join ', ')" -Level "WARN"
        }

        $lowThreshold = 10
        $summary | ForEach-Object {
            $status = if ($_.AvailableLicenses -le 0) { 'Exhausted' }
            elseif ($_.AvailableLicenses -lt $lowThreshold) { 'Low' }
            else { 'Healthy' }
            $_ | Add-Member -MemberType NoteProperty -Name Status -Value $status -Force

            # Alert eligibility is a separate axis from status, and deliberately not cached:
            # it is derived from the current numbers every run, so the schema stays at 2.
            #   Unlimited - free/viral SKUs with effectively infinite seats
            #   Unused    - nothing assigned, so nothing can run out; this is waste, not risk
            #   Trial     - too few seats for "0 available" to mean anything
            # These are still classified, exported and shown in the report. They just do not
            # raise alerts, which on a typical tenant is most of the alerting noise.
            $alertClass = if ($_.TotalLicenses -ge $UnlimitedSeatThreshold) { 'Unlimited' }
            elseif ($_.AssignedLicenses -le 0) { 'Unused' }
            elseif ($_.TotalLicenses -lt $MinSeatsForAlert) { 'Trial' }
            else { 'InUse' }
            $_ | Add-Member -MemberType NoteProperty -Name AlertClass -Value $alertClass -Force
        }
        $alertClassLookup = @{}
        foreach ($s in $summary) { $alertClassLookup[[string]$s.SkuPartNumber] = $s.AlertClass }
        $exhausted = $summary | Where-Object { $_.Status -eq 'Exhausted' }
        $low = $summary | Where-Object { $_.Status -eq 'Low' }
        $healthy = $summary | Where-Object { $_.Status -eq 'Healthy' }

        # Monitoring scope. -NotifySku narrows what is cached, diffed and notified on;
        # the HTML report always covers the whole tenant regardless of the filter.
        $monitoredSkus = if ($NotifySku) {
            @($summary | Where-Object { $_.SkuPartNumber.Trim().ToUpper() -in $NotifySku })
        } else {
            @($summary)
        }
        $licensesToNotify = @($monitoredSkus | Where-Object { $_.Status -ne 'Healthy' -and $_.AlertClass -eq 'InUse' })

        $suppressed = @($monitoredSkus | Where-Object { $_.Status -ne 'Healthy' -and $_.AlertClass -ne 'InUse' })
        if ($suppressed.Count -gt 0) {
            Write-Log -Message "Alerting suppressed for $($suppressed.Count) non-actionable SKU(s): $(($suppressed | ForEach-Object { "$($_.SkuPartNumber)[$($_.AlertClass)]" }) -join ', ')" -Level "INFO"
        }

        # Subscription health. Reported and logged from 1.9.5; transition detection needs a
        # cache field and therefore waits for the 2.0 schema bump.
        $unhealthySubscriptions = @($summary | Where-Object {
                ($_.CapabilityStatus -and $_.CapabilityStatus -ne 'Enabled') -or
                $_.WarningUnits -gt 0 -or $_.SuspendedUnits -gt 0
            })
        foreach ($u in $unhealthySubscriptions) {
            Write-Log -Message "Subscription health: $($u.SkuPartNumber) capabilityStatus=$($u.CapabilityStatus) warningUnits=$($u.WarningUnits) suspendedUnits=$($u.SuspendedUnits)" -Level "WARN"
        }

        $summary | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Log -Message "License summary exported to AzureLicenseSummary.csv." -Level "INFO"

        # ========== TREND LOGGING ==========
        # Appends one row per SKU per run; used for depletion forecasting below.
        $trendCsvPath = "$PSScriptRoot\$foldername\LicenseTrend.csv"
        $trendTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $summary | ForEach-Object {
            [PSCustomObject]@{
                Timestamp         = $trendTimestamp
                SkuPartNumber     = $_.SkuPartNumber
                TotalLicenses     = $_.TotalLicenses
                AssignedLicenses  = $_.AssignedLicenses
                AvailableLicenses = $_.AvailableLicenses
            }
        } | Export-Csv -Path $trendCsvPath -NoTypeInformation -Encoding UTF8 -Append
        Write-Log -Message "License trend appended to LicenseTrend.csv." -Level "INFO"

        # ========== DEPLETION FORECAST ==========
        # Least-squares estimate of days until a SKU runs out, from the assignment rate over
        # the last 30 days of trend history. Runs on every SKU, not just the warned ones, so
        # a healthy SKU heading for the wall is visible before it hits it.
        # $forecasts[sku] = @{ State = 'Ok'|'NoData'|'Stable'; DaysLeft; RatePerDay; Samples; SpanDays }
        $forecasts = @{}
        $upcomingDepletions = @()
        if (Test-Path $trendCsvPath) {
            $windowStart = (Get-Date).AddDays(-$ForecastWindowDays)
            $trendRows = @(Import-Csv $trendCsvPath)

            # ---------- TREND RETENTION ----------
            # Pruned in the same pass the forecast already reads, so the file cannot grow
            # without bound. Rows with an unparseable timestamp are kept, never discarded.
            if ($TrendRetentionDays -gt 0) {
                $retentionCutoff = (Get-Date).AddDays(-$TrendRetentionDays)
                $keptRows = @($trendRows | Where-Object {
                        $ts = ConvertFrom-AuditTimestamp $_.Timestamp
                        (-not $ts) -or ($ts -ge $retentionCutoff)
                    })
                if ($keptRows.Count -lt $trendRows.Count) {
                    $prunedCount = $trendRows.Count - $keptRows.Count
                    try {
                        $keptRows | Export-Csv -Path $trendCsvPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
                        $trendRows = $keptRows
                        Write-Log -Message "Pruned $prunedCount trend row(s) older than $TrendRetentionDays day(s) from LicenseTrend.csv." -Level "INFO"
                    }
                    catch {
                        Write-Log -Message "Trend pruning failed: $($_.Exception.Message)" -Level "WARN"
                    }
                }
            }

            $trendData = @($trendRows | Where-Object {
                    $ts = ConvertFrom-AuditTimestamp $_.Timestamp
                    $ts -and $ts -ge $windowStart
                })
            # Group once instead of filtering the whole window per SKU.
            $historyBySku = @{}
            foreach ($row in $trendData) {
                $key = [string]$row.SkuPartNumber
                if (-not $historyBySku.ContainsKey($key)) { $historyBySku[$key] = [System.Collections.ArrayList]::new() }
                [void]$historyBySku[$key].Add($row)
            }

            foreach ($lic in $summary) {
                $key = [string]$lic.SkuPartNumber
                $history = if ($historyBySku.ContainsKey($key)) { @($historyBySku[$key]) } else { @() }
                $fit = Get-AssignmentRatePerDay -History $history -MinPoints $ForecastMinPoints -MinSpanDays $ForecastMinSpanDays

                if (-not $fit) {
                    $forecasts[$key] = [PSCustomObject]@{ State = 'NoData'; DaysLeft = $null; RatePerDay = $null; Samples = @($history).Count; SpanDays = $null }
                    continue
                }
                if ($fit.RatePerDay -le 0) {
                    $forecasts[$key] = [PSCustomObject]@{ State = 'Stable'; DaysLeft = $null; RatePerDay = [math]::Round($fit.RatePerDay, 3); Samples = $fit.Samples; SpanDays = $fit.SpanDays }
                    continue
                }

                $daysLeft = [math]::Ceiling([math]::Max($lic.AvailableLicenses, 0) / $fit.RatePerDay)
                $forecasts[$key] = [PSCustomObject]@{
                    State      = 'Ok'
                    DaysLeft   = $daysLeft
                    RatePerDay = [math]::Round($fit.RatePerDay, 2)
                    Samples    = $fit.Samples
                    SpanDays   = $fit.SpanDays
                }

                # Early warning covers healthy SKUs too - that is the point of forecasting.
                if ($daysLeft -le $ForecastWarnDays -and $lic.AlertClass -eq 'InUse') {
                    Write-Log -Message "Forecast: $key depleted in ~$daysLeft day(s) at $([math]::Round($fit.RatePerDay,2))/day (status $($lic.Status), $($fit.Samples) samples over $($fit.SpanDays) days)." -Level "WARN"
                }
            }

            # SKUs still classified healthy but forecast to run out soon - the early warning
            # the old forecast could never produce, because it only looked at warned SKUs.
            $upcomingDepletions = @($summary | Where-Object {
                    $_.AlertClass -eq 'InUse' -and $_.Status -eq 'Healthy' -and
                    $forecasts.ContainsKey([string]$_.SkuPartNumber) -and
                    $forecasts[[string]$_.SkuPartNumber].State -eq 'Ok' -and
                    $forecasts[[string]$_.SkuPartNumber].DaysLeft -le $ForecastWarnDays
                })
        }

        # SkuId (GUID) -> friendly name lookup based on the tenant's own subscriptions
        $skuIdLookup = @{}
        if ($AuditDisabledUsers -or $AuditInactiveUsers) {
            foreach ($lic in $licenses) {
                $name = $friendlyNames[$lic.SkuPartNumber]
                if (-not $name) { $name = $lic.SkuPartNumber }
                $skuIdLookup[[string]$lic.SkuId] = $name
            }
        }

        # ========== DISABLED USERS WITH LICENSES (reclaimable) ==========
        # Requires the app registration to also have User.Read.All (application).
        $disabledLicensedUsers = @()
        if ($AuditDisabledUsers) {
            Write-Log -Message "Auditing disabled accounts with assigned licenses..." -Level "INFO"

            $uri = "v1.0/users?`$filter=accountEnabled eq false&`$select=displayName,userPrincipalName,assignedLicenses&`$top=999"
            $disabledUsers = @()
            do {
                $result = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
                $disabledUsers += $result.value
                $uri = $result.'@odata.nextLink'
            } while ($uri)

            $disabledLicenseAgg = @{}
            $disabledLicensedUsers = foreach ($user in ($disabledUsers | Where-Object { $_.assignedLicenses.Count -gt 0 })) {
                $userLicenses = foreach ($skuId in $user.assignedLicenses.skuId) {
                    if ($skuIdLookup.ContainsKey([string]$skuId)) { $skuIdLookup[[string]$skuId] } else { $skuId }
                }
                foreach ($ln in $userLicenses) { $disabledLicenseAgg[$ln]++ }
                [PSCustomObject]@{
                    DisplayName       = $user.displayName
                    UserPrincipalName = $user.userPrincipalName
                    LicenseCount      = @($userLicenses).Count
                    Licenses          = ($userLicenses | Sort-Object) -join "; "
                }
            }
            $disabledLicensedUsers = @($disabledLicensedUsers)
            $disabledLicenseSummary = $disabledLicenseAgg.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
                [PSCustomObject]@{ License = $_.Key; Users = $_.Value }
            }

            $reclaimableCount = ($disabledLicensedUsers | Measure-Object LicenseCount -Sum).Sum
            if (-not $reclaimableCount) { $reclaimableCount = 0 }
            Write-Log -Message "Found $($disabledLicensedUsers.Count) disabled account(s) holding $reclaimableCount license(s)." -Level "INFO"

            $disabledCsvPath = "$PSScriptRoot\$foldername\DisabledLicensedUsers.csv"
            $disabledLicensedUsers | Export-Csv -Path $disabledCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Disabled licensed users exported to DisabledLicensedUsers.csv." -Level "INFO"
        }

        # ========== INACTIVE LICENSED USERS ==========
        # Enabled accounts with licenses but no successful sign-in for $InactiveDays days.
        # Requires User.Read.All and AuditLog.Read.All (application).
        $inactiveLicensedUsers = @()
        if ($AuditInactiveUsers) {
            Write-Log -Message "Auditing enabled licensed accounts inactive for $InactiveDays+ days..." -Level "INFO"

            $inactiveCutoff = (Get-Date).AddDays(-$InactiveDays)
            $uri = "v1.0/users?`$filter=accountEnabled eq true&`$select=displayName,userPrincipalName,assignedLicenses,signInActivity,createdDateTime&`$top=999"
            $enabledUsers = @()
            do {
                $result = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
                $enabledUsers += $result.value
                $uri = $result.'@odata.nextLink'
            } while ($uri)

            $inactiveLicenseAgg = @{}
            $skippedNewAccounts = 0
            $inactiveLicensedUsers = foreach ($user in $enabledUsers) {
                if ($user.assignedLicenses.Count -eq 0) { continue }
                $lastSignIn = $user.signInActivity.lastSuccessfulSignInDateTime
                if ($lastSignIn -and ([datetime]$lastSignIn -ge $inactiveCutoff)) { continue }

                # An account created inside the inactivity window has not had the chance to
                # be inactive for that long. Without this, every new hire who has not signed
                # in yet is reported as a reclaimable licence.
                if ($user.createdDateTime -and ([datetime]$user.createdDateTime -ge $inactiveCutoff)) {
                    $skippedNewAccounts++
                    continue
                }

                $userLicenses = foreach ($skuId in $user.assignedLicenses.skuId) {
                    if ($skuIdLookup.ContainsKey([string]$skuId)) { $skuIdLookup[[string]$skuId] } else { $skuId }
                }
                foreach ($ln in $userLicenses) { $inactiveLicenseAgg[$ln]++ }
                [PSCustomObject]@{
                    DisplayName       = $user.displayName
                    UserPrincipalName = $user.userPrincipalName
                    LastSuccessfulSignIn = if ($lastSignIn) { ([datetime]$lastSignIn).ToString("yyyy-MM-dd") } else { "Never" }
                    LicenseCount      = @($userLicenses).Count
                    Licenses          = ($userLicenses | Sort-Object) -join "; "
                }
            }
            $inactiveLicensedUsers = @($inactiveLicensedUsers)
            $inactiveLicenseSummary = $inactiveLicenseAgg.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
                [PSCustomObject]@{ License = $_.Key; Users = $_.Value }
            }

            $inactiveLicenseCount = ($inactiveLicensedUsers | Measure-Object LicenseCount -Sum).Sum
            if (-not $inactiveLicenseCount) { $inactiveLicenseCount = 0 }
            Write-Log -Message "Found $($inactiveLicensedUsers.Count) inactive licensed account(s) holding $inactiveLicenseCount license(s)." -Level "INFO"
            if ($skippedNewAccounts -gt 0) {
                Write-Log -Message "Excluded $skippedNewAccounts account(s) created less than $InactiveDays day(s) ago." -Level "INFO"
            }

            $inactiveCsvPath = "$PSScriptRoot\$foldername\InactiveLicensedUsers.csv"
            $inactiveLicensedUsers | Export-Csv -Path $inactiveCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Inactive licensed users exported to InactiveLicensedUsers.csv." -Level "INFO"
        }

        # ========== HTML EXPORT ==========
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        # --- Localized labels (sv/en) ---
        $strings = @{
            sv = @{
                Title = 'Microsoft 365 – Licensrapport'; MetaFmt = 'Genererad {0} · tröskel för "få kvar": {1} lediga'
                CardSkus = 'Licens-SKU:er'; CardSkusSub = 'totalt antal prenumerationer'
                CardExhausted = 'Slut'; CardExhaustedSub = '0 lediga licenser'
                CardLow = 'Få kvar'; CardLowSubFmt = '&lt; {0} lediga licenser'
                CardReclaim = 'Återvinningsbara'; CardReclaimSubFmt = 'licenser på {0} avstängda konton'
                CardInactiveFmt = 'Inaktiva {0}+ dgr'; CardInactiveSubFmt = 'licenser på {0} konton'
                StatusHeading = 'Licensstatus'; H3Exhausted = '❌ Slut'; H3LowFmt = '⚠️ Få kvar (&lt; {0})'; H3Healthy = '✅ God marginal'
                ColLicense = 'Licens'; ColTotal = 'Totalt'; ColAssigned = 'Tilldelade'; ColAvailable = 'Lediga'; ColForecast = 'Prognos (slut om)'; ForecastUnit = 'dgr'
                DisabledHeading = '♻️ Avstängda konton med licenser'; DisabledLeadFmt = '{0} licenser kan återvinnas från {1} avstängda konton.'
                InactiveHeadingFmt = '💤 Inaktiva licensierade konton ({0}+ dagar)'; InactiveLeadFmt = '{0} licenser binds upp av {1} aktiverade konton som inte loggat in på {2}+ dagar.'
                TiedUpHeading = 'Licenser som binds upp'; AccountsHeading = 'Konton'
                ColDisabledAccounts = 'Avstängda konton'; ColInactiveUsers = 'Inaktiva användare'
                ColName = 'Namn'; ColUpn = 'UPN'; ColCount = 'Antal'; ColLicenses = 'Licenser'; ColLastSignIn = 'Senaste inloggning'
                ForecastNoData = 'för lite historik'; ForecastStable = 'ingen ökning'
                UpcomingHeadingFmt = '⏳ Prognos: tar slut inom {0} dagar'; UpcomingLeadFmt = '{0} licens(er) har god marginal idag men beräknas ta slut inom {1} dagar vid nuvarande tilldelningstakt.'
                ColDaysLeft = 'Slut om (dgr)'; ColRate = 'Takt/dag'
                HealthHeading = '🩺 Prenumerationer som behöver ses över'; HealthLead = 'Status skild från Enabled, eller platser i respit/avstängda. Kontrollera avtal och förnyelse.'
                ColCapability = 'Status'; ColWarningUnits = 'Platser i respit'; ColSuspendedUnits = 'Avstängda platser'
                CardHealth = 'Prenumerationer'; CardHealthSub = 'behöver ses över'
                Footer = 'Genererad via Microsoft Graph API. Prognosen är en minstakvadratanpassning av tilldelningstakten de senaste 30 dagarna och visas bara när underlaget räcker. Obegränsade, oanvända och utvärderingslicenser klassas men larmar inte.'
            }
            en = @{
                Title = 'Microsoft 365 – License Report'; MetaFmt = 'Generated {0} · "low" threshold: {1} available'
                CardSkus = 'License SKUs'; CardSkusSub = 'total subscriptions'
                CardExhausted = 'Exhausted'; CardExhaustedSub = '0 available licenses'
                CardLow = 'Low'; CardLowSubFmt = '&lt; {0} available licenses'
                CardReclaim = 'Reclaimable'; CardReclaimSubFmt = 'licenses on {0} disabled accounts'
                CardInactiveFmt = 'Inactive {0}+ days'; CardInactiveSubFmt = 'licenses on {0} accounts'
                StatusHeading = 'License status'; H3Exhausted = '❌ Exhausted'; H3LowFmt = '⚠️ Low (&lt; {0})'; H3Healthy = '✅ Healthy'
                ColLicense = 'License'; ColTotal = 'Total'; ColAssigned = 'Assigned'; ColAvailable = 'Available'; ColForecast = 'Forecast (depleted in)'; ForecastUnit = 'days'
                DisabledHeading = '♻️ Disabled accounts with licenses'; DisabledLeadFmt = '{0} licenses can be reclaimed from {1} disabled accounts.'
                InactiveHeadingFmt = '💤 Inactive licensed accounts ({0}+ days)'; InactiveLeadFmt = '{0} licenses are tied up by {1} enabled accounts with no sign-in for {2}+ days.'
                TiedUpHeading = 'Licenses tied up'; AccountsHeading = 'Accounts'
                ColDisabledAccounts = 'Disabled accounts'; ColInactiveUsers = 'Inactive users'
                ColName = 'Name'; ColUpn = 'UPN'; ColCount = 'Count'; ColLicenses = 'Licenses'; ColLastSignIn = 'Last sign-in'
                ForecastNoData = 'insufficient history'; ForecastStable = 'not growing'
                UpcomingHeadingFmt = '⏳ Forecast: depleted within {0} days'; UpcomingLeadFmt = '{0} license(s) look healthy today but are projected to run out within {1} days at the current assignment rate.'
                ColDaysLeft = 'Days left'; ColRate = 'Rate/day'
                HealthHeading = '🩺 Subscriptions needing attention'; HealthLead = 'Status other than Enabled, or seats in grace period / suspended. Check the agreement and renewal.'
                ColCapability = 'Status'; ColWarningUnits = 'Seats in grace'; ColSuspendedUnits = 'Suspended seats'
                CardHealth = 'Subscriptions'; CardHealthSub = 'needing attention'
                Footer = 'Generated via the Microsoft Graph API. The forecast is a least-squares fit of the assignment rate over the last 30 days and is shown only when there is enough history. Unlimited, unused and trial SKUs are classified but never alert.'
            }
        }
        $L = $strings[$Language]

        # Renders a forecast cell honestly. Up to 1.9 both "no history" and "not growing"
        # rendered as "-", which made an absent forecast indistinguishable from a safe one.
        function Format-ForecastCell {
            param ($Sku, [switch]$Short)
            $key = [string]$Sku
            if (-not $forecasts.ContainsKey($key)) { return $(if ($Short) { 'n/a' } else { $L.ForecastNoData }) }
            switch ($forecasts[$key].State) {
                'Ok' { if ($Short) { "~$($forecasts[$key].DaysLeft)" } else { "~$($forecasts[$key].DaysLeft) $($L.ForecastUnit)" } }
                'Stable' { if ($Short) { '-' } else { $L.ForecastStable } }
                default { if ($Short) { 'n/a' } else { $L.ForecastNoData } }
            }
        }

        # --- Summary cards ---
        $cardsHtml = @"
            <div class="card"><div class="card-label">$($L.CardSkus)</div><div class="card-value">$(@($summary).Count)</div><div class="card-sub">$($L.CardSkusSub)</div></div>
            <div class="card accent-red"><div class="card-label">$($L.CardExhausted)</div><div class="card-value">$(@($exhausted).Count)</div><div class="card-sub">$($L.CardExhaustedSub)</div></div>
            <div class="card accent-amber"><div class="card-label">$($L.CardLow)</div><div class="card-value">$(@($low).Count)</div><div class="card-sub">$($L.CardLowSubFmt -f $lowThreshold)</div></div>
"@
        if ($AuditDisabledUsers) {
            $cardsHtml += @"
            <div class="card accent-blue"><div class="card-label">$($L.CardReclaim)</div><div class="card-value">$reclaimableCount</div><div class="card-sub">$($L.CardReclaimSubFmt -f @($disabledLicensedUsers).Count)</div></div>
"@
        }
        if ($AuditInactiveUsers) {
            $cardsHtml += @"
            <div class="card accent-blue"><div class="card-label">$($L.CardInactiveFmt -f $InactiveDays)</div><div class="card-value">$inactiveLicenseCount</div><div class="card-sub">$($L.CardInactiveSubFmt -f @($inactiveLicensedUsers).Count)</div></div>
"@
        }
        if ($unhealthySubscriptions.Count -gt 0) {
            $cardsHtml += @"
            <div class="card accent-red"><div class="card-label">$($L.CardHealth)</div><div class="card-value">$($unhealthySubscriptions.Count)</div><div class="card-sub">$($L.CardHealthSub)</div></div>
"@
        }

        # --- Subscription health ---
        # Not a seat count: these are subscriptions expiring, in grace or suspended.
        $healthHtml = ""
        if ($unhealthySubscriptions.Count -gt 0) {
            $healthHtml += "<h2>$($L.HealthHeading)</h2>"
            $healthHtml += "<p class='lead'>$($L.HealthLead)</p>"
            $healthHtml += ConvertTo-StyledTable -Data ($unhealthySubscriptions | Sort-Object DisplayName) -Columns DisplayName, CapabilityStatus, WarningUnits, SuspendedUnits -Headers @{DisplayName = $L.ColLicense; CapabilityStatus = $L.ColCapability; WarningUnits = $L.ColWarningUnits; SuspendedUnits = $L.ColSuspendedUnits }
        }

        # --- Upcoming depletions (healthy today, forecast to run out) ---
        $upcomingHtml = ""
        if ($upcomingDepletions.Count -gt 0) {
            $upcomingDisplay = $upcomingDepletions |
                Sort-Object { $forecasts[[string]$_.SkuPartNumber].DaysLeft } |
                Select-Object DisplayName, TotalLicenses, AssignedLicenses, AvailableLicenses,
                    @{n = 'DaysLeft'; e = { $forecasts[[string]$_.SkuPartNumber].DaysLeft } },
                    @{n = 'Rate'; e = { $forecasts[[string]$_.SkuPartNumber].RatePerDay } }
            $upcomingHtml += "<h2>$($L.UpcomingHeadingFmt -f $ForecastWarnDays)</h2>"
            $upcomingHtml += "<p class='lead'>$($L.UpcomingLeadFmt -f $upcomingDepletions.Count, $ForecastWarnDays)</p>"
            $upcomingHtml += ConvertTo-StyledTable -Data $upcomingDisplay -Columns DisplayName, TotalLicenses, AssignedLicenses, AvailableLicenses, DaysLeft, Rate -Headers @{DisplayName = $L.ColLicense; TotalLicenses = $L.ColTotal; AssignedLicenses = $L.ColAssigned; AvailableLicenses = $L.ColAvailable; DaysLeft = $L.ColDaysLeft; Rate = $L.ColRate } -RowClass "low"
        }

        # --- License status tables ---
        $statusHtml = ""
        if ($exhausted) {
            $statusHtml += "<h3>$($L.H3Exhausted)</h3>"
            $statusHtml += ConvertTo-StyledTable -Data ($exhausted | Sort-Object DisplayName) -Columns DisplayName,TotalLicenses,AssignedLicenses,AvailableLicenses -Headers @{DisplayName=$L.ColLicense;TotalLicenses=$L.ColTotal;AssignedLicenses=$L.ColAssigned;AvailableLicenses=$L.ColAvailable} -RowClass "exhausted"
        }
        if ($low) {
            $lowDisplay = $low | Sort-Object DisplayName | Select-Object DisplayName, TotalLicenses, AssignedLicenses, AvailableLicenses, @{n='Forecast';e={ Format-ForecastCell $_.SkuPartNumber }}
            $statusHtml += "<h3>$($L.H3LowFmt -f $lowThreshold)</h3>"
            $statusHtml += ConvertTo-StyledTable -Data $lowDisplay -Columns DisplayName,TotalLicenses,AssignedLicenses,AvailableLicenses,Forecast -Headers @{DisplayName=$L.ColLicense;TotalLicenses=$L.ColTotal;AssignedLicenses=$L.ColAssigned;AvailableLicenses=$L.ColAvailable;Forecast=$L.ColForecast} -RowClass "low"
        }
        if ($healthy) {
            $statusHtml += "<h3>$($L.H3Healthy)</h3>"
            $statusHtml += ConvertTo-StyledTable -Data ($healthy | Sort-Object DisplayName) -Columns DisplayName,TotalLicenses,AssignedLicenses,AvailableLicenses -Headers @{DisplayName=$L.ColLicense;TotalLicenses=$L.ColTotal;AssignedLicenses=$L.ColAssigned;AvailableLicenses=$L.ColAvailable} -RowClass "healthy"
        }

        # --- Disabled accounts section ---
        $disabledHtml = ""
        if ($AuditDisabledUsers -and $disabledLicensedUsers.Count -gt 0) {
            $disabledHtml += "<h2>$($L.DisabledHeading)</h2>"
            $disabledHtml += "<p class='lead'>$($L.DisabledLeadFmt -f $reclaimableCount, @($disabledLicensedUsers).Count)</p>"
            $disabledHtml += "<h3>$($L.TiedUpHeading)</h3>"
            $disabledHtml += ConvertTo-StyledTable -Data $disabledLicenseSummary -Columns License,Users -Headers @{License=$L.ColLicense;Users=$L.ColDisabledAccounts}
            $disabledHtml += "<h3>$($L.AccountsHeading)</h3>"
            $disabledHtml += ConvertTo-StyledTable -Data ($disabledLicensedUsers | Sort-Object DisplayName) -Columns DisplayName,UserPrincipalName,LicenseCount,Licenses -Headers @{DisplayName=$L.ColName;UserPrincipalName=$L.ColUpn;LicenseCount=$L.ColCount;Licenses=$L.ColLicenses}
        }

        # --- Inactive accounts section ---
        $inactiveHtml = ""
        if ($AuditInactiveUsers -and $inactiveLicensedUsers.Count -gt 0) {
            $inactiveHtml += "<h2>$($L.InactiveHeadingFmt -f $InactiveDays)</h2>"
            $inactiveHtml += "<p class='lead'>$($L.InactiveLeadFmt -f $inactiveLicenseCount, @($inactiveLicensedUsers).Count, $InactiveDays)</p>"
            $inactiveHtml += "<h3>$($L.TiedUpHeading)</h3>"
            $inactiveHtml += ConvertTo-StyledTable -Data $inactiveLicenseSummary -Columns License,Users -Headers @{License=$L.ColLicense;Users=$L.ColInactiveUsers}
            $inactiveHtml += "<h3>$($L.AccountsHeading)</h3>"
            $inactiveHtml += ConvertTo-StyledTable -Data ($inactiveLicensedUsers | Sort-Object LastSuccessfulSignIn) -Columns DisplayName,UserPrincipalName,LastSuccessfulSignIn,LicenseCount,Licenses -Headers @{DisplayName=$L.ColName;UserPrincipalName=$L.ColUpn;LastSuccessfulSignIn=$L.ColLastSignIn;LicenseCount=$L.ColCount;Licenses=$L.ColLicenses}
        }

        $htmlContent = @"
<!DOCTYPE html>
<html lang="$Language">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$($L.Title)</title>
<style>
  :root { --blue:#0078D4; --blue-dk:#106EBE; --ink:#243447; --muted:#6b7785; --line:#e3e8ee; --bg:#f4f6f9; }
  * { box-sizing: border-box; }
  body { font-family:'Segoe UI',Arial,sans-serif; margin:0; background:var(--bg); color:var(--ink); }
  .wrap { max-width:1200px; margin:0 auto; padding:0 32px 56px; }
  header { background:linear-gradient(135deg,var(--blue) 0%,var(--blue-dk) 100%); color:#fff; padding:28px 0; margin-bottom:28px; box-shadow:0 3px 12px rgba(0,0,0,.12); }
  header .wrap { padding-bottom:0; }
  h1 { margin:0; font-size:26px; font-weight:600; letter-spacing:-.3px; }
  .meta { margin-top:6px; font-size:13px; opacity:.9; }
  h2 { font-size:20px; margin:40px 0 6px; padding-bottom:8px; border-bottom:2px solid var(--line); }
  h3 { font-size:15px; color:var(--muted); margin:22px 0 8px; text-transform:uppercase; letter-spacing:.4px; }
  p.lead { font-size:15px; margin:6px 0 4px; }
  p.empty { color:var(--muted); font-style:italic; }
  .cards { display:flex; flex-wrap:wrap; gap:16px; margin-top:8px; }
  .card { background:#fff; border-radius:10px; padding:18px 20px; flex:1 1 160px; box-shadow:0 1px 6px rgba(0,0,0,.07); border-top:4px solid var(--blue); }
  .card.accent-red { border-top-color:#d13438; }
  .card.accent-amber { border-top-color:#f7a600; }
  .card.accent-blue { border-top-color:var(--blue); }
  .card-label { font-size:12px; color:var(--muted); text-transform:uppercase; letter-spacing:.5px; }
  .card-value { font-size:34px; font-weight:700; margin:4px 0 2px; }
  .card-sub { font-size:12px; color:var(--muted); }
  table { width:100%; border-collapse:separate; border-spacing:0; margin:8px 0 4px; background:#fff; border-radius:10px; overflow:hidden; box-shadow:0 1px 6px rgba(0,0,0,.07); font-size:14px; }
  thead th { background:var(--blue); color:#fff; text-align:left; padding:11px 14px; font-weight:600; font-size:12px; text-transform:uppercase; letter-spacing:.4px; }
  tbody td { padding:10px 14px; border-bottom:1px solid var(--line); }
  tbody tr:last-child td { border-bottom:none; }
  tbody tr:nth-child(even) { background:#fafbfc; }
  tbody tr:hover { background:#eef5fc; }
  tr.exhausted td:nth-child(4) { color:#d13438; font-weight:700; }
  tr.low td:nth-child(4) { color:#b46e00; font-weight:700; }
  tr.healthy td:nth-child(4) { color:#107c10; font-weight:600; }
  footer { margin-top:40px; text-align:center; font-size:12px; color:var(--muted); }
</style>
</head>
<body>
<header><div class="wrap"><h1>$($L.Title)</h1><div class="meta">$($L.MetaFmt -f $timestamp, $lowThreshold)</div></div></header>
<div class="wrap">
  <div class="cards">
$cardsHtml
  </div>

$healthHtml
$upcomingHtml

  <h2>$($L.StatusHeading)</h2>
$statusHtml
$inactiveHtml
$disabledHtml

  <footer>$($L.Footer)</footer>
</div>
</body>
</html>
"@

        # ---------- PUBLISH THE REPORT ----------
        # Written locally first, then published to $htmlPath via a temp file + rename so a
        # reader never sees a half-written report. A publishing failure (share offline,
        # permissions) must not be logged as success and must not abort the run - the
        # notification below is marked instead, and the local copy remains available.
        $reportPublished = $false
        $localHtmlPath = Join-Path "$PSScriptRoot\$foldername" ([System.IO.Path]::GetFileName($htmlPath))
        try {
            $htmlContent | Out-File -FilePath $localHtmlPath -Encoding UTF8 -ErrorAction Stop
            Write-Log -Message "License report written to local copy $([System.IO.Path]::GetFileName($localHtmlPath))." -Level "INFO"
        }
        catch {
            Write-Log -Message "Failed to write the local report copy: $($_.Exception.Message)" -Level "ERROR"
        }

        $publishTempPath = "$htmlPath.tmp"
        try {
            $htmlParent = Split-Path -Path $htmlPath -Parent
            if ($htmlParent -and -not (Test-Path -LiteralPath $htmlParent)) {
                New-Item -ItemType Directory -Path $htmlParent -Force -ErrorAction Stop | Out-Null
            }
            $htmlContent | Out-File -FilePath $publishTempPath -Encoding UTF8 -ErrorAction Stop
            Move-Item -LiteralPath $publishTempPath -Destination $htmlPath -Force -ErrorAction Stop
            $reportPublished = $true
            Write-Log -Message "License report published to $htmlPath." -Level "INFO"
        }
        catch {
            Write-Log -Message "Failed to publish the report to ${htmlPath}: $($_.Exception.Message)" -Level "ERROR"
            if (Test-Path -LiteralPath $publishTempPath) {
                Remove-Item -LiteralPath $publishTempPath -Force -ErrorAction SilentlyContinue
            }
        }

        # ========== JSON CACHING & DIFF =====================
        # The cache holds every monitored SKU, not only the ones currently in warning. That
        # is what makes it possible to report a recovery as a recovery instead of as a
        # removed subscription, and to notice that seats were purchased or cancelled.
        $currentStatus = $monitoredSkus | Sort-Object SkuPartNumber | ForEach-Object {
            [PSCustomObject]@{
                SkuPartNumber     = $_.SkuPartNumber
                DisplayName       = $_.DisplayName
                Status            = $_.Status
                TotalLicenses     = $_.TotalLicenses
                AssignedLicenses  = $_.AssignedLicenses
                AvailableLicenses = $_.AvailableLicenses
            }
        }

        $currentJson = [PSCustomObject]@{
            SchemaVersion = $cacheSchemaVersion
            Generated     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Skus          = @($currentStatus)
        } | ConvertTo-Json -Depth 4

        # Two distinct questions, conflated as $hasChanged up to 1.9:
        #   $stateChanged          - did any recorded value move? Decides whether to rewrite
        #                            the cache. Must include non-alerting SKUs, otherwise the
        #                            cache freezes on them and reports a false jump the day
        #                            one of them becomes alert-eligible.
        #   $notificationWarranted - is this worth a message? Only alert-eligible SKUs count.
        $stateChanged = $true
        $notificationWarranted = $true
        $isBaseline = $false
        $changeComment = ""
        $changeDetailText = ""
        $changeDetails = @()

        if ($TestMode) {
            Write-Log -Message "TestMode is enabled – simulating a license status change." -Level "WARN"
            $changeDetailText = "`n Microsoft 365 E5`n    Assigned: 95 → 96`n    Available: 5 → 4"

           # Send a clearly marked test message to Teams, then stop. The real diff
           # logic and cache update are skipped so a test run never affects state.
            if ($WebhookUrl) {
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $notificationText = "Test Mode Activated – Simulated License Notification`n`n"
                $notificationText += "This is a simulated license warning sent on $timestamp.`n"
                $notificationText += "No actual license values were used in this message.`n"
                $notificationText += "`n$changeDetailText`n"

                $payload = @{ message = $notificationText } | ConvertTo-Json -Depth 3

                try {
                    Invoke-RestMethod -Method Post -Uri $WebhookUrl -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -ContentType 'application/json; charset=utf-8'
                    Write-Log -Message "TestMode: Simulated Teams notification sent." -Level "INFO"
                }
                catch {
                    Write-Log -Message "TestMode: Webhook send failed: $($_.Exception.Message)" -Level "ERROR"
                }
            }
            Write-Log -Message "TestMode: Skipping diff detection and cache update." -Level "INFO"
            return
        }

        # Load the previous state. A missing, unreadable or pre-schema-2 cache cannot be
        # diffed meaningfully, so the run establishes a baseline instead: the current watch
        # list is sent once without a change breakdown, and the new cache is written.
        $previousStatus = $null
        if (Test-Path $jsonPath) {
            try {
                $cached = Get-Content $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
                if ($cached.SchemaVersion -ge $cacheSchemaVersion -and $cached.Skus) {
                    $previousStatus = @($cached.Skus)
                }
                else {
                    Write-Log -Message "Cache predates schema $cacheSchemaVersion - establishing a new baseline this run." -Level "WARN"
                }
            }
            catch {
                Write-Log -Message "Cache could not be read ($($_.Exception.Message)) - establishing a new baseline this run." -Level "WARN"
            }
        }
        else {
            Write-Log -Message "No cache found - establishing a baseline this run." -Level "INFO"
        }

        if (-not $previousStatus) {
            $isBaseline = $true
            $stateChanged = $true
            $notificationWarranted = $true
            Write-Log -Message "Baseline run: $(@($currentStatus).Count) monitored SKU(s) recorded, no change breakdown reported." -Level "INFO"
        }
        else {
            $currentStatusDict = @{}
            $previousStatusDict = @{}
            foreach ($item in $currentStatus) { $currentStatusDict[[string]$item.SkuPartNumber] = $item }
            foreach ($item in $previousStatus) { $previousStatusDict[[string]$item.SkuPartNumber] = $item }

            $addedSkus = @($currentStatusDict.Keys | Where-Object { -not $previousStatusDict.ContainsKey($_) } | Sort-Object)
            $removedSkus = @($previousStatusDict.Keys | Where-Object { -not $currentStatusDict.ContainsKey($_) } | Sort-Object)
            $enteredWarning = @()
            $leftWarning = @()
            $capacityChanges = @()
            $changedSkus = @()

            $valuesMoved = $false

            foreach ($sku in @($currentStatusDict.Keys | Sort-Object)) {
                if (-not $previousStatusDict.ContainsKey($sku)) { continue }
                $prev = $previousStatusDict[$sku]
                $curr = $currentStatusDict[$sku]

                # Any movement at all, alert-eligible or not, means the cache is stale.
                if ([int]$prev.TotalLicenses -ne [int]$curr.TotalLicenses -or
                    [int]$prev.AssignedLicenses -ne [int]$curr.AssignedLicenses -or
                    [int]$prev.AvailableLicenses -ne [int]$curr.AvailableLicenses -or
                    [string]$prev.Status -ne [string]$curr.Status) {
                    $valuesMoved = $true
                }

                # Unlimited, unused and trial SKUs are classified and cached like any other,
                # but their transitions are not news: a 1-seat evaluation SKU flipping between
                # "0 available" and "1 available" is not an incident.
                if ($alertClassLookup[$sku] -ne 'InUse') { continue }

                $prevWarned = $prev.Status -ne 'Healthy'
                $currWarned = $curr.Status -ne 'Healthy'
                $transitioned = $false

                if (-not $prevWarned -and $currWarned) {
                    $transitioned = $true
                    $enteredWarning += [PSCustomObject]@{
                        DisplayName = $curr.DisplayName; From = $prev.Status; To = $curr.Status; Available = $curr.AvailableLicenses
                    }
                }
                elseif ($prevWarned -and -not $currWarned) {
                    $transitioned = $true
                    $leftWarning += [PSCustomObject]@{
                        DisplayName = $curr.DisplayName; From = $prev.Status; To = $curr.Status; Available = $curr.AvailableLicenses
                    }
                }

                if ([int]$prev.TotalLicenses -ne [int]$curr.TotalLicenses) {
                    $capacityChanges += [PSCustomObject]@{
                        DisplayName = $curr.DisplayName; Change = "$($prev.TotalLicenses) -> $($curr.TotalLicenses)"
                    }
                }

                # Count movement is only notified for SKUs that are in warning right now.
                # Assignments shift constantly on healthy SKUs - those are still recorded in
                # the cache and the trend file, but must not produce a message every run.
                # A SKU that just crossed into warning is already reported as a transition.
                if ($currWarned -and -not $transitioned -and
                    ([int]$prev.AssignedLicenses -ne [int]$curr.AssignedLicenses -or
                    [int]$prev.AvailableLicenses -ne [int]$curr.AvailableLicenses)) {
                    $changedSkus += $sku
                }
            }

            $notificationWarranted = ($addedSkus.Count + $removedSkus.Count + $enteredWarning.Count +
                $leftWarning.Count + $capacityChanges.Count + $changedSkus.Count) -gt 0
            $stateChanged = $notificationWarranted -or $valuesMoved -or
                $addedSkus.Count -gt 0 -or $removedSkus.Count -gt 0

            if (-not $notificationWarranted) {
                if ($stateChanged) {
                    Write-Log -Message "Counts moved but no alert-eligible change. Cache refreshed, no notification." -Level "INFO"
                }
                else {
                    Write-Log -Message "License status unchanged. Skipping notification." -Level "INFO"
                }
            }
            else {
                Write-Log -Message "Changes detected in license status:" -Level "INFO"

                if ($addedSkus.Count -gt 0) {
                    $names = @($addedSkus | ForEach-Object { $currentStatusDict[$_].DisplayName })
                    Write-Log -Message "   New subscriptions in tenant: $($addedSkus -join ', ')" -Level "INFO"
                    $changeComment += "`n🆕 **New subscriptions in tenant:** $($names -join ', ')"
                }
                if ($removedSkus.Count -gt 0) {
                    $names = @($removedSkus | ForEach-Object {
                            $n = $previousStatusDict[$_].DisplayName
                            if ($n) { $n } else { $_ }
                        })
                    Write-Log -Message "   Subscriptions no longer present: $($removedSkus -join ', ')" -Level "INFO"
                    $changeComment += "`n🗑️ **Subscriptions no longer present:** $($names -join ', ')"
                }
                if ($enteredWarning.Count -gt 0) {
                    foreach ($e in ($enteredWarning | Sort-Object DisplayName)) {
                        Write-Log -Message "   Entered warning: $($e.DisplayName) ($($e.From) -> $($e.To), $($e.Available) available)" -Level "WARN"
                    }
                    $txt = @($enteredWarning | Sort-Object DisplayName | ForEach-Object { "$($_.DisplayName) ($($_.To.ToLower()), $($_.Available) available)" })
                    $changeComment += "`n🔻 **Entered warning:** $($txt -join ', ')"
                }
                if ($leftWarning.Count -gt 0) {
                    foreach ($e in ($leftWarning | Sort-Object DisplayName)) {
                        Write-Log -Message "   Recovered: $($e.DisplayName) ($($e.From) -> healthy, $($e.Available) available)" -Level "INFO"
                    }
                    $txt = @($leftWarning | Sort-Object DisplayName | ForEach-Object { "$($_.DisplayName) ($($_.Available) available)" })
                    $changeComment += "`n✅ **Recovered:** $($txt -join ', ')"
                }
                if ($capacityChanges.Count -gt 0) {
                    foreach ($c in ($capacityChanges | Sort-Object DisplayName)) {
                        Write-Log -Message "   Capacity changed: $($c.DisplayName) $($c.Change) seat(s)" -Level "INFO"
                    }
                    $txt = @($capacityChanges | Sort-Object DisplayName | ForEach-Object { "$($_.DisplayName) $($_.Change)" })
                    $changeComment += "`n📦 **Purchased capacity changed:** $($txt -join ', ')"
                }

                if ($changedSkus.Count -gt 0) {
                    Write-Log -Message "   Changed SKUs in warning: $($changedSkus -join ', ')" -Level "INFO"
                    $changeDetails = @(foreach ($sku in $changedSkus) {
                            $prev = $previousStatusDict[$sku]
                            $curr = $currentStatusDict[$sku]
                            $assignedChange = "$($prev.AssignedLicenses) -> $($curr.AssignedLicenses)"
                            $availableChange = "$($prev.AvailableLicenses) -> $($curr.AvailableLicenses)"
                            $displayName = $curr.DisplayName
                            if (-not $displayName) { $displayName = $sku }

                            Write-Log -Message "  🔁 $sku - Assigned: $assignedChange, Available: $availableChange" -Level "INFO"
                            [PSCustomObject]@{
                                DisplayName     = $displayName
                                AssignedChange  = $assignedChange
                                AvailableChange = $availableChange
                            }
                        })
                    foreach ($item in ($changeDetails | Sort-Object DisplayName)) {
                        $changeDetailText += "`n $($item.DisplayName)`n    $($item.AssignedChange)`n    $($item.AvailableChange)`n"
                    }
                }
            }
        }

        # ========== TEAMS NOTIFICATION ==========
        foreach ($lic in @($licensesToNotify)) {
            Write-Log -Message "Will notify on $($lic.SkuPartNumber) - Available: $($lic.AvailableLicenses)" -Level "INFO"
        }
        Write-Log -Message "licensesToNotify.Count = $(@($licensesToNotify).Count)" -Level "INFO"
        Write-Log -Message "changeDetails.Count = $(@($changeDetails).Count)" -Level "INFO"

        # Tracks whether the state change has actually reached Teams. The cache is only
        # advanced once it has - see the cache write at the end of the try block.
        $notificationDelivered = $true

        if ($WebhookUrl -and $notificationWarranted) {
            $notificationDelivered = $false
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $uncPath = "$htmlPath"
            $mdLink = "($uncPath)"

            $notificationText = if ($isBaseline) {
                "📢 **License Monitoring Baseline Established**`n"
            } else {
                "📢 **License Status Change Detected**`n"
            }
            $notificationText += "`n🕒 **Report triggered:** $timestamp"
            $notificationText += "`n📄 **Full report:** $mdLink"
            if (-not $reportPublished) {
                $notificationText += "`n⚠️ **The report could not be published to that path - the linked file is stale. See the log and the local copy under AzureLicenseAudit\.**"
            }
            if ($isBaseline) {
                $notificationText += "`n`nℹ️ No comparable previous state was available, so this run only records the current position. Changes will be reported from the next run onwards."
            }

            if ($changeComment) {
                $notificationText += "`n$changeComment"
            }

            if ($changeDetails -and $changeDetails.Count -gt 0) {
                $notificationText += "`n`n🔁 **Changes in Detail:**`n`n"
                $notificationText += "| License | Assigned (before → after) | Available (before → after) |`n"
                $notificationText += "|---------|----------------------------|-----------------------------|`n"
                foreach ($item in ($changeDetails | Sort-Object DisplayName)) {
                    $notificationText += "| $($item.DisplayName) | $($item.AssignedChange) | $($item.AvailableChange) |`n"
                }
            }

            if (-not $licensesToNotify -or $licensesToNotify.Count -eq 0) {
                $notificationText += "`nℹ️ No licenses are currently low or exhausted, but a change in license allocation was detected."
            } else {
                $notificationText += "`n### ⚠️ Licenses to Watch:`n"
                $notificationText += "| License | Total | Available | Est. days left |`n"
                $notificationText += "|---------|-------|-----------|----------------|`n"
                $licensesToNotify | Sort-Object DisplayName | ForEach-Object {
                    $estDays = Format-ForecastCell $_.SkuPartNumber -Short
                    $notificationText += "| $($_.DisplayName) | $($_.TotalLicenses) | $($_.AvailableLicenses) | $estDays |`n"
                }
            }

            if ($AuditDisabledUsers -and $disabledLicensedUsers.Count -gt 0) {
                $notificationText += "`n♻️ **Reclaimable licenses:** $reclaimableCount license(s) assigned to $($disabledLicensedUsers.Count) disabled account(s). See full report for details.`n"
            }

            if ($AuditInactiveUsers -and $inactiveLicensedUsers.Count -gt 0) {
                $notificationText += "`n💤 **Inactive licensed users:** $($inactiveLicensedUsers.Count) enabled account(s) with $inactiveLicenseCount license(s) and no sign-in for $InactiveDays+ days. See full report for details.`n"
            }

            $payload = @{ message = $notificationText } | ConvertTo-Json -Depth 3

            Write-Log -Message "Webhook message body:`n$notificationText"

            # Three attempts with a short backoff. A transient 429/503 must not be allowed
            # to consume the change - see the cache write below.
            $maxAttempts = $WebhookRetryCount
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                try {
                    Invoke-RestMethod -Method Post -Uri $WebhookUrl -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -ContentType 'application/json; charset=utf-8' -ErrorAction Stop
                    $notificationDelivered = $true
                    Write-Log -Message "Teams notification sent due to license change." -Level "INFO"
                    break
                }
                catch {
                    if ($attempt -lt $maxAttempts) {
                        Write-Log -Message "Webhook send failed (attempt $attempt/$maxAttempts): $($_.Exception.Message). Retrying..." -Level "WARN"
                        Start-Sleep -Seconds (5 * $attempt)
                    }
                    else {
                        Write-Log -Message "Webhook send failed after $maxAttempts attempt(s): $($_.Exception.Message)" -Level "ERROR"
                    }
                }
            }
        }

        # ========== HEARTBEAT ==========
        # Reporting is change-based, so without this, "nothing changed" and "the scheduled
        # task stopped running in July" look exactly the same from the outside. If nothing
        # has been sent for -HeartbeatDays, send a digest instead: proof of life, the current
        # watch list, what the forecast expects to run out soon, and subscription health.
        $runState = $null
        if (Test-Path $runStatePath) {
            try { $runState = Get-Content $runStatePath -Raw -ErrorAction Stop | ConvertFrom-Json }
            catch { Write-Log -Message "Run-state file unreadable ($($_.Exception.Message)) - treating as first run." -Level "WARN" }
        }
        $lastNotification = $null
        if ($runState -and $runState.LastNotificationUtc) {
            $lastNotification = ConvertFrom-AuditTimestamp $runState.LastNotificationUtc
        }

        $heartbeatSent = $false
        if ($HeartbeatDays -gt 0 -and $WebhookUrl -and -not $TestMode -and -not $notificationWarranted) {
            $daysSince = if ($lastNotification) { ((Get-Date).ToUniversalTime() - $lastNotification).TotalDays } else { [double]::MaxValue }
            if ($daysSince -ge $HeartbeatDays) {
                $sinceText = if ($lastNotification) { "$([math]::Floor($daysSince)) day(s) ago" } else { "never" }
                $hb = "🫀 **License Monitoring Heartbeat**`n"
                $hb += "`n🕒 **Checked:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                $hb += "`n📄 **Full report:** ($htmlPath)"
                if (-not $reportPublished) { $hb += "`n⚠️ **The report could not be published - the linked file is stale.**" }
                $hb += "`n💬 **Last change reported:** $sinceText"
                $hb += "`n`nNo license changes worth reporting since then. This message confirms the job is still running.`n"

                if (@($licensesToNotify).Count -gt 0) {
                    $hb += "`n### ⚠️ Currently on the watch list:`n"
                    $hb += "| License | Total | Available | Est. days left |`n"
                    $hb += "|---------|-------|-----------|----------------|`n"
                    $licensesToNotify | Sort-Object DisplayName | ForEach-Object {
                        $hb += "| $($_.DisplayName) | $($_.TotalLicenses) | $($_.AvailableLicenses) | $(Format-ForecastCell $_.SkuPartNumber -Short) |`n"
                    }
                }
                else {
                    $hb += "`nℹ️ No licenses are low or exhausted right now.`n"
                }

                if ($upcomingDepletions.Count -gt 0) {
                    $hb += "`n### ⏳ Healthy today, forecast to run out within $ForecastWarnDays days:`n"
                    $hb += "| License | Available | Est. days left | Rate/day |`n"
                    $hb += "|---------|-----------|----------------|----------|`n"
                    $upcomingDepletions | Sort-Object { $forecasts[[string]$_.SkuPartNumber].DaysLeft } | ForEach-Object {
                        $f = $forecasts[[string]$_.SkuPartNumber]
                        $hb += "| $($_.DisplayName) | $($_.AvailableLicenses) | ~$($f.DaysLeft) | $($f.RatePerDay) |`n"
                    }
                }

                if ($unhealthySubscriptions.Count -gt 0) {
                    $hb += "`n🩺 **Subscriptions needing attention:** $(($unhealthySubscriptions | ForEach-Object { "$($_.DisplayName) ($($_.CapabilityStatus))" }) -join ', ')`n"
                }

                $hbPayload = @{ message = $hb } | ConvertTo-Json -Depth 3
                try {
                    Invoke-RestMethod -Method Post -Uri $WebhookUrl -Body ([System.Text.Encoding]::UTF8.GetBytes($hbPayload)) -ContentType 'application/json; charset=utf-8' -ErrorAction Stop
                    $heartbeatSent = $true
                    Write-Log -Message "Heartbeat digest sent (no change reported for $([math]::Floor($daysSince)) day(s))." -Level "INFO"
                }
                catch {
                    # Not retried: the next run picks it up anyway, since the timestamp is
                    # only advanced on success.
                    Write-Log -Message "Heartbeat send failed: $($_.Exception.Message)" -Level "WARN"
                }
            }
        }

        # Advance the cache once the change has been delivered. If the webhook failed, the
        # previous state is deliberately kept so the next run re-detects the change and
        # reports it again - otherwise a single failed POST would silence it forever.
        # Counts that moved without warranting an alert still refresh the cache: leaving it
        # stale would make the next alert-eligible change report a false jump.
        if ($stateChanged -and $notificationDelivered) {
            try {
                $currentJson | Out-File -FilePath $jsonPath -Encoding UTF8 -ErrorAction Stop
                Write-Log -Message "Updated license status written to cache (schema $cacheSchemaVersion, $(@($currentStatus).Count) SKU(s))." -Level "INFO"
            }
            catch {
                Write-Log -Message "Failed to write the state cache: $($_.Exception.Message)" -Level "ERROR"
            }
        }
        elseif ($stateChanged) {
            Write-Log -Message "Cache NOT updated: the notification was not delivered. The change will be reported again on the next run." -Level "WARN"
        }

        # Run state. LastNotificationUtc only advances on a delivered message, so a failed
        # send leaves the heartbeat due rather than silently consuming it.
        $lastNotificationUtc = if ($notificationDelivered -and $notificationWarranted) {
            (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        }
        elseif ($heartbeatSent) {
            (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        }
        elseif ($runState -and $runState.LastNotificationUtc) { [string]$runState.LastNotificationUtc }
        else { $null }

        try {
            [PSCustomObject]@{
                LastRunUtc          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
                LastNotificationUtc = $lastNotificationUtc
                Version             = '1.9.5'
                MonitoredSkus       = @($currentStatus).Count
                AlertingSkus        = @($licensesToNotify).Count
                ReportPublished     = $reportPublished
            } | ConvertTo-Json -Depth 3 | Out-File -FilePath $runStatePath -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-Log -Message "Failed to write the run-state file: $($_.Exception.Message)" -Level "WARN"
        }
    }
    catch {
        Write-Log -Message "Error occurred: $_" -Level "ERROR"
        throw
    }
    finally {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
}
