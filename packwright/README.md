# Packwright

Package a Windows application and publish it to Microsoft Intune — from a window or from a script.

Point it at the installer you got from a vendor and it works out the silent switches, writes the detection rule from the app's own uninstall entry, builds the `.intunewin` and creates the Win32 app in Intune. Everything it decides is visible and editable first, and it all lands in a plain `app.json` you can commit, review and replay.

Three PowerShell scripts, no dependencies beyond `Microsoft.Graph.Authentication`:

1. **`Packwright.ps1`** — the GUI: a guided wizard for occasional packagers and a full editor for everyone else. Start it with `.\Packwright.ps1` (optionally `-SourceFolder <path>`, `-Installer <file>`, or `-Wizard`).
2. **`Build-IntuneWinApp.ps1`** — packages a source folder into `.intunewin` using Microsoft's **IntuneWinAppUtil.exe** (downloaded automatically when missing), with logging, backups and safe overwrite handling.
3. **`Publish-IntuneWinApp.ps1`** — creates or updates the Win32 app in Intune via Microsoft Graph: metadata, detection rules, chunked content upload, commit. Idempotent with `-Update`, so the same spec can be applied from a scheduled task or a pipeline.

**Requirements:** Windows with PowerShell 7+, and an Intune tenant you may create apps in. `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser` covers the only dependency.

Start it with `pwsh`, not `powershell`. *Run with PowerShell* in Explorer hands a `.ps1` to Windows PowerShell 5.1, and all three scripts stop there with a single sentence telling you so — the studio in a dialog as well, since a double-click leaves no console to read. Keep the scripts saved as **UTF-8 with BOM**: without one, 5.1 decodes the em dashes as ANSI and dies in parse errors before it reaches that message. The self-test checks the BOM is still there.

### The GUI in one screen

It opens on a **start screen** with two choices — *I have an installer file* (guided wizard) and *I have a package folder* — plus your recent packages. You can also drop a package folder or an installer straight onto the window.

Once a package is open, the editor shows everything the Intune app will contain:

- **App information** — name, publisher, version, description, each with a tag saying where the value came from (`app.json` / `PSADT` / `MSI` / `installer` / `edited by hand`).
- **Detection** — written in plain language ("Intune reads DisplayVersion under the registry key 7-Zip and treats the app as installed when it is at least 24.08"), with one button — **Find the app on this computer...** — that generates the rule for you. The raw Intune fields live behind *Change detection method* for when you need them.
- **Advanced** — install/uninstall commands, run-as, restart behaviour, architecture, minimum Windows and the setup file, collapsed by default because most packages never need them.
- **Preview** — how the app will look in the Company Portal, live as you type.
- **Logo** — *Use the app's own icon* extracts the real icon (up to 256×256) from the installed app or the package payload; or choose a png/jpg.
- **Ready to publish** — a live checklist of what Intune requires. Nothing is a surprise at publish time: if something is missing, the field is highlighted and focused instead of a dialog appearing.

**Help** in the header (or **F1**) opens a short usage guide written for whoever is packaging the app — what Intune insists on, how detection works and what to do when a publish fails — with a button to open this README for the full picture. The guide lives in `$script:HelpTopics` at the top of the help region in the script; keep it short, and leave setup, sign-in and command-line detail here in the README.

Then **Publish to Intune** builds the `.intunewin` and creates the app, with a live log, progress and **Cancel**. A confirmation dialog repeats the name, version and detection rule first. Corrections are always written back to `app.json` in the package folder, so the GUI and the command line stay interchangeable.

**If the app already exists in Intune:** publishing stops before anything is created — the easy mistake when re-publishing. Under *Advanced* you can instead choose to **update it** (this package becomes a new version of that app, assignments kept) or to create a second app anyway. On the command line those are `-Update` and `-AllowDuplicateName`.

## Guided mode — from vendor installer to published app

Made so that a stand-in with little packaging experience can publish a simple app. Pick **"I have an installer file"** on the start screen (or start with `-Wizard` / `-Installer <file>`) and a five-step wizard runs the whole flow:

