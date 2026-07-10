# Expand-IntuneWin

Deconstructs a `.intunewin` file — shows metadata, lists or extracts the content.
Useful for troubleshooting and package review, e.g. to see exactly what a third-party
package contains or to recover a lost source folder.

Comes with both a GUI and a CLI in the same script.

## How the format works

A `.intunewin` (created by IntuneWinAppUtil/Content Prep Tool) is a plain ZIP:

```
IntuneWinPackage/
├── Metadata/Detection.xml            ← app name, setup file, MSI info + AES key, MAC key, IV (in clear text!)
└── Contents/IntunePackage.intunewin  ← encrypted content
```

The encrypted content: bytes 0–31 are an HMAC-SHA256 over the rest, bytes 32–47 are the IV,
the rest is the source folder as a ZIP, encrypted with AES-256-CBC. Since the keys are stored
in clear text in Detection.xml, anyone holding the file can unpack it — the encryption only
protects the content in transit/storage inside Intune; it is not a secret from whoever has
the file. Therefore: **treat .intunewin files as sensitive if their content is.**

## GUI

Run the script without parameters (or with `-Gui`) to open the GUI:

```powershell
.\Expand-IntuneWin.ps1
.\Expand-IntuneWin.ps1 .\app.intunewin -Gui   # preloaded with a package
```

- Browse or **drag and drop** an `.intunewin` file onto the window
- Metadata panel: app name, setup file, sizes, MSI info, HMAC verification badge
- Sortable, filterable file list (path, size, compressed size)
- Extract to a chosen folder (asks before overwriting into a non-empty folder)
- Save the raw `Detection.xml` for deeper review
- Decryption runs in the background — the window stays responsive on large packages

## CLI

```powershell
# Extract everything (default: <name>-extracted\ next to the file)
.\Expand-IntuneWin.ps1 .\app.intunewin
.\Expand-IntuneWin.ps1 .\app.intunewin -Destination C:\Temp\review -Force

# Metadata only (no decryption)
.\Expand-IntuneWin.ps1 .\app.intunewin -Info

# List the files without extracting
.\Expand-IntuneWin.ps1 .\app.intunewin -List
.\Expand-IntuneWin.ps1 .\app.intunewin -List | Sort-Object Size -Descending | Select-Object -First 10
```

## Integrity checks

- **HMAC-SHA256** is always verified — a mismatch (corrupt/tampered file) aborts before anything is extracted.
- **SHA256 digest** and **size** are compared against Detection.xml (warning on mismatch).
- Paths inside the package are validated against path traversal during extraction.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+ (no modules, no Graph connection).
- Applies to locally created `.intunewin` files. A payload downloaded straight from Intune
  storage (without the metadata wrapper) is not supported — it requires keys from Graph.
