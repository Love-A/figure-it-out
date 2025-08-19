# Include Rings for Applications in ConfigMgr — Beyond Two Phases (Public/Anonymized)

> PowerShell function to expand an **Application** deployment in Microsoft Endpoint Configuration Manager (ConfigMgr/MECM) beyond the built‑in two phases by adding **Include Membership Rules** to a master device collection once a threshold is reached. This approach **does not** change the app or create new deployments; it only adds Include Rules to your master collection.

---

## Why this exists

- Built‑in **Phased Deployment** for **Applications** supports only **two** phases.
- With **include rings**, a single deployment targets a **master device collection**. When your chosen metric crosses a threshold (e.g., *Installed ≥ 90%*), the next wave collection(s) are **included** in the master via Include Rules — so the **same** deployment expands.

## What the function does / does not do

**Does**
- Finds the deployment by **AssignmentID** (simple and robust).
- Verifies the master collection is a **device** collection.
- Adds **Include Membership Rules** for the next wave collection(s) when the threshold is met (deterministic name order).
- Supports **time windows** (days/hours, optional time zone).
- Supports **exclusions** by CollectionID and name patterns.
- Supports multiple success metrics: `Auto` (default), `Installed`, `Compliant`, `Success`.
- Writes logs to the **current session temp** (user: `%LOCALAPPDATA%\Temp`; SYSTEM: `C:\Windows\Temp`).

**Does not**
- Modify the Application (detection, requirements, content, supersedence) or deployment settings.
- Force immediate install; rollout depends on collection evaluation, client policy, and maintenance windows.

## Robust behavior in real environments

- **Deployment resolution:** Uses `Get-CMDeployment`. If your module lacks `-CollectionId`, it falls back to a full fetch and finally to **WMI** (`SMS_DeploymentSummary`) — all handled automatically.
- **Stale summary workaround:** If the deployment summary shows `NumberTargeted = 0` but your master collection has members, you can opt‑in to use the **current membership count** as denominator with `-UseMemberCountWhenZero`. You can also set `-SummaryStalenessMinutes` to consider summaries older than N minutes “stale.”
- **Logging:** Always written to the session temp folder, unaffected by switching to the `CMSite:` drive.

## Prerequisites

- ConfigMgr admin console PowerShell module (`ConfigurationManager.psd1`).
- One **Application** deployment targeting your **master device collection**.
- Wave **device collections** created and populated (lexicographic naming recommended: `Wave-01-*`, `Wave-02-*`, …).

## Install

Place `Invoke-NextPhaseDeployment.ps1` in your repo and dot‑source it:

```powershell
. .\Invoke-NextPhaseDeployment.ps1
```

## Quick start (AssignmentID-based)

```powershell
Invoke-NextPhaseDeployment `
  -SiteCode "A01" -ProviderMachineName "mecm01.example.local" `
  -MasterCollectionID "P010025C" -AssignmentID 16778519 `
  -MinPercentageForNextPhase 90 -PhaseCollectionNames "Wave-0*-*" `
  -SuccessCounter Installed -WhatIf
```

### Evening window, weekdays only, include up to 2 waves per run

```powershell
Invoke-NextPhaseDeployment `
  -SiteCode "A01" -ProviderMachineName "mecm01.example.local" `
  -MasterCollectionID "P010025C" -AssignmentID 16778519 `
  -MinPercentageForNextPhase 90 -PhaseCollectionNames "Wave-*" `
  -AllowedDaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday `
  -AllowedStartHour 20 -AllowedEndHour 5 -TimeZoneId "W. Europe Standard Time" `
  -MaxCollectionsPerRun 2
```

### Stale summary workaround (optional)

```powershell
Invoke-NextPhaseDeployment `
  -SiteCode "A01" -ProviderMachineName "mecm01.example.local" `
  -MasterCollectionID "P010025C" -AssignmentID 16778519 `
  -MinPercentageForNextPhase 85 -PhaseCollectionNames "Wave-*" `
  -UseMemberCountWhenZero -SummaryStalenessMinutes 30
```

## Parameters (high level)

- `SiteCode` — site code, e.g., `A01`.
- `ProviderMachineName` — SMS Provider FQDN, e.g., `mecm01.example.local`.
- `MasterCollectionID` — device CollectionID, e.g., `P010025C` (8 alphanumerics).
- `AssignmentID` — **numeric** deployment AssignmentID (from `Get-CMDeployment`), e.g., `16778519`.
- `MinPercentageForNextPhase` — integer 1–100, threshold to include next wave(s).
- `PhaseCollectionNames` — one or more exact/wildcard names for wave **device** collections.
- `MaxCollectionsPerRun` — how many waves to include per run (default 1).
- `SuccessCounter` — `Auto` (default) / `Installed` / `Compliant` / `Success`.
- `ExcludeCollectionIDs`, `ExcludeCollectionNames` — skip specific waves.
- Time window — `AllowedDaysOfWeek`, `AllowedStartHour`, `AllowedEndHour`, `TimeZoneId`.
- Stale summary handling — `UseMemberCountWhenZero`, `SummaryStalenessMinutes`.

## Output & Logging

- Returns a report object with fields like `Status`, `SuccessPercent`, `PlannedToInclude`, `IncludedCollections`, notes on summarization age, and which path was used to resolve the deployment.
- Logs are written to the session temp path: `Invoke-NextPhaseDeployment-YYYYMMDD.log`.

## Limitations

- Requires that the deployment actually targets the **master** device collection (the function enforces/validates this).
- Telemetry (state messages) is asynchronous; don’t schedule overly frequent runs.
- Not a replacement for app QA, content/DP governance, or collection hygiene.

## Changelog (script)

- **2.7** — Stale-summary workaround flags; improved notes; kept PS 5.1 compatibility.
- **2.6** — Robust device collection validation; logging to user/SYSTEM temp.
- **2.5** — Switched primary deployment lookup to AssignmentID.
- **2.4** — Relaxed CollectionID validation to `^[A-Za-z0-9]{8}$`.
- **2.3** — PS 5.1 compatibility (no ternary / if-expression).
- **2.1** — Hard target verification; SuccessCounter; exclusions; time windows; report object.
- **2.0** — Standards-compliant help/logging; numeric %; sorting; WhatIf/Confirm.
- **1.0** — Initial include-on-threshold concept.
