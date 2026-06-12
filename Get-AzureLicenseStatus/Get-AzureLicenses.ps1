<#
.SYNOPSIS
    Retrieves Microsoft 365 license status and sends Teams notification via webhook.

.DESCRIPTION
    Categorizes license status, exports HTML/CSV reports, caches previous state to JSON,
    and sends Teams notification only on changes. Includes -TestMode for simulating changes.

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

.EXAMPLE
    Get-AzureLicenseStatus -WebhookUrl "https://..." -NotifySku "SPE_E5","VISIOCLIENT" -AppId "your-app-id" -TenantId "your-tenant-id" -Thumbprint "your-cert-thumbprint" -htmlPath "\\UNCPATH\Directory\licensereport.html"

.EXAMPLE
    Simulated test run
    Get-AzureLicenseStatus -WebhookUrl "https://..." -NotifySku "SPE_E5" -AppId "your-app-id" -TenantId "your-tenant-id" -Thumbprint "your-cert-thumbprint" -TestMode

.NOTES
    Author     : Love A
    Updated    : 2025-06-18

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
#>

function Get-AzureLicenseStatus {
    [CmdletBinding()]
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
        [ValidateRange(1, 3650)][int]$InactiveDays = 90
    )

    $foldername = "AzureLicenseAudit"
    $logFile = "$PSScriptRoot\$foldername.log"
    $csvPath = "$PSScriptRoot\$foldername\AzureLicenseSummary.csv"
    $jsonPath = "$PSScriptRoot\$foldername\LastLicenseStatus.json"

    if (-not (Test-Path -Path "$PSScriptRoot\$foldername")) {
        New-Item -ItemType Directory -Path "$PSScriptRoot\$foldername" | Out-Null
    }

    function Write-Log {
        param (
            [Parameter(Mandatory = $true)][string]$Message,
            [string]$LogFile = $logFile,
            [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
        )
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logMessage = "[$timestamp] [$Level] $Message"
        Add-Content -Path $LogFile -Value $logMessage
        Write-Output $logMessage
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
            }
        }

        $friendlyNames = @{
            "WINDOWS_STORE"                               = "Microsoft Store Access"
            "VISIOCLIENT_FACULTY"                         = "Visio Plan 2 (faculty)"
            "VISIOCLIENT"                                 = "Visio Plan 2"
            "VIRTUAL_AGENT_USL"                           = "Virtual Agent USL"
            "STREAM"                                      = "Microsoft Stream"
            "SPZA_IW"                                     = "SharePoint IW"
            "SPE_F5_SEC"                                  = "Microsoft 365 F5 Security"
            "SPE_F1"                                      = "Microsoft 365 F3"
            "SPE_E5"                                      = "Microsoft 365 E5"
            "RIGHTSMANAGEMENT_ADHOC"                      = "Rights Management (ad hoc)"
            "PROJECTPROFESSIONAL"                         = "Project Professional"
            "POWERAPPS_VIRAL"                             = "PowerApps Viral"
            "POWERAPPS_PER_USER"                          = "PowerApps per user"
            "POWERAPPS_DEV"                               = "PowerApps Developer"
            "POWER_BI_STANDARD"                           = "Power BI Standard"
            "POWER_BI_PRO_FACULTY"                        = "Power BI Pro (faculty)"
            "POWER_BI_PRO"                                = "Power BI Pro"
            "Power_Virtual_Agents"                        = "Power Virtual Agents"
            "O365_w/o_Teams_Bundle_M5"                    = "Office 365 without Teams (bundle M5)"
            "MEE_STUDENT"                                 = "Office 365 A1 (student)"
            "MEE_FACULTY"                                 = "Office 365 A1 (faculty)"
            "Microsoft_Teams_Rooms_Pro"                   = "Microsoft Teams Rooms Pro"
            "Microsoft_Teams_EEA_New"                     = "Microsoft Teams (EEA only)"
            "Microsoft_365_Copilot"                       = "Microsoft 365 Copilot"
            "Microsoft_365_A3_Suite_features_for_faculty" = "Microsoft 365 A3 Suite Features (faculty)"
            "MDATP_XPLAT"                                 = "Microsoft Defender for Endpoint (cross-platform)"
            "MDATP_Server"                                = "Microsoft Defender for Endpoint (server)"
            "Microsoft_Defender_for_Endpoint_F2"          = "Microsoft Defender for Endpoint F2"
            "FLOW_FREE"                                   = "Power Automate Free"
            "EXCHANGESTANDARD"                            = "Exchange Standard"
            "ENTERPRISEPREMIUM_FACULTY"                   = "Enterprise Premium (faculty)"
            "ENTERPRISEPACKPLUS_STUDENT"                  = "Microsoft 365 A3 (student)"
            "ENTERPRISEPACKPLUS_FACULTY"                  = "Microsoft 365 A3 (faculty)"
            "EMS"                                         = "Enterprise Mobility + Security"
            "EMSPREMIUM"                                  = "EMS Premium"
            "DYN365_ENTERPRISE_CUSTOMER_SERVICE"          = "Dynamics 365 Customer Service Enterprise"
            "CCIBOTS_PRIVPREV_VIRAL"                      = "CCIBots Preview Viral"
            "AAD_PREMIUM_P2"                              = "Azure AD Premium P2"
            "WIN_DEF_ATP"                                 = "Windows Defender ATP"
            "WIN10_ENT_A5_FAC"                            = "Windows 10 Enterprise A5 (faculty)"
            "WIN10_ENT_A3_STU"                            = "Windows 10 Enterprise A3 (student)"
            "WIN10_ENT_A3_FAC"                            = "Windows 10 Enterprise A3 (faculty)"
            "STANDARDWOFFPACK_STUDENT"                    = "Office Standard (student)"
            "STANDARDWOFFPACK_FACULTY"                    = "Office Standard (faculty)"
            "M365_A5_SUITE_COMPONENTS_FACULTY"            = "Microsoft 365 A5 Components (faculty)"
            "IDENTITY_THREAT_PROTECTION_STUUSEBNFT"       = "ID Protection (student benefit)"
            "IDENTITY_THREAT_PROTECTION_FACULTY"          = "ID Protection (faculty)"
        }

        $summary | ForEach-Object {
            $displayName = $friendlyNames[$_.SkuPartNumber]
            if (-not $displayName) { $displayName = $_.SkuPartNumber }
            $_ | Add-Member -MemberType NoteProperty -Name DisplayName -Value $displayName -Force
        }

        $lowThreshold = 10
        $exhausted = $summary | Where-Object { $_.AvailableLicenses -le 0 }
        $low = $summary | Where-Object { $_.AvailableLicenses -gt 0 -and $_.AvailableLicenses -lt $lowThreshold }
        $healthy = $summary | Where-Object { $_.AvailableLicenses -ge $lowThreshold }
        $allWarn = @($exhausted) + @($low)

        $licensesToNotify = if ($NotifySku) {
            $allWarn | Where-Object {
                $skuName = $_.SkuPartNumber.Trim().ToUpper()
                $skuName -in $NotifySku
            }
        } else {
            $allWarn
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
        # Linear estimate of days until a warned SKU runs out, based on the
        # assignment rate over the last 30 days of trend history.
        $forecastWindowDays = 30
        $forecasts = @{}
        if (Test-Path $trendCsvPath) {
            $windowStart = (Get-Date).AddDays(-$forecastWindowDays)
            $trendData = Import-Csv $trendCsvPath | Where-Object { [datetime]$_.Timestamp -ge $windowStart }
            foreach ($lic in $allWarn) {
                $history = @($trendData | Where-Object { $_.SkuPartNumber -eq $lic.SkuPartNumber } | Sort-Object { [datetime]$_.Timestamp })
                if ($history.Count -lt 2) { continue }
                $spanDays = ([datetime]$history[-1].Timestamp - [datetime]$history[0].Timestamp).TotalDays
                if ($spanDays -lt 1) { continue }
                $ratePerDay = ([int]$history[-1].AssignedLicenses - [int]$history[0].AssignedLicenses) / $spanDays
                if ($ratePerDay -gt 0 -and $lic.AvailableLicenses -gt 0) {
                    $daysLeft = [math]::Ceiling($lic.AvailableLicenses / $ratePerDay)
                    $forecasts[$lic.SkuPartNumber] = $daysLeft
                    Write-Log -Message "Forecast: $($lic.SkuPartNumber) depleted in ~$daysLeft day(s) at current rate." -Level "WARN"
                }
            }
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

            $disabledLicensedUsers = foreach ($user in ($disabledUsers | Where-Object { $_.assignedLicenses.Count -gt 0 })) {
                $userLicenses = foreach ($skuId in $user.assignedLicenses.skuId) {
                    if ($skuIdLookup.ContainsKey([string]$skuId)) { $skuIdLookup[[string]$skuId] } else { $skuId }
                }
                [PSCustomObject]@{
                    DisplayName       = $user.displayName
                    UserPrincipalName = $user.userPrincipalName
                    LicenseCount      = @($userLicenses).Count
                    Licenses          = ($userLicenses | Sort-Object) -join "; "
                }
            }
            $disabledLicensedUsers = @($disabledLicensedUsers)

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
            $uri = "v1.0/users?`$filter=accountEnabled eq true&`$select=displayName,userPrincipalName,assignedLicenses,signInActivity&`$top=999"
            $enabledUsers = @()
            do {
                $result = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
                $enabledUsers += $result.value
                $uri = $result.'@odata.nextLink'
            } while ($uri)

            $inactiveLicensedUsers = foreach ($user in $enabledUsers) {
                if ($user.assignedLicenses.Count -eq 0) { continue }
                $lastSignIn = $user.signInActivity.lastSuccessfulSignInDateTime
                if ($lastSignIn -and ([datetime]$lastSignIn -ge $inactiveCutoff)) { continue }

                $userLicenses = foreach ($skuId in $user.assignedLicenses.skuId) {
                    if ($skuIdLookup.ContainsKey([string]$skuId)) { $skuIdLookup[[string]$skuId] } else { $skuId }
                }
                [PSCustomObject]@{
                    DisplayName       = $user.displayName
                    UserPrincipalName = $user.userPrincipalName
                    LastSuccessfulSignIn = if ($lastSignIn) { ([datetime]$lastSignIn).ToString("yyyy-MM-dd") } else { "Never" }
                    LicenseCount      = @($userLicenses).Count
                    Licenses          = ($userLicenses | Sort-Object) -join "; "
                }
            }
            $inactiveLicensedUsers = @($inactiveLicensedUsers)

            $inactiveLicenseCount = ($inactiveLicensedUsers | Measure-Object LicenseCount -Sum).Sum
            if (-not $inactiveLicenseCount) { $inactiveLicenseCount = 0 }
            Write-Log -Message "Found $($inactiveLicensedUsers.Count) inactive licensed account(s) holding $inactiveLicenseCount license(s)." -Level "INFO"

            $inactiveCsvPath = "$PSScriptRoot\$foldername\InactiveLicensedUsers.csv"
            $inactiveLicensedUsers | Export-Csv -Path $inactiveCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Inactive licensed users exported to InactiveLicensedUsers.csv." -Level "INFO"
        }

        # HTML export
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $htmlContent = @"
<html><head><style>
body { font-family: Arial; } h2 { color: #333; }
table { border-collapse: collapse; width: 100%; margin-bottom: 20px; }
th, td { border: 1px solid #aaa; padding: 8px; text-align: left; }
th { background-color: #eee; }
.exhausted { background-color: #fdd; }
.low { background-color: #fff5cc; }
.healthy { background-color: #dff0d8; }
</style></head><body>
<p><strong>Report time:</strong> $timestamp</p>
"@

        if ($exhausted) {
            $htmlContent += "<h2>❌ Licenses that are exhausted</h2>"
            $htmlContent += ($exhausted | Sort-Object DisplayName | ConvertTo-Html DisplayName, TotalLicenses, AssignedLicenses, AvailableLicenses -Fragment | ForEach-Object { $_ -replace '<tr>', '<tr class="exhausted">' })
        }
        if ($low) {
            $htmlContent += "<h2>⚠️ Licenses with few remaining (&lt;$lowThreshold)</h2>"
            $htmlContent += ($low | Sort-Object DisplayName | ConvertTo-Html DisplayName, TotalLicenses, AssignedLicenses, AvailableLicenses -Fragment | ForEach-Object { $_ -replace '<tr>', '<tr class="low">' })
        }
        if ($healthy) {
            $htmlContent += "<h2>✅ Licenses with sufficient availability</h2>"
            $htmlContent += ($healthy | Sort-Object DisplayName | ConvertTo-Html DisplayName, TotalLicenses, AssignedLicenses, AvailableLicenses -Fragment | ForEach-Object { $_ -replace '<tr>', '<tr class="healthy">' })
        }

        if ($AuditDisabledUsers -and $disabledLicensedUsers.Count -gt 0) {
            $htmlContent += "<h2>♻️ Disabled accounts with licenses ($reclaimableCount reclaimable)</h2>"
            $htmlContent += ($disabledLicensedUsers | Sort-Object DisplayName | ConvertTo-Html DisplayName, UserPrincipalName, LicenseCount, Licenses -Fragment | ForEach-Object { $_ -replace '<tr>', '<tr class="low">' })
        }

        if ($AuditInactiveUsers -and $inactiveLicensedUsers.Count -gt 0) {
            $htmlContent += "<h2>💤 Licensed accounts inactive for $InactiveDays+ days ($inactiveLicenseCount licenses)</h2>"
            $htmlContent += ($inactiveLicensedUsers | Sort-Object LastSuccessfulSignIn | ConvertTo-Html DisplayName, UserPrincipalName, LastSuccessfulSignIn, LicenseCount, Licenses -Fragment | ForEach-Object { $_ -replace '<tr>', '<tr class="low">' })
        }

        $htmlContent += "</body></html>"
        $htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
        Write-Log -Message "License summary exported to AzureLicenseSummary.html." -Level "INFO"

        # ========== JSON CACHING & DIFF =====================
        $currentStatus = $licensesToNotify | Sort-Object SkuPartNumber | ForEach-Object {
            [PSCustomObject]@{
                SkuPartNumber     = $_.SkuPartNumber
                AvailableLicenses = $_.AvailableLicenses
                AssignedLicenses  = $_.AssignedLicenses
            }
        }

        $currentJson = $currentStatus | ConvertTo-Json -Depth 3
        $hasChanged = $true
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

        if (Test-Path $jsonPath) {
            $previousJson = Get-Content $jsonPath -Raw | ConvertFrom-Json
            $currentStatusDict = @{}
            $previousStatusDict = @{}

            foreach ($item in $currentStatus) {
                $currentStatusDict[$item.SkuPartNumber] = @{
                    AvailableLicenses = $item.AvailableLicenses
                    AssignedLicenses  = $item.AssignedLicenses
                }
            }
            foreach ($item in $previousJson) {
                $previousStatusDict[$item.SkuPartNumber] = @{
                    AvailableLicenses = $item.AvailableLicenses
                    AssignedLicenses  = $item.AssignedLicenses
                }
            }

            $newSkus     = $currentStatusDict.Keys  | Where-Object { -not $previousStatusDict.ContainsKey($_) }
            $removedSkus = $previousStatusDict.Keys | Where-Object { -not $currentStatusDict.ContainsKey($_) }
            $changedSkus = @()

            foreach ($sku in $currentStatusDict.Keys) {
                if ($previousStatusDict.ContainsKey($sku)) {
                    $prev = $previousStatusDict[$sku]
                    $curr = $currentStatusDict[$sku]
                    if ($prev.AvailableLicenses -ne $curr.AvailableLicenses -or $prev.AssignedLicenses -ne $curr.AssignedLicenses) {
                        $changedSkus += $sku
                    }
                }
            }

            if ($newSkus.Count -eq 0 -and $removedSkus.Count -eq 0 -and $changedSkus.Count -eq 0) {
                $hasChanged = $false
                Write-Log -Message "License status unchanged. Skipping notification." -Level "INFO"
            } else {
                Write-Log -Message "Changes detected in license status:" -Level "INFO"
                if ($newSkus)     { Write-Log -Message "   New SKUs: $($newSkus -join ', ')" -Level "INFO"; $changeComment += "`n New SKUs monitored: $($newSkus -join ', ')" }
                if ($removedSkus) { Write-Log -Message "   Removed SKUs: $($removedSkus -join ', ')" -Level "INFO"; $changeComment += "`n Removed SKUs: $($removedSkus -join ', ')" }

                if ($changedSkus) {
                    Write-Log -Message "Changed SKUs: $($changedSkus -join ', ')" -Level "INFO"
                $changeDetails = foreach ($sku in $changedSkus) {
                    $prev = $previousStatusDict[$sku]
                    $curr = $currentStatusDict[$sku]
                    $assignedChange  = "$($prev.AssignedLicenses) -> $($curr.AssignedLicenses)"
                    $availableChange = "$($prev.AvailableLicenses) -> $($curr.AvailableLicenses)"
                    $displayName = ($licensesToNotify | Where-Object { $_.SkuPartNumber -eq $sku }).DisplayName
                    if (-not $displayName) { $displayName = $sku }

                    Write-Log -Message "  🔁 $sku - Assigned: $assignedChange, Available: $availableChange" -Level "INFO"
                    [PSCustomObject]@{
                        DisplayName      = $displayName
                        AssignedChange   = $assignedChange
                        AvailableChange  = $availableChange
                    }
                }
                    foreach ($item in $changeDetails | Sort-Object DisplayName) {
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


        if ($WebhookUrl -and $hasChanged) {
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $uncPath = "$htmlPath"
            $mdLink = "($uncPath)"

            $notificationText  = "📢 **License Status Change Detected**`n"
            $notificationText += "`n🕒 **Report triggered:** $timestamp"
            $notificationText += "`n📄 **Full report:** $mdLink"

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
                    $estDays = if ($forecasts.ContainsKey($_.SkuPartNumber)) { "~$($forecasts[$_.SkuPartNumber])" } else { "-" }
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

            try {
                Invoke-RestMethod -Method Post -Uri $WebhookUrl -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -ContentType 'application/json; charset=utf-8'
                Write-Log -Message "Teams notification sent due to license change." -Level "INFO"
            }
            catch {
                Write-Log -Message "Webhook send failed: $($_.Exception.Message)" -Level "ERROR"
            }
        }


        # Always update cache if changes occurred
        if ($hasChanged) {
            $currentJson | Out-File -FilePath $jsonPath -Encoding UTF8
            Write-Log -Message "Updated license status written to cache (outside webhook)." -Level "INFO"
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