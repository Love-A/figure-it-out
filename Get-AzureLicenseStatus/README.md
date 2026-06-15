# Get-AzureLicenseStatus.ps1

A PowerShell function for retrieving Microsoft 365 license status, exporting reports, and sending change-based notifications to Teams via Power Automate. Designed for automated/scheduled use with secure certificate-based app authentication.

---

## 🔧 Features

- Retrieves license data via Microsoft Graph API
- Categorizes licenses into:
  - ✅ Healthy
  - ⚠️ Low (<10 available)
  - ❌ Exhausted (0 available)
- Exports:
  - `AzureLicenseSummary.csv` (CSV)
  - `AzureLicenseSummary.html` (HTML report)
- Sends Teams notifications via Webhook only when license status has changed
- Caches previous license state to JSON (`LastLicenseStatus.json`)
- Supports test/simulation mode via `-TestMode`
- Optional audit of disabled accounts with licenses still assigned (reclaimable licenses) via `-AuditDisabledUsers`
- Optional audit of enabled licensed accounts with no sign-in for N days via `-AuditInactiveUsers` / `-InactiveDays`
- Appends per-run license history to `LicenseTrend.csv` and forecasts estimated days until depletion for low/exhausted SKUs (shown in the Teams notification)
- Styled HTML report (summary cards, status tables with depletion forecast, and a per-license aggregation showing how many disabled/inactive accounts hold each license)
- Bilingual HTML report (`-Language sv`/`en`) — generate one or both

---

## 🚀 Usage

### Basic example:

```powershell
Get-AzureLicenseStatus `
    -WebhookUrl "https://prod-123.westeurope.logic.azure.com:..." `
    -NotifySku "SPE_E5","VISIOCLIENT" `
    -AppId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -Thumbprint "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
```

### Simulated test run:

```powershell
Get-AzureLicenseStatus `
    -WebhookUrl "https://prod-123.westeurope.logic.azure.com:..." `
    -NotifySku "SPE_E5" `
    -AppId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -Thumbprint "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" `
    -TestMode
```

> This will trigger a fake notification with a simulated license change.

---

## 📤 Output

- **CSV:** `./AzureLicenseAudit/AzureLicenseSummary.csv`
- **HTML report:** path given via `-htmlPath`, e.g. `\\server\share\Reports\AzureLicenseSummary.html` (summary cards, status tables with depletion forecast, and per-license aggregation of disabled/inactive holdings)
- **Trend history:** `./AzureLicenseAudit/LicenseTrend.csv` (one row per SKU per run; powers the depletion forecast)
- **Disabled users:** `./AzureLicenseAudit/DisabledLicensedUsers.csv` (only with `-AuditDisabledUsers`)
- **Inactive users:** `./AzureLicenseAudit/InactiveLicensedUsers.csv` (only with `-AuditInactiveUsers`)
- **JSON cache:** `./AzureLicenseAudit/LastLicenseStatus.json`
- **Log file:** `./AzureLicenseAudit.log`

---

## 🧠 Parameters

| Name           | Description                                                                 |
|----------------|-----------------------------------------------------------------------------|
| `WebhookUrl`   | (Optional) Logic App/Power Automate webhook for Teams notifications         |
| `NotifySku`    | (Optional) Array of SKU identifiers (e.g. `"SPE_E5"`) to monitor            |
| `AppId`        | Required. App Registration (Enterprise App) Client ID                       |
| `TenantId`     | Required. Azure AD tenant ID                                                |
| `Thumbprint`   | Required. Certificate thumbprint used for authentication                    |
| `TestMode`     | (Optional) If set, sends a simulated test notification and exits (no diff/cache update) |
| `AuditDisabledUsers` | (Optional) Audits disabled accounts with assigned licenses; adds HTML section, `DisabledLicensedUsers.csv` and a Teams summary line. Requires `User.Read.All` |
| `AuditInactiveUsers` | (Optional) Audits enabled licensed accounts with no successful sign-in for `InactiveDays` days; adds HTML section, `InactiveLicensedUsers.csv` and a Teams summary line. Requires `User.Read.All` + `AuditLog.Read.All` |
| `InactiveDays`       | (Optional) Inactivity threshold in days for `AuditInactiveUsers`. Default: 90 |
| `Language`           | (Optional) HTML report language: `sv` (default) or `en`. Run twice with different `-htmlPath`/`-Language` to produce both. Teams notification and log stay English |

---

## 📄 Requirements

- PowerShell 5.1+ or Core
- Microsoft.Graph module
- Certificate-based App Registration in Azure AD with the following API permissions:
  - `Organization.Read.All`
  - `Directory.Read.All`
  - `User.Read.All` (only if using `-AuditDisabledUsers` or `-AuditInactiveUsers`)
  - `AuditLog.Read.All` (only if using `-AuditInactiveUsers`)

---

## 🔐 Notes on Authentication

The function uses certificate-based authentication (client credentials flow) via:
- `AppId` (Client ID)
- `TenantId` (Directory ID)
- `Thumbprint` (Certificate thumbprint installed in CurrentUser or LocalMachine store)

---

## 🧪 Test Mode

Use `-TestMode` to simulate a license warning scenario. This is useful for testing workflow triggers and Teams presentation without waiting for actual license changes.

It will:
- Force `hasChanged = $true`
- Simulate changes to `SPE_E5`
- Send a test message to Teams (clearly marked)

---

## 📦 License

MIT 

---

## ✍️ Author

**Love A**  
Created: 2025-06-10  
Last updated: 2025-06-18
