# Beyond two phases for **Applications** in ConfigMgr — ringed rollouts with Include Rules

> **TL;DR:** The built‑in **Phased Deployment** feature for **Applications** in ConfigMgr tops out at **two** phases. By targeting a single **master device collection** with one deployment, then using a small script to **include** the next wave collection(s) once a threshold is reached, you can run as many phases as you need while keeping reporting on one Deployment ID. This approach **does not** change the app or the deployment; it only adds Include Membership Rules.

---

## The problem
- Application Phased Deployments allow only **two** phases.
- If you need more, you typically create **multiple separate deployments**:
  - more administrative overhead
  - fragmented history & reporting
  - higher risk of inconsistent schedules and settings

## The solution — “Include rings”
Instead of creating many deployments, use **one** Application deployment that targets a **master device collection** (e.g., `COL-App-Wave-Master`). When installations reach your **success threshold** (e.g., `Installed ≥ 90%`), the script **adds an Include Membership Rule** for the next wave collection into the master. The same deployment then expands to more devices — **no new deployments created**.

**What the script actually does (and does not do):**
- ✅ Reads deployment counts and calculates a success percentage using a chosen metric (`Installed`, `Compliant`, or `Success`, with an **Auto** mode that picks a sensible one if available for that deployment type).
- ✅ Compares that value to your threshold. If met, it adds **Include Membership Rules** for the next wave(s), sorted deterministically by name.
- ✅ Supports **time windows** (days/hours, optional time zone), **exclusions**, **-WhatIf/-Confirm**, and returns a **report object** describing what happened.
- ✅ **Verifies** that the `DeploymentID` actually targets the master collection (aborts by default on mismatch; can be overridden).
- ❌ Does **not** modify the Application, its detection method, requirements, content distribution, supersedence, or any deployment settings.
- ❌ Does **not** force immediate install on clients; timing depends on collection evaluation & client policy cycles.

## When this is genuinely useful for Applications
- **Major app upgrades** (Teams, Adobe, browsers): roll out in 4–6 waves without stitching together many deployments.
- **Critical hotfix for an app**: start with a canary, then expand automatically as stability is proven.
- **Bandwidth‑sensitive sites**: combine time windows and maintenance windows to control load.
- **Simpler follow‑up**: all status under **one** Deployment ID.

## Set‑up (high level)
1. **Create a master device collection** for the target population: `COL-App-Wave-Master`.
2. **Create wave device collections**, for example:  
   `Wave-01-Canary-IT`, `Wave-02-Office`, `Wave-03-Schools-Staff`, `Wave-04-Schools-Students`, `Wave-05-Restricted`.
3. **Create a single Application deployment** to `COL-App-Wave-Master`.
4. **Seed the first wave** into the master (manually or via the script).
5. **Run the script** on a schedule with your threshold and time windows. When the threshold is reached, the next wave is included automatically.

### Example (Applications)
```powershell
Invoke-NextPhaseDeployment `
  -SiteCode "A01" -ProviderMachineName "mecm01.example.local" `
  -MasterCollectionID "PS100123" -DeploymentID "PS120999" `
  -MinPercentageForNextPhase 90 `
  -PhaseCollectionNames "Wave-0*-*" `
  -SuccessCounter Installed `
  -AllowedDaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday `
  -AllowedStartHour 20 -AllowedEndHour 5 -TimeZoneId "W. Europe Standard Time" `
  -ExcludeCollectionNames "Wave-05-Restricted" `
  -MaxCollectionsPerRun 1
```
*Tip:* Start with `-WhatIf` to verify which Include Rules would be added.

## How it behaves in the real world (no magic)
- **Include Rule timing:** The rule is immediate server‑side, but devices are affected only after:
  - the next **collection membership evaluation** adds them to the master, and
  - the client’s next **policy retrieval** picks up the deployment, and
  - any **maintenance windows** allow execution.
- **“Installed/Compliant/Success” metrics:** These rely on detection methods and state messages. Numbers lag behind real time; expect telemetry latency in minutes (sometimes longer in large environments).
- **Content & requirements:** If content isn’t on your DPs, requirements block install, or detection is wrong, simply including another wave won’t fix that. The script just includes collections.
- **Order of waves:** The script selects the next eligible wave(s) **by name order**. Use clear, lexicographic naming (`Wave-01-*`, `Wave-02-*`, …) for predictable sequencing.

## Comparison
| Capability | Built‑in Phased Deployment (Applications) | Include rings (this approach) |
|---|---|---|
| Number of phases | 2 | As many as you design (governance applies) |
| Number of deployments | 1–several (often multiple) | **1** |
| Reporting | Split across deployments | Centralized on one Deployment ID |
| Auto‑stop when quality dips | Limited | Yes — next wave isn’t triggered until threshold is met |
| Time windows | Indirect via MW | Script windows **plus** MW |
| Per‑wave exclusions | Manual | Parameters (`-Exclude*`) |

## Operational tips
- **Wave naming:** Keep lexicographic order so “next” is deterministic.
- **Threshold by app type:**  
  – heavy installs: `Installed ≥ 95%`  
  – small/low‑risk updates: `Installed ≥ 85–90%`
- **Monitoring:** The returned **report object** exposes `Status`, `SuccessPercent`, `PlannedToInclude`, `IncludedCollections`. Log it and/or post to Teams.
- **Circuit breaker:** If the canary underperforms, **no new wave** is included. Fix the issue (content, detection, app packaging) and rerun.

## Constraints & risks (so we don’t oversell it)
- The script **requires** that the deployment targets the **master** collection; it **aborts** on mismatch by default (can be overridden).
- Existing Include Rules affect which waves are still considered “remaining” — keep manual changes under control.
- Telemetry is asynchronous; do not schedule runs too frequently.
- This does **not** replace app QA, DP/content governance, or collection hygiene.

## Pre‑flight checklist
- [ ] Master device collection created and validated
- [ ] Waves named and populated (predictable order)
- [ ] Single Application deployment targets the master collection
- [ ] Threshold and time windows agreed
- [ ] Sensitive groups set as exclusions (IDs or names)
- [ ] First dry‑run with `-WhatIf` executed and log reviewed

---

### Summary
Include rings let you go beyond two phases for **Applications** in ConfigMgr **without** creating more deployments. You keep the simplicity of a single deployment and gain governance over rollout pace. The script adds Include Rules — nothing more — so outcomes still depend on your collections, client policy, detection methods, content distribution, and maintenance windows.
