# Remove-CMPackageOldVersions

PowerShell script to prune **older Microsoft Configuration Manager (ConfigMgr) package versions** (e.g., created by Driver Automation Tool), keeping the latest *N* versions per package **Name**.

- Single confirmation dialog shows **Name + Version + PackageId** (unless `-NoConfirm`).
- Supports `-WhatIf` for safe dry‑runs.
- Works with or without `Out-GridView` (use `-NoGui` for headless).
- Removes from a specific **Distribution Point** or from the **environment** entirely.
- Robust version sorting (parses `System.Version`; falls back safely for odd strings).

## Requirements
- Windows PowerShell **5.1**
- Configuration Manager console installed (for the **ConfigurationManager** PowerShell module)
- Sufficient rights to remove package content and/or delete packages

## Installation
1. Copy **`Remove-CMPackageOldVersions.ps1`** into a folder of your choice.
2. Start an elevated PowerShell session on a device with the ConfigMgr console installed.
3. (Optional) Unblock the file if downloaded from the internet:
   ```powershell
   Unblock-File .\Remove-CMPackageOldVersions.ps1
   ```

## Usage
> Tip: Always start with **`-WhatIf`**.

### 1) Dry-run on a DP (recommended first)
```powershell
.\Remove-CMPackageOldVersions.ps1 -SiteCode P01 -ProviderMachineName CM01 `
  -DistributionPointName DP01 -PackageName "BIOS Update - *" -WhatIf
```

### 2) Remove from environment, keep latest two per Name (explicit confirm)
```powershell
.\Remove-CMPackageOldVersions.ps1 -SiteCode P01 -ProviderMachineName CM01 `
  -PackageName "BIOS Update - *" -RemoveFromEnvironment -KeepLatest 2 -Confirm
```

### 3) Headless on a DP (no Out-GridView) and filter Names
```powershell
.\Remove-CMPackageOldVersions.ps1 -SiteCode P01 -ProviderMachineName CM01 `
  -DistributionPointName DP01 -PackageName "BIOS Update - *" -NoGui -IncludeName "*Latitude*"
```

### 4) Run without any confirmations (fast clean-up)
```powershell
.\Remove-CMPackageOldVersions.ps1 -SiteCode P01 -ProviderMachineName CM01 `
  -DistributionPointName DP01 -PackageName "BIOS Update - *" -NoConfirm
```

## Parameters
- `-SiteCode` *(string, required)* — ConfigMgr site code, e.g., `P01`.
- `-ProviderMachineName` *(string, required)* — Provider hostname/FQDN.
- `-PackageName` *(string, required)* — Wildcard-friendly package **Name** pattern, e.g., `"BIOS Update - *"`.
- `-DistributionPointName` *(string)* — DP to remove content from. **Required** unless using `-RemoveFromEnvironment`.
- `-RemoveFromEnvironment` *(switch)* — Remove older packages from ConfigMgr entirely (`Remove-CMPackage`).
- `-KeepLatest` *(int, default 1)* — Number of latest versions to keep per Name.
- `-NoGui` *(switch)* — Skip `Out-GridView` and process all matching Names.
- `-IncludeName` *(string)* — Optional post-filter for Names after grouping.
- `-NoConfirm` *(switch)* — Suppress confirmation prompts (script + cmdlets). `-WhatIf` still works.

## How it works
1. Connects to the specified site and provider (`CMSite` PSDrive).
2. Queries `Get-CMPackage` using your `-PackageName` wildcard.
3. Groups results by **Name** and keeps only Names with multiple versions.
4. Lets you select Names via `Out-GridView` (or processes all with `-NoGui`).
5. Sorts each group by **Version** (robust parser) and **PackageID** as tiebreaker.
6. Keeps the **latest `-KeepLatest`** and removes the rest from a **DP** or the **environment**.

## Safety & confirmations
- The script is decorated with `SupportsShouldProcess` and `ConfirmImpact = 'Low'`.
- A **single** confirmation is shown via `ShouldContinue` (includes **Name + Version + PackageId**).
- Underlying cmdlets are executed with confirmations suppressed to avoid double prompts.
- Use `-NoConfirm` to skip confirmations altogether; **`-WhatIf`** continues to simulate safely.

## Logging
- Logs to: `$(ScriptRoot)\Remove-CMPackageOldVersions.log`
- Format: `[YYYY-MM-DD HH:mm:ss] [LEVEL] Message`
- Examples:
  ```
  [2025-08-18 08:51:18] [INFO] Connected to site P01 (provider CM01)
  [2025-08-18 08:51:19] [INFO] Querying Get-CMPackage -Name 'BIOS *'...
  [2025-08-18 08:51:23] [INFO] Name: [BIOS Update - Example Model] - found 3 version(s). Keeping 1, removing 2.
  [2025-08-18 08:51:25] [INFO] User cancelled removal for PackageId P0100123 (Name "BIOS Update - Example Model", Version 01.22.00).
  [2025-08-18 08:51:28] [INFO] Removed PackageId P0100124 (Name "BIOS Update - Example Model", Version 01.20.00) from environment.
  ```

## Notes & best practices
- Always test with `-WhatIf` in a **lab** or on a **single model** first.
- Be aware of package dependencies (e.g., Task Sequences). Deleting packages could impact them.
- When string-interpolating variables next to `:` in PowerShell, this script uses the `${var}` style to avoid parsing issues.

## Troubleshooting
- **No `Out-GridView` available** → Use `-NoGui`.
- **Still seeing multiple prompts** → Ensure you didn’t set global `$ConfirmPreference` elsewhere; try `-NoConfirm`.
- **Package remains after removal** → Check distribution/replication and references. The script logs a warning if verification detects the package is still present after `Remove-CMPackage`.
