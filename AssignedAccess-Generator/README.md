# AssignedAccess-Generator

A self-contained generator for **Assigned Access XML** – the value of the Intune OMA-URI
`./Vendor/MSFT/AssignedAccess/Configuration` – plus a PowerShell script that validates the XML
against **Microsoft's official XSD**.

Nothing to install: open `AssignedAccess-Generator.html` in Edge. Everything runs locally in the
browser, with no external dependencies, and nothing is sent anywhere.

---

## What it does

- **Form → finished XML**, previewed as you type:
  - **Single-app kiosk** – a Win32 app (`v4:ClassicAppPath`), Microsoft Edge (builds the `--kiosk` arguments for you) or a Store app (AUMID), with an optional breakout sequence (`v4:BreakoutSequence`).
  - **Restricted desktop (multi-app)** – allowed apps, auto-start, Start pins (Windows 11 `v5:StartPins`), File Explorer folder access, taskbar, and in the advanced section a Windows 10 `StartLayout` and `v5:TaskbarLayout`.
  - **Assignments** – automatic sign-in, local/AD/Entra user accounts, local/AD/Entra groups, HoloLens special groups and a global profile.
- **The right namespaces automatically** – only the ones actually used are declared, and the tool shows the **schema level**: the lowest Windows release per Microsoft's XSD reference for the newest namespace in use.
- **Correct escaping** – `&`, `<` and `"` in paths, addresses and arguments become valid XML, and Start pins become valid JSON (with doubled `\\`).
- **Checks as you type** – errors (breaks the schema or Microsoft's documented rules) and warnings (known pitfalls). Click a line to jump to the field.
- **Import** of existing XML (also HTML-encoded `&lt;…`), Graph JSON for an Intune custom profile (`omaSettings`) and Intune's kiosk template (`windowsKioskConfiguration`, e.g. exported from Microsoft Graph).
- **Help finding apps** – a catalog of common built-in apps, and a script for a reference device that collects AUMIDs, `.exe` paths and Start shortcuts to paste in.
- **Intune instructions** and a plain-language **summary** to paste into the ticket or the documentation.
- The draft is kept in the browser's local storage, on your machine only.

---

## Quick start

1. Open `AssignedAccess-Generator.html` in Edge.
2. Pick a template – e.g. **Your own app, full screen** – or **Import** existing XML.
3. Fill in the form; the XML on the right updates as you go. Fix all red errors.
4. **Copy XML** and add it to Intune:
   - **Devices → Configuration → Create → New policy**, platform **Windows 10 and later**, profile type **Templates → Custom**
   - OMA-URI `./Vendor/MSFT/AssignedAccess/Configuration`, data type **String**, value = the XML, pasted as is
   - Assign the profile to a **device group**
5. To check against Microsoft's schema: **Download .xml** and run

   ```powershell
   .\Test-AssignedAccessXml.ps1 -Path .\AssignedAccess-Lobby-kiosk.xml
   ```

---

## Test-AssignedAccessXml.ps1

Validates in two passes:

1. **Schema** – against the XSDs in `schema/` (namespaces 2017, 201810, 2020, 202010, 2021 and 2022). Schema warnings, such as an element in an unknown namespace, count as errors.
2. **Rules** the XSD doesn't express – every `DefaultProfile`/`GlobalProfile` points at an existing profile, at most one `KioskModeApp` profile, no `UserGroup` assigned to a kiosk profile, at least one assignment, at most one `AutoLogonAccount`, and `StartPins` is JSON with a `pinnedList`.

Exits with code `1` if any input fails, so it can gate a pipeline.

| Parameter | Description |
|---|---|
| `-Path` | One or more XML files. Takes pipeline input, e.g. from `Get-ChildItem`. |
| `-Xml` | XML as a string instead of a file. |
| `-SelfTestBundle` | Runs the generator's self-test bundle (see below). |
| `-SchemaPath` | Folder with the XSD files. Default: `schema/` next to the script. |
| `-PassThru` | Also emits result objects (`Valid`, `SchemaErrors`, `RuleErrors`, `Warnings`, `MinimumWindows`) to the pipeline. |

```powershell
# Every XML file in a folder, show only the ones that fail
Get-ChildItem .\*.xml | .\Test-AssignedAccessXml.ps1 -PassThru | Where-Object { -not $_.Valid }
```

Requires PowerShell 7.

---

## Checks in the generator (selection)

| Check | Level | Why |
|---|---|---|
| Profile ID is a GUID in `{}` and unique | Error | XSD |
| Kiosk profile: either an AUMID or a `ClassicAppPath`; arguments only with `ClassicAppPath` | Error | XSD |
| Multi-app: each app listed once, at most one with auto-start | Error | XSD |
| At most one automatic sign-in | Error | XSD |
| At most one kiosk profile per configuration | Error | Microsoft |
| Kiosk profile assigned to a user group | Error | Microsoft – user accounts only. HoloLens special groups (`Visitor`) are allowed |
| Assignment pointing to a profile that doesn't exist | Error | Not caught by the XSD, but fails on the device |
| Path contains a version number (`…\versions\1.3.4.0\…`) | Warning | The profile must be updated with every app update, or the kiosk won't start |
| Path inside a user profile (`%APPDATA%`, `C:\Users\…`) | Warning | The kiosk account is a different user |
| A Store app pinned to Start but not allowed | Warning | It shows but can't start |
| Multi-app with nothing pinned | Warning | Microsoft requires a Start layout |
| Pinned Edge websites without `msedge_proxy.exe` and the Edge AUMID | Warning | Required per Microsoft |
| Entra group that isn't an object ID, Entra account without a UPN | Warning / Error | Formats per Microsoft |

---

## Get apps from a reference device

A multi-app profile needs AUMIDs for Store apps and paths (and ideally Start shortcuts) for
desktop apps. **Allowed apps → From a reference device…** offers this script; run it on a device
where the apps are installed and paste the result:

```powershell
$sh = New-Object -ComObject WScript.Shell
$store = Get-StartApps | Where-Object AppID -like '*!*' |
    ForEach-Object { [pscustomobject]@{ Name = $_.Name; AUMID = $_.AppID } }
$desktop = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
           "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" |
    Get-ChildItem -Recurse -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
        $target = $sh.CreateShortcut($_.FullName).TargetPath
        if ($target -like '*.exe') { [pscustomobject]@{ Name = $_.BaseName; Path = $target; Link = $_.FullName } }
    }
@($store) + @($desktop) | ConvertTo-Json | Set-Clipboard
```

Works in both Windows PowerShell 5.1 and PowerShell 7. Paths are rewritten to environment
variables (`%ProgramFiles%`, `%windir%`, `%ALLUSERSPROFILE%` …). Plain `Get-StartApps` output can
be pasted too, but only gives paths for apps in known folders and no shortcuts.

---

## Self-test

Open `AssignedAccess-Generator.html#selftest`. The page runs 28 cases – every template, imports of
Microsoft's examples and the kiosk template, special characters, a HoloLens visitor kiosk,
import → export without changes, and negative cases that must fail – and shows the result.
Download the test bundle and let PowerShell check the same XML against the XSD:

```powershell
.\Test-AssignedAccessXml.ps1 -SelfTestBundle "$HOME\Downloads\selftest-bundle.json"
```

Run both after every change to the generator. The self-test never touches your saved draft.

---

## Limitations / good to know

- **The XSD is the reference.** The browser validation is the generator's own implementation of the schema rules, so the status says "No errors" rather than "valid". `Test-AssignedAccessXml.ps1` validates against Microsoft's actual schema.
- **The schema level is a guide.** It follows the headings on Microsoft's XSD reference page, but the sources don't fully agree: the XSD files `v4:ClassicAppPath` under Windows 11 21H2, while Microsoft's Edge kiosk docs also describe Edge single-app kiosks on Windows 10 1909 and 2004+ with the February 2021 updates. Test before relying on Windows 10.
- **A device holds one Assigned Access configuration.** Assign only one such profile per device – two profiles setting the same OMA-URI overwrite or conflict with each other.
- **Install the app before the profile reaches the device** – Assigned Access starts it at sign-in.
- **Version-bound paths** break when the app is updated into a new folder. A stable path (fixed install folder, junction or launcher) avoids that, but test it under Assigned Access before relying on it – it doesn't work in every case.
- **Breakout keys:** Microsoft documents the `Key` format only by example (`Ctrl+A`). The picker offers Ctrl/Alt/Shift plus A–Z, 0–9 and F1–F12; test the combination on a device.
- **Special groups are HoloLens account types** – `Visitor` (temporary visitor accounts) and `DeviceOwner` (device owners), per Microsoft's HoloLens kiosk documentation.
- **Intune's kiosk template sets up multi-app kiosks on Windows 10 only**; on Windows 11, deploy the XML as a custom profile. When importing from the template, Kiosk Browser settings and the update schedule are left out (they aren't part of the Assigned Access XML), and desktop apps without a shortcut path aren't pinned to Start.
- Automatic sign-in doesn't work if `PreferredAadTenantDomainName` is set or Exchange ActiveSync password restrictions are active (Microsoft).
- On import, `StartPins` JSON is reformatted (the content stays the same). Edge arguments in a different order than the generator's are kept as free text in the Win32 mode, so they don't change.
- The catalog's AUMIDs were checked against `Get-StartApps` on a Windows 11 device or against Microsoft's documentation. Store apps can change AUMID when they're updated.
- `desktopAppId` pins and custom JSON objects (e.g. `secondaryTile`) are written as entered – try them on a test device.
- When Microsoft adds a schema version: fetch the XSDs again from the XSD reference into `schema/` and add the support to the generator.

