// Packwright's windows, rebuilt from the XAML in Packwright.ps1 (MainXaml, WizardXaml,
// PickerXaml, SettingsXaml, HelpXaml) with the strings its logic writes into them.
// Each <div class="win"> is screenshotted on its own by shoot.mjs.

const PKG = 'C:\\Users\\it-admin\\IntunePackages\\7-Zip 25.01';
const ROOT = 'C:\\Users\\it-admin\\IntunePackages';
const TOOLS = 'C:\\Tools\\Packwright';

// The parcel mark New-StudioIconBytes draws, on its 256-unit grid
const PARCEL = `<svg viewBox="0 0 256 256" xmlns="http://www.w3.org/2000/svg">
<rect x="8" y="8" width="240" height="240" rx="52" fill="#0F6CBD"/>
<g stroke="#0F6CBD" stroke-width="7" stroke-linejoin="round">
<path d="M128,45 L200,86.6 128,128.2 56,86.6 Z" fill="#FFFFFF"/>
<path d="M56,86.6 L128,128.2 128,211.4 56,169.8 Z" fill="#CFE3F7"/>
<path d="M128,128.2 L200,86.6 200,169.8 128,211.4 Z" fill="#9DC3EC"/></g>
<path d="M84.8,70 L99.2,61.6 171.2,103.2 156.8,111.6 Z" fill="#B7D3F1"/>
<path d="M156.8,111.6 L171.2,103.2 171.2,186.4 156.8,194.8 Z" fill="#78A9DF"/></svg>`;

// Stand-in for the icon Packwright extracts from the installed app (not the vendor's artwork)
const APPICON = `<svg viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg">
<rect x="4" y="4" width="56" height="56" rx="6" fill="#202326"/>
<rect x="4" y="4" width="56" height="18" rx="6" fill="#33383D"/><rect x="4" y="14" width="56" height="8" fill="#33383D"/>
<text x="32" y="50" text-anchor="middle" font-family="Arial, sans-serif" font-weight="700" font-size="25" fill="#FFFFFF">7z</text></svg>`;

const caps = `<div class="caps">
<span><svg viewBox="0 0 10 10"><path d="M0 5.5 H10"/></svg></span>
<span><svg viewBox="0 0 10 10"><rect x="0.5" y="0.5" width="9" height="9" rx="1"/></svg></span>
<span><svg viewBox="0 0 10 10"><path d="M0.5 0.5 L9.5 9.5 M9.5 0.5 L0.5 9.5"/></svg></span></div>`;

function frame(title, body, { inactive = false, noMax = false } = {}) {
  const c = noMax ? caps.replace(/<span><svg viewBox="0 0 10 10"><path d="M0 5.5 H10"\/><\/svg><\/span>\s*<span>.*?<\/span>/s, '') : caps;
  return `<div class="titlebar"><span class="ico">${PARCEL}</span><span class="ttl">${title}</span>${c}</div>
<div class="client">${body}</div>`;
}

const expGlyph = (open) => `<svg viewBox="0 0 19 19"><circle cx="9.5" cy="9.5" r="8.5" fill="#FFFFFF" stroke="#333333"/>
<path d="${open ? 'M6 11 L9.5 7.5 L13 11' : 'M6 8 L9.5 11.5 L13 8'}" fill="none" stroke="#333333" stroke-width="2"/></svg>`;
const exp = (header, open) => `<div class="exp">${expGlyph(open)}<span>${header}</span></div>`;

const grip = `<svg class="grip" viewBox="0 0 13 13"><path d="M10 3 L3 10 M10 7 L7 10" stroke="#868C95" stroke-width="1" fill="none"/></svg>`;
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const tb = (text, cls = '') => `<div class="tb ${cls}">${esc(text)}</div>`;
const label = (text, extra = '') => `<div class="FieldLabel"${extra}>${text}</div>`;
const tagged = (text, tag) => `<div class="row" style="justify-content:space-between">${label(text)}<span class="Tiny" style="margin:10px 0 3px">${tag}</span></div>`;
const check = (ok, text) => `<div class="Body" style="margin:2px 0;color:var(--${ok ? 'Ok' : 'Warn'})">${ok ? '✓' : '✕'}&nbsp;&nbsp;&nbsp;${esc(text)}</div>`;

