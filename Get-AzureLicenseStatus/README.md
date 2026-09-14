# Get-AzureLicenseStatus.ps1

A PowerShell function for retrieving Microsoft 365 license status, exporting reports, and sending change-based notifications to Teams via Power Automate. Designed for automated/scheduled use with secure certificate-based app authentication.

**Current version: 1.9.5** (2026-09-14) — see [Version history](#-version-history).

---

## 🔧 Features

- Retrieves license data via Microsoft Graph API
- Categorizes licenses into:
  - ✅ Healthy
  - ⚠️ Low (<10 available)
  - ❌ Exhausted (0 available)
- Separates **alert eligibility** from status: unlimited, unused and trial SKUs are classified and reported but never raise alerts — see [Alert eligibility](#-alert-eligibility)
- Exports:
  - `AzureLicenseSummary.csv` (one row per SKU incl. `Status`, `AlertClass` and subscription health)
  - `AzureLicenseSummary.html` (HTML report)
- Sends Teams notifications via Webhook only when something alert-worthy has changed
- Caches previous license state to JSON (`LastLicenseStatus.json`) — **every monitored SKU**, not just the ones in warning
- Distinguishes real state transitions: entered warning, recovered, subscription added/removed, purchased capacity changed
- **Heartbeat digest** when nothing has been reported for a while, so silence does not mean the scheduled task died unnoticed
- **Subscription health**: flags `capabilityStatus` other than `Enabled` and seats in grace period / suspended
- Supports test/simulation mode via `-TestMode`
- Optional audit of disabled accounts with licenses still assigned (reclaimable licenses) via `-AuditDisabledUsers`
- Optional audit of enabled licensed accounts with no sign-in for N days via `-AuditInactiveUsers` / `-InactiveDays`, excluding accounts too new to have been inactive that long
- Appends per-run license history to `LicenseTrend.csv` and forecasts days until depletion with a **least-squares fit over the window**, for every SKU — including ones that look healthy today
- Styled HTML report (summary cards, status tables with depletion forecast, upcoming depletions, subscription health, and a per-license aggregation showing how many disabled/inactive accounts hold each license)
- Bilingual HTML report (`-Language sv`/`en`) — generate one or both
- Webhook URL can live in a gitignored `.webhook` file instead of the scheduled task's arguments
- SKU display names live in `skunames.json` beside the script, not in code — see [Data files](#-data-files)
- Self-maintaining: log rotation and trend-history retention keep the output folder bounded

---

## 🚀 Usage

### Basic example:

```powershell
Get-AzureLicenseStatus `
    -AppId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -Thumbprint "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" `
    -htmlPath "\\server\share\Reports\AzureLicenseSummary.html" `
    -WebhookUrl "https://prod-123.westeurope.logic.azure.com:..." `
    -NotifySku "SPE_E5","VISIOCLIENT"
```

`-AppId`, `-TenantId`, `-Thumbprint` and `-htmlPath` are **mandatory** — omitting any of them makes PowerShell prompt, which will hang a scheduled task.

### Simulated test run:

```powershell
Get-AzureLicenseStatus `
    -AppId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -Thumbprint "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" `
    -htmlPath "\\server\share\Reports\AzureLicenseSummary.html" `
    -WebhookUrl "https://prod-123.westeurope.logic.azure.com:..." `
    -NotifySku "SPE_E5" `
    -TestMode
```

> This will trigger a fake notification with a simulated license change.

---

## 📤 Output

- **CSV:** `./AzureLicenseAudit/AzureLicenseSummary.csv` — columns `SkuPartNumber, TotalLicenses, AssignedLicenses, AvailableLicenses, CapabilityStatus, WarningUnits, SuspendedUnits, DisplayName, Status, AlertClass`
- **HTML report:** published to the path given via `-htmlPath`, e.g. `\\server\share\Reports\AzureLicenseSummary.html`
- **Local HTML copy:** `./AzureLicenseAudit/<same filename as -htmlPath>` — always written, so the report survives a file-share outage
- **Trend history:** `./AzureLicenseAudit/LicenseTrend.csv` (one row per SKU per run; powers the depletion forecast, pruned by `-TrendRetentionDays`)
- **Disabled users:** `./AzureLicenseAudit/DisabledLicensedUsers.csv` (only with `-AuditDisabledUsers`)
- **Inactive users:** `./AzureLicenseAudit/InactiveLicensedUsers.csv` (only with `-AuditInactiveUsers`)
- **JSON cache:** `./AzureLicenseAudit/LastLicenseStatus.json` (schema 2 — see [Change detection](#-change-detection))
- **Run state:** `./AzureLicenseAudit/LastRun.json` — last run, last delivered notification, SKU counts. Powers the heartbeat and is the quickest way to see whether the task is still running
- **Log file:** `./AzureLicenseAudit.log`, rotated to `./AzureLicenseAudit.<yyyyMMdd-HHmmss>.log`
- **Webhook (optional input):** `./.webhook` — gitignored, first non-blank non-`#` line is used
- **SKU names (optional input):** `./skunames.json` — your own, gitignored; start from `skunames.example.json`, see [Data files](#-data-files)

---

## 📁 Data files

Two optional files live **next to the script**, not in the output folder. Both are loaded through the same helper, and **both degrade instead of failing** — a scheduled task must not die because a file was forgotten when the folder was copied to the server.

| File | Committed? | Purpose | If missing |
|------|-----------|---------|------------|
| `skunames.json` | No (gitignored) | Maps `skuPartNumber` → display name | Every SKU renders as its raw part number, logged as `WARN` |
| `.webhook` | No (gitignored) | Teams webhook URL | Reports are still written, no notifications sent |

### `skunames.json`

```json
{
  "_comment": "Keys starting with _ are ignored.",
  "SPE_E5": "Microsoft 365 E5",
  "VISIOCLIENT": "Visio Plan 2"
}
```

Copy `skunames.example.json` to `skunames.json` and fill in the SKUs your tenant actually owns. The file is gitignored, because the list of subscriptions an organisation holds is its own inventory rather than a general product-name reference — which is precisely why this stopped being a hashtable inside the script in 1.9.5.

**SKUs missing from the file are logged every run**, so you do not have to compile the list up front: run it once and the log names every SKU it could not resolve. The same mechanism catches drift later — without it, a newly purchased subscription simply renders as `MICROSOFT_365_SOMETHING_F3` in the report and nobody notices.

Canonical product names are published by Microsoft under *Product names and service plan identifiers for licensing*.

> Localization strings and the report CSS deliberately stay in the script. The strings are coupled to their call sites through `{0}`/`{1}` format placeholders, so a typo in a JSON file would be a runtime break with nothing to catch it — and unlike names there is no graceful degradation, since a missing strings file means no report at all. The CSS has to be inlined into the standalone HTML anyway, so extracting it would add a failure mode for no deployment benefit.

---

## 🧠 Parameters

| Name | Required | Default | Description |
|------|----------|---------|-------------|
| `AppId` | **Yes** | – | App Registration (Enterprise App) Client ID |
| `TenantId` | **Yes** | – | Entra ID tenant (directory) ID |
| `Thumbprint` | **Yes** | – | Thumbprint of the authentication certificate. Must be readable by the account running the script — for a SYSTEM scheduled task that means `Cert:\LocalMachine\My` |
| `htmlPath` | **Yes** | – | Full path (local or UNC) where the HTML report is published |
| `WebhookUrl` | No | `.webhook` file | Logic App/Power Automate webhook for Teams notifications. If omitted, a `.webhook` file next to the script is used. Without either, the script only writes reports |
| `NotifySku` | No | all SKUs | Array of SKU identifiers (e.g. `"SPE_E5"`) to monitor. Narrows the cache, the diff and the notification — **not** the HTML report, which always covers the whole tenant |
| `TestMode` | No | off | Sends a simulated test notification and exits (no diff, no cache update) |
| `AuditDisabledUsers` | No | off | Audits disabled accounts with assigned licenses; adds an HTML section, `DisabledLicensedUsers.csv` and a Teams summary line. Requires `User.Read.All` |
| `AuditInactiveUsers` | No | off | Audits enabled licensed accounts with no successful sign-in for `InactiveDays` days; adds an HTML section, `InactiveLicensedUsers.csv` and a Teams summary line. Requires `User.Read.All` + `AuditLog.Read.All` |
| `InactiveDays` | No | `90` | Inactivity threshold in days for `AuditInactiveUsers` |
| `Language` | No | `sv` | HTML report language: `sv` or `en`. Run twice with different `-htmlPath`/`-Language` to produce both. Teams notification and log stay English |
| `TrendRetentionDays` | No | `400` | Days of history kept in `LicenseTrend.csv`. Older rows are pruned each run. `0` disables pruning |
| `MaxLogSizeMB` | No | `5` | Archive and restart the log once it exceeds this size. `0` disables rotation |
| `LogHistoryCount` | No | `5` | Number of archived log files to keep |
| `UnlimitedSeatThreshold` | No | `10000` | At or above this many purchased seats a SKU counts as free/unlimited and never alerts |
| `MinSeatsForAlert` | No | `5` | Below this many purchased seats a SKU counts as a trial and never alerts |
| `HeartbeatDays` | No | `7` | Send a heartbeat digest if nothing has been reported for this many days. `0` disables |
| `ForecastMinPoints` | No | `5` | Minimum trend samples before a forecast is produced |
| `ForecastMinSpanDays` | No | `7` | Minimum days the samples must span before a forecast is produced |
| `ForecastWarnDays` | No | `60` | SKUs forecast to deplete within this many days are highlighted, healthy ones included |
| `ForecastWindowDays` | No | `30` | How far back in `LicenseTrend.csv` the forecast looks |
| `WebhookRetryCount` | No | `3` | Attempts when posting to the webhook, with increasing backoff |

---

## 🚦 Alert eligibility

Status (`Healthy`/`Low`/`Exhausted`) says how much headroom a SKU has. **Alert class** says whether anyone should be woken up about it. They are separate on purpose, and alert class is recomputed every run rather than cached.

| Alert class | Rule | Alerts? |
|-------------|------|---------|
| `Unlimited` | ≥ `UnlimitedSeatThreshold` purchased seats | No — free/viral SKUs have no meaningful capacity |
| `Unused` | 0 assigned licenses | No — nothing is being consumed, so nothing can run out. This is waste, not risk |
| `Trial` | < `MinSeatsForAlert` purchased seats | No — a fully consumed 1-seat evaluation SKU is not an incident |
| `InUse` | everything else | Yes |

Non-alerting SKUs are still classified, still exported, still shown in the HTML report, and still tracked in the cache and the trend file. They simply do not produce Teams messages. On a typical tenant this removes most of the alerting noise, because 1-seat evaluation SKUs and never-assigned subscriptions are exactly the ones that sit permanently at `0 available`.

> **This does not yet surface the opposite problem.** The low threshold is a fixed number of available licenses regardless of SKU size, so a several-thousand-seat SKU with a couple of dozen free still classifies as ✅ Healthy while sitting at roughly 1 % headroom. Making the threshold relative changes `Status` values and therefore the cache schema, so it is deliberately held for 2.0.

---

## 🔍 Change detection

Each run classifies every SKU as `Healthy`, `Low` or `Exhausted`, and stores that state for **all monitored SKUs** in `LastLicenseStatus.json` (schema 2). The next run compares against it.

**A Teams notification is sent when:**

| Event | Example message |
|-------|-----------------|
| A SKU entered warning (`Healthy` → `Low`/`Exhausted`) | 🔻 Entered warning: Microsoft 365 E5 (low, 8 available) |
| A SKU recovered (`Low`/`Exhausted` → `Healthy`) | ✅ Recovered: Visio Plan 2 (41 available) |
| A subscription appeared in the tenant | 🆕 New subscriptions in tenant: Microsoft 365 Copilot |
| A subscription disappeared from the tenant | 🗑️ Subscriptions no longer present: Retired Thing |
| Purchased capacity changed | 📦 Purchased capacity changed: Microsoft 365 E5 500 -> 750 |
| Assigned/available moved **on a SKU that is currently in warning** | the 🔁 *Changes in Detail* table |

All state transitions above are gated on the SKU's [alert class](#-alert-eligibility) being `InUse`. Subscriptions appearing or disappearing from the tenant are reported regardless of class, because that is a real tenant change however small the SKU.

**No notification is sent when** assignments merely move up and down on a healthy SKU, or when anything at all happens to an unlimited, unused or trial SKU. That movement is still recorded in the cache and in `LicenseTrend.csv` — it just does not generate a message, because on a tenant with thousands of users it would fire on every single run.

**Two separate questions.** *Did any recorded value move?* decides whether the cache is rewritten. *Is this worth a message?* decides whether Teams hears about it. Up to 1.9 these were one flag, which would have frozen the cache on non-alerting SKUs and then reported a false jump the day one of them became alert-eligible.

**Baseline runs.** If the cache is missing, unreadable, or from an older schema, the run cannot diff anything. It then sends one message headed *"License Monitoring Baseline Established"* containing the current watch list but no change breakdown, and writes the new cache. Change reporting resumes on the next run.

---

## 🫀 Heartbeat

Because reporting is change-based, a healthy quiet tenant and a scheduled task that stopped running in July produce exactly the same output: nothing. If no notification has been delivered for `HeartbeatDays`, the next run sends a digest instead:

- proof the job ran, and when the last real change was reported
- the current watch list with estimated days left
- **SKUs that look healthy today but are forecast to run out within `ForecastWarnDays`** — the early warning the pre-1.9.5 forecast could never give, because it only looked at SKUs that were already in trouble
- any subscriptions with a `capabilityStatus` other than `Enabled`

`LastNotificationUtc` in `LastRun.json` only advances on a delivered message, so a failed send leaves the heartbeat due rather than silently consuming it.

---

## 📈 Depletion forecast

The forecast is a least-squares fit of assigned licenses over the trend window (30 days), run for **every** SKU.

- Requires at least `ForecastMinPoints` samples spanning at least `ForecastMinSpanDays` days. Below that the report says *insufficient history* rather than extrapolating.
- A flat or shrinking series renders as *not growing*, which is distinct from *insufficient history*. Up to 1.9 both showed as `–`, so an absent forecast was indistinguishable from a safe one.
- SKUs forecast to deplete within `ForecastWarnDays` are logged at `WARN`, listed in the HTML report under *Forecast: depleted within N days*, and included in the heartbeat digest.

> Versions 1.6–1.9 computed the rate from the first and last sample only. A single assignment shortly before a run produced rates like +24/day and a nonsense "1 day left". The regression is resistant to that: on a flat 30-day series with a +40 spike on the final sample, the old method claimed 1.38/day where the fit stays below 0.5.

---

## 🛡️ Reliability behaviour

| Situation | What happens |
|-----------|--------------|
| Webhook POST fails | Retried 3 times with backoff. If it still fails, **the cache is deliberately not advanced**, so the next run re-detects the same change and reports it again. A failed POST can no longer swallow a change permanently |
| File share unavailable | The report is written locally first and published via a temp file + rename. A publishing failure is logged as `ERROR`, the run continues, and the Teams notification carries a ⚠️ *stale report* warning |
| Report being read while written | Publishing is a rename over the target, so a reader never sees a half-written file |
| Log grows | Rotated at `MaxLogSizeMB`, `LogHistoryCount` archives kept |
| Trend history grows | Pruned to `TrendRetentionDays` in the same pass the forecast already reads. Rows with an unparseable timestamp are kept, never discarded |
| Graph call fails | Logged as `ERROR` and rethrown, so the scheduled task fails visibly |
| Nothing has been reported for a while | A heartbeat digest is sent, so silence stops being ambiguous |
| Counts moved but nothing alert-worthy | Cache is refreshed anyway, so the next real change is measured from the right baseline |

---

## ⬆️ Upgrading from 1.9 to 1.9.5

1. **No new baseline run.** The cache schema is unchanged (still 2), so a 1.9 cache is diffed normally.
2. **Alerting volume drops.** Unlimited, unused and trial SKUs stop producing messages. If you *want* one of them to alert, lower `-MinSeatsForAlert` or raise `-UnlimitedSeatThreshold`. Suppressed SKUs are listed in the log every run, so nothing disappears silently.
3. **`AzureLicenseSummary.csv` gains four columns** — `CapabilityStatus`, `WarningUnits`, `SuspendedUnits`, `AlertClass`. Consumers reading by name are unaffected.
4. **Forecast output changes shape.** Cells can now read *insufficient history* or *not growing* instead of `–`. Forecasts only appear once there are `ForecastMinPoints` samples over `ForecastMinSpanDays` — on a fresh trend file that means no forecasts for the first week.
5. **Create `skunames.json` from `skunames.example.json`.** It is new in 1.9.5 and holds the SKU display names that used to be inside the `.ps1`. Forgetting it is not fatal — the report falls back to raw part numbers and says so in the log — but the report will look wrong.
6. **Optional:** move the webhook URL from the scheduled task's arguments into a `.webhook` file next to the script.
7. `Get-AzureLicensesDev.ps1` and `Webbhooktest.ps1` were removed — stale copies of a v1.4 code path, with a hard-coded UNC target.

---

## ⬆️ Upgrading from 1.8 to 1.9

1. **The first run after upgrading is a baseline run.** The old cache is schema 1 and is not diffable; you get one *"Baseline Established"* message instead of a wall of false "new SKU" entries. Normal change reporting resumes on the run after that.
2. **`AzureLicenseSummary.csv` gains a `Status` column.** Anything consuming that CSV by column position needs checking; by name it is unaffected.
3. **The function no longer returns its log lines.** `Write-Log` used to emit to the success stream, which contaminated collections built with `$x = foreach {...}` and injected empty phantom rows into the Teams change table. It now writes to the host. If you captured `$out = Get-AzureLicenseStatus ...` for the log text, read `AzureLicenseAudit.log` instead.
4. **Nothing else needs changing** — all new parameters have defaults.

---

## 📄 Requirements

- PowerShell 5.1+ or Core
- Microsoft.Graph module
- Certificate-based App Registration in Entra ID with the following **application** permissions (admin consent required):
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

A scheduled task running as SYSTEM can only read certificates from `Cert:\LocalMachine\My`.

---

## 🧪 Test Mode

Use `-TestMode` to simulate a license warning scenario. This is useful for testing workflow triggers and Teams presentation without waiting for actual license changes.

It will:
- Send a clearly marked test message to Teams
- Skip diff detection entirely
- Leave the cache untouched, so a test run never affects real state

---

## 🗒️ Version history

| Version | Date | Change |
|---------|------|--------|
| 1.0 | 2025-06-10 | Initial version |
| 1.1 | 2025-06-10 | HTML and Teams export |
| 1.2 | 2025-06-10 | Azure AD App authentication |
| 1.3 | 2025-06-18 | JSON caching, diff detection, Teams diff reporting |
| 1.4 | 2025-06-18 | TestMode simulation support |
| 1.5 | 2026-06-12 | Bug fixes (diff text, logging, single-item arrays), mandatory params, stricter error handling, TestMode no longer runs the real diff, `-AuditDisabledUsers` |
| 1.6 | 2026-06-12 | Trend logging (`LicenseTrend.csv`), depletion forecast in the Teams notification, `-AuditInactiveUsers`/`-InactiveDays` |
| 1.7 | 2026-06-15 | Redesigned HTML report (cards, styled tables, charset), per-license aggregation of disabled/inactive holdings |
| 1.8 | 2026-06-15 | Bilingual HTML report via `-Language` (sv/en) |
| **1.9.5** | **2026-09-14** | **Signal quality.** Alert eligibility separated from license status — unlimited, unused and trial SKUs are classified and reported but no longer alert (on a typical tenant this removes most of the alerting noise). Depletion forecast rewritten as a least-squares fit with minimum sample and span requirements, run on every SKU rather than only warned ones, and stating *insufficient history* instead of guessing. Added a heartbeat digest, subscription health (`capabilityStatus`, seats in grace/suspended), an optional `.webhook` file, and a created-date guard so new accounts are not reported as inactive. Cache write decoupled from notification so non-alerting movement still refreshes the baseline. SKU display names moved out to `skunames.json` behind a reusable `Import-DataFile` helper that degrades rather than fails, with unmapped SKUs now logged instead of silently rendering as part numbers. Cache schema unchanged |
| 1.9 | 2026-09-09 | **Reliability release.** Cache is only advanced once the notification is actually delivered (a failed webhook no longer swallows the change). Report written locally and published atomically; a publishing failure is reported instead of logged as success. Cache tracks every monitored SKU (schema 2), so recovery reads as recovery instead of *"removed SKU"*, and purchases/cancellations are detected. `Write-Log` no longer pollutes the pipeline (this was injecting phantom rows into the Teams change table). Log rotation, trend retention, culture-invariant timestamp parsing, and complete comment-based help |

### Known limitations (candidates for 2.0)

- The low threshold is still a fixed 10 available licenses regardless of SKU size, so a several-thousand-seat SKU with a couple of dozen free reads as ✅ Healthy. Fixing this changes `Status` and therefore the cache schema, so it is held for 2.0 together with a reclassification guard
- Static headroom is arguably the wrong axis altogether — 165 free seats is eight months of runway at 20 onboardings a month and three weeks at 200. 2.0 moves severity onto runway, which is why the forecast was fixed first
- No cost dimension — reclaimable and inactive licenses are reported as counts, not money. This needs a curated price list, since public list prices are materially wrong for most volume and education agreements
- The reclaimable list does not distinguish direct from group-inherited assignments (`licenseAssignmentStates.assignedByGroup`), so part of it is not directly actionable
- Failed license assignments (`licenseAssignmentStates.error`) are not surfaced at all
- Room, equipment and shared mailboxes are not excluded from the inactive audit — Graph v1.0 has no clean recipient-type signal, so this needs an exclusion list
- Subscription health is reported but not diffed; a subscription *entering* grace period needs a cache field, so it waits for the 2.0 schema bump
- Users are enumerated without 429/`Retry-After` handling, which will matter on a large tenant once the audit switches are enabled
- The whole thing is one ~1 300-line function, which is why 2.0 starts by splitting it
- Behaviour lives in parameters rather than a configuration file. 2.0-A adds `-ConfigPath`, loaded through the same `Import-DataFile` helper `skunames.json` already uses

---

## 📦 License

MIT

---

## ✍️ Author

**Love Arvidsson**
Created: 2025-06-10
Last updated: 2026-09-14
