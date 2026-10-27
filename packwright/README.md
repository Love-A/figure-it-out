# Packwright

Package a Windows application and publish it to Microsoft Intune — from a window or from a script.

Point it at the installer you got from a vendor and it works out the silent switches, writes the detection rule from the app's own uninstall entry, builds the `.intunewin` and creates the Win32 app in Intune. Or pick an app from the **Microsoft Store** or the **WinGet repository** and let each device install it with WinGet. Everything it decides is visible and editable first, and it all lands in a plain `app.json` you can commit, review and replay.

Five PowerShell scripts — the GUI in two files — and no dependencies beyond `Microsoft.Graph.Authentication`:

1. **`Packwright.ps1`** — the GUI: a guided wizard for occasional packagers and a full editor for everyone else. Start it with `.\Packwright.ps1` (optionally `-SourceFolder <path>`, `-Installer <file>`, or `-Wizard`). Its WinGet part — the WinGet dialog, the WinGet card in the editor and the runtime package — is **`Packwright.WinGet.ps1`**, which it reads, with `New-WinGetPackage.ps1`, the first time a session needs WinGet. Keep the two files together; it is not run on its own.
2. **`Build-IntuneWinApp.ps1`** — packages a source folder into `.intunewin` using Microsoft's **IntuneWinAppUtil.exe** (downloaded automatically when missing), with logging, backups and safe overwrite handling.
3. **`Publish-IntuneWinApp.ps1`** — creates or updates the Win32 app in Intune via Microsoft Graph: metadata, detection and requirement rules, dependencies, chunked content upload, commit. Idempotent with `-Update`, so the same spec can be applied from a scheduled task or a pipeline. Also publishes Intune's own Microsoft Store app type.
4. **`New-WinGetPackage.ps1`** — writes a package folder that installs an app with WinGet, from the Microsoft Store or the community repository, with the detection rule taken from the app's manifest; and the *WinGet runtime* package every device needs once. See [Apps from WinGet](#apps-from-winget--the-microsoft-store-or-the-community-repository).
5. **`Test-IntuneWinApp.ps1`** — installs or uninstalls any package on this computer the way Intune would (as SYSTEM, from a copy, started from a 32-bit process) and checks the requirement and detection rules. See [Test on this computer](#test-on-this-computer).

**Requirements:** Windows with PowerShell 7+, and an Intune tenant you may create apps in. `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser` covers the only dependency — run it **from `pwsh`, as the account that will run Packwright, unelevated**. From Windows PowerShell 5.1 it installs into `Documents\WindowsPowerShell\Modules`, which PowerShell 7 does not read; elevated with `-Scope CurrentUser` it installs into the administrator's profile instead of yours. Both look like a successful install and then like a missing module. A third case behaves the same way: on a machine where Documents is redirected, `-Scope CurrentUser` puts the module in the **network home directory**, where it is found but may not load. `-Scope AllUsers` from an elevated `pwsh` puts it on the local disk and avoids all three. Packwright names the path it found and repeats PowerShell's own reason when a load fails. To see what this PowerShell actually has:

```powershell
$env:PSModulePath -split ';'; Get-Module -ListAvailable Microsoft.Graph.Authentication | Select-Object Version, Path
```

Start it with `pwsh`, not `powershell`. *Run with PowerShell* in Explorer hands a `.ps1` to Windows PowerShell 5.1, and all five scripts stop there with a single sentence telling you so — the studio in a dialog as well, since a double-click leaves no console to read. Keep the scripts saved as **UTF-8 with BOM**: without one, 5.1 decodes the em dashes as ANSI and dies in parse errors before it reaches that message. The self-test checks the BOM is still there.

Packwright gets a taskbar button and an icon of its own instead of sharing PowerShell's. To start it from the taskbar next time, right-click that button and choose **Pin to taskbar**. The pin runs `pwsh -STA -File` on the script where it was when you pinned it, so pin it again if you move the folder.

### The GUI in one screen

It opens on a **start screen** with three choices — *I have an installer file* (guided wizard), *Install it with WinGet* and *I have a package folder* — plus your recent packages. You can also drop a package folder, an installer or an install script straight onto the window; a script opens the folder around it with that script already chosen as the setup file.

Once a package is open, the editor shows everything the Intune app will contain:

- **App information** — name, publisher, version, description, each with a tag saying where the value came from (`app.json` / `PSADT` / `MSI` / `installer` / `edited by hand`).
- **Detection** — written in plain language ("Intune reads DisplayVersion under the registry key 7-Zip and treats the app as installed when it is at least 24.08"), with one button — **Find the app on this computer...** — that generates the rule for you. The raw Intune fields live behind *Change detection method* for when you need them.
- **Advanced** — install/uninstall commands, run-as, restart behaviour, architecture, minimum Windows and the setup file, collapsed by default because most packages never need them. The setup file can be an `.exe`, an `.msi` or a `.ps1`/`.cmd`/`.bat` — see [Packaging a folder that installs with a script](#packaging-a-folder-that-installs-with-a-script).
- **Preview** — how the app will look in the Company Portal, live as you type.
- **Logo** — *Use the app's own icon* extracts the real icon (up to 256×256) from the installed app or the package payload; or choose a png/jpg.
- **Ready to publish** — a live checklist of what Intune requires, plus what this package can be shown to have wrong. Nothing is a surprise at publish time: if something is missing, the field is highlighted and focused instead of a dialog appearing. Below the checklist, anything that is *probably* wrong is stated in ⚠ lines that never block — see [Reusing a package folder for the next release](#reusing-a-package-folder-for-the-next-release).
- **Installed with WinGet** — only for a WinGet package: where the app comes from, the version devices get and the next one there is, and whether its scripts are still the ones Packwright wrote.

**Test on this computer** in the action bar installs or uninstalls the package here the way Intune would — see [Test on this computer](#test-on-this-computer).

**Help** in the header (or **F1**) opens a short usage guide written for whoever is packaging the app — what Intune insists on, how detection works and what to do when a publish fails — with a button to open this README for the full picture. The guide lives in `$script:HelpTopics` at the top of the help region in the script; keep it short, and leave setup, sign-in and command-line detail here in the README.

Then **Publish to Intune** builds the `.intunewin` and creates the app, with a live log, progress and **Cancel**. Closing the window while that runs is asked about first — the run ends with the window, and an interrupted publish can leave an app in Intune with no content. A confirmation dialog repeats the name, version and detection rule first. Corrections are always written back to `app.json` in the package folder, so the GUI and the command line stay interchangeable.

**If the app already exists in Intune:** publishing stops before anything is created — the easy mistake when re-publishing. Under *Advanced* you can instead choose to **update it** (this package becomes a new version of that app, assignments kept) or to create a second app anyway. On the command line those are `-Update` and `-AllowDuplicateName`.

## Guided mode — from vendor installer to published app

Made so that a stand-in with little packaging experience can publish a simple app. Pick **"I have an installer file"** on the start screen (or start with `-Wizard` / `-Installer <file>`) and a five-step wizard runs the whole flow:

1. **Installation file** — point at the `.exe`/`.msi` you got from the vendor. The tool identifies the installer engine and prefills the silent commands: MSI (`/qn`), Inno Setup (`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-`), NSIS (`/S`), InstallShield (`/s /v"/qn"`), WiX Burn (`/quiet`). Name/publisher/version are read from the MSI properties or the exe's version info. You also pick where package folders are created (prefilled from **Settings**, see below). If you go back and pick a different file, everything the tool derived from the old one — commands, hint, MSI product code, extracted logo, suggested folder name — follows the new file; anything you typed yourself is left alone, with a note saying so.
2. **App information** — how the app will appear in Intune/Company Portal, plus the install/uninstall commands. Everything prefilled where possible, everything editable.
3. **Detection** — for MSI the product code is used automatically. For exe installers, click **"Choose installed program..."**: a searchable list of this computer's Apps & features entries; picking the app generates the uninstall-key registry rule (`DisplayVersion` ≥ version, WOW6432Node handled) and harvests a silent uninstall command from `QuietUninstallString` when available. If the app isn't installed yet, run the installer once on your machine first — that's the whole trick. Detection can also be deferred, but publishing stays blocked until it's set.
4. **Logo** — optional Company Portal icon.
5. **Summary** — creates the package folder (installer copied in, `app.json` written) and either opens it in the studio for review or builds and publishes to Intune in the same run.

The same installed-programs picker is available in the editor as **"Find the app on this computer..."**. The wizard's output is a plain package folder with `app.json`, so it works identically with the scripts.

Run `.\Packwright.ps1 -TestLoad` to build every window and run the headless self-test suite without showing the UI — useful after any change. Run it that way, not as `pwsh -File Packwright.ps1 -TestLoad`: the two differ in scope handling, and a handler written as a `.GetNewClosure()` fails only under the first (a closure gets a module scope of its own, where the functions in the file are out of reach). A self-test reads the source for that pattern, since no run can be relied on to hit it. It prints a PASS/FAIL line per check and exits non-zero on failure. Set `PACKWRIGHT_TESTPACKAGES` to a semicolon-separated list of your own package folders to have them opened as part of the run.

The suite finishes with an **end-to-end build**: the same run body the Publish button uses, in a real runspace, dot-sourcing both engines and calling `IntuneWinAppUtil.exe` for real (no publishing). That is the only path the rest of the suite cannot reach, and the bugs that cost the most have lived in it. It runs whenever `IntuneWinAppUtil.exe` is already next to the script or in `C:\IntuneWinAppUtil`; otherwise it is skipped, and `PACKWRIGHT_TESTBUILD=1` lets the engine download the tool so it can run anyway.

## Apps from WinGet — the Microsoft Store or the community repository

Pick **Install it with WinGet** on the start screen, choose where the app comes from, and search. The package holds a few scripts and the app's icon, and each device installs the app with WinGet when Intune tells it to.

**Two sources, and the difference matters:**

| | Microsoft Store (`msstore`) | WinGet community repository (`winget`) |
|---|---|---|
| Who vets it | Microsoft certifies every app | Volunteers review manifests on GitHub |
| Where the installer comes from | The Store's own servers — for Win32 apps from the Store (ids starting `XP`) too — checked against a SHA-256 | Each publisher's own site, checked against the SHA-256 in the manifest |
| Versions | Only the newest | Every version still listed; Packwright pins one |
| Updates | MSIX apps: the Store keeps them current. Win32 apps: their own updater, if any | Pick the next version in Packwright and publish again |

An organisation that wants nothing but the curated Store says so once, in **`Packwright.policy.json`** next to the scripts — see [Allowing only the Microsoft Store](#allowing-only-the-microsoft-store).

**What Packwright works out from the manifest**, before anything is installed anywhere:

- **SYSTEM or the signed-in user.** An installer that installs per user runs as the user; one that installs for every user runs as SYSTEM. (A per-user installer run as SYSTEM installs into SYSTEM's own profile, where nobody sees it, and reports success.)
- **Exactly which installer.** The architecture and the installer type are passed to winget (`--architecture x64 --installer-type wix`). Intune's x64 includes ARM64 devices, and an ARM64 device left to choose takes the arm64 installer — a different product code, a detection rule that never matches, a reinstall every day. 7-Zip has an `.exe` and an `.msi` for x64, and winget would take the `.msi`.
- **The detection rule**, on something that outlives the version installed today. Apps update themselves, and a rule on today's product code stops matching the day one does: Intune installs on top, WinGet answers that a newer version is already there, and the device reports a failure. So it is the MSIX package family for a Store app; an MSI's **upgrade code**, which stays the same from release to release; an uninstall key with no version in it (7-Zip's `7-Zip`); and for everything else the device asks **WinGet** itself (`winget list --id`), which recognises the app the way `winget upgrade` does. A pinned package is detected as *that version or newer*, so publishing the next version as an update upgrades the devices. No test install needed.
- **What cannot work:** a Store app that is not free, or not offered in the devices' market, is refused with the reason. The market is the **country or region set in Windows** on the computer packaging, unless `storeMarket` in the policy says otherwise.

The dialog shows all of this before anything is written — the `winget install` command each device will run, how it is detected, and anything worth a second look.

**How it is delivered.** A community app is always a Win32 app. A Store app can be either:

- **a Win32 app with WinGet scripts** (default) — logs, retries, a detection rule you can see and test, and the same model as every other Win32 app; or
- **Intune's own Microsoft Store app type** — nothing to build or upload, and Intune installs, detects and updates it itself. **Choose this where the Microsoft Store app is blocked on the devices** (for example *Turn off the Store application*): WinGet's command line then refuses every Store install with `0x8A15001B`, while Intune's own Store app type is not affected, because Intune drives WinGet through an interface that skips that check.

**The package folder** holds `Install-WinGetApp.ps1`, `Uninstall-WinGetApp.ps1`, `Require-WinGetRuntime.ps1`, a `Detect-WinGetApp.ps1` when the rule is a script, the app's icon and `app.json` — whose `winget` block is what all of it is written from.

**The icon** comes from the first place that has one at a size the Company Portal shows sharply (128 px), the best one found otherwise: the Microsoft Store (for its Win32 apps, the `XP` ids, from the app's page in the web Store), the manifest, the app when it is installed on this computer, and else the installer itself — downloaded, checked against the manifest's SHA-256, read without being run, and deleted again; an MSI without an icon is followed by the app's `.exe`. Installers over 200 MB are not fetched for an icon. **Use the app's own icon** under Logo does the same for a package that has none yet. The install command names the source and the id, so the Intune portal shows where every app comes from:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install-WinGetApp.ps1" -Id 7zip.7zip -Source winget -Version 26.04 -Scope machine -Architecture x64 -InstallerType wix
```

### What the scripts do on the device

Intune starts the install command from a **32-bit** process, under **Windows PowerShell 5.1**, as SYSTEM (or as the user). The scripts are written for exactly that — plain ASCII, 5.1 syntax, saved with a BOM so a name with å, ä or ö survives — and they:

1. start again as **64-bit**, with the arguments exactly as Intune passed them (the 32-bit PowerShell sees `Program Files (x86)` as Program Files and cannot load the AppX cmdlets);
2. stop with `0x8A15003A` when App Installer, its command line or the source is **turned off by policy** on the device, naming the policy;
3. find **`winget.exe` the way SYSTEM has to** — SYSTEM has no `winget` command, so it runs the newest `winget.exe` in the App Installer folder under `WindowsApps` by its full path — and check that it **starts** (started that way it needs the Visual C++ runtime, and dies with `0xC0000135` without it) and is at least **1.29.280**;
4. wait, **ten minutes at most, for WinGet's install lock**. WinGet runs one installation at a time: before it starts an installer, `winget.exe` waits for a lock another installation may hold, for as long as that takes, and says nothing while it waits when its output is captured. One installation that never lets go — an installer that hangs, a stuck WinGet COM server — would leave every later one on the device at *Installing* until Intune gives up after an hour. The script looks at the lock first, waits for it where the log shows it, and after ten minutes ends with `1618` without starting winget, naming the winget, WinGet COM server and Windows Installer processes running then;
5. install with `--source X --dependency-source X`: the app and everything it pulls in come from that one source, with no fallback to another configured one. winget gets **until 55 minutes have passed**, inside Intune's own limit of 60: one still running then is stopped — not the installer it started, which could be left half done — and the run ends with `1618`, so Intune tries again rather than reporting only a timeout;
6. turn WinGet's result into what Intune acts on:

| Exit code | Means | Intune |
|---|---|---|
| `0` | Installed — also when WinGet finds it already installed, or a newer version | Success; the detection rule has the last word |
| `1618` | Not ready yet: WinGet missing or too old, another install running or holding WinGet's install lock for ten minutes, winget stopped at the 55-minute limit, the app in use, no network, a download that failed | Tries again after 5 minutes, three times |
| `3010` / `1641` | A restart finishes it / the installer started one | Soft / hard reboot |
| `0x8A15…` | WinGet's own error, passed through | Failed — look it up with `winget error 0x8A150011` |

Everything is logged to `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\Packwright-WinGet-<id>.log` (with WinGet's own log and the installer's beside it), so **Collect diagnostics** brings it along. A per-user install that cannot write there logs to `%TEMP%`.

The detection and requirement scripts write their answer and nothing else, and never anything to the error stream — Intune reads any output as *detected*, and anything on the error stream as *not installed*.

Uninstalling goes by the WinGet id; when WinGet cannot — the source has been turned off since, say — it falls back to the product code, and for an MSIX app to removing the app package for every user. It waits for the install lock and stops winget at the time limit the same way.

### The WinGet runtime package

Every device needs WinGet that works for SYSTEM: App Installer **1.29.280 or later** (the first that installs a Store app for every user as SYSTEM and provisions it), and the Visual C++ runtime. Most Windows 11 devices have the first; an image often lacks the second; a device where Store updates are blocked has an old App Installer for ever.

**Create the WinGet runtime package** (in the WinGet card or the WinGet dialog) builds one Win32 app that sees to both, from the latest winget-cli release on GitHub and Microsoft's Visual C++ runtime — about 330 MB, each file checked against its published SHA-256 and Microsoft's signature before it goes into the package. On a device it installs only what is missing or older, provisions App Installer so every user gets it, and checks that winget then starts. It removes nothing when uninstalled. **Publish it once and assign it to all devices**, and add it to the Enrollment Status Page's blocking apps so new devices have it before their user apps arrive.

Each WinGet app waits for it through a **requirement rule** (`Require-WinGetRuntime.ps1`): on a device without a ready WinGet the app is *not applicable* rather than failed, and is installed once the runtime has run. That is the default for a reason. The alternative — making each app **depend** on the runtime app (`"runtimeLink": "dependency"`) — guarantees the order, but Intune counts every app that shares a dependency into one graph of **at most 100 apps**, so it stops at about 99 WinGet apps; and the Company Portal hides the uninstall button for any app with a dependency. Packwright never sets both: a requirement that waits for the runtime would keep Intune from ever installing the dependency that provides it.

### Allowing only the Microsoft Store

Copy [`Packwright.policy.example.json`](Packwright.policy.example.json) to **`Packwright.policy.json`** next to the scripts, and keep it with them:

```json
{ "winget": { "allowedSources": [ "msstore" ] } }
```

`allowedSources` is the one key a policy file must have. The others are optional, and the example file explains each: `defaultSource`, `storeMarket` (two letters, for when the devices are in another country than the people packaging), `storeLocale`, `storeDelivery`, `runtimeLink` and `runtimeAppName`.

Then nothing from the community repository is offered, written or published — and it is checked in four places, so a script, a hand-edited `app.json` or another copy of the studio does not get round it:

1. **the studio** offers only the Store, and says why;
2. **`New-WinGetPackage.ps1`** refuses to write a community package;
3. **`Publish-IntuneWinApp.ps1`** checks the policy again before anything is created — whoever runs it — and, because a script changed by hand can install from anywhere whatever its command line says, refuses scripts and commands that are not the ones Packwright wrote;
4. **the script on the device** takes only `msstore` or `winget` and always installs with `--source msstore --dependency-source msstore`.

A policy file that cannot be read allows **nothing** — "msstore only" with a stray comma did not mean "everything" — and neither does one without `allowedSources`, so a misspelled key cannot open everything up. Keys are read whatever their case; one Packwright does not know is pointed out. The Settings dialog shows what the policy says.

`Packwright.policy.json` is a guardrail for the people packaging, not a lock on the devices. The lock is App Installer's own policy, in the Settings catalog under *Administrative Templates > Windows Components > Desktop App Installer*: **Enable App Installer Default Source = Disabled** takes the community repository away from every winget on the devices, manual use included, and **Enable App Installer Microsoft Store Source** must stay enabled. The scripts read those policies and say which one stopped them.

### Things to know

- **The Store app blocked by policy** stops WinGet's command line, not Intune's Store app type — see above. Packwright warns when this computer has that policy.
- **Pinned versions disappear.** The community repository drops a version when its download link breaks. The WinGet card says when the pinned version is no longer listed, and when there is a newer one: pick it and publish again with *Update* — commands, scripts, detection and the version label all follow.
- **"Latest" is decided per device**, on the day it installs. Intune does not upgrade it after that.
- **SYSTEM uses the machine proxy** (WinHTTP), not the user's. A device behind a proxy that needs a signed-in user cannot download.
- **Installer language**: SYSTEM's language decides which localized installer winget picks. Add a `"locale"` such as `"de-DE"` to the `winget` block to choose.
- **One market per package.** The Store sells per country. A Store app is checked against one market when it is packaged; a device set to a country where the Store does not offer it fails with `0x8A150010`, and its log says so. With devices in several countries, check the app is offered in each.
- **Detection by asking WinGet** is the fallback for an app whose manifest names nothing lasting. It needs WinGet on the device — which the requirement rule already sees to — takes a few seconds per check, and for a Store app reaches the Store's catalog. [Test on this computer](#test-on-this-computer) shows what it finds.

On the command line:

```powershell
.\New-WinGetPackage.ps1 -Search whiteboard -Source msstore                  # find an id
.\New-WinGetPackage.ps1 -Id 9MSPC6MP8FM4 -Source msstore                    # a Store app
.\New-WinGetPackage.ps1 -Id 7zip.7zip -Source winget -Version 26.04         # pinned
.\New-WinGetPackage.ps1 -Id 9MSPC6MP8FM4 -Source msstore -Delivery store    # as Intune's Store app type
.\New-WinGetPackage.ps1 -Runtime                                            # the WinGet runtime package
```

The folder it writes builds and publishes like any other — or, for Intune's Store app type, publishes with `Publish-IntuneWinApp -ManifestPath <folder>\app.json` alone.

## Test on this computer

**Test on this computer** in the action bar (or `Test-IntuneWinApp.ps1` from an elevated `pwsh`) installs the package here the way Intune would:

- from a **copy** of the package folder, as Intune extracts it, with that as the working directory;
- as **SYSTEM** through a one-off scheduled task — or, for an app that installs per user, as the person signed in at the console, never as the administrator who elevated;
- started from a **32-bit** `cmd.exe`, so `powershell.exe` in a command is the 32-bit PowerShell, as on a device;
- with the **requirement rules** checked first (an app that is not applicable is not run) and the **detection rule** checked before and after, in that same account — an app already detected is not installed again, as Intune would not;
- judged as Intune judges it: by the **exit code** first (0, 1707, 3010 and 1641 succeed, 1618 is tried again, anything else failed, whatever the detection then finds), and only after a success by the detection rule — waiting for the command itself, not for anything it leaves running.

It reports the exit code and what it means, the detection result, the Apps and features entries the install added, and the WinGet log for a WinGet package. When the detection rule did not find the app, Packwright offers to write the rule from the entry the install added. The app really is installed; the same button's **Uninstall** removes it, which tests the uninstall command too.

```powershell
.\Test-IntuneWinApp.ps1 -SourceFolder "C:\IntunePackages\7-Zip 26.04"
.\Test-IntuneWinApp.ps1 -SourceFolder "C:\IntunePackages\7-Zip 26.04" -Action Uninstall
```

## Reusing a package folder for the next release

7-Zip 24.08 → 25.01 is the same package with three things changed, so the way to do it is to copy the folder, drop the new binary in beside the old one, delete the old one, and open the copy. `app.json` comes with it and everything you already decided is still there.

The three things that must change are exactly the three that a copy carries over silently, and each of them fails *after* publishing rather than during it. So Packwright checks them:

| What the copy keeps | What it does if left | Where it shows |
|---|---|---|
| `installCommandLine` naming the old file (`"7z2408-x64.exe" /S`) | Intune runs a file that is not in the package — every device fails | **Checklist**, blocking: *The install command runs 7z2408-x64.exe, which is not in this package* |
| An MSI rule holding the previous MSI's product code | Detection never matches what was installed | **Checklist**, blocking: the rule is not counted as finished |
| `detectionValue` left on the old version (`DisplayVersion ≥ 24.08`) | Intune finds the old release, calls the app installed, and the upgrade never runs — reported as success | **⚠ line**, not blocking |

Picking the new file under *Advanced → Setup file* does most of it for you: the commands are re-derived, a command naming the file you just replaced is rewritten (a hand-edited one that still runs something present in the folder is left alone, as before), and an MSI product code follows the new MSI. Editing the version carries the detection comparison with it whenever that comparison was the version — so bumping 24.08 to 25.01 in one field moves the rule too, and the log says it did.

Only what can be proven wrong blocks the publish. The rest is stated in ⚠ lines under the checklist and left to you:

- the detection rule compares against a different version than the package is labelled with
- the setup file reports a different version than the package is labelled with (`24.08` and `24.8.0.0` count as the same release — the MSI pads, the vendor does not)
- the uninstall command still removes the product code of the MSI that was replaced

An `app.json` is also just a file, so the other way round works too: keep it in git, and `Publish-IntuneWinApp -Update` applies the same spec as often as you like. See [Idempotent publishing](#idempotent-publishing--update).

## Settings — where Packwright keeps things

**Settings** in the header opens them, and the first run asks once, so nobody has to go looking for the JSON file after something has already failed. Both live in `%APPDATA%\Packwright\settings.json`.

| Setting | What it is | Default |
|---|---|---|
| `PackageRoot` | Where the wizard creates a folder per package (installer + `app.json`). | `%USERPROFILE%\IntunePackages` |
| `OutputRoot` | Where built `.intunewin` files are written. | `Output`, next to the script |

Both defaults are on a **local disk** deliberately. On a managed machine Documents is usually redirected to a network home directory, and packaging from there fails in ways that name the wrong culprit: the WindowsInstaller COM object refuses to open the MSI (`Could not read MSI properties from ...`), and `IntuneWinAppUtil.exe` reports `ERROR The setup file you specified cannot be accessed` — while still exiting 0, so the build only fails at the point where no `.intunewin` turns up. `%USERPROFILE%` stays local even when Documents does not, which is why the default hangs off it rather than off `MyDocuments`. The settings dialog says so if you point either folder at a share, and the build log repeats it for a package opened by hand from one.

Paths are resolved with `.ProviderPath`, never `PathInfo.Path`: for a UNC path the latter is provider-qualified (`Microsoft.PowerShell.Core\FileSystem::\\server\share\...`), `Join-Path` carries the prefix along, and nothing outside PowerShell can open the result. The self-test scans all three scripts for that mistake.

## Quick start

```powershell
# One-off build (setup file is auto-detected for PSADT, MSI and single-install-script packages)
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
- Auto-detects the setup file: `Invoke-AppDeployToolkit.exe` (PSADT), a single `.msi`, or — in a folder with no `.msi` — a single `Install*.ps1` / `.cmd` / `.bat`. Override with `-SetupFile`, which has always taken any file: `IntuneWinAppUtil.exe` records whatever it is handed and only reads properties out of an `.msi`.
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
| `-SetupFile` | Setup file inside the source folder — any file the package installs from, an install script included. Optional — auto-detected. |
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

If neither `.secret` nor `-ClientId` is present, the script falls back to delegated interactive sign-in (browser) with the same permission as a delegated scope. Already-connected matching sessions are reused. **Microsoft Graph PowerShell remembers that sign-in on the computer** (in `.mg` in your profile) and uses it again without a prompt until it expires — for every script that uses Graph, not just this one — so a publish often asks nothing at all. The studio's header shows the remembered account, and every publish logs the account and tenant it signed in as.

**A sign-in carries the roles the account had when it signed in.** Activate an Intune role in PIM after that, and Intune answers `403 Forbidden` (*User is not authorized to perform this operation*) until the remembered sign-in expires, which can be hours. **Sign in again** in the studio's header forgets it and opens a new sign-in in the browser, with the roles the account has now; it is also how to sign in as another account. From PowerShell: `Disconnect-MgGraph` (in a session that is connected) and `Remove-Item ~\.mg\mg.authrecord.json, $env:LOCALAPPDATA\.IdentityService\mg.msal.cache.*`, then publish again - `Disconnect-MgGraph` alone leaves the tokens Graph keeps in `%LOCALAPPDATA%\.IdentityService`, and the next request goes on using one from before PIM.

Every publish also logs **when the sign-in was made and which Entra roles it carries**, read from its own access token on the computer (the token is decoded there and sent nowhere). A `403 Forbidden` is explained from the same facts: without an administrator role in the sign-in, it says to activate the role first and sign in again — or, when the rights come from a role assigned in Intune itself, that the role needs *Mobile apps: Create* and that an assignment limited to scope tags needs `roleScopeTagIds` in `app.json`; with Intune Administrator in the sign-in, it points at Multi Admin Approval or a role too new for Intune to see yet.

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
| Architecture / min OS | `x64`, ARM64 devices included (see below) / Windows 10 1607. |
| Scope tags | None given, so Intune files the app under *Default*. An account whose Intune role is limited to some scope tags may not create an app there and gets `403 Forbidden`: give the tags' ids, `"roleScopeTagIds": ["3"]` (Tenant administration > Roles > Scope tags shows them). |

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

Beyond the detection rule, `app.json` may carry:

```jsonc
// Requirement rules: a PowerShell script that has to answer before Intune offers the app.
// A device that does not meet one reports the app as not applicable, not failed.
"requirements": [ { "type": "script", "scriptFile": "Require-WinGetRuntime.ps1", "displayName": "WinGet is ready",
                    "runAsAccount": "system", "detectionType": "boolean", "operator": "equal", "detectionValue": "true" } ],

// Dependencies on other Win32 apps, by display name or appId. Looked up before anything is
// created; set after the upload without dropping what the app already supersedes.
"dependencies": [ { "displayName": "WinGet runtime", "autoInstall": true } ],

// Shown in the Company Portal / to administrators
"privacyInformationUrl": "https://example.com/privacy", "developer": "Contoso", "informationUrl": "...", "owner": "...", "notes": "..."
```

A WinGet package also has a `winget` block, which is what its commands and scripts are written from — leave it to Packwright.

`minimumWindowsRelease` must use the exact ids the Intune service knows: build-number style for older releases (`1607`, `1809`, ...) and `Windows10_21H2` / `Windows10_22H2` / `Windows11_21H2` / `Windows11_22H2` for newer ones. Bare `22H2` is rejected with `400 Unknown MinimumSupportedWindowsRelease`.

`architecture` takes `x64`, `x86`, `arm64`, a comma list of them (`x86,x64`), or `neutral` for all three. It is sent to Intune as `allowedArchitectures`, and **`x64` includes ARM64**: before Intune split the two it offered every 64-bit app to ARM64 devices, and when it did split them it gave every existing x64 app ARM64 as well, so an `app.json` keeps reaching the devices it always did. `arm64` on its own limits the app to ARM64 devices. There is no way yet to say x64 *without* ARM64 in `app.json`: untick ARM64 in the portal and the next `-Update` ticks it again.

### Packaging a folder that installs with a script
The usual shape for an application built in house: a publish step drops the program and its dependencies in a payload folder, and an `Install-App.ps1` beside them does the installing. The **setup file** is then that script.

The setup file is only what `IntuneWinAppUtil.exe` records in the package metadata and what the `.intunewin` is named after — what actually runs on the device is the install command. It still matters which one is chosen, because the application's own `App.exe` sitting in the payload is the one file in there nobody meant Intune to start.

Put an `app.json` in the payload folder and let it say so:

```json
{
  "displayName": "Acme Kiosk",
  "publisher": "IT Department",
  "version": "1.0.0.0",
  "installCommandLine": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\Install-App.ps1",
  "uninstallCommandLine": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\Uninstall-App.ps1",
  "detection": { "type": "script", "scriptFile": "Detect-App.ps1" }
}
```

Opening that folder picks `Install-App.ps1` as the setup file, because the manifest's install command names it — the file list is only consulted when no manifest answers the question. Without an `app.json` the choice is the old one (PSADT, then a single `.msi`, then the first `.exe`), and you can always change it under *Advanced → Setup file*, which now lists `.ps1`, `.cmd` and `.bat` alongside `.exe` and `.msi`. Picking a script fills in `powershell.exe -NoProfile -ExecutionPolicy Bypass -File` and finds the matching `Uninstall-` script if there is one.

Two things to keep in mind:

- **The detection script has to be findable from `app.json`.** A bare `Detect-App.ps1` is looked for next to the manifest; a build that writes the manifest and the detection script into a folder *beside* the payload needs `"scriptFile": "..\\intune\\Detect-App.ps1"`, or the script copied in. It is uploaded to Intune as script content, so it does not have to be inside the `.intunewin`. A path that resolves to nothing is now a red checklist item instead of a rule that reads as finished.
- **Packwright writes `app.json` into the folder it has open.** If a build script generates the manifest somewhere else, the next build will not see the corrections you make here — generate it into the payload folder to begin with.

On the command line the same package needs nothing special; a single `Install*.ps1` is auto-detected, and anything else is named explicitly:

```powershell
.\Build-IntuneWinApp.ps1 -SourceFolder "C:\pkg\payload" -SetupFile "Install-App.ps1" -PassThru |
    .\Publish-IntuneWinApp.ps1
```

### Parameters
| Parameter | Description |
|---|---|
| `-Path` | The `.intunewin` file (pipeline from `Build-IntuneWinApp -PassThru`). Left out only for an Intune Store app, published from `-ManifestPath` alone. |
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

Five components, versioned separately: **Studio** (`Packwright.ps1`, the GUI, with its WinGet part in `Packwright.WinGet.ps1`), **Build** (`Build-IntuneWinApp.ps1`), **Publish** (`Publish-IntuneWinApp.ps1`), **WinGet** (`New-WinGetPackage.ps1`, with the device scripts it writes as *WinGet runner*) and **Test** (`Test-IntuneWinApp.ps1`). Each script's own `.VERSION` block is the authoritative changelog; this is the merged view, newest first.

- **2026-10-27 — WinGet 1.2 (runner 1.1)** — **A time limit, and WinGet's install lock waited for in the open.** `winget.exe` waits for a lock before it starts an installer, for as long as that takes and silently when its output is captured, so one installation that never let go of it left every later WinGet install on a device at *Installing* until Intune stopped it after an hour, with nothing in either log to say why. The install and uninstall scripts now look at the lock first and wait for it ten minutes at most, give winget until 55 minutes have passed, stop it there (not the installer it started) and return `1618`, so Intune tries again; the log names the winget, WinGet COM server and Windows Installer processes running at the time, with their start times. WinGet's own log is now copied beside the script's when it runs as SYSTEM as well — it is in `SystemTemp` there. Packages made before this show their scripts as older in the WinGet card: **Refresh the scripts** and publish the app again as an update. See [What the scripts do on the device](#what-the-scripts-do-on-the-device).
- **2026-10-20 — Studio 2.11** — **The studio's WinGet part is a file of its own**, `Packwright.WinGet.ps1`: the WinGet dialog, the WinGet card in the editor, the runtime package and their self-tests. Packwright reads it, with `New-WinGetPackage.ps1`, the first time a session needs WinGet — a WinGet package opened, *Install it with WinGet*, Settings, or a `Packwright.policy.json` for the start screen to read — instead of at every start, so a session packaging an installer reads neither. Nothing it does has changed. Packwright stops at startup, naming the file, when it is missing.
- **2026-10-12 — Studio 2.10 / Publish 1.9 / WinGet 1.1** — **WinGet packages get the app's icon.** The catalogs named one only for MSIX apps from the Store and the few community manifests that carry one, so Win32 apps from the Store (`XP` ids) and most community apps came out without. Now the icon is the Store's (for `XP` ids, from the app's page in the web Store), the manifest's, the installed app's on this computer, or else the installer's own — downloaded, checked against the manifest's SHA-256, read without being run, and deleted; an MSI's comes from its Icon table, and an MSI without one is followed by the app's `.exe`. A catalog icon under 128 px gives way to a larger one, judged by the sizes the files really hold rather than the enlargement Windows hands back. **Use the app's own icon** does the same for a WinGet package that has none. **Who publishes is said**: the header showed "publishing opens a browser sign-in" and then no browser opened, because Microsoft Graph PowerShell remembers the last sign-in on the computer and uses it again without asking. The header now names that account, and every publish logs the account and tenant it signed in as. **Sign in again** beside it forgets the remembered sign-in and opens a new one — a sign-in carries the roles the account had when it was made, so an Intune role activated in PIM afterwards got `403 Forbidden` for as long as it lasted — and a 403 now says so in the log instead of only that no app id came back. Every publish logs when its sign-in was made and the Entra roles it carries, read from the token on the computer, and a 403 is explained from them; `app.json` may give `roleScopeTagIds`, for accounts whose Intune role is limited to scope tags. See [Apps from WinGet](#apps-from-winget--the-microsoft-store-or-the-community-repository).
- **2026-10-08 — Studio 2.9 / Publish 1.8 / WinGet 1.0 / Test 1.0** — **Apps from WinGet.** A third way to start: pick an app from the Microsoft Store or the WinGet community repository, and Packwright writes a package that installs it with WinGet on each device. The plan — SYSTEM or the signed-in user, which installer, the detection rule — is read from the app's manifest: the Store's catalog is asked directly (in the market of the computer's own country or region in Windows, or the policy's), and the community repository through the manifest winget itself caches, so most apps need no test install for their detection rule. **Detection goes by what outlives the version installed today**, because apps update themselves: the MSIX package family, an MSI's upgrade code, an uninstall key without a version in it, and otherwise WinGet itself (`winget list`) — a pinned version is detected as that version or newer. **`Packwright.policy.json` decides which sources may be used**, checked by the studio, by `New-WinGetPackage`, by `Publish-IntuneWinApp` before anything is created, and by the script on the device, which installs from exactly one source including dependencies. The device scripts run under Windows PowerShell 5.1 as Intune starts them — 32-bit, as SYSTEM — and handle what winget needs there: the 64-bit restart, `winget.exe` by its full path, the Visual C++ runtime, App Installer's policies, and exit codes Intune acts on. A Store app can be delivered as Intune's own Store app type instead, which keeps working where the Microsoft Store app is blocked; `Publish-IntuneWinApp` publishes that from `app.json` alone. The **WinGet runtime package** (App Installer and the Visual C++ runtime, downloaded and checked here) is linked to each app by a requirement rule rather than a dependency, which Intune caps at 100 apps per graph. `Publish-IntuneWinApp` gained requirement rules, dependencies that keep an app's supersedence, a privacy URL and a developer — and no longer has the second of several piped packages update the app the first one just created. **Test on this computer** (`Test-IntuneWinApp.ps1`) installs or uninstalls any package as Intune would — as SYSTEM, from a copy, from a 32-bit process — judges it by the exit code first and then the detection rule, checked in the same account, and offers a detection rule written from what a successful install added. See [Apps from WinGet](#apps-from-winget--the-microsoft-store-or-the-community-repository) and [Test on this computer](#test-on-this-computer).

- **2026-10-02 — Studio 2.8** — **Packwright has a taskbar button and an icon of its own.** Every window wore `pwsh.exe`'s icon, and the taskbar filed the studio under PowerShell's button, stacked with the console that started it. Setting the window icon alone changes only the title bar: the taskbar groups buttons by AppUserModelID, and a window without one takes its process's. The main window now carries its own ID (`Packwright.Studio`) and a parcel icon drawn in code, so there is still no file to ship beside the scripts. Pinning the button keeps Packwright: the window names the command that starts it and an icon in `%LOCALAPPDATA%\Packwright\Packwright.ico` for the pin to show. Drawing the icon and compiling the C# this needs would add more than half a second to startup; both run on runspaces of their own while the windows are parsed, so startup pays about a tenth of a second.
- **2026-09-24 — Studio 2.7** — The description box can be made taller: drag the grip in its bottom-right corner, the way a textarea is resized. It also starts at four lines in the studio rather than a line and a half — 52 px left 26 for text, because the box's padding was applied twice, once by the template and once by the scroll viewer inside it. The wizard's box has the same grip and starts at two whole lines, since step 2 already fills that window.
- **2026-09-24 — Publish 1.7** — **`-Update` works on an app Intune already has.** It failed at the very last step, after the whole upload, with `The ApplicableArchitectures property can only be set via ODataAction: enableApplicableArchitectures`. The app stayed on its previous content version, as designed, but never got the new one. Intune has replaced `applicableArchitectures`, the property the architecture was written to, with `allowedArchitectures`, and no longer lets a PATCH set the old one — and an update PATCHes the whole of `app.json`. The architecture now goes out as `allowedArchitectures`, on create as well as on update. `app.json` keeps its meaning: `x64` still includes ARM64 devices, which is how Intune read a 64-bit app before the split and how it moved its own x64 apps across, so the same `app.json` reaches the same devices — see the note under [App settings](#app-settings--appjson). An architecture Intune cannot target (`arm`, a typo) is refused before anything is created or uploaded. The self-test's stubbed Graph now answers such a PATCH the way Intune does, and covers updating an app that already exists.
- **2026-09-22 — Studio 2.6 / Build 2.4** — A package that installs with a script is a package. The setup file list held `.exe` and `.msi` only, so a payload folder whose entry point is `Install-App.ps1` opened on the application's own `.exe` — the one file in there nobody meant Intune to run — and a folder holding neither came back with no setup file and nothing that could be published at all. `.ps1`, `.cmd` and `.bat` are offered too, with commands derived for them (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File`, plus the `Uninstall-` script beside it when there is one), and a single `Install*.ps1` is auto-detected on the command line. **An `app.json` that carries an install command now decides which file the setup file is** — the manifest has already answered what installs this package, and reading the file list instead overrode the answer. The wizard still starts from a vendor `.exe` or `.msi` and says why when handed a script; a script dropped on the window opens the folder around it with that script selected. **A detection script the package does not hold is no longer summarised as a finished rule** while the checklist beside it said the rule was not set and named nothing: a script name without a path is looked for in the package folder, and an `app.json` written for a folder next to this one is the ordinary way it is not there. See [Packaging a folder that installs with a script](#packaging-a-folder-that-installs-with-a-script).
- **2026-09-08 — Studio 2.5 / Publish 1.6 / Build 2.3** — Four found by reading the three scripts end to end, each now covered by a self-test. **A `[` in the installed-app picker's search box exited the process** — the filter went into `-like`, an unterminated character class threw `WildcardPatternException`, and it came out of a `TextChanged` handler with nothing above it to catch; entries in Apps and features really are named `Java 8 Update 391 [64-bit]`. Matching is `IndexOf` now. **A manifest value none of the dropdowns offers is added to the list instead of dropped** — dropping it did not clear the combo, it left it on the *previously opened package's* selection, the editor showed that, and saving wrote it back, so an `app.json` with `architecture: neutral` or `detectionType: doesNotExist` (both legal to Intune, neither in the list) came back rewritten. **A build that wrote no `.intunewin` could report one that was already there** — `IntuneWinAppUtil.exe` exits 0 even when it writes nothing, and the newest-file fallback had no time bound, so a package left by an earlier build of a differently named setup file was hashed, reported as `Produced`, and uploaded as a new version. **A duplicate-name check that could not run now stops the publish** — it used to warn and carry on, which reads as "Intune has no app of this name": without `-Update` that creates the duplicate the check exists to prevent, and with `-Update` it creates a *second* app instead of updating the first, so the real app keeps its assignments and its old content and no device sees the new version. Graph throttling on a filtered `mobileApps` query is the ordinary way in.

  Four smaller ones from the same read. **Closing the window during a run is asked about first**, and stops the run before the window goes — the runspace died with the window, so an interrupted publish could leave an app in Intune with no content, which is what Cancel warns about and the X did not. **The 8 MB scan that identifies the installer engine reads in a loop** — `Read` may return less than it was asked for, and a single call left the rest of the buffer as zeros, so an ordinary Inno Setup installer on a share could come back as `unknown` with no silent switches. **`-AllowDuplicateName` is refused alongside `-AppId`** as well as `-Update`; naming the app to update contradicts creating a second one either way, and `-AppId` used to slip past the check and then be ignored. **A block upload is retried** on no response, 408, 429 and 5xx — four attempts with a short backoff, because one transient 500 used to throw away the whole upload. A 403 is not retried: that is an expired SAS uri, which the renewal handles. The self-test now drives the publish engine's whole create-upload-commit chain against a stubbed Graph and a stubbed Azure Storage, so it needs no tenant, module or network.
- **2026-09-08 — Studio 2.5** — What a package folder carries over from the previous release is caught instead of published. A command naming a file the package does not hold is a checklist item rather than a line in the log: `msiexec /i "7z2408-x64.msi"` in a folder that now holds `7z2501-x64.msi` used to build, publish, and then fail on every device. So did an empty install command, which nothing checked at all. Changing the setup file rewrites a command that is provably broken (a hand edit that still runs something present is kept, as before), and the MSI product code follows the setup file instead of only filling an empty box; an `msi` rule holding another MSI's code no longer counts as a finished rule. A version comparison set from the version field follows it, and one that does not match is stated under the checklist — a rule left on 24.08 in a 25.01 package makes Intune treat the old release as installed, so the upgrade never runs and reports success. Two more are stated without blocking: the setup file's own version against the package's, and an uninstall command still removing the MSI that was replaced. Opening a package folder also drops what was cached about the MSIs in it — that cache is keyed by full path and lived as long as the process, so a new release shipped under the same file name went on answering with the previous product code, which is the code the rule is written from. See [Reusing a package folder for the next release](#reusing-a-package-folder-for-the-next-release).
- **2026-09-04 — Studio 2.4 / Publish 1.5 / Build 2.2** — Settings dialog for the package folder and the output folder, reachable from the header and asked once on first run. Both default to a local disk instead of following a redirected Documents folder onto a network home directory, which used to surface as `Could not read MSI properties` and `The setup file you specified cannot be accessed`. Resolved paths use `.ProviderPath`, so a UNC path no longer reaches IntuneWinAppUtil.exe provider-qualified and unopenable. Dialog handlers are plain scriptblocks over `$script:` state rather than `.GetNewClosure()`, which runs in a module scope where the functions in the file are out of reach, and a `settings.json` that parses to nothing is written over instead of throwing `Cannot index into a null array` somewhere unrelated. A background run that produces no result object is reported in the log rather than throwing that same error out of a dispatcher tick, where it unwound through `ShowDialog` and closed the window. The run's parameters are `run`-prefixed because dot-sourcing an engine script executes its `param()` block in the same scope: `$OutputRoot` shared a name with `Build-IntuneWinApp.ps1`'s own parameter and was reset to `''` before the build saw it, which is what `Cannot validate argument on parameter 'OutputRoot'` was. A self-test keeps the two sets of names disjoint, and the suite now ends with a real end-to-end build through that same run body.
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