// ---- Main window ---------------------------------------------------------------
function mainWindow({ pkg, view, actions, log, status, progress, height = 800, scrollTop = 0, scrollbar = null }) {
  const header = `<div class="bar top" style="padding:10px 20px"><div class="row">
  <div style="font-size:14px;font-weight:600">Packwright</div>
  <div class="row grow" style="margin-left:12px;visibility:${pkg ? 'visible' : 'hidden'}">
    <span class="Tiny" style="margin-right:8px">—</span>
    <span class="Muted nowrap" style="max-width:430px">${esc(pkg || '')}</span>
    <span class="btn BtnQuiet" style="margin-left:4px">Change package</span>
  </div>
  <div class="row">
    <div class="Note" style="padding:4px 9px"><div class="Tiny nowrap" style="max-width:330px">No .secret — publishing opens a browser sign-in</div></div>
    <span class="btn BtnDefault" style="margin-left:8px">Settings</span>
    <span class="btn BtnDefault" style="margin-left:8px">Help</span>
  </div></div></div>`;

  const content = `<div style="flex:1;min-height:0;overflow:hidden;position:relative">
    <div style="padding:16px ${scrollbar ? 37 : 20}px 4px 20px;margin-top:${-scrollTop}px">${view}</div>
    ${scrollbar ? `<div class="vscroll" style="--t:${scrollbar[0]}px;--h:${scrollbar[1]}px"></div>` : ''}
  </div>`;

  const actionBar = actions ? `<div class="bar bottom" style="padding:10px 20px"><div class="row">
    ${actions.portal ? '<span class="btn BtnQuiet">Open in the Intune portal</span>' : ''}
    <div class="Tiny grow" style="margin:0 12px 0 8px">${actions.hint || ''}</div>
    ${actions.cancel ? '<span class="btn BtnDefault" style="margin-right:8px">Cancel</span>' : ''}
    <span class="btn BtnQuiet ${actions.busy ? 'disabled' : ''}" style="margin-right:4px">Save settings</span>
    <span class="btn BtnDefault ${actions.busy ? 'disabled' : ''}" style="margin-right:8px">Build only</span>
    <span class="btn BtnPrimary ${actions.busy ? 'disabled' : ''}">Publish to Intune</span>
  </div></div>` : '';

  const logBlock = `<div style="margin:8px 20px 4px">${exp('Log', !!log)}
    ${log ? `<div style="background:#1E2126;border-radius:6px;padding:2px;margin-top:6px"><div class="log" style="height:170px">${esc(log.split('\n').slice(-11).join('\n'))}</div></div>` : ''}</div>`;

  const statusBar = `<div class="bar bottom" style="padding:7px 20px"><div class="row">
    <div class="Muted grow nowrap">${esc(status)}</div>
    ${progress != null ? `<div style="width:180px;height:6px;background:var(--Stroke);margin-left:12px"><div style="width:${progress}%;height:6px;background:var(--Accent)"></div></div>` : ''}
  </div></div>`;

  return { title: 'Packwright', height, body: header + content + actionBar + logBlock + statusBar };
}

const startView = `<div style="max-width:840px;margin:0 auto;padding-top:16px">
  <div class="H1">Package an app for Intune</div>
  <div class="Muted" style="margin:6px 0 18px">Pick where you want to start. Nothing is sent to Intune until you review it and press Publish.</div>
  <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px">
    ${[['I have an installer file', 'Start from the .exe or .msi you got from the vendor. Five short steps: the tool identifies the installer, fills in the silent switches and builds the package for you.', 'Create a new package', false],
       ['I have a package folder', 'Open a folder that already holds the installation files — a PSADT package, an MSI, a plain installer, or a payload that installs with a script. Existing app.json settings are loaded.', 'Open a folder...', true]]
      .map(([t, d, a, hover]) => `<div style="background:${hover ? 'var(--AccentSoft)' : '#FFFFFF'};border:1px solid ${hover ? 'var(--Accent)' : 'var(--Stroke)'};border-radius:5px;padding:18px">
        <div style="font-size:15px;font-weight:600">${t}</div>
        <div style="margin-top:6px;font-size:12px;color:#5B6169">${d}</div>
        <div style="margin-top:10px;font-size:12px;font-weight:600;color:#0F6CBD">${a}</div></div>`).join('')}
  </div>
  <div class="H2" style="margin:22px 0 6px">Recent packages</div>
  <div class="list" style="padding:1px 0">
    ${[['7-Zip 25.01', PKG], ['Notepad++ 8.7.4', ROOT + '\\Notepad++ 8.7.4'], ['Acme Kiosk', 'C:\\Builds\\Acme Kiosk\\payload'], ['VLC media player 3.0.21', ROOT + '\\VLC media player 3.0.21']]
      .map(([t, f]) => `<div class="li"><div style="font-size:12px;font-weight:600">${t}</div><div style="font-size:11px;color:#868C95">${esc(f)}</div></div>`).join('')}
  </div>
  <div class="Note" style="margin-top:16px"><div class="Tiny">Tip: you can also drag a package folder or an installer file straight onto this window.</div></div>
</div>`;