---

## Files

```
AssignedAccess-Generator/
├─ AssignedAccess-Generator.html   # the generator – one file, no dependencies, works offline
├─ Test-AssignedAccessXml.ps1      # XSD and rule validation, runs the self-test bundle
├─ schema/                         # Microsoft's XSDs, verbatim (fetched 2026-10-05)
└─ README.md
```

---

## Sources

- [AssignedAccess CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/assignedaccess-csp)
- [Create an Assigned Access configuration XML file](https://learn.microsoft.com/en-us/windows/configuration/assigned-access/configuration-file)
- [Assigned Access XML Schema Definition (XSD)](https://learn.microsoft.com/en-us/windows/configuration/assigned-access/xsd)
- [Assigned Access examples](https://learn.microsoft.com/en-us/windows/configuration/assigned-access/examples)
- [Assigned Access recommendations](https://learn.microsoft.com/en-us/windows/configuration/assigned-access/recommendations)
- [Configure Microsoft Edge kiosk mode](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-configure-kiosk-mode)
- [Intune kiosk settings for Windows](https://learn.microsoft.com/en-us/intune/intune-service/configuration/kiosk-settings-windows)
- [Set up HoloLens as a kiosk](https://learn.microsoft.com/en-us/hololens/hololens-kiosk) and its [XML samples](https://learn.microsoft.com/en-us/hololens/hololens-kiosk-reference)