1. **Installation file** — point at the `.exe`/`.msi` you got from the vendor. The tool identifies the installer engine and prefills the silent commands: MSI (`/qn`), Inno Setup (`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-`), NSIS (`/S`), InstallShield (`/s /v"/qn"`), WiX Burn (`/quiet`). Name/publisher/version are read from the MSI properties or the exe's version info. You also pick where package folders are created (remembered in `%APPDATA%\Packwright\settings.json`). If you go back and pick a different file, everything the tool derived from the old one — commands, hint, MSI product code, extracted logo, suggested folder name — follows the new file; anything you typed yourself is left alone, with a note saying so.
2. **App information** — how the app will appear in Intune/Company Portal, plus the install/uninstall commands. Everything prefilled where possible, everything editable.
3. **Detection** — for MSI the product code is used automatically. For exe installers, click **"Choose installed program..."**: a searchable list of this computer's Apps & features entries; picking the app generates the uninstall-key registry rule (`DisplayVersion` ≥ version, WOW6432Node handled) and harvests a silent uninstall command from `QuietUninstallString` when available. If the app isn't installed yet, run the installer once on your machine first — that's the whole trick. Detection can also be deferred, but publishing stays blocked until it's set.
4. **Logo** — optional Company Portal icon.
5. **Summary** — creates the package folder (installer copied in, `app.json` written) and either opens it in the studio for review or builds and publishes to Intune in the same run.

The same installed-programs picker is available in the editor as **"Find the app on this computer..."**. The wizard's output is a plain package folder with `app.json`, so it works identically with the scripts.

Run `.\Packwright.ps1 -TestLoad` to build every window and run the headless self-test suite without showing the UI — useful after any change. It prints a PASS/FAIL line per check and exits non-zero on failure. Set `PACKWRIGHT_TESTPACKAGES` to a semicolon-separated list of your own package folders to have them opened as part of the run.

## Quick start

```powershell
# One-off build (setup file is auto-detected for PSADT/MSI packages)
.\Build-IntuneWinApp.ps1 -SourceFolder "C:\psadt\7-zip"

# Build AND publish to Intune in one pipeline
. .\Build-IntuneWinApp.ps1
. .\Publish-IntuneWinApp.ps1
Build-IntuneWinApp -SourceFolder "C:\psadt\7-zip" -PassThru | Publish-IntuneWinApp

# Publish an existing .intunewin
.\Publish-IntuneWinApp.ps1 -Path ".\Output\7-zip\Invoke-AppDeployToolkit.intunewin" -ManifestPath "C:\psadt\7-zip\app.json"

# Dry run — show what would be created in Intune
Build-IntuneWinApp -SourceFolder "C:\psadt\7-zip" -PassThru | Publish-IntuneWinApp -WhatIf
```

---

## Build-IntuneWinApp