// ---- Editor ----------------------------------------------------------------------
function editorView(o) {
  const detection = `<div class="Card"><div class="H2">Detection</div>
    <div class="Tiny">How Intune checks whether the app is already installed on a device. Intune requires this.</div>
    <div class="Note ${o.detOk ? 'ok' : 'warn'}" style="margin-top:10px"><div class="Body" style="color:inherit">${esc(o.detSummary)}</div></div>
    <span class="btn BtnDefault" style="margin-top:10px">Find the app on this computer...</span>
    <div class="Tiny" style="margin-top:6px">Recommended: install the app on this computer first, then pick it here — the registry rule is written for you. You can uninstall it again afterwards.</div>
    <div style="margin-top:12px">${exp('Change detection method', !!o.detOpen)}</div>
    ${o.detOpen ? `<div style="margin-top:8px">
      ${label('METHOD')}<div class="cb">Registry key (works for most installers)</div>
      ${label('REGISTRY KEY')}${tb('HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\7-Zip')}
      ${label('VALUE NAME (EMPTY = KEY MUST EXIST)')}${tb('DisplayVersion')}
      ${label('COMPARE')}<div style="display:grid;grid-template-columns:1fr 1fr;gap:8px"><div class="cb">version</div><div class="cb">greaterThanOrEqual</div></div>
      ${label('COMPARISON VALUE')}${tb(o.detValue)}
      <div class="chk"><i></i>32-bit app on 64-bit Windows (WOW6432Node)</div></div>` : ''}
  </div>`;

  const advanced = `<div class="Card">${exp('Advanced: commands, run-as, restart, architecture', !!o.advOpen)}
    ${o.advOpen ? `<div style="margin-top:10px">
      ${label('INSTALL COMMAND')}${tb(o.install, o.installCls || '')}
      ${label('UNINSTALL COMMAND')}${tb(o.uninstall)}
      <div class="Tiny" style="margin-top:6px">NSIS installer — /S (capital S) installs silently. The uninstaller is usually uninstall.exe /S in the install folder.</div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-top:4px">
        <div>${label('RUN AS')}<div class="cb">system</div></div>
        <div>${label('RESTART BEHAVIOUR')}<div class="cb">suppress</div></div>
        <div style="margin-top:-6px">${label('ARCHITECTURE')}<div class="cb">x64</div></div>
        <div style="margin-top:-6px">${label('MINIMUM WINDOWS')}<div class="cb edit">Windows10_22H2</div></div>
      </div>
      ${label('SETUP FILE')}<div class="cb">7z2501-x64.exe</div>
      ${label('IF THE APP ALREADY EXISTS IN INTUNE')}
      <div class="Tiny">By default publishing stops, so a re-publish cannot create a duplicate by mistake.</div>
      <div class="chk ${o.update ? 'on' : ''}"><i></i>Update it: upload this package as a new version of that app</div>
      <div class="chk"><i></i>Create a second app with the same name anyway</div>
    </div>` : ''}</div>`;

  const left = `<div class="Card"><div class="H2">App information</div>
    <div class="Tiny">What the app is called in Intune and the Company Portal.</div>
    ${tagged('NAME', o.tags[0])}${tb(o.name)}
    ${tagged('PUBLISHER', o.tags[1])}${tb('Igor Pavlov')}
    ${tagged('VERSION', o.tags[2])}${tb(o.version, o.versionCls || '')}
    ${label('DESCRIPTION (OPTIONAL)')}
    <div class="tb multi" style="height:96px">${esc(o.description)}${grip}</div>
  </div>${detection}${advanced}`;

  const ready = o.ready;
  const right = `<div class="Card"><div class="H2">Preview</div>
      <div class="Tiny">How the app will look in the Company Portal.</div>
      <div style="background:var(--BgSubtle);border:1px solid var(--Stroke);border-radius:6px;padding:12px;margin-top:10px;display:flex">
        <div style="width:64px;height:64px;background:#FFFFFF;border:1px solid var(--Stroke);border-radius:6px;margin-right:12px;padding:6px;flex:none">${APPICON}</div>
        <div style="min-width:0">
          <div class="nowrap" style="font-size:14px;font-weight:600">${esc(o.name)}</div>
          <div class="Muted nowrap">Igor Pavlov</div>
          <div class="Tiny" style="margin-top:2px">Version ${esc(o.version)}</div>
          <div class="Tiny" style="margin-top:6px;max-height:46px;overflow:hidden">${esc(o.description)}</div>
        </div></div></div>
    <div class="Card"><div class="H2">Logo</div>
      <div style="display:flex;margin-top:10px">
        <div style="width:56px;height:56px;background:#FFFFFF;border:1px solid var(--Stroke);border-radius:6px;margin-right:12px;padding:5px;flex:none">${APPICON}</div>
        <div><span class="btn BtnDefault">Use the app's own icon</span><br><span class="btn BtnQuiet" style="margin-top:4px">Choose an image instead...</span></div>
      </div>
      <div class="Tiny" style="margin-top:8px">${esc(o.iconNote)}</div></div>
    <div class="Card" style="border-color:var(--${ready ? 'Ok' : 'Stroke'})">
      <div class="H2" style="color:var(--${ready ? 'Ok' : 'Ink'})">${ready ? 'Ready to publish' : 'Not ready yet'}</div>
      <div style="margin-top:8px">${o.checks.map(([ok, t]) => check(ok, t)).join('')}</div>
      ${o.warn ? `<div class="Body" style="margin-top:10px;color:var(--Warn)">⚠&nbsp;&nbsp;&nbsp;${esc(o.warn)}</div>` : ''}
      <div class="Tiny" style="margin-top:10px">${o.readyNote}</div></div>`;

  return `<div style="display:grid;grid-template-columns:minmax(400px,1fr) 370px;gap:16px;align-items:start"><div>${left}</div><div>${right}</div></div>`;
}

