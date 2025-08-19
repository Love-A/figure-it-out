<#
    .SYNOPSIS
    Phased-like rollout for Configuration Manager Applications: once a deployment's success
    threshold is reached, include the next device collection(s) into a master collection so
    the same deployment expands without creating new deployments.

    .DESCRIPTION
    Monitors a single Application deployment that targets a "master" device collection.
    When a success/compliance threshold is met (configurable), the function adds Include
    Membership Rules for the next eligible device collection(s) that match given name
    patterns. Eligibility excludes already-included collections and optionally anything
    matched by ID or wildcarded name exclusions. Time windows can be enforced (allowed
    days/hours, optional TimeZone). Returns a detailed report object.

    .PARAMETER SiteCode
    Site code, e.g., "A01".

    .PARAMETER ProviderMachineName
    SMS Provider FQDN, e.g., "mecm01.example.local".

    .PARAMETER MasterCollectionID
    CollectionID of the master device collection, e.g., "P010025C" (8 alphanumerics).

    .PARAMETER AssignmentID
    Numeric AssignmentID of the deployment (as shown by Get-CMDeployment), e.g., 16778519.

    .PARAMETER MinPercentageForNextPhase
    Integer 1–100: when success percent >= this value, include next wave collections.

    .PARAMETER PhaseCollectionNames
    One or more exact or wildcard names for *device* collections, e.g., "Wave-0*-*".

    .PARAMETER MaxCollectionsPerRun
    Include up to this many eligible collections in one run (default 1).

    .PARAMETER SuccessCounter
    How to compute "success" percent.
    - Auto (default): prefers NumberCompliant (if present), else NumberInstalled, else NumberSuccess.
    - Success: use NumberSuccess.
    - Compliant: use NumberCompliant.
    - Installed: use NumberInstalled.

    .PARAMETER ExcludeCollectionIDs
    One or more CollectionIDs to exclude from consideration.

    .PARAMETER ExcludeCollectionNames
    One or more wildcard name patterns to exclude (e.g., "Wave-*-Canary", "Skip-*").

    .PARAMETER AllowedDaysOfWeek
    Allowed days (English names): Monday..Sunday. If omitted, all days allowed.

    .PARAMETER AllowedStartHour
    Start hour (0-23) of allowed window; default 0. Used with AllowedEndHour.

    .PARAMETER AllowedEndHour
    End hour (0-23) of allowed window; default 23. Supports windows that pass midnight (22..4).

    .PARAMETER TimeZoneId
    Optional Windows Time Zone Id (e.g., "W. Europe Standard Time"). If omitted, server local time is used.

    .PARAMETER UseMemberCountWhenZero
    If set, and the deployment summary shows NumberTargeted=0, use the CURRENT member count of the master collection
    as the denominator (useful when summaries are stale).

    .PARAMETER SummaryStalenessMinutes
    Consider summaries older than this many minutes as "stale" (default 60). When stale and NumberTargeted=0,
    the function also uses the current member count of the master as denominator.

    .EXAMPLE
    Invoke-NextPhaseDeployment -SiteCode "A01" -ProviderMachineName "mecm01.example.local" -MasterCollectionID "P010025C" -AssignmentID 16778519 -MinPercentageForNextPhase 90 -PhaseCollectionNames "Wave-0*-*" -SuccessCounter Installed -WhatIf

    .EXAMPLE
    Invoke-NextPhaseDeployment -SiteCode "A01" -ProviderMachineName "mecm01.example.local" -MasterCollectionID "P010025C" -AssignmentID 16778519 -MinPercentageForNextPhase 85 -PhaseCollectionNames "Wave-*" -UseMemberCountWhenZero -SummaryStalenessMinutes 30

    .NOTES
    File Name : Invoke-NextPhaseDeployment.ps1
    Author    : Love A
    Created   : 2025-08-19
    .VERSION
        2025-08-19 - 2.7 - Added UseMemberCountWhenZero & SummaryStalenessMinutes; improved deployment resolution notes; PS 5.1 compatible.
        2025-08-19 - 2.6 - Robust device collection check via Get-CMDeviceCollection; logs now write to user/SYSTEM temp.
        2025-08-19 - 2.5 - Switched primary deployment lookup to AssignmentID.
        2025-08-19 - 2.4 - Relaxed CollectionID validation to ^[A-Za-z0-9]{8}$.
        2025-08-19 - 2.3 - PS 5.1 compatibility fixes (no ternary / if-expression).
        2025-08-18 - 2.1 - Hard target verification; SuccessCounter; exclusions; time windows; report object; examples.
        2025-08-18 - 2.0 - Standards-compliant help/logging, numeric % math, sorting, WhatIf/Confirm, error handling, safer interpolation.
        2022-01-01 - 1.0 - Initial script to include collections when threshold met.
