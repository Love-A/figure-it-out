# OSDForm (Config-Driven Task Sequence Frontend)

A small, production-ready WPF dialog for **Microsoft Configuration Manager (ConfigMgr/SCCM) Task Sequences** that lets a technician select **device type**, **business unit (affinity)**, **shared device** setting, whether to **install Microsoft 365 Apps**, and **Windows version** — and then writes those choices back as **Task Sequence variables**.

The UI is **fully driven by JSON configuration** — no hardcoded menus in the script — making it easy to reuse across organizations (Finance, HR, Engineering, Production, etc.).

> **Highlights**
>
> - ✅ Config-driven options (types, business units, shared options, UI text)
> - ✅ **Windows 11 default & locked**, with an optional **Win10 override gesture** (default: `Ctrl+W`)
> - ✅ Writes both **legacy string vars** and **boolean-friendly flags** for easy TS conditions
> - ✅ `-ResetTS` to clear stale TS variables at start
> - ✅ `-DevMode` + **presets** for rapid local testing
> - ✅ Clean logging to `OSDForm.log`
> - ✅ Robust JSON defaulting and **legacy compatibility** for older configs


---

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Files in this repo](#files-in-this-repo)
- [Quick start](#quick-start)
- [Configuration](#configuration)
  - [Search order for config](#search-order-for-config)
  - [Config schema (informal)](#config-schema-informal)
  - [Example `OSDForm.config.json`](#example-osdformconfigjson)
  - [Legacy compatibility](#legacy-compatibility)
- [How it maps to Task Sequence variables](#how-it-maps-to-task-sequence-variables)
  - [Legacy string variables](#legacy-string-variables)
  - [Boolean-friendly variables (recommended for conditions)](#booleanfriendly-variables-recommended-for-conditions)
- [Integrating with a ConfigMgr Task Sequence](#integrating-with-a-configmgr-task-sequence)
  - [Suggested step order](#suggested-step-order)
  - [Example conditions](#example-conditions)
- [CLI usage (outside TS)](#cli-usage-outside-ts)
- [Hotkeys](#hotkeys)
- [Logging](#logging)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [Contributing](#contributing)
- [License](#license)
- [Changelog](#changelog)

---

## Features

- **Config-Driven UI.** Menus and labels come from a JSON file (`OSDForm.config.json`). No code edits required to add new types/BUs.
- **Windows 11 by default.** UI is locked to Windows 11, with an optional **Win10 override gesture** (disabled via config if unwanted).
- **Office toggle.** Enable Microsoft 365 Apps choice only for specified types.
- **Shared device logic.** Require a “Shared device?” decision for selected business units.
- **Dual variable writes.** Script writes both “legacy string” variables and “boolean flags,” making robust TS conditions easy.
- **Operator-friendly.** Reset stale variables with `-ResetTS`; local smoke tests with `-DevMode` and optional presets.
- **Clean logs.** Everything important is logged to `OSDForm.log` next to the script.
- **Robust config defaults.** Sensible defaults are injected even when parts of the JSON are missing.

---

## Prerequisites

- Windows with **PowerShell 5+** (Windows 10/11 include this)
- **ConfigMgr Task Sequence** environment for production (COM `Microsoft.SMS.TSEnvironment`)
- Execution Policy that allows the script (TS step should run with **Bypass**)

---

## Files in this repo

- `Start-OSDForm.ps1` — the WPF frontend (PowerShell)
- `OSDForm.config.json` — the configuration file (JSON)
- `README.md` — this document

> **Tip:** Put the script and JSON config in a **Package** and reference it from your Task Sequence step.

---

## Quick start

1. Clone/download.
2. Place `Start-OSDForm.ps1` and `OSDForm.config.json` together.
3. **Run locally** (dev mode) to see the UI:
   ```powershell
   .\Start-OSDForm.ps1 -DevMode -ConfigPath .\OSDForm.config.json
   ```
4. **Integrate with your Task Sequence** (see below).

---

## Configuration

### Search order for config

The script looks for the JSON config in this order:

1. `-ConfigPath "C:\path\OSDForm.config.json"` (PowerShell parameter)
2. **Task Sequence variable** `OSDFormConfigPath`
3. **Environment variable** `OSD_FORM_CONFIG`
4. `.\OSDForm.config.json` (same folder as the script)

### Config schema (informal)

```jsonc
{
  "schemaVersion": 1,
  "types": [ "Corporate Laptop", "Shared Workstation", ... ],

  "affinity": {
    "Corporate Laptop": ["Finance", "HR", "Sales", ...],
    "Shared Workstation": ["Front Desk", "Contact Center"]
  },

  "shared": {
    "default": ["No", "Yes"],
    // If a specific BU is listed here, the Shared choice is REQUIRED for that BU
    "Front Desk": ["Yes", "No"]
  },

  "rules": {
    "officeEnabledTypes": ["Corporate Laptop", "Engineering Workstation"],
    "lockWin11": true,
    "allowWin10Hotkey": true,
    // Simple, single gesture (letters recommended):
    "win10OverrideGesture": "Ctrl+W",
    "postInstallOfficeNoticeTypes": ["Corporate Laptop"]
  },

  "ui": {
    "title": "Select deployment options",
    "strings": {
      "typeLabel": "Type",
      "affinityLabel": "Business unit",
      "sharedLabel": "Shared device?",
      "officeLabel": "Install Microsoft 365 Apps?",
      "windowsLabel": "Choose Windows version",
      "runButton": "Start deployment"
    }
  }
}
```

> The script validates presence of **`types`** and **`shared.default`**. Everything else falls back to safe defaults.

### Example `OSDForm.config.json`

```json
{
  "schemaVersion": 1,
  "types": [
    "Corporate Laptop",
    "Shared Workstation",
    "Engineering Workstation",
    "Kiosk / Digital Signage",
    "Factory HMI / Production",
    "Lab / Test Bench"
  ],
  "affinity": {
    "Corporate Laptop": ["Finance", "HR", "Sales", "Marketing", "Legal", "IT", "Executive"],
    "Shared Workstation": ["Front Desk", "Contact Center", "Training Room"],
    "Engineering Workstation": ["Software Dev", "QA / Test", "CAD / Design", "Data Science"],
    "Kiosk / Digital Signage": ["Lobby", "Showroom", "Warehouse", "Cafeteria"],
    "Factory HMI / Production": ["Plant 1", "Plant 2", "Quality Lab", "Maintenance"],
    "Lab / Test Bench": ["R&D Lab A", "R&D Lab B", "Demo Lab"]
  },
  "shared": {
    "default": ["No", "Yes"],
    "Front Desk": ["Yes", "No"],
    "Contact Center": ["Yes", "No"],
    "Training Room": ["Yes", "No"]
  },
  "rules": {
    "officeEnabledTypes": [
      "Corporate Laptop",
      "Shared Workstation",
      "Engineering Workstation"
    ],
    "lockWin11": true,
    "allowWin10Hotkey": true,
    "win10OverrideGesture": "Ctrl+W",
    "postInstallOfficeNoticeTypes": ["Corporate Laptop"]
  },
  "ui": {
    "title": "Select deployment options",
    "strings": {
      "typeLabel": "Type",
      "affinityLabel": "Business unit",
      "sharedLabel": "Shared device?",
      "officeLabel": "Install Microsoft 365 Apps?",
      "windowsLabel": "Choose Windows version",
      "runButton": "Start deployment"
    }
  }
}
```

### Legacy compatibility

Older configs might have used a **plural** form:
```json
"win10OverrideGestures": ["Ctrl+Shift+F10", "Ctrl+W"]
```
The script will automatically take the **first** entry and use it as the singular
`win10OverrideGesture`. If neither is present, it defaults to `"Ctrl+W"`.

---

## How it maps to Task Sequence variables

When the technician clicks **Start deployment**, the script writes both “legacy” string values and boolean-style flags.

### Legacy string variables

| Purpose        | Variable   | Example value             |
|----------------|------------|---------------------------|
| Device type    | `Type`     | `Corporate Laptop`        |
| Business unit  | `Affinity` | `Finance`                 |
| Shared device  | `Shared`   | `Yes` / `No`              |
| Office choice  | `Office`   | `With Microsoft 365 Apps` |

### Boolean-friendly variables (recommended for conditions)

| Purpose           | Variable            | Values (`"True"` / `"False"`) |
|------------------|---------------------|--------------------------------|
| Windows 11 image | `OSDWin11Image`     | `"True"` / `"False"`          |
| Windows 10 image | `OSDWin10Image`     | `"True"` / `"False"`          |
| Office include   | `OSDOfficeInclude`  | `"True"` / `"False"`          |
| Device type      | `OSDClientType`     | *(string mirror of `Type`)*   |
| Business unit    | `OSDAffinity`       | *(string mirror of `Affinity`)* |
| Shared device    | `OSDShared`         | *(string mirror of `Shared`)* |

---

## Integrating with a ConfigMgr Task Sequence

1. Create a **Package** containing:
   - `Start-OSDForm.ps1`
   - `OSDForm.config.json`
2. Add a **Run PowerShell Script** step:
   - **Script**: `Start-OSDForm.ps1`
   - **Parameters**: `-ResetTS` (recommended)  
     *(Optional)* `-ConfigPath ".\OSDForm.config.json"` if you don’t set a TS variable.
   - **Execution policy**: **Bypass**
3. (Optional) Set a **Task Sequence variable** `OSDFormConfigPath` to a network or package path if you prefer not to ship the JSON inside the package.
4. Add conditional steps that key off the variables listed above.

### Suggested step order

```
1) Preflight / Reset variables (OSDForm does this with -ResetTS)
2) OSDForm UI (Run PowerShell Script: Start-OSDForm.ps1 -ResetTS)
3) Apply OS (Win11 if OSDWin11Image == True; Win10 if OSDWin10Image == True)
4) Join domain / apply drivers / etc.
5) Install Microsoft 365 Apps (if OSDOfficeInclude == True)
6) App bundles / baselines keyed by OSDClientType/OSDAffinity/OSDShared
7) Finalize
```

### Example conditions

- **Windows 11 image** step:  
  `Task Sequence Variable OSDWin11Image equals True`

- **Windows 10 image** step (if you allow the override):  
  `Task Sequence Variable OSDWin10Image equals True`

- **Install Microsoft 365 Apps**:  
  `Task Sequence Variable OSDOfficeInclude equals True`

- **Finance baseline**:  
  `Task Sequence Variable OSDAffinity equals Finance`

- **Shared kiosk lockdown**:  
  `Task Sequence Variable OSDShared equals Yes`

---

## CLI usage (outside TS)

- Smoke test with dev mode:
  ```powershell
  .\Start-OSDForm.ps1 -DevMode -ConfigPath .\OSDForm.config.json
  ```

- Smoke test with presets:
  ```powershell
  .\Start-OSDForm.ps1 -DevMode -ConfigPath .\OSDForm.config.json `
      -PresetType 'Corporate Laptop' -PresetAffinity 'Finance' -PresetOffice With
  ```

- Clear stale variables at start (recommended in TS):
  ```powershell
  .\Start-OSDForm.ps1 -ResetTS -ConfigPath .\OSDForm.config.json
  ```

---

## Hotkeys

- **Single** gesture defined in JSON under `rules.win10OverrideGesture` (default: `"Ctrl+W"`).
- The script listens on **PreviewKeyDown** only (simple and reliable).
- We recommend **letter-based** gestures (`W`, `Ctrl+W`, `Ctrl+W`), since F-keys are often intercepted by WinPE/TS host or OEM Fn layers.
- To disable entirely: set `"allowWin10Hotkey": false`.

---

## Logging

- Log path: `.\OSDForm.log` (alongside the script).  
- The log includes timestamps, levels (INFO/WARN/ERROR), and key actions (config loaded, selections confirmed, TS set, registered gesture).

---

## Troubleshooting

- **“Configuration error” on launch**  
  The JSON is missing required keys (`types`, `shared.default`) or is malformed. Validate with a JSON linter.

- **UI loads but lists are empty**  
  Ensure your `OSDForm.config.json` is found. Check the log for `Loaded config: <path>`. Use `-ConfigPath` explicitly while testing.

- **Office radio buttons are disabled**  
  The selected `Type` isn’t listed under `rules.officeEnabledTypes`.

- **Windows 10 gesture doesn’t trigger**  
  If using F-keys, they may be intercepted. Use a letter-based gesture like `Ctrl+W`.

- **TS doesn’t react to choices**  
  Verify TS **conditions**, variable **names**, and **case**. The log shows lines like `Set TS variable OSDWin11Image=True`.

---

## Security notes

- This UI is for **technician use** during imaging. If exposing to end users, add the right approvals/auth flows.
- If storing config on a share, use proper **ACLs** so only imaging techs/admins can modify it.
- Avoid storing secrets in the JSON.

---