const DESC = 'Free file archiver with a high compression ratio. Opens 7z, zip, rar, tar, gzip and most other archive formats from the Explorer context menu.';
const readyBase = {
  name: '7-Zip', version: '25.01', description: DESC, tags: ['from app.json', 'from app.json', 'from app.json'],
  detOk: true, detSummary: 'Intune reads DisplayVersion under the registry key 7-Zip and treats the app as installed when it is at least 25.01.',
  detValue: '25.01', install: '"7z2501-x64.exe" /S', uninstall: '"C:\\Program Files\\7-Zip\\Uninstall.exe" /S',
  iconNote: 'icon.png', ready: true,
  checks: [[true, 'Setup file: 7z2501-x64.exe'], [true, 'Name'], [true, 'Publisher'], [true, 'Install command'], [true, 'Detection rule']],
  readyNote: 'Publishing builds the .intunewin and creates the app in Intune. No groups are assigned — do that in the portal.',
};

const PUBLISH_LOG = [
  '==== Build and publish — 14:32:07 ====',
  '[2026-10-02 14:32:08] [INFO] ==== Build start: 7-Zip 25.01 ====',
  `[2026-10-02 14:32:08] [INFO] ToolPath : ${TOOLS}\\IntuneWinAppUtil.exe`,
  `[2026-10-02 14:32:08] [INFO] Source   : ${PKG}`,
  '[2026-10-02 14:32:08] [INFO] Setup    : 7z2501-x64.exe',
  `[2026-10-02 14:32:08] [INFO] Output   : ${TOOLS}\\Output\\7-Zip 25.01`,
  '[2026-10-02 14:32:08] [INFO] Invoking IntuneWinAppUtil.exe...',
  '[2026-10-02 14:32:11] [INFO] IntuneWinAppUtil.exe finished with ExitCode: 0',
  `[2026-10-02 14:32:11] [INFO] Produced : ${TOOLS}\\Output\\7-Zip 25.01\\7z2501-x64.intunewin`,
  '[2026-10-02 14:32:11] [INFO] Size     : 1.62 MB',
  '[2026-10-02 14:32:11] [INFO] Duration : 00:03',
  '[2026-10-02 14:32:11] [INFO] ==== Build end: 7-Zip 25.01 ====',
  `Built ${TOOLS}\\Output\\7-Zip 25.01\\7z2501-x64.intunewin (1.62 MB)`,
  "No app credentials found ('.secret' missing) - signing in as you (-SignIn Browser). Finish the prompt to continue.",
  `Using manifest: ${PKG}\\app.json`,
  "Creating Win32 app '7-Zip' in Intune...",
  '  App created: 6c1f2a9e-4b7d-4e0a-9d35-2f8b61c0e7a4',
  '  Uploading content (1.6 MB)...',
  "  Done. '7-Zip' is published (no assignments yet).",
  "Published '7-Zip' — app id 6c1f2a9e-4b7d-4e0a-9d35-2f8b61c0e7a4",
].join('\n');