### Features
- Run directly with parameters (`.\Build-IntuneWinApp.ps1 -SourceFolder ...`) or dot-source to load the function — no more editing the bottom of the script.
- Auto-detects the setup file: `Invoke-AppDeployToolkit.exe` (PSADT) or a single `.msi` in the folder. Override with `-SetupFile`.
- Runs `IntuneWinAppUtil.exe` from the script folder (fallback: `C:\IntuneWinAppUtil\`).
- Output goes to `.\Output\<PackageName>` with a per-build log file.
- Existing `.intunewin` files are renamed to `*-<timestamp>.bak.intunewin`; old backups beyond `-KeepBackups` (default 3) are pruned automatically. `-OverwriteExisting` deletes instead.
- `-PassThru` returns a result object (`IntuneWinFile`, `SourceFolder`, `SetupFile`, `SizeMB`, `Sha256`, `Duration`, `LogFile`) that pipes straight into `Publish-IntuneWinApp`.
- Accepts pipeline input for batch builds: `Get-ChildItem C:\psadt -Directory | Build-IntuneWinApp -PassThru`.
- Supports `-WhatIf` / `-Confirm`, `-Clean`, `-Quiet`.

### Parameters
| Parameter | Description |
|---|---|
| `-SourceFolder` | Folder with installation files (mandatory, pipeline input). |
| `-SetupFile` | Setup file inside the source folder. Optional — auto-detected. |
| `-OutputRoot` | Output base folder. Default: `.\Output` next to the script. |
| `-OverwriteExisting` | Delete existing `.intunewin` instead of backing it up. |
| `-Clean` | Purge the package output folder before build. |
| `-Quiet` | No console output; log file only. |
| `-PassThru` | Return a result object for the produced package. |
| `-KeepBackups` | Number of `.bak.intunewin` files to keep (default 3). |

---

## Publish-IntuneWinApp

Creates or updates the Win32 app in Intune from a `.intunewin` file:

1. Reads the package metadata (`Detection.xml`) directly out of the `.intunewin` (name, setup file, MSI info, encryption keys).
2. Decides whether this is a new app or an existing one — by display name, or `-AppId`.
3. Creates the `win32LobApp` via Graph (beta) with install/uninstall commands, detection rules, return codes, icon etc.
4. Extracts the encrypted payload and uploads it to Azure Storage in 6 MB chunks (SAS renewal handled for large packages).
5. Commits the content and points the app at the new content version.

Apps are created **without assignments** — assign to groups in the portal afterwards.

### Idempotent publishing (`-Update`)

`app.json` is the desired state, so the same spec can be applied over and over:

```powershell
Build-IntuneWinApp -SourceFolder "C:\psadt\7-zip" -PassThru |
    Publish-IntuneWinApp -Update -Confirm:$false
```

- **App missing** → created, exactly as before.
- **App exists** → a new content version is uploaded to that same app and its metadata is re-asserted from `app.json`. **Assignments are kept**, and an existing icon survives unless the manifest names one.
- **Several apps share the name** → the run stops and lists them; pass `-AppId` to say which one.

Because the app is only switched over to the new content in the very last call, a failed or cancelled upload leaves it serving the **previous** version — retrying is safe.

Without `-Update`, an existing app of the same name stops the run before anything is created, so a re-publish cannot silently produce a duplicate. `-AllowDuplicateName` deliberately creates a second app; combining it with `-Update` is refused as contradictory.

`-WhatIf` is a usable plan step: it prints whether the run would create or update (and which app id), without touching Intune.

For automation, prefer `-AppId` as the key — a display name is only unique by convention.

### Auth — Entra app registration (`.secret`)
Authenticates app-only via an Entra app registration, configured in a gitignored `.secret` JSON file next to the script — copy [.secret.template](.secret.template) to `.secret` and fill in:

| Field | Description |
|---|---|
| `AppId` | App registration (client) id. |
| `TenantId` | Tenant id. |
| `GraphThumbprint` | Thumbprint of the app's certificate in the runner's cert store (**preferred, esp. prod**). |
| `ClientSecret` | Optional client secret for dev convenience (plaintext at rest — avoid in prod). Wins over the cert if set. |

The app registration needs the Microsoft Graph **Application** permission **`DeviceManagementApps.ReadWrite.All`** with admin consent. Explicit parameters (`-TenantId`, `-ClientId`, `-CertificateThumbprint`, `-ClientSecret`) override `.secret` fields.

Setting the app registration up once, by hand:

1. Entra portal → **App registrations** → **New registration** (single tenant is enough).
2. **API permissions** → Microsoft Graph → **Application permissions** → `DeviceManagementApps.ReadWrite.All` → **Grant admin consent** (needs Global Administrator or Privileged Role Administrator).
3. **Certificates & secrets** → upload the public key of a certificate that lives in the cert store of the account that will run the tool (`New-SelfSignedCertificate` is fine), then put its thumbprint in `.secret`.

A client secret works too and is quicker to set up, but it sits in `.secret` as plain text — keep it for testing.

If neither `.secret` nor `-ClientId` is present, the script falls back to delegated interactive sign-in (browser) with the same permission as a delegated scope. Already-connected matching sessions are reused.

`-SignIn` decides how that prompt appears. By default (`Auto`) the Graph SDK brokers it through **WAM**, which parents its window to the console window of the process — a host without one gets no prompt and an empty `InteractiveBrowserCredential authentication failed:`. `-SignIn Browser` turns WAM off (`Set-MgGraphOption -EnableLoginByWAM $false`) and signs in in the default browser instead; that is what the studio uses, because a GUI has no console window to hand over. `-SignIn DeviceCode` prints a code for <https://microsoft.com/devicelogin> — for remote sessions, and only useful from a real console, since the SDK writes that code straight to the console rather than to a PowerShell stream.

Sign-in failures stop the run. Nothing is created in Intune before there is a working Graph connection.

### App settings — `app.json`
Settings are read from an `app.json` manifest, searched for in this order:

1. `-ManifestPath`
2. `<SourceFolder>\app.json` (automatic when piping from the build)
3. Next to the `.intunewin` file

Everything has sensible defaults, so **MSI and PSADT packages can often be published without a manifest**:

| Setting | Default without manifest |
|---|---|
| Install/uninstall command | PSADT: `Invoke-AppDeployToolkit.exe -DeploymentType Install/Uninstall -DeployMode Silent`. MSI: `msiexec /i ... /qn` / `msiexec /x <productcode> /qn`. |
| Detection | MSI: product code rule. Otherwise a manifest `detection` block is required. |
| Name/publisher/version | PSADT: `AppName`/`AppVendor`/`AppVersion` from the `$adtSession` block in `Invoke-AppDeployToolkit.ps1`. Otherwise MSI metadata when available. |
| Context/restart | `system` / `suppress`. |
| Architecture / min OS | `x64` / Windows 10 1607. |

### Packaging an .exe with PSADT — recommended pattern
An .exe installer has no MSI product code, so detection is the one thing you must provide yourself. The workflow that keeps everything in one place:

1. Fill in `AppVendor`, `AppName` and `AppVersion` in the `$adtSession` block of `Invoke-AppDeployToolkit.ps1` (you should anyway — PSADT uses them for logging) — the publish step picks them up automatically.
2. Drop a minimal `app.json` in the PSADT package folder with just the detection rule. The most robust rule for .exe installers is the app's uninstall registry key with a version comparison — it matches what *Apps & features* shows and keeps working when the app self-updates:

```json
{
  "detection": {
    "type": "registry",
    "keyPath": "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{app-guid-or-name}",
    "valueName": "DisplayVersion",
    "detectionType": "version",
    "operator": "greaterThanOrEqual",
    "detectionValue": "1.2.3",
    "check32BitOn64System": false
  }
}
```

Find the key name under `HKLM\...\Uninstall\` (or `WOW6432Node\...\Uninstall\` for 32-bit installers — then set `check32BitOn64System: true`) on a machine with the app installed. File-version detection on the main .exe (`"detectionType": "version"` on e.g. `C:\Program Files\App\app.exe`) is a good alternative when the installer writes no uninstall key; plain `"exists"` only for version-less apps, since it can't tell an old install from a new one. Note that `app.json` in the source folder is compressed into the `.intunewin` along with everything else — harmless, and it keeps the manifest versioned with the package.

See [app.example.json](app.example.json) for the full schema. Detection block variants:

```jsonc
// MSI product code (productCode optional — taken from the package)
{ "type": "msi" }

// File or folder
{ "type": "file", "path": "C:\\Program Files\\7-Zip", "fileOrFolderName": "7zFM.exe", "detectionType": "exists" }

// Registry
{ "type": "registry", "keyPath": "HKEY_LOCAL_MACHINE\\SOFTWARE\\MyApp", "valueName": "Version",
  "detectionType": "string", "operator": "equal", "detectionValue": "1.0" }

// PowerShell script (path relative to app.json)
{ "type": "script", "scriptFile": "Detect-MyApp.ps1" }
```

`minimumWindowsRelease` must use the exact ids the Intune service knows: build-number style for older releases (`1607`, `1809`, ...) and `Windows10_21H2` / `Windows10_22H2` / `Windows11_21H2` / `Windows11_22H2` for newer ones. Bare `22H2` is rejected with `400 Unknown MinimumSupportedWindowsRelease`.

### Parameters
| Parameter | Description |
|---|---|
| `-Path` | The `.intunewin` file (mandatory; pipeline from `Build-IntuneWinApp -PassThru`). |
| `-SourceFolder` | Used to locate `app.json`; set automatically when piping. |
| `-ManifestPath` | Explicit path to `app.json`. |
| `-TenantId` / `-ClientId` / `-CertificateThumbprint` / `-ClientSecret` | App-only auth overrides; normally read from `.secret`. |
| `-Update` | Create when missing, otherwise upload a new content version to the existing app. Use this from automation. |
| `-AppId` | Update this exact app instead of matching on display name. Implies `-Update`. |
| `-AllowDuplicateName` | Create a second app even though the name is taken. Cannot be combined with `-Update`. |
| `-SignIn` | How the delegated prompt is shown: `Auto` (WAM, default), `Browser` (no WAM — needed without a console window), `DeviceCode`. |

Returns `Action` (`Created`/`Updated`), `AppId`, `DisplayName`, `Version`, `ContentVersion`, `TenantId` and `PortalUrl`.

Returns an object with `AppId`, `DisplayName`, `Version` and a clickable `PortalUrl`.

---

## Logging
Each build writes `Build-<PackageName>-<yyyyMMdd_HHmmss>.log` in the package output folder.

## Licence

MIT — see [LICENSE](LICENSE). `IntuneWinAppUtil.exe` is Microsoft's [Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) and is not redistributed here; `Build-IntuneWinApp.ps1` downloads it on first use.

## Version history

Three components, versioned separately: **Studio** (`Packwright.ps1`, the GUI), **Build** (`Build-IntuneWinApp.ps1`) and **Publish** (`Publish-IntuneWinApp.ps1`). Each script's own `.VERSION` block is the authoritative changelog; this is the merged view, newest first.

- **2026-09-04 — Studio 2.3 / Publish 1.5 / Build 2.2** — Windows PowerShell 5.1 is turned away with one sentence naming the version and the `pwsh` command to use, the studio in a dialog as well. It used to produce 41 parse errors, because the scripts were saved without a BOM and 5.1 read the em dashes as ANSI; they are UTF-8 with BOM now and the self-test checks it.
- **2026-09-04 — Studio 2.3** — Asks for the delegated sign-in with `-SignIn Browser`, so the prompt actually appears when publishing from the GUI.
- **2026-09-04 — Publish 1.5** — A failed sign-in stops the run. It used to be reported and then ignored, so the publish carried on unauthenticated, printed `App created:` with no id, and told you to go delete an app that was never created. `-SignIn` picks how the delegated prompt appears; the studio passes `Browser`, because the default WAM prompt needs a console window to parent itself to and a GUI has none.
- **2026-09-04 — Studio 2.2** — Picking another installer in the wizard refreshes everything derived from the previous file (commands, hint, MSI product code, extracted logo, suggested folder name); hand-edited text is kept and pointed out. A hidden *use the MSI product code* option can no longer stay selected and write an empty product code.
- **2026-09-03 — Studio 2.1** — Built-in help (Help button / F1): a short usage guide for the person packaging the app, with a link to this README.
- **2026-09-03 — Studio 2.0** — Redesigned for low-threshold use: start screen with recent packages and drag-and-drop, single-window editor with live Company Portal preview and readiness checklist, detection reduced to one button with the raw fields behind an expander, advanced settings collapsed, icon extraction from the installer or installed app, Cancel for a running build.
  - Fixes: changing the setup file refreshes the commands and detection; absolute detection-script paths validate; MSI COM handles released; MSI and installed-app lookups cached; engine arguments passed as parameters instead of string concatenation; the window fits small screens.
- **2026-09-03 — Publish 1.4** — Idempotent publishing: `-Update` creates the app when missing and otherwise uploads a new content version to the existing app and re-asserts its metadata (assignments kept); `-AppId` targets one app directly; several apps sharing a name are reported instead of guessed at; `-WhatIf` is a real plan step; the result carries `Action` and `ContentVersion`. In the studio this is the *update it* option under Advanced.
- **2026-09-03 — Publish 1.3** — Refuses to create a second app with the same display name unless `-AllowDuplicateName` is given, checked before anything is created.
- **2026-07-10 — Studio 1.4** — Guided wizard from a vendor installer: engine detection with silent switches for MSI/Inno Setup/NSIS/InstallShield/WiX Burn, installed-apps picker that generates the uninstall-key registry rule and harvests `QuietUninstallString`, remembered package root.
- **2026-07-07 — Studio 1.3** — English UI, neutral publisher default.
- **2026-07-07 — Studio 1.2** — Correct `minimumWindowsRelease` values.
- **2026-07-07 — Studio 1.1** — *From MSI...* product code fetch, manual source tags.
- **2026-07-07 — Build 2.1** — Downloads `IntuneWinAppUtil.exe` from GitHub when it is missing.
- **2026-07-06 — Studio 1.0** — Initial GUI.
- **2026-07-06 — Build 2.0** — Direct script invocation with parameters (no more editing the last line), setup file auto-detection, deterministic output detection, backup pruning, rich `-PassThru` object (SHA256/size/duration), pipeline input for batch builds; fixed console echo and output-stream pollution.
- **2026-07-06 — Publish 1.2** — PSADT metadata: displayName/publisher/version read from the `$adtSession` block (AppVendor/AppName/AppVersion).
- **2026-07-06 — Publish 1.1** — App-only auth via Entra app registration (the `.secret` pattern: certificate thumbprint or client secret), delegated sign-in kept as fallback.
- **2026-07-06 — Publish 1.0** — Initial version: create the `win32LobApp`, chunked content upload, commit.
- **2025-09-24 — Build 1.0** — Initial advanced function version (`SupportsShouldProcess`, `-Clean`, `-Quiet`, `-PassThru`).
