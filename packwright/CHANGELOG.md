# Changelog

Packwright is five components, versioned separately:

| Component | File |
|---|---|
| **Studio** | `Packwright.ps1` (the GUI) and `Packwright.WinGet.ps1` |
| **Build** | `Build-IntuneWinApp.ps1`, and `Packwright.Package.ps1`, which all of them read |
| **Publish** | `Publish-IntuneWinApp.ps1` |
| **WinGet** | `New-WinGetPackage.ps1`, and the device scripts it writes (*runner*) |
| **Test** | `Test-IntuneWinApp.ps1` |

Newest first. A heading names every component the release changed; under a heading that names several, each bullet starts with its component. Why a change was made, and how it was tested, is in its commit message.

## Studio 2.16 · WinGet 1.5 — 2026-11-11

### Added
- Studio: `x64only` can be picked as the architecture, for an app that must not reach ARM64 devices.

### Fixed
- Studio: an unexpected error in a click or a keystroke is written to the log and the window stays, instead of Packwright closing with what was not saved.
- Studio: an `app.json` that cannot be read is said in the status line, and saving keeps it as `app.unreadable-<time>.json` instead of writing over it.
- Studio: a package folder opened with a backslash on the end, as Tab completes it, no longer fails to save with `Cannot overwrite the item ... with itself`.
- Studio: an app whose uninstall key has `[` or `]` in its name is no longer missing from *Find the app on this computer*.
- Studio: a detection method misspelt in `app.json` is no longer shown, and saved, as the method the package opened before had.
- Studio: a test window closed before the test had a result no longer blocks *Test on this computer* for three hours.
- Studio: the link to the app published last goes when another package is opened.
- Studio, WinGet: a WinGet package moved to a version that installs per user has its WinGet requirement rule run as the user too.
- WinGet: `New-WinGetPackage.ps1` takes `-Force`, which its own message asked for when the folder already holds files.

## Build 2.7 · Test 1.6 — 2026-11-10

### Fixed
- Build: a command such as `ServiceUI.exe -Process:explorer.exe Invoke-AppDeployToolkit.exe` no longer stops with `runs -Process:explorer.exe, which is not in this package`.
- Build: a command that starts one of Windows' own tools, such as `regedit.exe` or `certutil.exe`, is no longer reported as running a file the package does not hold.
- Build: a downloaded `IntuneWinAppUtil.exe` is kept only when it carries Microsoft's signature, so a broken download no longer fails every later build.
- Test: a detection or requirement script kept outside the package folder is found, instead of the test reporting *Not detected after install*. A missing one stops the test first.

## Studio 2.15 · Build 2.6 · Publish 1.15 · WinGet 1.4 · Test 1.5 — 2026-11-09

### Fixed
- Studio, Build, Publish, WinGet, Test: `Get-Help` shows each script's synopsis, parameters and examples, not only its syntax; `-Parameter` no longer answers `No parameter matches criteria`.

## Publish 1.14 — 2026-11-09