const screens = {
  start: mainWindow({ view: startView, status: 'Choose how you want to start.', height: null }),

  editor: mainWindow({
    pkg: PKG, view: editorView(readyBase), actions: { hint: '' }, height: null,
    status: "Opened '7-Zip 25.01'. Review the fields, then publish.",
  }),

  issues: mainWindow({
    pkg: ROOT + '\\7-Zip 25.01', height: 860, scrollTop: 300, scrollbar: [258, 380],
    view: editorView({
      ...readyBase, version: '25.01', tags: ['from app.json', 'from app.json', 'edited by hand'],
      detSummary: 'Intune reads DisplayVersion under the registry key 7-Zip and treats the app as installed when it is at least 24.08.',
      detValue: '24.08', install: '"7z2408-x64.exe" /S', installCls: 'invalid', advOpen: true, ready: false,
      checks: [[true, 'Setup file: 7z2501-x64.exe'], [true, 'Name'], [true, 'Publisher'],
               [false, 'The install command runs 7z2408-x64.exe, which is not in this package'], [true, 'Detection rule']],
      warn: 'The detection rule compares against 24.08, but this package is version 25.01. A rule left on the previous version makes Intune treat the old release as installed.',
      readyNote: 'Fill in the items marked above. "Build only" works without them.',
    }),
    actions: { hint: 'Some required information is still missing.' },
    status: 'The install command runs 7z2408-x64.exe, which is not in this package.',
  }),

  published: mainWindow({
    pkg: PKG, view: editorView(readyBase), actions: { portal: true }, log: PUBLISH_LOG, height: null,
    status: "'7-Zip' is published in Intune. Assign groups in the portal.",
  }),
};

// ---- Wizard -----------------------------------------------------------------------
function wizard(step, title, sub, content, { last = false, backOff = false } = {}) {
  return { title: 'New package from an installer', height: 660, width: 820, body: `
  <div class="bar top"><div style="padding:16px 22px 14px">
    <div class="Tiny" style="margin-bottom:4px">STEP ${step} OF 5</div>
    <div class="H1" style="font-size:18px">${title}</div>
    <div class="Muted" style="margin-top:4px">${sub}</div></div></div>
  <div style="flex:1;padding:16px 22px 8px;overflow:hidden">${content}</div>
  <div class="bar bottom" style="padding:12px 22px"><div class="row">
    <div class="Tiny grow">Everything can still be changed in the studio afterwards.</div>
    <span class="btn BtnDefault ${backOff ? 'disabled' : ''}">Back</span>
    ${last ? '<span class="btn BtnDefault" style="margin-left:8px">Create package</span><span class="btn BtnPrimary" style="margin-left:8px">Create and publish</span>'
           : '<span class="btn BtnPrimary" style="margin-left:8px">Next</span>'}
    <span class="btn BtnQuiet" style="margin-left:8px">Cancel</span>
  </div></div>` };
}

