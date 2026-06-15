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
    2026-06-15 - 1.7 - Redesigned HTML report (cards, styled tables, charset), added
                       per-license aggregation of disabled/inactive holdings
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

    # Builds a styled HTML table with a proper header row and HTML-encoded values.
    function ConvertTo-StyledTable {
        param (
            [object[]]$Data,
            [string[]]$Columns,
            [hashtable]$Headers,
            [string]$RowClass = "",
            [string]$EmptyText = "Inget att visa."
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
            $uri = "v1.0/users?`$filter=accountEnabled eq true&`$select=displayName,userPrincipalName,assignedLicenses,signInActivity&`$top=999"
            $enabledUsers = @()
            do {
                $result = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
                $enabledUsers += $result.value
                $uri = $result.'@odata.nextLink'
            } while ($uri)

            $inactiveLicenseAgg = @{}
            $inactiveLicensedUsers = foreach ($user in $enabledUsers) {
                if ($user.assignedLicenses.Count -eq 0) { continue }
                $lastSignIn = $user.signInActivity.lastSuccessfulSignInDateTime
                if ($lastSignIn -and ([datetime]$lastSignIn -ge $inactiveCutoff)) { continue }

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

            $inactiveCsvPath = "$PSScriptRoot\$foldername\InactiveLicensedUsers.csv"
            $inactiveLicensedUsers | Export-Csv -Path $inactiveCsvPath -NoTypeInformation -Encoding UTF8
            Write-Log -Message "Inactive licensed users exported to InactiveLicensedUsers.csv." -Level "INFO"
        }

        # ========== HTML EXPORT ==========
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        # --- Summary cards ---
        $cardsHtml = @"
            <div class="card"><div class="card-label">Licens-SKU:er</div><div class="card-value">$(@($summary).Count)</div><div class="card-sub">totalt antal prenumerationer</div></div>
            <div class="card accent-red"><div class="card-label">Slut</div><div class="card-value">$(@($exhausted).Count)</div><div class="card-sub">0 lediga licenser</div></div>
            <div class="card accent-amber"><div class="card-label">Få kvar</div><div class="card-value">$(@($low).Count)</div><div class="card-sub">&lt; $lowThreshold lediga licenser</div></div>
"@
        if ($AuditDisabledUsers) {
            $cardsHtml += @"
            <div class="card accent-blue"><div class="card-label">Återvinningsbara</div><div class="card-value">$reclaimableCount</div><div class="card-sub">licenser på $(@($disabledLicensedUsers).Count) avstängda konton</div></div>
"@
        }
        if ($AuditInactiveUsers) {
            $cardsHtml += @"
            <div class="card accent-blue"><div class="card-label">Inaktiva $InactiveDays+ dgr</div><div class="card-value">$inactiveLicenseCount</div><div class="card-sub">licenser på $(@($inactiveLicensedUsers).Count) konton</div></div>
"@
        }

        # --- License status tables ---
        $statusHtml = ""
        if ($exhausted) {
            $statusHtml += "<h3>❌ Slut</h3>"
            $statusHtml += ConvertTo-StyledTable -Data ($exhausted | Sort-Object DisplayName) -Columns DisplayName,TotalLicenses,AssignedLicenses,AvailableLicenses -Headers @{DisplayName='Licens';TotalLicenses='Totalt';AssignedLicenses='Tilldelade';AvailableLicenses='Lediga'} -RowClass "exhausted"
        }
        if ($low) {
            $lowDisplay = $low | Sort-Object DisplayName | Select-Object DisplayName, TotalLicenses, AssignedLicenses, AvailableLicenses, @{n='Forecast';e={ if ($forecasts.ContainsKey($_.SkuPartNumber)) { "~$($forecasts[$_.SkuPartNumber]) dgr" } else { "–" } }}
            $statusHtml += "<h3>⚠️ Få kvar (&lt; $lowThreshold)</h3>"
            $statusHtml += ConvertTo-StyledTable -Data $lowDisplay -Columns DisplayName,TotalLicenses,AssignedLicenses,AvailableLicenses,Forecast -Headers @{DisplayName='Licens';TotalLicenses='Totalt';AssignedLicenses='Tilldelade';AvailableLicenses='Lediga';Forecast='Prognos (slut om)'} -RowClass "low"
        }
        if ($healthy) {
            $statusHtml += "<h3>✅ God marginal</h3>"
            $statusHtml += ConvertTo-StyledTable -Data ($healthy | Sort-Object DisplayName) -Columns DisplayName,TotalLicenses,AssignedLicenses,AvailableLicenses -Headers @{DisplayName='Licens';TotalLicenses='Totalt';AssignedLicenses='Tilldelade';AvailableLicenses='Lediga'} -RowClass "healthy"
        }

        # --- Disabled accounts section ---
        $disabledHtml = ""
        if ($AuditDisabledUsers -and $disabledLicensedUsers.Count -gt 0) {
            $disabledHtml += "<h2>♻️ Avstängda konton med licenser</h2>"
            $disabledHtml += "<p class='lead'>$reclaimableCount licenser kan återvinnas från $(@($disabledLicensedUsers).Count) avstängda konton.</p>"
            $disabledHtml += "<h3>Licenser som binds upp</h3>"
            $disabledHtml += ConvertTo-StyledTable -Data $disabledLicenseSummary -Columns License,Users -Headers @{License='Licens';Users='Avstängda konton'}
            $disabledHtml += "<h3>Konton</h3>"
            $disabledHtml += ConvertTo-StyledTable -Data ($disabledLicensedUsers | Sort-Object DisplayName) -Columns DisplayName,UserPrincipalName,LicenseCount,Licenses -Headers @{DisplayName='Namn';UserPrincipalName='UPN';LicenseCount='Antal';Licenses='Licenser'}
        }

        # --- Inactive accounts section ---
        $inactiveHtml = ""
        if ($AuditInactiveUsers -and $inactiveLicensedUsers.Count -gt 0) {
            $inactiveHtml += "<h2>💤 Inaktiva licensierade konton ($InactiveDays+ dagar)</h2>"
            $inactiveHtml += "<p class='lead'>$inactiveLicenseCount licenser binds upp av $(@($inactiveLicensedUsers).Count) aktiverade konton som inte loggat in på $InactiveDays+ dagar.</p>"
            $inactiveHtml += "<h3>Licenser som binds upp</h3>"
            $inactiveHtml += ConvertTo-StyledTable -Data $inactiveLicenseSummary -Columns License,Users -Headers @{License='Licens';Users='Inaktiva användare'}
            $inactiveHtml += "<h3>Konton</h3>"
            $inactiveHtml += ConvertTo-StyledTable -Data ($inactiveLicensedUsers | Sort-Object LastSuccessfulSignIn) -Columns DisplayName,UserPrincipalName,LastSuccessfulSignIn,LicenseCount,Licenses -Headers @{DisplayName='Namn';UserPrincipalName='UPN';LastSuccessfulSignIn='Senaste inloggning';LicenseCount='Antal';Licenses='Licenser'}
        }

        $htmlContent = @"
<!DOCTYPE html>
<html lang="sv">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Microsoft 365 – Licensrapport</title>
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
<header><div class="wrap"><h1>Microsoft 365 – Licensrapport</h1><div class="meta">Genererad $timestamp · tröskel för "få kvar": $lowThreshold lediga</div></div></header>
<div class="wrap">
  <div class="cards">
$cardsHtml
  </div>

  <h2>Licensstatus</h2>
$statusHtml
$inactiveHtml
$disabledHtml

  <footer>Genererad via Microsoft Graph API. Prognosen baseras på tilldelningstakten de senaste 30 dagarna och visas endast när historik finns.</footer>
</div>
</body>
</html>
"@

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
