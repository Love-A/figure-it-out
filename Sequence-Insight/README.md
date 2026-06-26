# Sequence Insight

A modern, dependency-free monitor for Configuration Manager (ConfigMgr / MEMCM / SCCM) task-sequence
executions — live and historically — with a clean WPF UI and a self-contained HTML report.

> **A homage, not a fork.** Sequence Insight is an independent tribute to — and inspired by — the
> much-loved **[ConfigMgr Task Sequence Monitor](https://github.com/SMSAgentSoftware/ConfigMgr-Task-Sequence-Monitor)**
> by Trevor Jones (SMSAgentSoftware), v1.6 (2021). It is a fresh, separately-named implementation and is
> **not affiliated with or endorsed by** SMSAgentSoftware. Comparisons to "1.6" below honour that original.

> Read-only by design. The tool only **reads** from ConfigMgr (AdminService over HTTPS and a SQL
> reader role). It never writes to your environment.

---

## What's new vs 1.6

| Area | TS Monitor 1.6 | Sequence Insight |
|---|---|---|
| Data access | Direct SQL only | **Hybrid**: AdminService (REST/HTTPS) for the TS list, name resolution and live status feed; SQL (read-only) for the deep step-level execution history |
| Live data | **MDT web service** (deprecated by Microsoft) | MDT removed — near-real-time via polling the execution view + AdminService status feed |
| UI toolkit | WPF + **MahApps.Metro** DLL | **Dependency-free WPF** (no external assemblies) |
| Theming | Single theme | **Light / dark / auto** (follows the OS) |
| Settings | Windows registry | **JSON config file** (no hardcoded site) |
| Export | HTML summary | **HTML + CSV + JSON**, plus offline report rebuild |
| Structure | One ~1,700-line script | Testable **module** + thin launcher, Pester tests, PSScriptAnalyzer-clean |
| PowerShell | 3.0+ | **5.1 baseline, 7-compatible** |
| Analytics | — | **Fleet dashboard** (HTML, inline-SVG): success rate **with 95% confidence intervals** & failure trends, a **per-task-sequence scorecard**, **root-cause step** + **decoded exit codes**, **failures by deployment phase**, a **step-health** table, **duration distribution & slowdowns**, retry churn, repeat offenders and **recent regressions** — with **click-through drill-down** and a one-click **exec summary** |
| Progress estimate | MDT progress bar | **Baseline-driven %-complete** + in-progress detection, no MDT required |
| Alerts | — | **Local toast** when a monitored task sequence fails (nothing sent externally) |

---

## Requirements

- **Windows PowerShell 5.1** (recommended — it is STA by default, which WPF needs) **or PowerShell 7+**
  (the launcher auto-relaunches under Windows PowerShell `-STA` for the UI).
- A **ConfigMgr Current Branch** site with the **AdminService** enabled (default since 1810).
- **Read access** to the site SQL database (`db_datareader` on `CM_<SiteCode>`), used for the
  task-sequence execution history (the `vSMS_TaskSequenceExecutionStatus` view, which has no WMI/AdminService equivalent).
- Network connectivity to the SMS Provider over **HTTPS (443)** and to SQL over **1433** (or your port).
- The tool uses **integrated Windows authentication** throughout — run it as an account with the above rights.

No modules to install for the tool itself. (Pester 5 and PSScriptAnalyzer are only needed to run the tests.)

---

## Permissions

| Source | What you need |
|---|---|
| AdminService | A ConfigMgr RBAC role that can read devices and packages (e.g. *Read-only Analyst*). Accessed as the logged-on user. |
| SQL | `CONNECT` + `db_datareader` on the site database `CM_<SiteCode>`. No write rights required. |

---

## Quick start

```powershell
# 1) Try it with synthetic demo data - no ConfigMgr needed
.\Start-SequenceInsight.ps1 -DevMode

# 2) Point it at your site
Copy-Item .\config\SequenceInsight.config.sample.json .\SequenceInsight.config.json
#   edit provider / siteCode / sql.*  (see below)
.\Start-SequenceInsight.ps1 -ConfigPath .\SequenceInsight.config.json

# 3) Force a theme
.\Start-SequenceInsight.ps1 -DevMode -Theme dark
```

If you launch from PowerShell 7, the UI auto-relaunches under Windows PowerShell (STA). To run it
directly in an STA host: `powershell.exe -STA -File .\Start-SequenceInsight.ps1 -DevMode`.

---

## Configuration

Copy `config/SequenceInsight.config.sample.json` to `SequenceInsight.config.json` and edit it. The launcher
looks for the file at `-ConfigPath`, then `$env:SEQUENCEINSIGHT_CONFIG`, then next to the script.

| Key | Description |
|---|---|
| `provider` | SMS Provider / AdminService host, e.g. `cm-provider.contoso.com`. The tool builds `https://<provider>/AdminService`. |
| `siteCode` | Three-character site code, e.g. `ABC`. |
| `adminService.trustServerCertificate` | Set `true` if the AdminService uses a self-signed cert. |
| `sql.server` | SQL Server hosting the site database. |
| `sql.database` | Site database name, e.g. `CM_ABC`. |
| `sql.encrypt` / `sql.trustServerCertificate` | TLS options for the SQL connection. |
| `refreshIntervalSeconds` | **Default** auto-refresh cadence (min 5s); change it live in the UI with the **"every"** selector. Default 30. |
| `dateDisplay` | `local` or `utc`. The view stores UTC; this controls display. |
| `theme` | `light`, `dark` or `auto`. |
| `defaultTimeWindowHours` | Seeds the "Last N hours" box at startup (default 24). Smaller = less data loaded up front. |
| `errorsOnlyDefault` | Start with the "errors only" filter on. |
| `maxRows` | Safety cap on step-rows fetched per query (default 20000). The query returns the **newest** rows up to this cap, so on a busy site a long window can be truncated to the most recent days - raise this (or narrow by task sequence/computer) if older runs are missing. The UI warns when the cap is hit. |
| `liveWindowMinutes` | Upper bound for treating a run as in-progress by how recent its last step is — tightened automatically to the task sequence's own baseline duration, so a quick TS isn't flagged as running long after it finished. Default 30. |
| `analytics.baselineMinSuccessRuns` | Successful runs needed before a task sequence's timing baseline is "trusted". Default 3. |
| `analytics.phasePatterns` | Optional per-site override for failure-phase classification: an array of `{ "phase": "...", "pattern": "<regex>" }` (first match wins, tested against the group name then the action name). Empty = use the built-in map. Lets you map custom or localized step names. |
| `alerts.onFailure` | Toast when a monitored run newly fails during the session. Default true. |
| `alerts.toast` | Use a local Windows toast (NotifyIcon). Nothing is sent externally. Default true. |

---

## Using the UI

- Pick a **task sequence** to load its runs - **nothing loads at startup**. Set the look-back with the
  free-form **Last [N] hours** box (e.g. 1, 24, 120 - Enter to apply; small windows load fast), filter by **Computer**, toggle
  **Errors only**. **Refresh** loads the current selection (use it to load *all* task sequences at once).
- The left grid lists **runs** (one per computer + task sequence, split on a large time gap or a sequence
  restart — i.e. a re-image). The right grid shows that run's **steps**; click a step to see its **action output**.
- In-progress runs are flagged in the **Live** column ("running ~NN%") and sorted to the top. The
  percent is estimated from historical per-step timing baselines (the analytics feed the live view).
- **Auto** enables periodic background refresh; pick the cadence with the **"every"** selector
  (15 sec - 30 min, seeded from `refreshIntervalSeconds`). Refreshes run in a background runspace so
  the UI never freezes.
- **Export report** writes a self-contained `report.html` (plus `report-data.json` and `execution-rows.csv`)
  and opens it. The report has a **Runs** view and an **Analytics** dashboard — root-cause steps with
  decoded exit codes, failures by phase, a step-health table, duration distribution & slowdowns, retries,
  repeat offenders and recent regressions. Click any row, bar or column in the dashboard to jump to the
  matching runs. The dashboard also shows 95% confidence intervals on success rates, a per-task-sequence
  scorecard, and a **Copy exec summary** button that produces a ready-to-paste stakeholder summary.
- **How outcomes are counted (honest by design).** A run is *clean success*, *warnings* (completed with a
  non-fatal / continue-on-error step), *failed* (ended on an error step), *in progress*, or *superseded*
  (an attempt that a later re-image restarted). The success rate is computed over **completed** runs only —
  in-progress and superseded attempts are excluded so they can't inflate it, and the report prints these
  definitions inline.
- **Theme** toggles light/dark live.

---

## Module API

The launcher is a thin shell over the `SequenceInsight` module, which you can use directly for scripting,
scheduled reports, or your own tooling:

```powershell
Import-Module .\SequenceInsight\SequenceInsight.psd1
$ctx = Connect-SequenceInsight -ConfigPath .\SequenceInsight.config.json     # or -DevMode

Get-TSList        -Context $ctx                                  # deployed task sequences
Get-TSExecution   -Context $ctx -SinceHours 24 -ErrorsOnly       # normalized step rows
Get-TSRun         -Context $ctx -Computer 'WS-*'                 # rows grouped into runs
Get-TSStatusFeed  -Context $ctx                                  # best-effort live status feed
$runs = Get-TSRun -Context $ctx
Get-TSAnalytics   -Runs $runs                                    # fleet analytics (success rate + CI, root cause, durations, regressions, churn)
Get-TSStepBaseline -Runs $runs                                   # per-step timing baselines
Add-TSLiveInfo    -Runs $runs -Baseline (Get-TSStepBaseline -Runs $runs)  # annotate in-progress + %-complete
Export-TSReport   -Context $ctx -OutputDirectory .\out -Formats Html,Csv,Json
Export-TSReport   -OutputDirectory .\out -RebuildReportOnly      # rebuild HTML from saved JSON
```

| Function | Purpose |
|---|---|
| `Connect-SequenceInsight` | Validate config / build the session context (or `-DevMode`). |
| `Get-TSList` | List task sequences (AdminService, SQL fallback). |
| `Get-TSExecution` | Normalized execution rows (Status, UTC time, per-step duration). |
| `Get-TSRun` | Execution rows grouped into runs with nested steps. |
| `Get-TSStatusFeed` | Near-real-time status messages from the AdminService (best-effort). |
| `Get-TSStepBaseline` | Per-step timing baselines (median/p90) from successful runs. |
| `Get-TSAnalytics` | Fleet analytics: success rate (with 95% confidence intervals) & trends, per-task-sequence scorecard, root-cause steps, failure stages, step health, duration distribution, slowdowns, retry churn, repeat offenders, regressions. |
| `Add-TSLiveInfo` | Annotate runs with in-progress status + baseline-driven %-complete. |
| `Get-TSNewFailure` | Detect runs newly transitioned to failed (drives toast alerts). |
| `Export-TSReport` | Standalone HTML report (Runs + Analytics) + optional CSV/JSON; offline rebuild. |

---

## Architecture

```
Start-SequenceInsight.ps1          launcher: config -> connect -> WPF window -> background polling
SequenceInsight/                   the data + reporting module
  SequenceInsight.psd1 / .psm1
  Public/                    Connect-SequenceInsight, Get-TSList, Get-TSExecution, Get-TSStepOutput, Get-TSRun,
                             Get-TSStatusFeed, Get-TSStepBaseline, Get-TSAnalytics, Add-TSLiveInfo,
                             Get-TSNewFailure, Export-TSReport
  Private/                   AdminService.ps1 (REST), SqlProvider.ps1 (SQL), Config.ps1,
                             Logging.ps1, Html.ps1, DemoData.ps1
ui/MainWindow.xaml           the WPF window (themed via DynamicResource brushes)
config/                      SequenceInsight.config.sample.json
Tests/                       Pester v5 tests
```

- **Hybrid data layer.** The AdminService serves the TS list, ResourceID -> name resolution
  (replacing MDT's unknown-name lookup) and a status feed. The step-level execution history comes
  from a parameterised, read-only SQL query because `vSMS_TaskSequenceExecutionStatus` is a SQL view
  with no WMI/AdminService equivalent.
- **Responsive UI.** A `DispatcherTimer` plus a runspace pool keeps queries off the UI thread; results
  are marshalled back on the UI thread by a short completion poller.

---

## Verifying / testing

```powershell
# Unit tests (Pester v5) - no live ConfigMgr required
Invoke-Pester .\Tests\SequenceInsight.Tests.ps1

# Static analysis
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1

# Headless UI self-test (build window + bind controls + populate demo data), STA required
powershell.exe -STA -File .\Start-SequenceInsight.ps1 -DevMode -SelfTest
```

---

## Notes & limitations

- **STA required for the UI** (WPF). PowerShell 7 is MTA by default; the launcher relaunches under
  Windows PowerShell `-STA` automatically.
- **Run grouping is heuristic.** Steps are grouped into runs by computer + task sequence and split on a
  large time gap or a sequence restart (a re-image). Devices not yet named during bare-metal OSD appear
  under **"Unknown"**, so distinct unnamed machines can be grouped together until naming resolves.
- **Status feed is best-effort.** Insertion strings are not resolved to full text (that needs the
  message-string DLLs); the feed surfaces MessageID + component + time. The execution grid is the
  source of truth.
- **AdminService certificate.** If the site cert is self-signed, set
  `adminService.trustServerCertificate: true`.
- Column availability in `vSMS_TaskSequenceExecutionStatus` is stable across recent Current Branch
  builds; the query uses `LEFT JOIN`s so a missing package/name lookup never drops rows.

---

## License & credits

Licensed under the **MIT License** — see [`LICENSE`](LICENSE). Sequence Insight is an independent,
from-scratch implementation and **shares no source code** with the original; the only commonalities are
unavoidable ConfigMgr facts any such tool must use (the `vSMS_TaskSequenceExecutionStatus` view and its
join keys, the `FeatureType = 7` task-sequence filter, and the standard integrated-auth connection string).
It is a homage to — and inspired by — the **ConfigMgr Task Sequence Monitor** by Trevor Jones
(SMSAgentSoftware), v1.6, which is licensed under Apache-2.0. Not affiliated with or endorsed by
SMSAgentSoftware.