screens.wiz1 = wizard(1, 'Installation file', 'Pick the file you got from the vendor. The tool identifies the installer type and prefills the silent switches.', `
  ${label('INSTALLATION FILE FROM THE VENDOR (.EXE OR .MSI)', ' style="margin-top:0"')}
  <div class="row"><div class="grow">${tb('C:\\Users\\it-admin\\Downloads\\7z2501-x64.exe')}</div><span class="btn BtnDefault" style="margin-left:6px">Browse...</span></div>
  <div class="Note ok" style="margin-top:12px"><div class="Body" style="color:inherit">Installer type: NSIS. Product: 7-Zip 25.01. NSIS installer — /S (capital S) installs silently. The uninstaller is usually uninstall.exe /S in the install folder.</div></div>
  <div class="FieldLabel" style="margin-top:20px">WHERE PACKAGE FOLDERS ARE CREATED</div>
  <div class="row"><div class="grow">${tb(ROOT)}</div><span class="btn BtnDefault" style="margin-left:6px">Browse...</span></div>
  <div class="Tiny" style="margin-top:6px">A folder for this app is created here, holding the installer and an app.json with the settings. The location is remembered for next time.</div>`,
  { backOff: true });

screens.wiz2 = wizard(2, 'App information', 'This is how the app appears in Intune and the Company Portal. The commands are what Intune runs on the devices.', `
  ${label('NAME', ' style="margin-top:0"')}${tb('7-Zip')}
  ${label('PUBLISHER')}${tb('Igor Pavlov')}
  ${label('VERSION')}${tb('25.01')}
  ${label('DESCRIPTION (OPTIONAL)')}<div class="tb multi" style="height:61px">${esc(DESC)}${grip}</div>
  ${label('INSTALL COMMAND')}${tb('"7z2501-x64.exe" /S')}
  ${label('UNINSTALL COMMAND')}${tb('', 'focus')}
  <div class="Note" style="margin-top:12px"><div class="Muted">NSIS installer — /S (capital S) installs silently. The uninstaller is usually uninstall.exe /S in the install folder.</div></div>`);

screens.wiz3 = wizard(3, 'Detection', 'Intune needs a way to check whether the app is already on a device. Without it, publishing is blocked.', `
  <div class="rad on" style="margin-top:0"><i></i>Pick the app from the programs installed on this computer (recommended)</div>
  <div style="margin:6px 0 4px 22px"><span class="btn BtnDefault">Choose installed program...</span>
    <div class="Muted" style="margin-top:6px">Selected: 7-Zip 25.01 (x64) 25.01 — rule on the app's uninstall key (DisplayVersion at least 25.01)</div></div>
  <div class="rad"><i></i>Skip for now — set Detection in the studio before publishing</div>
  <div class="Note warn" style="margin-top:16px"><div class="Body" style="color:inherit">If the app is not installed on this computer yet: run the installer now as a normal double-click install, then click Choose installed program. That teaches the tool exactly what Intune should look for, and you can uninstall the app again afterwards.</div></div>`);

screens.wiz5 = wizard(5, 'Summary', 'Review what will be created. The package then opens in the studio, where everything can still be adjusted.', `
  ${label('PACKAGE FOLDER NAME', ' style="margin-top:0"')}${tb('7-Zip 25.01')}
  ${label('THIS IS WHAT WILL BE CREATED')}
  <div class="Note" style="background:#FFFFFF;padding:8px 10px"><div class="mono" style="font-size:11px;line-height:15px;white-space:pre;height:190px;overflow:hidden;color:var(--Ink)">${esc([
    `Created in:  ${ROOT}`,
    'Setup file:  7z2501-x64.exe (NSIS)',
    '',
    'App name:    7-Zip',
    'Publisher:   Igor Pavlov',
    'Version:     25.01',
    'Install:     "7z2501-x64.exe" /S',
    'Uninstall:   "C:\\Program Files\\7-Zip\\Uninstall.exe" /S',
    'Detection:   Registry: HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\7-Zip, DisplayVersion >= 25.01',
    'Logo:        7-zip.png',
  ].join('\n'))}</div></div>`, { last: true });

// The wizard at its MinHeight, for a collage that has no room for empty space
screens.wiz1s = { ...screens.wiz1, height: 560 };
screens.wiz3s = { ...screens.wiz3, height: 560 };