#>

# ---------------------------
# Logging
# ---------------------------
function Write-Log {
    param (
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$LogFile = "$PSScriptRoot\Invoke-NextPhaseDeployment.log",
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $logMessage
    Write-Output $logMessage
}

function Invoke-NextPhaseDeployment {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9]{3}$')][string]$SiteCode,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ProviderMachineName,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9]{8}$')][string]$MasterCollectionID,
        [Parameter(Mandatory = $true)][ValidateRange(1,2147483647)][int]$AssignmentID,
        [Parameter(Mandatory = $true)][ValidateRange(1,100)][int]$MinPercentageForNextPhase,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$PhaseCollectionNames,
        [ValidateRange(1,50)][int]$MaxCollectionsPerRun = 1,
        [ValidateSet('Auto','Success','Compliant','Installed')][string]$SuccessCounter = 'Auto',
        [string[]]$ExcludeCollectionIDs,
        [string[]]$ExcludeCollectionNames,
        [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')][string[]]$AllowedDaysOfWeek,
        [ValidateRange(0,23)][int]$AllowedStartHour = 0,
        [ValidateRange(0,23)][int]$AllowedEndHour = 23,
        [string]$TimeZoneId,
        [switch]$UseMemberCountWhenZero,
        [ValidateRange(1,1440)][int]$SummaryStalenessMinutes = 60
    )

    begin {
        # Always log to session temp (user or SYSTEM)
        $logRoot = [System.IO.Path]::GetTempPath()
        $logFile = Join-Path $logRoot ("Invoke-NextPhaseDeployment-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
        Write-Log -LogFile $logFile -Message "Logging to $logFile"

        # Import Configuration Manager module
        try {
            if (-not (Get-Module -Name ConfigurationManager -ListAvailable)) {
                $uiPath = $env:SMS_ADMIN_UI_PATH
                if ($uiPath) {
                    $cmPs = Join-Path -Path (Split-Path -Path $uiPath) -ChildPath "ConfigurationManager.psd1"
                    Import-Module $cmPs -ErrorAction Stop
                } else {
                    Import-Module ConfigurationManager -ErrorAction Stop
                }
            } else {
                Import-Module ConfigurationManager -ErrorAction Stop
            }
            Write-Log -LogFile $logFile -Message "ConfigurationManager module imported."
        } catch {
            Write-Log -LogFile $logFile -Level ERROR -Message "Failed to import ConfigurationManager module. $($_.Exception.Message)"
            throw
        }

        # Connect CMSite drive if needed
        try {
            if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName -ErrorAction Stop | Out-Null
                Write-Log -LogFile $logFile -Message "CMSite drive ${SiteCode}: created to provider ${ProviderMachineName}."
            }
            Set-Location "${SiteCode}:" -ErrorAction Stop
            Write-Log -LogFile $logFile -Message "Location set to ${SiteCode}:"
        } catch {
            Write-Log -LogFile $logFile -Level ERROR -Message "Failed to connect/set CMSite drive. $($_.Exception.Message)"
            throw
        }
    }

    process {
        function Get-Now {
            param([string]$TzId)
            if ([string]::IsNullOrWhiteSpace($TzId)) { return Get-Date }
            try {
                $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($TzId)
                return [System.TimeZoneInfo]::ConvertTime([datetime]::UtcNow, $tz)
            } catch {
                Write-Log -LogFile $logFile -Level WARN -Message "Invalid TimeZoneId '$TzId'. Using local time."
                return Get-Date
            }
        }

        function Is-WithinWindow {
            param([datetime]$Now,[string[]]$Days,[int]$StartHour,[int]$EndHour)
            $dayOk = $true
            if ($Days -and $Days.Count -gt 0) { $dayOk = $Days -contains $Now.DayOfWeek.ToString() }
            $h = $Now.Hour
            if ($StartHour -le $EndHour) { $hourOk = ($h -ge $StartHour -and $h -le $EndHour) }
            else { $hourOk = ($h -ge $StartHour -or $h -le $EndHour) }
            return ($dayOk -and $hourOk)
        }

        function Get-PropertyIfExists {
            param([object]$Obj,[string]$PropName)
            if ($null -ne $Obj -and $Obj.PSObject -and ($Obj.PSObject.Properties.Name -contains $PropName)) {
                return $Obj.$PropName
            } else {
                return $null
            }
        }

        function Name-MatchesAny {
            param([string]$Name,[string[]]$Patterns)
            if (-not $Patterns -or $Patterns.Count -eq 0) { return $false }
            foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
            return $false
        }

        $now = Get-Now -TzId $TimeZoneId
        $withinWindow = Is-WithinWindow -Now $now -Days $AllowedDaysOfWeek -StartHour $AllowedStartHour -EndHour $AllowedEndHour

        # Base report object
        $report = [pscustomobject]@{
            Status='Unknown'; TimestampLocal=$now; TimestampUtc=[datetime]::UtcNow
            SiteCode=$SiteCode; ProviderMachineName=$ProviderMachineName
            MasterCollectionID=$MasterCollectionID; AssignmentID=$AssignmentID; DeploymentID=$null
            SuccessMetricUsed=$null; SuccessPercent=$null; SuccessCount=$null; TargetedCount=$null
            ThresholdPercent=$MinPercentageForNextPhase
            AllowedDaysOfWeek=$AllowedDaysOfWeek; AllowedStartHour=$AllowedStartHour; AllowedEndHour=$AllowedEndHour; TimeZoneId=$TimeZoneId; WithinWindow=$withinWindow
            PlannedToInclude=@(); IncludedCollections=@(); RemainingEligibleCount=$null; Notes=@()
        }

        try {
            if (-not $withinWindow) {
                $report.Status='OutsideWindow'; $report.Notes+='Current time is outside the allowed window.'
                Write-Log -LogFile $logFile -Message "Outside allowed time window; skipping."
                return $report
            }

            # Validate master device collection
            $master = Get-CMDeviceCollection -Id $MasterCollectionID -ErrorAction SilentlyContinue
            if (-not $master) {
                $maybe = Get-CMCollection -CollectionId $MasterCollectionID -ErrorAction SilentlyContinue
                $ct = $null; if ($maybe) { $ct = $maybe.CollectionType }
                Write-Log -LogFile $logFile -Level ERROR -Message "MasterCollectionID '$MasterCollectionID' not recognized as DEVICE. Observed CollectionType='$ct'."
                throw "MasterCollectionID '$MasterCollectionID' is not a Device collection (or not found)."
            }

            # Resolve deployment by AssignmentID with layered fallbacks
            $deployment = $null; $pathUsed = $null
            try {
                $deployment = Get-CMDeployment -CollectionId $MasterCollectionID -ErrorAction Stop | Where-Object { $_.AssignmentID -eq $AssignmentID }
                if ($deployment) { $pathUsed = "Get-CMDeployment -CollectionId + filter" }
            } catch {
                Write-Log -LogFile $logFile -Level WARN -Message "Get-CMDeployment -CollectionId not supported; trying full fetch."
            }
            if (-not $deployment) {
                try {
                    $deployment = Get-CMDeployment -ErrorAction Stop | Where-Object { $_.AssignmentID -eq $AssignmentID -and $_.CollectionID -eq $MasterCollectionID }
                    if ($deployment) { $pathUsed = "Get-CMDeployment (all) + filter" }
                } catch {
                    Write-Log -LogFile $logFile -Level WARN -Message "Get-CMDeployment failed; trying WMI fallback."
                }
            }
            if (-not $deployment) {
                $ns = "root\sms\site_$SiteCode"
                $filter = "AssignmentID=$AssignmentID and CollectionID='$MasterCollectionID'"
                try {
                    $deployment = Get-CimInstance -ComputerName $ProviderMachineName -Namespace $ns -ClassName SMS_DeploymentSummary -Filter $filter -ErrorAction Stop
                    if ($deployment) { $pathUsed = "WMI SMS_DeploymentSummary" }
                } catch {
                    Write-Log -LogFile $logFile -Level ERROR -Message "WMI fallback failed: $($_.Exception.Message)"
                }
            }
            if (-not $deployment) { throw "No deployment with AssignmentID '$AssignmentID' targeting master '$MasterCollectionID' was found." }
            if ($deployment -is [System.Array] -and $deployment.Count -gt 1) { throw "Multiple deployments matched AssignmentID '$AssignmentID' for master '$MasterCollectionID'. Please disambiguate." }
            Write-Log -LogFile $logFile -Message "Deployment resolved via: $pathUsed"

            # Defensive: verify target is master when available
            $depCollectionId = Get-PropertyIfExists -Obj $deployment -PropName 'CollectionID'
            if ($depCollectionId -and $depCollectionId -ne $MasterCollectionID) {
                $msg = "Deployment with AssignmentID '$AssignmentID' targets '$depCollectionId', not master '$MasterCollectionID'. Aborting."
                Write-Log -LogFile $logFile -Level ERROR -Message $msg
                $report.Status = 'AbortedMismatch'; $report.Notes += $msg
                return $report
            }
            $report.DeploymentID = Get-PropertyIfExists -Obj $deployment -PropName 'DeploymentID'

            # ---- Success metric & denominator (with stale-summary workaround) ----
            $sumTime = Get-PropertyIfExists -Obj $deployment -PropName 'SummarizationTime'
            if ($sumTime) { $report.Notes += ("SummarizationTime: {0}" -f $sumTime) }
            $numTargeted = [int](Get-PropertyIfExists -Obj $deployment -PropName 'NumberTargeted')

            $shouldUseMemberCount = $false
            if ($numTargeted -le 0) {
                $isStale = $false
                if ($sumTime) {
                    try {
                        $minutesOld = ((Get-Date) - [datetime]$sumTime).TotalMinutes
                        if ($minutesOld -ge $SummaryStalenessMinutes) { $isStale = $true }
                        $report.Notes += ("Summary age: {0:N0} minutes" -f $minutesOld)
                    } catch { }
                }
                if ($UseMemberCountWhenZero -or $isStale) { $shouldUseMemberCount = $true }
            }
            if ($shouldUseMemberCount) {
                $memberCount = (Get-CMCollectionMember -CollectionId $MasterCollectionID -ErrorAction SilentlyContinue | Measure-Object).Count
                if ($memberCount -gt 0) {
                    $report.Notes += "NumberTargeted=0 but master has members; using current member count as denominator."
                    $numTargeted = [int]$memberCount
                }
            }

            if ($numTargeted -le 0) {
                $report.Status='NoTargeted'; $report.TargetedCount=0
                $report.Notes += "Deployment has zero targeted clients per summary and no member-count workaround applied."
                Write-Log -LogFile $logFile -Level WARN -Message "Deployment has zero targeted clients; aborting."
                return $report
            }
            $report.TargetedCount = $numTargeted

            # Success metric value
            $metricName = $SuccessCounter; $numSuccess = $null
            switch ($SuccessCounter) {
                'Success'   { $numSuccess = [int](Get-PropertyIfExists -Obj $deployment -PropName 'NumberSuccess') }
                'Compliant' { $numSuccess = [int](Get-PropertyIfExists -Obj $deployment -PropName 'NumberCompliant') }
                'Installed' { $numSuccess = [int](Get-PropertyIfExists -Obj $deployment -PropName 'NumberInstalled') }
                'Auto' {
                    $numSuccess = [int](Get-PropertyIfExists -Obj $deployment -PropName 'NumberCompliant')
                    if (-not $numSuccess) {
                        $numSuccess = [int](Get-PropertyIfExists -Obj $deployment -PropName 'NumberInstalled')
                        if (-not $numSuccess) { $numSuccess = [int](Get-PropertyIfExists -Obj $deployment -PropName 'NumberSuccess'); $metricName='Success' }
                        else { $metricName='Installed' }
                    } else { $metricName='Compliant' }
                }
            }
            if (-not $numSuccess -and $numSuccess -ne 0) {
                $numSuccess = [int](Get-PropertyIfExists -Obj $deployment -PropName 'NumberSuccess'); $metricName='Success'
                $report.Notes += "Chosen metric not available; fell back to NumberSuccess."
            }

            $pct = [math]::Round(($numSuccess / $numTargeted) * 100, 2)
            $report.SuccessMetricUsed=$metricName; $report.SuccessPercent=$pct; $report.SuccessCount=$numSuccess
            Write-Log -LogFile $logFile -Message "Deployment (AssignmentID $AssignmentID): $numSuccess of $numTargeted ($pct%) using '$metricName'. Threshold: $MinPercentageForNextPhase%."

            if ($pct -lt $MinPercentageForNextPhase) {
                $report.Status='BelowThreshold'; $report.Notes += "Success percent below threshold; no changes made."
                Write-Log -LogFile $logFile -Message "STOP - Below threshold."
                return $report
            }

            # Candidate device collections
            $phaseCollections = @()
            foreach ($pattern in $PhaseCollectionNames) {
                $phaseCollections += (Get-CMCollection -CollectionType Device -Name $pattern -ErrorAction SilentlyContinue)
            }
            $phaseCollections = $phaseCollections | Where-Object { $_ -and $_.CollectionID -ne $MasterCollectionID } | Sort-Object Name -Unique
            if (-not $phaseCollections) {
                $report.Status='NoMatch'; $report.Notes += "No device collections matched provided patterns."
                Write-Log -LogFile $logFile -Level WARN -Message "No matching phase collections."
                return $report
            }

            # Already-included Include rules
            $alreadyIncludedIds = @()
            $includeRules = Get-CMCollectionIncludeMembershipRule -CollectionId $MasterCollectionID -ErrorAction SilentlyContinue
            if ($includeRules) {
                foreach ($r in $includeRules) {
                    if ($r.PSObject.Properties.Name -contains 'IncludeCollectionID') { $alreadyIncludedIds += $r.IncludeCollectionID }
                    elseif ($r.PSObject.Properties.Name -contains 'IncludeCollectionId') { $alreadyIncludedIds += $r.IncludeCollectionId }
                }
            }

            # Filter eligible waves
            $eligible = $phaseCollections | Where-Object {
                ($alreadyIncludedIds -notcontains $_.CollectionID) -and
                (-not $ExcludeCollectionIDs -or ($ExcludeCollectionIDs -notcontains $_.CollectionID)) -and
                (-not (Name-MatchesAny -Name $_.Name -Patterns $ExcludeCollectionNames))
            }
            if (-not $eligible) {
                $report.Status='NoCandidates'; $report.RemainingEligibleCount=0
                $report.Notes += "All matching collections are already included or excluded."
                Write-Log -LogFile $logFile -Message "No eligible collections remain."
                return $report
            }

            $toInclude = $eligible | Select-Object -First $MaxCollectionsPerRun
            $report.PlannedToInclude = $toInclude | ForEach-Object { [pscustomobject]@{ Name=$_.Name; CollectionID=$_.CollectionID } }
            $report.RemainingEligibleCount = ($eligible | Measure-Object).Count

            $listForLog = ($toInclude | ForEach-Object { "$($_.Name) [$($_.CollectionID)]" }) -join ', '
            Write-Log -LogFile $logFile -Message "GO - Will include (max $MaxCollectionsPerRun): $listForLog"

            foreach ($col in $toInclude) {
                $targetDesc = "$($col.Name) [$($col.CollectionID)] into master [$MasterCollectionID]"
                if ($PSCmdlet.ShouldProcess($targetDesc, "Add-CMDeviceCollectionIncludeMembershipRule")) {
                    Add-CMDeviceCollectionIncludeMembershipRule -CollectionId $MasterCollectionID -IncludeCollectionId $col.CollectionID -ErrorAction Stop | Out-Null
                    Write-Log -LogFile $logFile -Message "$($col.Name) [$($col.CollectionID)] added to master [$MasterCollectionID]."
                    $report.IncludedCollections += ,([pscustomobject]@{ Name=$col.Name; CollectionID=$col.CollectionID })
                }
            }

            if ($report.IncludedCollections.Count -gt 0) { $report.Status='Included' } else { $report.Status='PlannedOnly' }
            return $report

        } catch {
            $msg = $_.Exception.Message
            Write-Log -LogFile $logFile -Level ERROR -Message $msg
            $report.Status='Error'; $report.Notes += $msg
            return $report
        } finally {
            Write-Log -LogFile $logFile -Message "Completed execution."
        }
    }
}