### Added
- Several `-SourceFolder` folders are a batch: all planned first, reviewed one at a time, the approved ones published one after the other. See [Several packages in one run](README.md#several-packages-in-one-run--plan-review-publish).
- A batch review offers to update an app with a similar name, such as one renamed in the portal, instead of creating a second app.
- `-Batch <file>` publishes what a review approved and is not published yet, unless its files or its app in Intune have changed since.
- `-SourceFolder` takes wildcards, and a name without a folder is looked for in the studio's package folder.

## Publish 1.13 · Test 1.4 · WinGet 1.3 — 2026-11-03

### Added
- Publish: `app.json` may set `returnCodes` (on top of Intune's five), `maxRunTimeInMinutes`, `allowAvailableUninstall` and `isFeatured`. See [App settings](README.md#app-settings--appjson).
- Publish: a key in `app.json` that Packwright does not read is a warning, and a value Intune would refuse stops the publish before anything is created.
- Publish: `app.schema.json` describes every key `app.json` may have, for an editor to complete and check.
- Test: a test install is judged by the package's own return codes and given its `maxRunTimeInMinutes`, as Intune will.
- WinGet: `New-WinGetPackage.ps1 -Refresh <folder>` writes a package's scripts again; with `-Version` or `-Latest` it moves a community package to that version. See [Apps from WinGet](README.md#apps-from-winget--the-microsoft-store-or-the-community-repository).

## Publish 1.12 — 2026-11-03

### Added
- `-SourceFolder` without `-Path` builds the folder first, so one command builds and publishes it. See [Idempotent publishing](README.md#idempotent-publishing--update).
- `app.json` remembers the app a package was published as, per tenant, and the next run goes to that app even after a rename in the portal.
- A package published before stops without `-Update`, naming the app it became, and a copied folder given another name stops until `-AppId` says which app it is.

## Studio 2.14 · Build 2.5 · Publish 1.11 · Test 1.3 — 2026-11-03

**Action:** a script copied out on its own needs `Packwright.Package.ps1` beside it — keep the Packwright scripts together.

### Added
- Publish: stops before anything is created where the studio's checklist stops — a command running a file the package does not hold, a detection rule that cannot match. See [Reusing a package folder](README.md#reusing-a-package-folder-for-the-next-release).
- Publish: the studio's ⚠ lines are printed as warnings, such as a detection rule left on the previous version.
- Publish, Test: a script package's install and uninstall commands are filled in when `app.json` names none, as in the studio.

### Changed
- Build: the setup file is the one `app.json`'s install command runs, as in the studio, so a vendor `.exe` with an `app.json` builds without `-SetupFile`.
- Studio: a folder without `app.json` whose one install script is `Install*.ps1`/`.cmd`/`.bat` opens with that script as the setup file, as Build chooses it.
- Publish: with `-SourceFolder`, an MSI rule without a product code takes it from the one MSI in the package, under `Files\` too, as the studio does.

## Studio 2.13 — 2026-11-02

### Fixed
- In *Install it with WinGet*, a licence that is a whole text, such as VLC's in the Microsoft Store, shows as its first line instead of filling the details.

## Publish 1.10 · Test 1.2 — 2026-11-02

### Added
- Publish: `"architecture": "x64only"` targets x64 devices without ARM64. See [App settings](README.md#app-settings--appjson).
- Publish: `-MetadataOnly` changes the settings of an app Intune has without uploading content. See [Changing settings only](README.md#changing-settings-only--metadataonly).
- Publish: an update lists the settings it changes before changing them, also under `-WhatIf`.
- Publish: the app is read back after publishing; a setting Intune holds otherwise is a warning and is returned in `Differences`.
- Publish: `-SourceFolder` can be given when the script is run directly.
- Test: `-Elevate` asks Windows for administrator rights from a `pwsh` that is not elevated; saying no reports *Not tested*. See [Test on this computer](README.md#test-on-this-computer).

## Studio 2.12 — 2026-10-28

### Fixed
- A search in *Find the app on this computer* that matches exactly one program no longer closes Packwright.
- The hint to install the app and pick it is no longer shown under an MSI, file or script rule, where there is nothing to pick.

## Test 1.1 — 2026-10-28

### Security
- The folder a test runs the package from as SYSTEM can only be changed by SYSTEM and administrators; under `%ProgramData%` any user could put files beside the installer.

### Fixed
- What `app.json` leaves out (PSADT/MSI commands, MSI product code, the MSI rule) is filled in as Publish fills it, so a minimal `app.json` no longer stops at *no install command*.
- A requirement rule without operator or type gets Publish's defaults (`boolean`, `equal`, `true`) instead of never being met.
- Requirement and detection scripts honour `runAs32Bit`.

### Changed
- The WinGet runtime package's log is shown like a WinGet package's, and dependencies (which the test does not install) are listed.

## WinGet 1.2 (runner 1.1) — 2026-10-27

**Action:** packages made before this show their scripts as older — **Refresh the scripts** and publish as an update.

### Fixed
- An install no longer sits at *Installing* until Intune's one-hour timeout when another install holds WinGet's lock: the runner waits for the lock 10 minutes at most, stops winget at 55 minutes and returns `1618` so Intune retries. See [What the scripts do on the device](README.md#what-the-scripts-do-on-the-device).

### Changed
- The runner log lists the winget, WinGet COM server and Windows Installer processes running at the time.
- WinGet's own log is copied beside the runner's when it runs as SYSTEM too.

## Studio 2.11 — 2026-10-20

### Changed
- The studio's WinGet part is a file of its own, `Packwright.WinGet.ps1`, read the first time a session needs WinGet instead of at every start. No change in behaviour.

## Studio 2.10 · Publish 1.9 · WinGet 1.1 — 2026-10-12

### Added
- WinGet: packages get the app's icon — from the Store, the manifest, the installed app, or the installer itself (hash-checked, read without being run). Icons under 128 px give way to larger ones.
- Studio: **Use the app's own icon** works for WinGet packages.
- Studio: the header names the account publishing signs in as; **Sign in again** forgets the remembered sign-in, which is needed after activating an Intune role in PIM.
- Publish: every run logs the account, tenant, sign-in time and Entra roles, and a `403 Forbidden` is explained from them.
- Publish: `app.json` may set `roleScopeTagIds`, for accounts whose Intune role is limited to scope tags.

## Studio 2.9 · Publish 1.8 · WinGet 1.0 · Test 1.0 — 2026-10-08

### Added
- WinGet: **Apps from WinGet** — pick an app from the Microsoft Store or the WinGet community repository and get a package that installs it with WinGet. Install context, installer and detection rule come from the manifest. See [Apps from WinGet](README.md#apps-from-winget--the-microsoft-store-or-the-community-repository).
- WinGet: detection uses what outlives self-updates — MSIX package family, MSI upgrade code, a version-less uninstall key, or `winget list`.
- WinGet: `Packwright.policy.json` decides which sources may be used, enforced by the studio, `New-WinGetPackage`, Publish and the script on the device.
- WinGet: a Store app can be published as Intune's own Store app type instead.
- WinGet: the WinGet runtime package (App Installer and the Visual C++ runtime), linked to apps by a requirement rule rather than a dependency.
- Publish: `app.json` may carry requirement rules, dependencies (existing supersedence is kept), a privacy URL and a developer.
- Test: `Test-IntuneWinApp.ps1` installs or uninstalls a package as Intune would — as SYSTEM, from a copy, from a 32-bit process — and offers a detection rule. See [Test on this computer](README.md#test-on-this-computer).

### Fixed
- Publish: with several packages piped in, the later ones no longer update the app the first one created.
- Studio: a command no longer reports a script's arguments as missing files.

## Studio 2.8 — 2026-10-02

### Added
- Packwright has its own taskbar button and icon, and a pinned button starts Packwright.

## Studio 2.7 — 2026-09-24

### Changed
- The description box can be resized by dragging its corner, and starts at four lines (two in the wizard).

## Publish 1.7 — 2026-09-24

### Fixed
- `-Update` on an existing app no longer fails after the upload with an `ApplicableArchitectures` error; the architecture is sent as `allowedArchitectures`, and `x64` still includes ARM64. See [App settings](README.md#app-settings--appjson).
- An architecture Intune cannot target is refused before anything is created.

## Studio 2.6 · Build 2.4 — 2026-09-22

### Added
- Studio: packages that install with a script (`.ps1`, `.cmd`, `.bat`), with install and uninstall commands derived for them. See [Packaging a folder that installs with a script](README.md#packaging-a-folder-that-installs-with-a-script).
- Build: a single `Install*.ps1`/`.cmd`/`.bat` is auto-detected as the setup file.

### Changed
- Studio: an install command in `app.json` decides which file is the setup file.

### Fixed
- Studio: a detection script the package does not hold is no longer shown as a finished rule.

## Studio 2.5 · Publish 1.6 · Build 2.3 — 2026-09-08

### Added
- Studio: what a reused package folder carries over from the previous release is caught before publishing — commands naming files no longer there, an empty install command, the old MSI product code, a version rule left on the old version. See [Reusing a package folder](README.md#reusing-a-package-folder-for-the-next-release).

### Fixed
- Studio: a `[` in the installed-app search box no longer closes Packwright.
- Studio: an `app.json` value none of the dropdowns offers is kept instead of replaced with the previous package's.
- Studio: closing the window during a run asks first and stops the run.
- Studio: an Inno Setup installer on a share no longer comes back as `unknown` with no silent switches.
- Studio: a new release saved under the same MSI file name no longer keeps the previous product code.
- Build: a build that wrote no `.intunewin` no longer reports an older one as its output.
- Publish: a duplicate-name check that could not run stops the publish instead of creating a duplicate.
- Publish: `-AllowDuplicateName` is refused together with `-AppId`.
- Publish: block uploads are retried on no response, 408, 429 and 5xx.

## Studio 2.4 — 2026-09-04

### Added
- Settings dialog for the package and output folders, asked once on first run; both default to a local disk.

### Fixed
- A package folder on a network share no longer fails with `Could not read MSI properties`.
- `Cannot validate argument on parameter 'OutputRoot'` when building from the studio.
- An empty `settings.json` is written over instead of throwing `Cannot index into a null array`.
- A background run that returns nothing is logged instead of closing the window.

## Studio 2.3 · Publish 1.5 · Build 2.2 — 2026-09-04

### Changed
- Windows PowerShell 5.1 is turned away with one sentence naming `pwsh`, instead of 41 parse errors.
- Publish: `-SignIn` picks how the sign-in prompt appears; the studio uses `Browser`, so the prompt appears when publishing from the GUI.

### Fixed
- Publish: a failed sign-in stops the run instead of carrying on unauthenticated.
- Build: a UNC source folder no longer fails with `The setup file you specified cannot be accessed`.

## Studio 2.2 — 2026-09-04

### Fixed
- Picking another installer in the wizard refreshes the commands, MSI product code, logo and suggested folder name; hand-edited text is kept and pointed out.
- A hidden *use the MSI product code* option can no longer write an empty product code.

## Studio 2.1 — 2026-09-03

### Added
- Built-in help (Help button / F1) with a link to the README.

## Studio 2.0 — 2026-09-03

### Changed
- Redesigned: start screen with recent packages and drag-and-drop, one-window editor with Company Portal preview and readiness checklist, one-button detection.

### Added
- Icon from the installer or the installed app; Cancel for a running build.

### Fixed
- Changing the setup file refreshes the commands and detection; absolute detection-script paths validate; the window fits small screens.

## Publish 1.4 — 2026-09-03

### Added
- `-Update` creates the app when missing, and otherwise uploads a new content version and keeps its assignments. In the studio: *update it* under Advanced. See [Idempotent publishing](README.md#idempotent-publishing--update).
- `-AppId` targets one app directly; `-WhatIf` shows the plan.

### Changed
- Several apps sharing a name are reported instead of guessed at.

## Publish 1.3 — 2026-09-03

### Added
- Refuses to create a second app with the same display name unless `-AllowDuplicateName` is given.

## Studio 1.4 — 2026-07-10

### Added
- Guided wizard from a vendor installer, with silent switches for MSI, Inno Setup, NSIS, InstallShield and WiX Burn.
- Installed-apps picker that writes the uninstall-key detection rule and takes the `QuietUninstallString`.

## Studio 1.3 — 2026-07-07

### Changed
- English UI; neutral publisher default.

## Studio 1.2 — 2026-07-07

### Fixed
- Correct `minimumWindowsRelease` values.

## Studio 1.1 — 2026-07-07

### Added
- *From MSI...* fetches the product code; manual source tags.

## Build 2.1 — 2026-07-07

### Added
- Downloads `IntuneWinAppUtil.exe` from GitHub when it is missing.

## Studio 1.0 — 2026-07-06

- Initial GUI.

## Build 2.0 — 2026-07-06

### Added
- Run as a script with parameters, setup file auto-detection, a `-PassThru` object (SHA256, size, duration), pipeline input for batch builds.

### Fixed
- Console echo and output-stream pollution.

## Publish 1.2 — 2026-07-06

### Added
- Display name, publisher and version read from a PSADT package's `$adtSession` block.

## Publish 1.1 — 2026-07-06

### Added
- App-only sign-in through an Entra app registration (`.secret`), with delegated sign-in as fallback.

## Publish 1.0 — 2026-07-06

- Initial version: creates the `win32LobApp`, uploads the content in chunks and commits it.

## Build 1.0 — 2025-09-24

- Initial advanced-function version (`-Clean`, `-Quiet`, `-PassThru`, `-WhatIf`).