// ---- Installed-app picker -----------------------------------------------------------
const APPS = [
  ['7-Zip 25.01 (x64)', '25.01', 'Igor Pavlov', 'x64'],
  ['Adobe Acrobat (64-bit)', '25.001.20432', 'Adobe', 'x64'],
  ['Git', '2.47.1', 'The Git Development Community', 'x64'],
  ['Google Chrome', '131.0.6778.205', 'Google LLC', 'x64'],
  ['Java 8 Update 431 (64-bit)', '8.0.4310.11', 'Oracle Corporation', 'x64'],
  ['Microsoft 365 Apps for enterprise - en-us', '16.0.18129.20158', 'Microsoft Corporation', 'x64'],
  ['Microsoft Edge', '131.0.2903.112', 'Microsoft Corporation', 'x86'],
  ['Microsoft OneDrive', '24.226.1110.0004', 'Microsoft Corporation', 'x64'],
  ['Microsoft Teams Meeting Add-in for Microsoft Office', '1.24.33001', 'Microsoft', 'x86'],
  ['Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.42.34433', '14.42.34433.0', 'Microsoft Corporation', 'x86'],
  ['Notepad++ (64-bit x64)', '8.7.4', 'Notepad++ Team', 'x64'],
  ['PowerShell 7-x64', '7.4.6.0', 'Microsoft Corporation', 'x64'],
  ['VLC media player', '3.0.21', 'VideoLAN', 'x64'],
  ['Zoom Workplace (64-bit)', '6.3.1.53893', 'Zoom Video Communications, Inc.', 'x64'],
  ['Zscaler', '4.4.0.389', 'Zscaler Inc.', 'x64'],
];
screens.picker = { title: 'Find the app on this computer', width: 740, height: 540, body: `
  <div style="padding:18px;display:flex;flex-direction:column;height:100%">
    <div class="H2">Pick the application</div>
    <div class="Muted" style="margin-top:4px">This is the list from Apps and features on this computer. Picking the app writes the detection rule from its uninstall entry. If the app is missing, install it here first and then reopen this list.</div>
    <div style="margin:12px 0 8px">${tb('', 'focus')}</div>
    <div class="grid" style="flex:1">
      <div class="hd"><div style="width:300px">Name</div><div style="width:110px">Version</div><div style="width:190px">Publisher</div><div style="width:50px">Bits</div></div>
      <div class="vscroll" style="top:25px;--t:2px;--h:330px"></div>
      ${APPS.map((a, i) => `<div class="r ${i === 0 ? 'sel' : ''}"><div style="width:300px">${esc(a[0])}</div><div style="width:110px">${a[1]}</div><div style="width:190px">${esc(a[2])}</div><div style="width:50px">${a[3]}</div></div>`).join('')}
    </div>
    <div class="row" style="margin-top:12px">
      <div class="Tiny grow">41 programs installed</div>
      <span class="btn BtnPrimary">Use this app</span><span class="btn BtnDefault" style="margin-left:8px">Cancel</span>
    </div>
  </div>` };

// ---- Settings, first run --------------------------------------------------------------
screens.settings = { title: 'Welcome to Packwright', width: 700, height: null, body: `
  <div class="bar top"><div style="padding:16px 22px 14px">
    <div class="H1" style="font-size:18px">Where should Packwright keep things?</div>
    <div class="Muted" style="margin-top:4px">Two folders, both on a local disk by default. You can change them later from Settings in the header — this is only asked once.</div></div></div>
  <div style="padding:18px 22px 8px">
    ${label('PACKAGE FOLDER')}
    <div class="Tiny" style="margin-bottom:4px">Where the wizard creates a folder per package, with the installer and app.json in it.</div>
    <div class="row"><div class="grow">${tb(ROOT)}</div><span class="btn BtnDefault" style="margin-left:8px">Browse...</span></div>
    <div class="FieldLabel" style="margin-top:16px">OUTPUT FOLDER</div>
    <div class="Tiny" style="margin-bottom:4px">Where the built .intunewin files are written before they are uploaded.</div>
    <div class="row"><div class="grow">${tb(TOOLS + '\\Output')}</div><span class="btn BtnDefault" style="margin-left:8px">Browse...</span></div>
    <span class="btn BtnQuiet" style="margin-top:14px">Reset to the defaults</span>
    <div class="Tiny" style="margin-top:10px">Saved in C:\\Users\\it-admin\\AppData\\Roaming\\Packwright\\settings.json</div>
  </div>
  <div class="bar bottom" style="margin-top:10px;padding:12px 22px"><div class="row">
    <div class="Tiny grow">Folders are created when they are first used.</div><span class="btn BtnPrimary">Get started</span></div></div>` };

