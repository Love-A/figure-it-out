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
    Optional switch. If set, simulates a change to test notification flow.

.EXAMPLE
    Get-AzureLicenseStatus -WebhookUrl "https://..." -NotifySku "SPE_E5","VISIOCLIENT" -AppId "your-app-id" -TenantId "your-tenant-id" -Thumbprint "your-cert-thumbprint" -htmlPath ""\\UNCPATH\Directory\licensereport.html

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
#>

function Get-AzureLicenseStatus {
    [CmdletBinding()]
    param (
        [string]$WebhookUrl,
        [string[]]$NotifySku,
        [switch]$TestMode,
        [string]$AppId,
        [string]$TenantId,
        [string]$htmlPath,
        [string]$Thumbprint
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
        Connect-MgGraph -TenantId $tenantid -AppId $appid -CertificateThumbprint $thumbprint
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
    "WINDOWS_STORE"="Microsoft Store Access"
    "VISIOCLIENT_FACULTY"="Visio Plan 2 (faculty)"
    "VISIOCLIENT"="Visio Plan 2"
    "STREAM"="Microsoft Stream"
    "ENTERPRISEPREMIUM_FACULTY"="Enterprise Premium (faculty)"
    "ENTERPRISEPACKPLUS_STUDENT"="Microsoft 365 A3 (student)"
    "ENTERPRISEPACKPLUS_FACULTY"="Microsoft 365 A3 (faculty)"
    "DYN365_ENTERPRISE_CUSTOMER_SERVICE"="Dynamics 365 Customer Service Enterprise"
    "AAD_PREMIUM_P2"="Azure AD Premium P2"
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
        $allWarn = $exhausted + $low

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

        if ($TestMode) {
            Write-Log -Message " TestMode is enabled – simulating a license status change." -Level "WARN"
            $hasChanged = $true
            $changeComment = "`n Test mode active – change simulated"
            $changeDetailText = "`n Microsoft 365 E5`n    Assigned: 95 → 96`n    Available: 5 → 4"

           # Force sending a test message to Teams even if no actual license changes have occurred
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
                    foreach ($item in $changedDetails | Sort-Object DisplayName) {
                        $changeDetailText += "`n $($item.DisplayName)`n    $($item.AssignedChange)`n    $($item.AvailableChange)`n"
                    }
                }
            }
        }

        # ========== TEAMS NOTIFICATION ==========
        $licensesToNotify | ForEach-Object {
            Write-Log -Message "Will notify on $_.SkuPartNumber - Available: $($_.AvailableLicenses)" -Level "INFO"
        }
        Write-Log -Message "licensesToNotify.Count = $($licensesToNotify.Count)" -Level "INFO"
        Write-Log -Message "changeDetails.Count = $($changeDetails.Count)" -Level "INFO"
        

        if ($WebhookUrl -and $hasChanged) {
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $uncPath = "$htmlPath"
            $mdLink = "($uncPath)"

            $notificationText  = "## 📢 License Status Change Detected`n"
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
                $notificationText += "| License | Total | Available |`n"
                $notificationText += "|---------|-------|-----------|`n"
                $licensesToNotify | Sort-Object DisplayName | ForEach-Object {
                    $notificationText += "| $($_.DisplayName) | $($_.TotalLicenses) | $($_.AvailableLicenses) |`n"
                }
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
    }
} 