// ---- Confirmation before publishing ---------------------------------------------------
screens.confirm = { title: 'Publish to Intune', width: 560, height: null, noIcon: true, noMax: true, body: `
  <div class="mb-body">
    <svg viewBox="0 0 32 32" style="width:32px;height:32px;flex:none"><circle cx="16" cy="16" r="15" fill="#0F6CBD"/><text x="16" y="23" text-anchor="middle" font-family="Arial" font-weight="700" font-size="20" fill="#FFFFFF">?</text></svg>
    <div style="white-space:pre-wrap">${esc([
      'Create this app in Intune?', '',
      'Name:       7-Zip', 'Publisher:  Igor Pavlov', 'Version:    25.01', 'Package:    7z2501-x64.exe', '',
      'Detection:  Intune reads DisplayVersion under the registry key 7-Zip and treats the app as installed when it is at least 25.01.', '',
      'If Intune already has an app with this name, publishing stops before anything is created.',
      'No groups are assigned — do that in the portal.'].join('\n'))}</div>
  </div>
  <div class="mb-foot"><div class="mb-btn def">Yes</div><div class="mb-btn">No</div></div>` };

// ---- Help --------------------------------------------------------------------------------
screens.help = { title: 'How to use Packwright', width: 720, height: 640, body: `
  <div class="bar top"><div style="padding:16px 22px 14px">
    <div class="H1" style="font-size:18px">How to use this tool</div>
    <div class="Muted" style="margin-top:4px">The short version. The README next to the script covers setup, sign-in and the command line.</div></div></div>
  <div style="flex:1;overflow:hidden;padding:2px 22px 8px">
    ${[['What this does', ['It turns a folder holding an installation file into a Win32 app in Intune.',
        'Publishing does two things: the folder is packed into an .intunewin file, and an app is created in Intune with the settings shown on screen. No groups are assigned — you do that in the Intune portal afterwards.']],
       ['Two ways to start', ['I have an installer file — pick the .exe or .msi you got from the vendor. A five-step wizard creates the package folder and fills in the silent install switches for the installer type it recognises (MSI, Inno Setup, NSIS, InstallShield, WiX Burn).',
        'I have a package folder — open a folder that already holds the installation files: a PSADT package, an MSI, a plain installer, or a payload folder that installs with a .ps1 or .cmd script. Anything previously saved in the folder is loaded.']],
       ['What Intune insists on', ['A name, a publisher, a command to install with and a detection rule. The checklist on the right turns green when all four are set, and the Publish button tells you which field is missing if you try too early.',
        'Under the checklist you may also see lines marked with a warning sign. Those are things that look wrong but cannot be proven wrong, so they never stop you publishing — read them, and publish if they are what you meant.']],
       ['Detection — the one thing worth understanding', ['Intune has to answer "is this app already on the device?" without running the installer. That is what a detection rule is for, and Intune refuses an app without one.']]]
      .map(([t, ps]) => `<div class="H2" style="margin:14px 0 4px">${t}</div>${ps.map(p => `<div class="Body" style="margin-bottom:6px;line-height:17px">${esc(p)}</div>`).join('')}`).join('')}
  </div>
  <div class="bar bottom" style="padding:12px 22px"><div class="row">
    <div class="Tiny grow">Press F1 in the main window to open this again.</div>
    <span class="btn BtnQuiet" style="margin-right:8px">Open the full README</span><span class="btn BtnPrimary">Close</span></div></div>` };

// ---- Render ---------------------------------------------------------------------------------
const stage = document.querySelector('.stage');
for (const [id, s] of Object.entries(screens)) {
  const el = document.createElement('div');
  el.className = 'win';
  el.id = id;
  el.style.width = (s.width || 1120) + 'px';
  if (s.height) el.style.height = s.height + 'px'; else el.classList.add('auto');
  el.innerHTML = frame(s.title, s.body, { noMax: s.noMax });
  if (s.noIcon) el.querySelector('.ico').remove(), el.querySelector('.ttl').style.marginLeft = '12px';
  stage.appendChild(el);
}
document.body.dataset.ready = '1';
