<#
.SYNOPSIS
    Create or update a Win32 app in Intune from a .intunewin file (metadata + content upload).

.DESCRIPTION
    Publishes a .intunewin package to Intune as a Win32 app using Microsoft Graph
    (Microsoft.Graph.Authentication module only — no other dependencies):
      1. Reads package metadata (Detection.xml) straight out of the .intunewin file
      2. Decides whether this is a new app or an existing one (by display name, or -AppId)
      3. Creates the win32LobApp with display name, install/uninstall commands and detection rules
      4. Uploads the encrypted payload to Azure Storage in chunks (with SAS renewal for large files)
      5. Commits the content and points the app at the new content version

    With -Update the run is idempotent — the same spec can be applied over and over: the app
    is created the first time and gets a new content version (plus refreshed metadata) after
    that. Assignments and an existing icon are never touched, and because the app is only
    switched over in the last step, a failed upload leaves it serving the previous version.
    Without -Update an existing app of the same name stops the run, so a re-publish cannot
    silently create a duplicate.

    App settings come from an app.json manifest (see app.example.json) placed next to the
    installation source (or given via -ManifestPath). Sensible defaults are derived when
    possible, so an MSI or PSADT package can often be published without any manifest at all:
      - PSADT packages  : Invoke-AppDeployToolkit.exe -DeploymentType Install/Uninstall -DeployMode Silent,
                          and name/publisher/version from AppVendor/AppName/AppVersion in the
                          $adtSession block of Invoke-AppDeployToolkit.ps1
      - MSI packages    : msiexec install/uninstall + product code detection rule
      - Name/publisher/version fall back to MSI metadata when available
    Non-MSI packages always need a detection rule in the manifest (file/registry/script).

    Can be run directly:  .\Publish-IntuneWinApp.ps1 -Path ".\Output\7-zip\Invoke-AppDeployToolkit.intunewin"
    or dot-sourced and used in a pipeline:  Build-IntuneWinApp -SourceFolder X -PassThru | Publish-IntuneWinApp

.PARAMETER Path
    Path to the .intunewin file. Accepts pipeline input from Build-IntuneWinApp -PassThru.
    Left out for an Intune Store app (a WinGet package from the Microsoft Store whose app.json
    says delivery "store"): that is published from -ManifestPath alone, with nothing to upload.

.PARAMETER SourceFolder
    Optional. Used to locate app.json next to the installation source. Populated automatically
    when piping from Build-IntuneWinApp.

.PARAMETER ManifestPath
    Optional explicit path to an app.json manifest. If omitted, app.json is searched for in
    SourceFolder and next to the .intunewin file.

.PARAMETER TenantId
    Tenant id/domain for Connect-MgGraph. Overrides the 'TenantId' field in '.secret'.

.PARAMETER ClientId
    App registration (client) id for app-only auth. Overrides the 'AppId' field in '.secret'.

.PARAMETER CertificateThumbprint
    Thumbprint of the app's certificate (CurrentUser\My or LocalMachine\My).
    Overrides the 'GraphThumbprint' field in '.secret'.

.PARAMETER ClientSecret
    Client secret for app-only auth (dev convenience; plaintext at rest — prefer the
    certificate in prod). Overrides the 'ClientSecret' field in '.secret'.

.PARAMETER SignIn
    How the delegated fallback prompts (ignored for app-only auth):
      Auto       - let the Graph SDK decide; on Windows that is the WAM broker, which
                   parents its prompt to the console window of the process (default)
      Browser    - turn WAM off and sign in in the default browser. Needed whenever the
                   process has no console window to parent a prompt to, or the prompt
                   would open behind a window — a GUI host, a background thread
      DeviceCode - print a code for https://microsoft.com/devicelogin. For remote
                   sessions and hosts with no browser. The SDK writes that code to the
                   console, so a host without one will not show it

.EXAMPLE
    .\Publish-IntuneWinApp.ps1 -Path ".\Output\7-zip\Invoke-AppDeployToolkit.intunewin" -ManifestPath "C:\psadt\7-zip\app.json"

.EXAMPLE
    . .\Build-IntuneWinApp.ps1
    . .\Publish-IntuneWinApp.ps1
    Build-IntuneWinApp -SourceFolder "C:\psadt\7-zip" -PassThru | Publish-IntuneWinApp -WhatIf

    Builds and shows what would be created in Intune without doing it.

.NOTES
    Author    : Love A
    Requires  : Microsoft.Graph.Authentication (Connect-MgGraph/Invoke-MgGraphRequest)

    Auth      : App-only via an Entra app registration, configured in a gitignored '.secret'
                JSON file next to this script (see '.secret.template'). Fields: AppId, TenantId,
                GraphThumbprint (cert in the runner's cert store; preferred, esp. prod) and/or
                ClientSecret (dev convenience; wins over the cert if set). Explicit parameters
                override '.secret' fields. If neither '.secret' nor -ClientId is present, the
                script falls back to delegated interactive sign-in — see -SignIn for how that
                prompt is shown, which matters as soon as the caller has no console window.
    Permission: DeviceManagementApps.ReadWrite.All — Application permission (admin consent)
                for app-only auth, or delegated for the interactive fallback.
    The app is created without assignments — assign it in the portal (or extend this script).
.PARAMETER Update
    Make the run idempotent: create the app when Intune does not have it, and when it
    does, upload a new content version to that same app and re-assert its metadata from
    app.json. Assignments and the existing icon are left untouched. This is the switch
    to use from a pipeline, where the same spec is applied over and over.

.PARAMETER AppId
    Update this exact app instead of looking it up by display name. The stable key to
    use in automation, and the way to disambiguate when several apps share a name.
    Implies -Update.

.PARAMETER AllowDuplicateName
    Publish even when Intune already has a Win32 app with the same display name. Without
    it, publishing stops before anything is created — the usual cause is publishing the
    same package twice.

.EXAMPLE
    Build-IntuneWinApp -SourceFolder "C:\psadt\7-zip" -PassThru |
        Publish-IntuneWinApp -Update -Confirm:$false

    Applies the package as desired state: created the first time, a new content version
    on every later run. Safe to run from a scheduled task or a pipeline.

.VERSION
    2026-10-12 - 1.9 - Says who it signed in as and explains a 403; roleScopeTagIds
    2026-10-08 - 1.8 - WinGet packages: requirement rules, dependencies, Store apps, source policy
    2026-09-24 - 1.7 - -Update works on an app Intune already has
    2026-09-08 - 1.6 - A duplicate-name check that cannot run stops the publish; uploads retried
    2026-09-04 - 1.5 - A failed sign-in stops the run; -SignIn
    2026-09-03 - 1.4 - Idempotent publishing: -Update, -AppId, -WhatIf
    2026-09-03 - 1.3 - Refuses a second app with the same display name unless -AllowDuplicateName
    2026-07-06 - 1.2 - Display name, publisher and version read from a PSADT package's $adtSession
    2026-07-06 - 1.1 - App-only sign-in through an Entra app registration (.secret)
    2026-07-06 - 1.0 - Initial version (create win32LobApp, chunked content upload, commit)

    What each version changed: CHANGELOG.md
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [string]$Path,

    [Parameter(Position = 1)]
    [string]$ManifestPath,

    [string]$TenantId,

    [string]$ClientId,

    [string]$CertificateThumbprint,

    [string]$ClientSecret,

    [switch]$Update,

    [string]$AppId,

    [switch]$AllowDuplicateName,

    [ValidateSet('Auto', 'Browser', 'DeviceCode')]
    [string]$SignIn = 'Auto'
)

# Fails the same way whether the script is run or dot-sourced, and before anything reaches
# Intune. See the note in Packwright.ps1 on why the BOM is what keeps this line reachable.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw ("Publish-IntuneWinApp needs PowerShell 7 — this is Windows PowerShell $($PSVersionTable.PSVersion). " +
           'Start pwsh and run it from there (winget install Microsoft.PowerShell).')
}

function Publish-IntuneWinApp {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        # Required for a Win32 app. An app.json that describes an Intune Store app (a WinGet
        # package from the Microsoft Store delivered as Intune's own Store app type) has no
        # content to upload and is published from -ManifestPath alone.
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [Alias('IntuneWinFile', 'FullName')]
        [string]$Path,

        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [string]$SourceFolder,

        [Parameter(Position = 1)]
        [string]$ManifestPath,

        [string]$TenantId,

        [string]$ClientId,

        [string]$CertificateThumbprint,

        [string]$ClientSecret,

        [switch]$Update,

        [string]$AppId,

        [switch]$AllowDuplicateName,

        [ValidateSet('Auto', 'Browser', 'DeviceCode')]
        [string]$SignIn = 'Auto'
    )

    begin {
        $graphBase = 'https://graph.microsoft.com/beta'

        # Auto-loading usually finds it; ask explicitly so a module that is present but not
        # auto-discovered still loads, and keep the reason when the load itself fails.
        $graphLoadError = $null
        if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
            try   { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop }
            catch { $graphLoadError = $_.Exception.Message }
        }
        if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
            # "Install it" is no help to someone who just did. The usual causes are an install
            # that landed out of reach — Install-Module from Windows PowerShell 5.1 writes to
            # Documents\WindowsPowerShell, which PowerShell 7 does not read, and -Scope CurrentUser
            # while elevated installs into the administrator's profile — or a module sitting in a
            # redirected home directory that this process is not allowed to load from.
            $onDisk = @(Get-Module -ListAvailable Microsoft.Graph.Authentication -ErrorAction SilentlyContinue)
            $detail = if ($onDisk) {
                $found  = "$($onDisk[0].Path)"
                $remote = $found.StartsWith('\\') -or
                          $(try { [IO.DriveInfo]::new([IO.Path]::GetPathRoot($found)).DriveType -ne 'Fixed' } catch { $false })
                "It is at $found but could not be loaded." +
                    $(if ($remote) { ' That is a network location — install it on the local disk instead, from an ' +
                                     'elevated pwsh: Install-Module Microsoft.Graph.Authentication -Scope AllUsers.' } else { '' }) +
                    $(if ($graphLoadError) { " PowerShell said: $graphLoadError" } else { '' })
            }
            else {
                'Install it from PowerShell 7 (pwsh), as the same account that runs this tool, without elevating: ' +
                'Install-Module Microsoft.Graph.Authentication -Scope CurrentUser.' + [Environment]::NewLine +
                "Searched: $($env:PSModulePath)"
            }
            throw "Microsoft.Graph.Authentication is required. $detail"
        }

        # App credentials from a gitignored '.secret' JSON file next to this script
        # (see '.secret.template'). Explicit parameters override '.secret' fields.
        # The certificate lives in the runner's cert store, referenced by thumbprint.
        $secretFile = Join-Path -Path $PSScriptRoot -ChildPath '.secret'
        $cloudAuth  = $null
        if (Test-Path -LiteralPath $secretFile) {
            try { $cloudAuth = Get-Content -LiteralPath $secretFile -Raw -Encoding UTF8 | ConvertFrom-Json }
            catch { Write-Warning "Could not parse '$secretFile': $($_.Exception.Message)" }
        }
        function Get-SecretField {
            param([string]$Name)
            if ($cloudAuth -and ($cloudAuth.PSObject.Properties.Name -contains $Name)) { return $cloudAuth.$Name }
            return $null
        }
        $authTenantId   = if ($TenantId)              { $TenantId }              else { Get-SecretField 'TenantId' }
        $authClientId   = if ($ClientId)              { $ClientId }              else { Get-SecretField 'AppId' }
        $authThumbprint = if ($CertificateThumbprint) { $CertificateThumbprint } else { Get-SecretField 'GraphThumbprint' }
        $authSecret     = if ($ClientSecret)          { $ClientSecret }          else { Get-SecretField 'ClientSecret' }

        $ctx = Get-MgContext
        if (-not [string]::IsNullOrWhiteSpace($authClientId)) {
            # App-only auth via the Entra app registration
            if ([string]::IsNullOrWhiteSpace($authTenantId)) {
                throw "App-only auth requires a TenantId. Add it to '.secret' or pass -TenantId."
            }
            $reusable = $ctx -and $ctx.ClientId -eq $authClientId -and "$($ctx.AuthType)" -eq 'AppOnly'
            if (-not $reusable) {
                # Client secret wins over certificate if both are present (dev convenience);
                # the certificate is the preferred choice, especially in prod.
                if (-not [string]::IsNullOrWhiteSpace($authSecret)) {
                    $cred = [System.Management.Automation.PSCredential]::new(
                        $authClientId, (ConvertTo-SecureString $authSecret -AsPlainText -Force))
                    Connect-MgGraph -TenantId $authTenantId -ClientSecretCredential $cred -NoWelcome -ErrorAction Stop
                    Write-Host 'Connected to Microsoft Graph (app-only, client secret).' -ForegroundColor Cyan
                }
                elseif (-not [string]::IsNullOrWhiteSpace($authThumbprint)) {
                    Connect-MgGraph -TenantId $authTenantId -ClientId $authClientId `
                        -CertificateThumbprint $authThumbprint -NoWelcome -ErrorAction Stop
                    Write-Host 'Connected to Microsoft Graph (app-only, certificate).' -ForegroundColor Cyan
                }
                else {
                    throw "App-only auth requires GraphThumbprint or ClientSecret in '.secret' (or -CertificateThumbprint / -ClientSecret)."
                }
            }
        }
        elseif (-not $ctx -or ($ctx.Scopes -notcontains 'DeviceManagementApps.ReadWrite.All')) {
            # Fallback: delegated interactive sign-in (no '.secret' and no -ClientId).
            # By default the prompt is brokered by WAM, which parents itself to the console
            # window of the process. A host without one — a GUI, a hidden window — gives it
            # nothing to parent to and the prompt fails with an empty message, so those
            # callers pass -SignIn Browser and get the plain browser flow instead.
            # Microsoft Graph remembers the last interactive sign-in on this computer and uses it
            # again without a prompt, so "finish the prompt" would send people looking for one
            Write-Host ("No app credentials found ('.secret' missing) - signing in as you (-SignIn $SignIn). A sign-in prompt opens " +
                        'unless Microsoft Graph remembers your sign-in on this computer.') -ForegroundColor Yellow
            $connect = @{ Scopes = @('DeviceManagementApps.ReadWrite.All'); NoWelcome = $true; ErrorAction = 'Stop' }
            if ($authTenantId) { $connect.TenantId = $authTenantId }
            if ($SignIn -eq 'DeviceCode') { $connect.UseDeviceCode = $true }
            if ($SignIn -eq 'Browser' -and (Get-Command Set-MgGraphOption -ErrorAction SilentlyContinue)) {
                Set-MgGraphOption -EnableLoginByWAM $false
            }
            try { Connect-MgGraph @connect }
            catch {
                throw ("Interactive sign-in to Microsoft Graph failed: $($_.Exception.Message)" +
                       $(if ($SignIn -eq 'Auto') { ' Retry with -SignIn Browser if no sign-in window appeared.' } else { '' }))
            }
        }

        # Connect-MgGraph can report a failure without throwing. Stop here rather than let
        # every Graph call below fail on its own with 'Authentication needed' — half of them
        # non-terminating, which is how a run gets far enough to claim it created an app.
        $signedIn = Get-MgContext
        if (-not $signedIn) {
            throw ('Not connected to Microsoft Graph. Run "Connect-MgGraph -Scopes DeviceManagementApps.ReadWrite.All" ' +
                   'in this session, retry with -SignIn Browser, or set up app-only auth in ''.secret''.')
        }

        # The sign-in as Intune sees it, out of its own access token - decoded here and sent
        # nowhere: when it was made, the Entra roles in it, and the permissions Graph granted.
        # Intune goes by those roles (or by the ones it assigns itself, which a token does not
        # show), and they are the roles the account had when it signed in: one activated in
        # PIM since is not among them. @{ Issued; Roles; OtherRoles; Scopes }, or $null.
        $entraRoleNames = @{
            '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator'
            '3a2c62db-5318-420d-8d74-23affee5d9d5' = 'Intune Administrator'
            '7698a772-787b-4ac8-901f-60d6b08affd2' = 'Cloud Device Administrator'
            '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3' = 'Application Administrator'
            '158c047a-c907-4556-b7ef-446551a6b5f7' = 'Cloud Application Administrator'
            'f2ef992c-3afb-46b9-b7cf-a126ee74c451' = 'Global Reader'
            'b79fbf4d-3ef9-4689-8143-76b194e85509' = ''   # every member's own: not a role anyone was given
        }
        function Get-SignInClaims {
            try {
                $response = Invoke-MgGraphRequest -Method GET -Uri "$graphBase/deviceAppManagement/mobileApps?`$top=1&`$select=id" `
                                -OutputType HttpResponseMessage -ErrorAction Stop
                $payload = "$($response.RequestMessage.Headers.Authorization.Parameter)".Split('.')[1]
                if (-not $payload) { return $null }
                $payload = $payload.Replace('-', '+').Replace('_', '/')
                $payload += '=' * ((4 - $payload.Length % 4) % 4)
                $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
                $ids = @($claims.wids | ForEach-Object { "$_".ToLowerInvariant() })
                [pscustomobject]@{
                    Issued     = [DateTimeOffset]::FromUnixTimeSeconds([int64]$claims.iat).LocalDateTime
                    Roles      = @($ids | ForEach-Object { $entraRoleNames[$_] } | Where-Object { $_ })
                    OtherRoles = @($ids | Where-Object { -not $entraRoleNames.ContainsKey($_) }).Count
                    Scopes     = @("$($claims.scp)" -split '\s+' | Where-Object { $_ })
                }
            }
            catch { $null }
        }
        function Format-SignInClaims {
            param($Claims)
            $roles = @($Claims.Roles) + @(if ($Claims.OtherRoles) { "$($Claims.OtherRoles) other Entra role(s)" })
            ('This sign-in was made {0:yyyy-MM-dd HH:mm} and carries {1}.' -f $Claims.Issued,
                $(if ($roles) { "the Entra role(s) $($roles -join ', ')" }
                  else { 'no Entra administrator role - Intune then goes by the roles it assigns itself (Tenant administration > Roles)' }))
        }

        # Whoever it is, said every time: a remembered sign-in gives no other sign of it, and a
        # publish to the wrong tenant is not found out until someone looks for the app
        Write-Host $(if ("$($signedIn.AuthType)" -eq 'AppOnly') { "Signed in to Microsoft Graph as the app $($signedIn.ClientId), tenant $($signedIn.TenantId)." }
                     elseif ($signedIn.Account) { "Signed in to Microsoft Graph as $($signedIn.Account), tenant $($signedIn.TenantId)." }
                     else { "Signed in to Microsoft Graph, tenant $($signedIn.TenantId)." }) -ForegroundColor Cyan
        $signInClaims = if ("$($signedIn.AuthType)" -ne 'AppOnly') { Get-SignInClaims }
        if ($signInClaims) { Write-Host (Format-SignInClaims $signInClaims) -ForegroundColor Cyan }

        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        # --- helpers -------------------------------------------------------------

        function Get-FirstValue {
            foreach ($v in $args) { if ($null -ne $v -and "$v" -ne '') { return $v } }
        }

        # A 403 from Intune, and what it usually means for whoever publishes. A delegated
        # sign-in carries the roles the account had when it signed in: an Intune role activated
        # in PIM after that is not in it, and Graph keeps using that sign-in until it expires,
        # which can be hours. An app registration needs the application permission instead.
        function Test-GraphForbidden {
            param($ErrorRecord)
            "$ErrorRecord" -match '\b403\b|Forbidden|not authorized to perform'
        }

        # What to do about it depends on what the sign-in carries, so the message says that first.
        # Disconnect-MgGraph alone is not enough: it leaves the tokens Graph keeps, in
        # %LOCALAPPDATA%\.IdentityService, and the next request takes one of those again.
        function Get-GraphForbiddenMessage {
            param([string]$Action)
            $forgetSignIn = 'Disconnect-MgGraph; Remove-Item ~\.mg\mg.authrecord.json, $env:LOCALAPPDATA\.IdentityService\mg.msal.cache.*'
            $context = Get-MgContext
            if ("$($context.AuthType)" -eq 'AppOnly') {
                return ("Intune refused to $Action (403 Forbidden): the app registration $($context.ClientId) needs the application permission " +
                        'DeviceManagementApps.ReadWrite.All, with admin consent. Nothing more was changed.')
            }
            $who = if ($context.Account) { $context.Account } else { 'the signed-in account' }
            $claims = Get-SignInClaims
            $message = "Intune refused to $Action (403 Forbidden) for $who. "
            if (-not $claims) {
                return ($message + 'If you activated an Intune role in PIM after signing in, the sign-in still carries the roles from before, and ' +
                        'Microsoft Graph keeps using it until it expires: sign in again - "Sign in again" in Packwright, or in PowerShell ' +
                        "$forgetSignIn - and publish again. Nothing more was changed.")
            }
            $message += (Format-SignInClaims $claims) + ' '
            if ($claims.Scopes -and $claims.Scopes -notcontains 'DeviceManagementApps.ReadWrite.All') {
                $message += ('It lacks the permission DeviceManagementApps.ReadWrite.All, which an administrator has to grant to Microsoft ' +
                             'Graph Command Line Tools in Entra ID (Enterprise applications). ')
            }
            elseif ($claims.Roles -contains 'Intune Administrator' -or $claims.Roles -contains 'Global Administrator') {
                $message += ('That role allows it, so Intune refuses for another reason: an access policy that needs a second administrator to ' +
                             'approve changes to apps (Multi Admin Approval, Tenant administration > Multi Admin Approval), or a role activated so ' +
                             'recently that Intune does not see it yet - wait a few minutes, sign in again and publish again. ')
            }
            else {
                $message += ('If you activate Intune Administrator in PIM, do it first, then sign in again - "Sign in again" in Packwright, or in ' +
                             "PowerShell $forgetSignIn - and publish again. If your rights come from a role assigned in Intune instead, it " +
                             'needs Mobile apps: Create, and when its assignment is limited to scope tags, the app has to carry one of them: add ' +
                             '"roleScopeTagIds": ["<tag id>"] to app.json. ')
            }
            $message + 'Nothing more was changed.'
        }

        # app.json's 'architecture' is in the words of applicableArchitectures, the property
        # this script used to write, where x64 took in ARM64 devices as well. Intune has since
        # replaced it with allowedArchitectures, where x64 means x64 alone, and no longer lets a
        # PATCH set the old one: "The ApplicableArchitectures property can only be set via
        # ODataAction: enableApplicableArchitectures". An update PATCHes the whole desired
        # state, so -Update failed on exactly that, at the last step and after the upload.
        # The value goes out as allowedArchitectures instead, translated the way Intune moved
        # its own apps across — arm64 wherever there was x64 — so an app.json keeps reaching
        # the devices it always did, and a created app and an updated one end up the same.
        function ConvertTo-AllowedArchitecture {
            param([string]$Architecture)
            $expected = '(expected x64, x86, arm64, a comma list of them, or neutral for all three)'
            $wanted = @(foreach ($token in ($Architecture -split '[,\s]+' | Where-Object { $_ })) {
                switch ($token) {
                    'x86'     { 'x86' }
                    'x64'     { 'x64', 'arm64' }
                    'arm64'   { 'arm64' }
                    'neutral' { 'x86', 'x64', 'arm64' }
                    default   { throw "Architecture '$Architecture' in manifest: '$token' is not one Intune can target $expected." }
                }
            })
            if (-not $wanted) { throw "Architecture '$Architecture' in manifest names no architecture $expected." }
            # One fixed order, so the same app.json always sends the same value
            @('x86', 'x64', 'arm64' | Where-Object { $_ -in $wanted }) -join ','
        }

        # Reads ApplicationInfo (name, setup file, encryption info, MSI info) from the package
        function Get-IntuneWinMetadata {
            param([string]$FilePath)
            $zip = [System.IO.Compression.ZipFile]::OpenRead($FilePath)
            try {
                $entry = $zip.Entries | Where-Object { $_.FullName -eq 'IntuneWinPackage/Metadata/Detection.xml' }
                if (-not $entry) { throw "Not a valid .intunewin file (Detection.xml missing): $FilePath" }
                $reader = New-Object System.IO.StreamReader($entry.Open())
                try { $xml = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
                return $xml.ApplicationInfo
            }
            finally { $zip.Dispose() }
        }

        # Extracts the encrypted payload (the file that actually gets uploaded)
        function Export-IntuneWinPayload {
            param([string]$FilePath, [string]$Destination)
            $zip = [System.IO.Compression.ZipFile]::OpenRead($FilePath)
            try {
                $entry = $zip.Entries | Where-Object { $_.FullName -eq 'IntuneWinPackage/Contents/IntunePackage.intunewin' }
                if (-not $entry) { throw "Payload IntunePackage.intunewin missing in: $FilePath" }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $Destination, $true)
                return (Get-Item -LiteralPath $Destination)
            }
            finally { $zip.Dispose() }
        }

        function Wait-IntuneFileState {
            param([string]$Uri, [string]$State, [int]$TimeoutSec = 300)
            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            do {
                $file = Invoke-MgGraphRequest -Method GET -Uri $Uri
                if ($file.uploadState -eq $State) { return $file }
                if ($file.uploadState -like '*failed*' -or $file.uploadState -like '*timedout*') {
                    throw "Intune returned uploadState '$($file.uploadState)' while waiting for '$State'."
                }
                Start-Sleep -Seconds 3
            } while ((Get-Date) -lt $deadline)
            throw "Timed out waiting for uploadState '$State' (last: $($file.uploadState))."
        }

        # One PUT of one block, retried on the failures that pass. A single transient 500 or
        # a dropped connection used to throw the whole upload away, and an 8 GB package is an
        # hour of it. Retrying a block is safe: the block id is unchanged, so a block that did
        # land is simply written again, and nothing is visible to Intune until the block list
        # is committed. A 403 is not retried — that is an expired SAS uri, which needs renewing
        # rather than repeating, and the renewal below handles it.
        function Send-BlobPut {
            param([string]$Uri, $Body, [hashtable]$Headers = @{}, [int]$Attempts = 4)
            for ($attempt = 1; ; $attempt++) {
                try { return Invoke-WebRequest -Method Put -Uri $Uri -Body $Body -Headers $Headers -UseBasicParsing }
                catch {
                    # No response at all (a dropped connection or a timeout) reads as 0
                    $status = [int]$_.Exception.Response.StatusCode
                    $worthRetrying = $attempt -lt $Attempts -and
                                     ($status -eq 0 -or $status -eq 408 -or $status -eq 429 -or $status -ge 500)
                    if (-not $worthRetrying) { throw }
                    $backoff = [int][Math]::Min(30, [Math]::Pow(2, $attempt))
                    Write-Warning ("Uploading a block failed (attempt $attempt of $Attempts" +
                                   $(if ($status) { ", HTTP $status" } else { ', no response' }) +
                                   "): $($_.Exception.Message) Retrying in $backoff s.")
                    Start-Sleep -Seconds $backoff
                }
            }
        }

        # Chunked block blob upload to the Azure Storage SAS uri Intune hands out
        function Send-IntuneAzureBlob {
            param([string]$FilePath, [string]$SasUri, [string]$FileUri)
            $chunkSize = 6MB
            $stream = [System.IO.File]::OpenRead($FilePath)
            try {
                $blockIds   = New-Object System.Collections.Generic.List[string]
                $buffer     = New-Object byte[] $chunkSize
                $index      = 0
                $totalRead  = 0L
                $renewTimer = [System.Diagnostics.Stopwatch]::StartNew()
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $blockId = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($index.ToString('D4')))
                    $blockIds.Add($blockId)
                    if ($read -lt $buffer.Length) {
                        $body = New-Object byte[] $read
                        [Array]::Copy($buffer, $body, $read)
                    } else {
                        $body = $buffer
                    }
                    $uri = '{0}&comp=block&blockid={1}' -f $SasUri, [Uri]::EscapeDataString($blockId)
                    Send-BlobPut -Uri $uri -Body $body -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } | Out-Null
                    $index++
                    $totalRead += $read
                    Write-Progress -Activity 'Uploading content to Intune' -Status ('{0:N1} / {1:N1} MB' -f ($totalRead / 1MB), ($stream.Length / 1MB)) -PercentComplete ([int](100 * $totalRead / $stream.Length))

                    # SAS uris expire; renew if the upload runs long
                    if ($renewTimer.Elapsed.TotalMinutes -ge 7) {
                        Invoke-MgGraphRequest -Method POST -Uri "$FileUri/renewUpload" -Body '{}' -ContentType 'application/json' | Out-Null
                        $renewed = Wait-IntuneFileState -Uri $FileUri -State 'azureStorageUriRenewalSuccess'
                        if ($renewed.azureStorageUri) { $SasUri = $renewed.azureStorageUri }
                        $renewTimer.Restart()
                    }
                }
                $blockList = '<?xml version="1.0" encoding="utf-8"?><BlockList>' +
                             (($blockIds | ForEach-Object { "<Latest>$_</Latest>" }) -join '') +
                             '</BlockList>'
                Send-BlobPut -Uri "$SasUri&comp=blocklist" -Body $blockList | Out-Null
                Write-Progress -Activity 'Uploading content to Intune' -Completed
            }
            finally { $stream.Dispose() }
        }

        # Create or update? One answer for both app types: the app named by -AppId, the one app of
        # this name and type, or none. Without -Update an existing app stops the run, so nobody
        # creates a duplicate by publishing twice. -AppId names the app to update, so it
        # contradicts -AllowDuplicateName exactly as -Update does.
        function Find-PublishTarget {
            param([string]$DisplayName, [string]$ODataType, [string]$TypeLabel)
            if (($Update -or $AppId) -and $AllowDuplicateName) {
                $named = if ($AppId) { '-AppId' } else { '-Update' }
                throw "$named and -AllowDuplicateName contradict each other: one replaces the app that is already there, the other creates a second one. Pick one."
            }
            if ($AppId) {
                try { $found = Invoke-MgGraphRequest -Method GET -Uri "$graphBase/deviceAppManagement/mobileApps/$AppId" }
                catch { throw "No app with id '$AppId' could be read in Intune: $($_.Exception.Message)" }
                if ("$($found.'@odata.type')" -ne "#microsoft.graph.$ODataType") {
                    throw "App '$AppId' is $($found.'@odata.type'), not $TypeLabel — refusing to touch it."
                }
                return $found
            }
            if ($AllowDuplicateName) { return $null }

            $nameFilter = "isof('microsoft.graph.$ODataType') and displayName eq '$($DisplayName -replace "'", "''")'"
            $existingApps = @()
            $lookupError  = $null
            try {
                $existingApps = @((Invoke-MgGraphRequest -Method GET -Uri (
                    "$graphBase/deviceAppManagement/mobileApps?`$filter=" + [Uri]::EscapeDataString($nameFilter))).value)
            }
            catch {
                if (Test-GraphForbidden $_) { throw (Get-GraphForbiddenMessage -Action "list its apps for '$DisplayName'") }
                $lookupError = $_.Exception.Message
            }

            # A check that cannot be performed is not a check that passed. This used to be a
            # warning, and the run then carried on as though Intune held no app of this name:
            # without -Update that creates the duplicate the check exists to prevent, and with
            # -Update it creates a second app instead of updating the first — so the existing
            # app keeps its assignments and its old content, and no device sees the new version.
            # Graph throttling on a filtered mobileApps query is the ordinary way to get here,
            # and retrying costs nothing. -AllowDuplicateName is the way to say the answer
            # does not matter; it skips this whole check.
            if ($lookupError) {
                throw ("Could not ask Intune whether an app named '$DisplayName' already exists: $lookupError " +
                       'Nothing was created, because the answer decides whether this run creates an app or updates ' +
                       'one. Retry, pass -AppId to name the app to update, or pass -AllowDuplicateName if a second ' +
                       'app of this name is what you want.')
            }
            if ($existingApps.Count -gt 1) {
                $candidates = @($existingApps | ForEach-Object { "$($_.id) (v$($_.displayVersion))" }) -join ', '
                throw ("Intune has $($existingApps.Count) apps named '$DisplayName': $candidates. " +
                       'There is no way to tell which one this package belongs to — pass -AppId to name one, ' +
                       'or give this package a unique display name.')
            }
            if ($existingApps.Count -eq 1) {
                if (-not $Update) {
                    throw ("Intune already has an app named '$DisplayName' (v$($existingApps[0].displayVersion), id $($existingApps[0].id)). " +
                           'Publishing was stopped so you do not create a duplicate. Pass -Update to replace that app''s content with ' +
                           'this package, change the display name (for example add the version), or pass -AllowDuplicateName to create a second app.')
                }
                return $existingApps[0]
            }
            $null
        }

        # --- WinGet packages -------------------------------------------------------------
        # An app.json with a winget block was written by New-WinGetPackage. Before anything is
        # created, the organisation's choice of sources is checked again here — whoever runs
        # this, from the studio or from a pipeline — and the scripts and commands are compared
        # with what New-WinGetPackage would write for that block, because a script changed by
        # hand can install from anywhere whatever the command line says. Where the organisation
        # restricts the sources that is a stop; otherwise it is a warning.
        function Assert-WinGetManifest {
            param($Manifest, [string]$ManifestDir)
            $engine = Join-Path -Path $PSScriptRoot -ChildPath 'New-WinGetPackage.ps1'
            if (-not (Test-Path -LiteralPath $engine)) {
                throw "This is a WinGet package, and New-WinGetPackage.ps1 is needed next to this script to check it: $engine"
            }
            $winget = $Manifest.winget
            $check = & {
                param($EnginePath, $Folder, $WinGetBlock, $InstallCommand, $UninstallCommand)
                . $EnginePath
                $policy = Get-PackwrightPolicy
                $asTable = $WinGetBlock | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
                $commands = if ($asTable['delivery'] -ne 'store') { Get-WinGetCommandLine -WinGet $asTable } else { $null }
                [pscustomobject]@{
                    Refusal    = Get-WinGetSourceRefusal -Source "$($asTable['source'])" -Policy $policy
                    Restricted = [bool]$policy.Restricted
                    PolicyPath = $policy.Path
                    Problems   = @($policy.Problems)
                    Scripts    = @(if ($asTable['delivery'] -ne 'store') { Get-WinGetScriptState -Folder $Folder })
                    Commands   = @(if ($commands) {
                        foreach ($pair in @(@{ Name = 'install'; Expected = $commands.Install; Actual = $InstallCommand },
                                            @{ Name = 'uninstall'; Expected = $commands.Uninstall; Actual = $UninstallCommand })) {
                            if (("$($pair.Actual)" -replace '\s+', ' ').Trim() -ne ($pair.Expected -replace '\s+', ' ').Trim()) { $pair.Name }
                        }
                    })
                }
            } $engine $ManifestDir $winget $Manifest.installCommandLine $Manifest.uninstallCommandLine
            foreach ($problem in $check.Problems) { Write-Warning $problem }
            if ($check.Refusal) { throw "$($check.Refusal) Nothing was created." }
            $findings = @(
                $check.Scripts | Where-Object { $_.State -in 'edited', 'missing' } | ForEach-Object { $_.Detail }
                $check.Commands | ForEach-Object { "The $_ command in app.json is not the one the WinGet settings give (it was edited by hand)." }
            )
            if ($findings -and $check.Restricted) {
                throw (($findings -join ' ') + " Your organisation restricts the WinGet sources ($(Split-Path -Leaf $check.PolicyPath)), " +
                       'so only scripts and commands Packwright wrote are published. Refresh the scripts in Packwright. Nothing was created.')
            }
            foreach ($finding in $findings) { Write-Warning $finding }
            foreach ($old in @($check.Scripts | Where-Object { $_.State -eq 'outdated' })) {
                Write-Warning "$($old.Detail) Refresh the scripts in Packwright to get the current ones."
            }
        }

        # --- Dependencies -----------------------------------------------------------------
        # Resolved before anything is created, so a missing dependency stops the run instead of
        # leaving an app behind that cannot install. Intune counts every app that shares a
        # dependency into one graph of at most 100 apps, the shared one included — which is the
        # ceiling a dependency used by every WinGet app runs into.
        function Resolve-AppDependency {
            param($Manifest)
            @(foreach ($dependency in @($Manifest.dependencies)) {
                if (-not $dependency) { continue }
                $target = $null
                if ($dependency.appId) {
                    try { $target = Invoke-MgGraphRequest -Method GET -Uri "$graphBase/deviceAppManagement/mobileApps/$($dependency.appId)" }
                    catch { throw "The dependency $($dependency.appId) could not be read in Intune: $($_.Exception.Message)" }
                }
                elseif ($dependency.displayName) {
                    $filter = "isof('microsoft.graph.win32LobApp') and displayName eq '$("$($dependency.displayName)" -replace "'", "''")'"
                    try {
                        $found = @((Invoke-MgGraphRequest -Method GET -Uri (
                            "$graphBase/deviceAppManagement/mobileApps?`$filter=" + [Uri]::EscapeDataString($filter))).value)
                    }
                    catch { throw "Could not ask Intune for the dependency '$($dependency.displayName)': $($_.Exception.Message) Nothing was created." }
                    if ($found.Count -eq 0) {
                        throw ("This app depends on '$($dependency.displayName)', and Intune has no Win32 app of that name. " +
                               'Publish it first (for WinGet apps: the WinGet runtime package). Nothing was created.')
                    }
                    if ($found.Count -gt 1) {
                        throw ("Intune has $($found.Count) Win32 apps named '$($dependency.displayName)', so the dependency is ambiguous. " +
                               'Give the dependency an appId in app.json. Nothing was created.')
                    }
                    $target = $found[0]
                }
                else { throw 'A dependency in app.json needs an appId or a displayName.' }
                if ("$($target.'@odata.type')" -ne '#microsoft.graph.win32LobApp') {
                    throw "The dependency $($target.displayName) is $($target.'@odata.type'); Intune only lets a Win32 app depend on Win32 apps."
                }
                $parents = 0
                try {
                    $parents = @((Invoke-MgGraphRequest -Method GET -Uri ("$graphBase/deviceAppManagement/mobileApps/$($target.id)/relationships?`$filter=" +
                                 [Uri]::EscapeDataString("targetType eq 'parent'"))).value).Count
                }
                catch { }
                if ($parents -ge 98) {
                    throw ("$parents apps already depend on '$($target.displayName)'. Intune counts every app that shares a dependency into one graph " +
                           'of at most 100 apps, so this one would not fit. Link the WinGet runtime with a requirement rule instead ' +
                           '(runtimeLink "requirement" in Packwright.policy.json). Nothing was created.')
                }
                [pscustomobject]@{ Id = $target.id; Name = $target.displayName; AutoInstall = ($dependency.autoInstall -ne $false) }
            })
        }

        # updateRelationships replaces every relationship the app has, supersedence included. So
        # what the app already depends on or supersedes is read first and sent back with it.
        function Set-AppDependency {
            param([string]$TargetAppId, [object[]]$Dependencies)
            $existing = @((Invoke-MgGraphRequest -Method GET -Uri "$graphBase/deviceAppManagement/mobileApps/$TargetAppId/relationships").value)
            $relationships = @(
                foreach ($relationship in $existing) {
                    if ("$($relationship.targetType)" -ne 'child') { continue }   # other apps' relationships to this one
                    $type = "$($relationship.'@odata.type')"
                    if ($type -eq '#microsoft.graph.mobileAppDependency' -and $relationship.targetId -in $Dependencies.Id) { continue }
                    $kept = [ordered]@{ '@odata.type' = $type; targetId = $relationship.targetId }
                    if ($relationship.dependencyType)   { $kept.dependencyType = $relationship.dependencyType }
                    if ($relationship.supersedenceType) { $kept.supersedenceType = $relationship.supersedenceType }
                    $kept
                }
                foreach ($dependency in $Dependencies) {
                    [ordered]@{
                        '@odata.type'  = '#microsoft.graph.mobileAppDependency'
                        targetId       = $dependency.Id
                        dependencyType = $(if ($dependency.AutoInstall) { 'autoInstall' } else { 'detect' })
                    }
                }
            )
            Invoke-MgGraphRequest -Method POST -Uri "$graphBase/deviceAppManagement/mobileApps/$TargetAppId/updateRelationships" `
                -Body (@{ relationships = $relationships } | ConvertTo-Json -Depth 6) -ContentType 'application/json' | Out-Null
        }

        # The parts of app.json both app types share
        function Add-CommonAppProperty {
            param($Body, $Manifest, [string]$ManifestDir)
            foreach ($field in 'informationUrl', 'privacyInformationUrl', 'developer', 'owner', 'notes') {
                if ("$($Manifest.$field)".Trim()) { $Body[$field] = "$($Manifest.$field)".Trim() }
            }
            # Scope tags, for an account whose Intune role is limited to some of them: without one
            # of its tags the app is created under Default, which such an account may not touch
            $scopeTags = @($Manifest.roleScopeTagIds | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            if ($scopeTags) {
                $notNumbers = @($scopeTags | Where-Object { $_ -notmatch '^\d+$' })
                if ($notNumbers) { throw "roleScopeTagIds in app.json are the tags' ids, numbers such as ""3"" - not $($notNumbers -join ', ')." }
                $Body.roleScopeTagIds = $scopeTags
            }
            if ($Manifest.icon) {
                $iconPath = $Manifest.icon
                if ($ManifestDir -and -not [IO.Path]::IsPathRooted($iconPath)) {
                    $iconPath = Join-Path -Path $ManifestDir -ChildPath $iconPath
                }
                if (Test-Path -LiteralPath $iconPath) {
                    $mime = if ($iconPath -match '\.jpe?g$') { 'image/jpeg' } else { 'image/png' }
                    $Body.largeIcon = @{
                        '@odata.type' = '#microsoft.graph.mimeContent'
                        type          = $mime
                        value         = [Convert]::ToBase64String([IO.File]::ReadAllBytes($iconPath))
                    }
                }
                else { Write-Warning "Icon not found, skipping: $iconPath" }
            }
        }

        # An Intune Store app: nothing to build or upload. Intune itself installs the app through
        # its own copy of winget — which, unlike winget's command line, still works on devices
        # where the Microsoft Store app is blocked — detects it and keeps it current.
        function Publish-WinGetStoreApp {
            param($Manifest, [string]$ManifestDir)
            $winget = $Manifest.winget
            if ("$($winget.source)" -ne 'msstore' -or -not "$($winget.id)".Trim()) {
                throw "Only a Microsoft Store app can be published as an Intune Store app (app.json has source '$($winget.source)')."
            }
            $displayName = Get-FirstValue $Manifest.displayName $winget.packageName $winget.id
            $publisher = Get-FirstValue $Manifest.publisher 'Unknown'
            $runAs = Get-FirstValue $Manifest.runAsAccount 'system'
            $body = [ordered]@{
                '@odata.type'     = '#microsoft.graph.winGetApp'
                displayName       = $displayName
                description       = (Get-FirstValue $Manifest.description $displayName)
                publisher         = $publisher
                packageIdentifier = "$($winget.id)"
                installExperience = @{ '@odata.type' = '#microsoft.graph.winGetAppInstallExperience'; runAsAccount = $runAs }
            }
            Add-CommonAppProperty -Body $body -Manifest $Manifest -ManifestDir $ManifestDir

            $tenant = (Get-MgContext).TenantId
            $target = Find-PublishTarget -DisplayName $displayName -ODataType 'winGetApp' -TypeLabel 'an Intune Store app'
            if ($target -and "$($target.packageIdentifier)" -and "$($target.packageIdentifier)" -ine "$($winget.id)") {
                throw ("The Intune Store app '$displayName' ($($target.id)) installs $($target.packageIdentifier), not $($winget.id). " +
                       'Intune cannot change that on an existing app — publish this one under another name. Nothing was changed.')
            }
            $action = if ($target) { "Update Intune Store app $($target.id) in tenant $tenant" } else { "Create Intune Store app in tenant $tenant" }
            if (-not $PSCmdlet.ShouldProcess("$displayName ($($winget.id))", $action)) { return }

            if ($target) {
                # Neither the package nor the install context can be changed on an existing app
                $patch = [ordered]@{ '@odata.type' = '#microsoft.graph.winGetApp' }
                foreach ($key in $body.Keys) { if ($key -notin '@odata.type', 'packageIdentifier', 'installExperience') { $patch[$key] = $body[$key] } }
                Invoke-MgGraphRequest -Method PATCH -Uri "$graphBase/deviceAppManagement/mobileApps/$($target.id)" `
                    -Body ($patch | ConvertTo-Json -Depth 10) -ContentType 'application/json' | Out-Null
                $storeAppId = $target.id
                Write-Host "  Done. The Intune Store app '$displayName' was updated; assignments were left as they were." -ForegroundColor Green
            }
            else {
                Write-Host "Creating the Intune Store app '$displayName' ($($winget.id))..."
                $created = $null; $createError = $null
                try {
                    $created = Invoke-MgGraphRequest -Method POST -Uri "$graphBase/deviceAppManagement/mobileApps" `
                                   -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -ErrorAction Stop -ErrorVariable createError
                }
                catch { if (Test-GraphForbidden $_) { throw (Get-GraphForbiddenMessage -Action "create '$displayName'") }; throw }
                $storeAppId = $created.id
                if ([string]::IsNullOrWhiteSpace($storeAppId)) {
                    if (Test-GraphForbidden $createError) { throw (Get-GraphForbiddenMessage -Action "create '$displayName'") }
                    throw "Intune returned no app id for '$displayName' — the app was not created."
                }
                Write-Host ("  Done. '$displayName' is published as an Intune Store app (no assignments yet). Intune takes a few minutes " +
                            'to fetch it from the Store before it can be assigned.') -ForegroundColor Green
            }
            [pscustomobject]@{
                Action         = if ($target) { 'Updated' } else { 'Created' }
                AppId          = $storeAppId
                DisplayName    = $displayName
                Version        = ''
                ContentVersion = ''
                TenantId       = $tenant
                PortalUrl      = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$storeAppId"
                AppType        = 'winGetApp'
            }
        }
    }

    process {
        # .ProviderPath, never .Path — see the note in Build-IntuneWinApp.ps1 on UNC paths
        if ($Path) { $Path = (Resolve-Path -LiteralPath $Path).ProviderPath }

        # --- Locate and read manifest (app.json) ---
        $manifest    = $null
        $manifestDir = $null
        $candidates  = @()
        if ($ManifestPath)  { $candidates += $ManifestPath }
        if ($SourceFolder)  { $candidates += (Join-Path -Path $SourceFolder -ChildPath 'app.json') }
        if ($Path)          { $candidates += (Join-Path -Path (Split-Path -Path $Path -Parent) -ChildPath 'app.json') }
        foreach ($candidate in $candidates) {
            if ($candidate -and (Test-Path -LiteralPath $candidate)) {
                $resolved    = (Resolve-Path -LiteralPath $candidate).ProviderPath
                $manifest    = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
                $manifestDir = Split-Path -Path $resolved -Parent
                Write-Host "Using manifest: $resolved"
                break
            }
        }
        if ($ManifestPath -and -not $manifest) {
            throw "Manifest not found: $ManifestPath"
        }

        # A WinGet package is checked against the organisation's sources first of all, and an
        # Intune Store app has nothing to upload: it is published from app.json alone
        if ($manifest.winget) { Assert-WinGetManifest -Manifest $manifest -ManifestDir $manifestDir }
        if ("$($manifest.winget.delivery)" -eq 'store') {
            if ($Path) {
                throw "app.json describes an Intune Store app, which has no content to upload. Publish it with -ManifestPath alone, without '$Path'."
            }
            return Publish-WinGetStoreApp -Manifest $manifest -ManifestDir $manifestDir
        }
        if (-not $Path) {
            throw 'Path is required: the .intunewin file to publish. Only an app.json for an Intune Store app is published without one.'
        }
        $meta = Get-IntuneWinMetadata -FilePath $Path

        $setupFile = $meta.SetupFile
        $isPsadt   = ($setupFile -ieq 'Invoke-AppDeployToolkit.exe')
        $msiInfo   = $meta.MsiInfo

        # PSADT packages: read AppVendor/AppName/AppVersion from the $adtSession block in
        # Invoke-AppDeployToolkit.ps1 (requires SourceFolder, i.e. piping from the build or
        # passing it explicitly). Empty values in the template are ignored.
        $psadtMeta = @{}
        if ($isPsadt -and $SourceFolder) {
            $deployScript = Join-Path -Path $SourceFolder -ChildPath 'Invoke-AppDeployToolkit.ps1'
            if (Test-Path -LiteralPath $deployScript) {
                $deployContent = Get-Content -LiteralPath $deployScript -Raw
                foreach ($key in 'AppVendor', 'AppName', 'AppVersion') {
                    $pattern = '(?m)^\s*' + $key + '\s*=\s*([''"])(.*?)\1'
                    if ($deployContent -match $pattern -and $Matches[2].Trim()) {
                        $psadtMeta[$key] = $Matches[2].Trim()
                    }
                }
                if ($psadtMeta.Count -gt 0) {
                    Write-Host ("PSADT metadata: " + (($psadtMeta.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)='$($_.Value)'" }) -join ', '))
                }
            }
        }

        # --- Resolve app properties (manifest > PSADT > MSI metadata > defaults) ---
        $displayName = Get-FirstValue $manifest.displayName $psadtMeta.AppName $meta.Name ([IO.Path]::GetFileNameWithoutExtension($Path))
        $publisher   = Get-FirstValue $manifest.publisher $psadtMeta.AppVendor $msiInfo.MsiPublisher
        if (-not $publisher) {
            $publisher = 'Unknown'
            Write-Warning "No publisher found for '$displayName' — using 'Unknown'. Set 'publisher' in app.json or AppVendor in the PSADT script."
        }
        $version     = Get-FirstValue $manifest.version $psadtMeta.AppVersion $msiInfo.MsiProductVersion

        $installCmd = Get-FirstValue $manifest.installCommandLine $(
            if ($isPsadt)      { 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent' }
            elseif ($msiInfo)  { "msiexec /i `"$setupFile`" /qn /norestart" }
        )
        $uninstallCmd = Get-FirstValue $manifest.uninstallCommandLine $(
            if ($isPsadt)      { 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent' }
            elseif ($msiInfo)  { "msiexec /x `"$($msiInfo.MsiProductCode)`" /qn /norestart" }
        )
        if (-not $installCmd -or -not $uninstallCmd) {
            throw "Cannot derive install/uninstall command lines for '$displayName'. Add installCommandLine/uninstallCommandLine to app.json."
        }

        # --- Detection rules ---
        $detection = $manifest.detection
        $detectionRule = $null
        if ($detection) {
            switch ($detection.type) {
                'msi' {
                    $detectionRule = @{
                        '@odata.type'          = '#microsoft.graph.win32LobAppProductCodeDetection'
                        productCode            = (Get-FirstValue $detection.productCode $msiInfo.MsiProductCode)
                        productVersionOperator = 'notConfigured'
                        productVersion         = $null
                    }
                }
                'file' {
                    $detectionRule = @{
                        '@odata.type'        = '#microsoft.graph.win32LobAppFileSystemDetection'
                        path                 = $detection.path
                        fileOrFolderName     = $detection.fileOrFolderName
                        check32BitOn64System = [bool]$detection.check32BitOn64System
                        detectionType        = (Get-FirstValue $detection.detectionType 'exists')
                        operator             = (Get-FirstValue $detection.operator 'notConfigured')
                        detectionValue       = $detection.detectionValue
                    }
                }
                'registry' {
                    $detectionRule = @{
                        '@odata.type'        = '#microsoft.graph.win32LobAppRegistryDetection'
                        keyPath              = $detection.keyPath
                        valueName            = $detection.valueName
                        check32BitOn64System = [bool]$detection.check32BitOn64System
                        detectionType        = (Get-FirstValue $detection.detectionType 'exists')
                        operator             = (Get-FirstValue $detection.operator 'notConfigured')
                        detectionValue       = $detection.detectionValue
                    }
                }
                'script' {
                    $scriptPath = $detection.scriptFile
                    if ($manifestDir -and -not [IO.Path]::IsPathRooted($scriptPath)) {
                        $scriptPath = Join-Path -Path $manifestDir -ChildPath $scriptPath
                    }
                    if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Detection script not found: $scriptPath" }
                    $detectionRule = @{
                        '@odata.type'         = '#microsoft.graph.win32LobAppPowerShellScriptDetection'
                        enforceSignatureCheck = [bool]$detection.enforceSignatureCheck
                        runAs32Bit            = [bool]$detection.runAs32Bit
                        scriptContent         = [Convert]::ToBase64String([IO.File]::ReadAllBytes($scriptPath))
                    }
                }
                default { throw "Unknown detection type '$($detection.type)' in manifest (expected msi/file/registry/script)." }
            }
        }
        elseif ($msiInfo) {
            $detectionRule = @{
                '@odata.type'          = '#microsoft.graph.win32LobAppProductCodeDetection'
                productCode            = $msiInfo.MsiProductCode
                productVersionOperator = 'notConfigured'
                productVersion         = $null
            }
        }
        else {
            throw "No detection rule for '$displayName'. Non-MSI packages need a 'detection' block in app.json (type: file/registry/script) — a registry rule on the app's uninstall key (DisplayVersion, operator greaterThanOrEqual) is usually the most robust for .exe installers."
        }

        # Intune accepts '1607'-style build numbers or 'Windows10_22H2'/'Windows11_22H2';
        # anything else (e.g. bare '22H2') is rejected with 400 Unknown MinimumSupportedWindowsRelease
        $minOsRelease = Get-FirstValue $manifest.minimumWindowsRelease '1607'
        if ($minOsRelease -notmatch '^(\d{4}|Windows1[01]_\d{2}H\d)$') {
            Write-Warning "minimumWindowsRelease '$minOsRelease' looks invalid — Intune expects e.g. '1607', 'Windows10_22H2' or 'Windows11_22H2'. The create call will likely fail."
        }

        # --- Build the win32LobApp body ---
        $appBody = [ordered]@{
            '@odata.type'                  = '#microsoft.graph.win32LobApp'
            displayName                    = $displayName
            description                    = (Get-FirstValue $manifest.description $displayName)
            publisher                      = $publisher
            fileName                       = [IO.Path]::GetFileName($Path)
            setupFilePath                  = $setupFile
            installCommandLine             = $installCmd
            uninstallCommandLine           = $uninstallCmd
            installExperience              = @{
                runAsAccount          = (Get-FirstValue $manifest.runAsAccount 'system')
                deviceRestartBehavior = (Get-FirstValue $manifest.restartBehavior 'suppress')
            }
            allowedArchitectures           = (ConvertTo-AllowedArchitecture (Get-FirstValue $manifest.architecture 'x64'))
            minimumSupportedWindowsRelease = $minOsRelease
            detectionRules                 = @($detectionRule)
            returnCodes                    = @(
                @{ returnCode = 0;    type = 'success' }
                @{ returnCode = 1707; type = 'success' }
                @{ returnCode = 3010; type = 'softReboot' }
                @{ returnCode = 1641; type = 'hardReboot' }
                @{ returnCode = 1618; type = 'retry' }
            )
        }
        if ($version) { $appBody.displayVersion = "$version" }
        Add-CommonAppProperty -Body $appBody -Manifest $manifest -ManifestDir $manifestDir

        # --- Requirement rules ---
        # A device that does not meet them reports the app as not applicable instead of trying
        # to install it. A WinGet package uses one to wait for winget to be ready.
        $requirementRules = @(foreach ($requirement in @($manifest.requirements)) {
            if (-not $requirement) { continue }
            if ("$($requirement.type)" -ne 'script') {
                throw "Unknown requirement type '$($requirement.type)' in manifest (expected script)."
            }
            $scriptPath = "$($requirement.scriptFile)"
            if ($manifestDir -and -not [IO.Path]::IsPathRooted($scriptPath)) {
                $scriptPath = Join-Path -Path $manifestDir -ChildPath $scriptPath
            }
            if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Requirement script not found: $scriptPath" }
            [ordered]@{
                '@odata.type'         = '#microsoft.graph.win32LobAppPowerShellScriptRequirement'
                displayName           = (Get-FirstValue $requirement.displayName ([IO.Path]::GetFileName($scriptPath)))
                enforceSignatureCheck = [bool]$requirement.enforceSignatureCheck
                runAs32Bit            = [bool]$requirement.runAs32Bit
                runAsAccount          = (Get-FirstValue $requirement.runAsAccount 'system')
                scriptContent         = [Convert]::ToBase64String([IO.File]::ReadAllBytes($scriptPath))
                detectionType         = (Get-FirstValue $requirement.detectionType 'boolean')
                operator              = (Get-FirstValue $requirement.operator 'equal')
                detectionValue        = (Get-FirstValue $requirement.detectionValue 'true')
            }
        })
        if ($requirementRules) { $appBody.requirementRules = $requirementRules }

        $tenant = (Get-MgContext).TenantId

        # --- Create or update? -----------------------------------------------------
        # app.json is the desired state. -Update makes running the same spec again
        # idempotent: create the app when it is missing, otherwise add a new content
        # version to the existing app and re-assert its metadata. Without -Update an
        # existing app is left alone and publishing stops, so nobody creates a
        # duplicate by re-running a publish.
        $targetApp = Find-PublishTarget -DisplayName $displayName -ODataType 'win32LobApp' -TypeLabel 'a Win32 app'
        $isUpdate = [bool]$targetApp
        $dependencies = @(Resolve-AppDependency -Manifest $manifest)

        $processAction = if ($isUpdate) {
            "Update Win32 app $($targetApp.id) in tenant $tenant (v$($targetApp.displayVersion) -> v$version, new content version)"
        } else {
            "Create Win32 app in Intune tenant $tenant"
        }
        if (-not $PSCmdlet.ShouldProcess("$displayName ($([IO.Path]::GetFileName($Path)))", $processAction)) {
            return
        }

        # --- 1. Create the app, or take over the existing one ----------------------
        # Not $appId: PowerShell names are case-blind, so that would be the -AppId parameter, and
        # the next package down the pipeline would update this one's app instead of its own
        $publishedAppId = $null
        if ($isUpdate) {
            $publishedAppId = $targetApp.id
            Write-Host "Updating Win32 app '$displayName' ($publishedAppId) — uploading a new content version..."
        }
        else {
            Write-Host "Creating Win32 app '$displayName' in Intune..."
            $app = $null; $createError = $null
            try {
                $app = Invoke-MgGraphRequest -Method POST -Uri "$graphBase/deviceAppManagement/mobileApps" `
                           -Body ($appBody | ConvertTo-Json -Depth 20) -ContentType 'application/json' -ErrorAction Stop -ErrorVariable createError
            }
            catch { if (Test-GraphForbidden $_) { throw (Get-GraphForbiddenMessage -Action "create '$displayName'") }; throw }
            $publishedAppId = $app.id
            # No id means the POST reported an error instead of creating anything; going on
            # would upload content to a nonexistent app and blame the user for the leftovers.
            if ([string]::IsNullOrWhiteSpace($publishedAppId)) {
                if (Test-GraphForbidden $createError) { throw (Get-GraphForbiddenMessage -Action "create '$displayName'") }
                throw "Intune returned no app id for '$displayName' — the app was not created."
            }
            Write-Host "  App created: $publishedAppId"
        }

        $tempPayload = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("IntunePackage_{0}.bin" -f [guid]::NewGuid())
        try {
            # --- 2. Content version + file entry ---
            $cv = Invoke-MgGraphRequest -Method POST -Uri "$graphBase/deviceAppManagement/mobileApps/$publishedAppId/microsoft.graph.win32LobApp/contentVersions" `
                      -Body '{}' -ContentType 'application/json'
            $cvId = $cv.id

            $payload  = Export-IntuneWinPayload -FilePath $Path -Destination $tempPayload
            $fileBody = @{
                '@odata.type' = '#microsoft.graph.mobileAppContentFile'
                name          = [IO.Path]::GetFileName($Path)
                size          = [int64]$meta.UnencryptedContentSize
                sizeEncrypted = [int64]$payload.Length
                manifest      = $null
                isDependency  = $false
            }
            $contentFile = Invoke-MgGraphRequest -Method POST -Uri "$graphBase/deviceAppManagement/mobileApps/$publishedAppId/microsoft.graph.win32LobApp/contentVersions/$cvId/files" `
                               -Body ($fileBody | ConvertTo-Json) -ContentType 'application/json'
            $fileUri = "$graphBase/deviceAppManagement/mobileApps/$publishedAppId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$($contentFile.id)"

            # --- 3. Upload payload to Azure Storage ---
            $contentFile = Wait-IntuneFileState -Uri $fileUri -State 'azureStorageUriRequestSuccess'
            Write-Host ("  Uploading content ({0:N1} MB)..." -f ($payload.Length / 1MB))
            Send-IntuneAzureBlob -FilePath $tempPayload -SasUri $contentFile.azureStorageUri -FileUri $fileUri

            # --- 4. Commit with encryption info from the package ---
            $enc = $meta.EncryptionInfo
            $commitBody = @{
                fileEncryptionInfo = @{
                    encryptionKey        = $enc.EncryptionKey
                    macKey               = $enc.MacKey
                    initializationVector = $enc.InitializationVector
                    mac                  = $enc.Mac
                    profileIdentifier    = $enc.ProfileIdentifier
                    fileDigest           = $enc.FileDigest
                    fileDigestAlgorithm  = $enc.FileDigestAlgorithm
                }
            }
            Invoke-MgGraphRequest -Method POST -Uri "$fileUri/commit" -Body ($commitBody | ConvertTo-Json -Depth 5) -ContentType 'application/json' | Out-Null
            Wait-IntuneFileState -Uri $fileUri -State 'commitFileSuccess' | Out-Null

            # --- 5. Point the app at the new content ----------------------------
            # On an update the whole desired state rides along, so app.json stays the
            # source of truth for metadata too. largeIcon is only part of the body when
            # the manifest names an icon, so an existing icon is never wiped by accident,
            # and assignments are not touched at all.
            $patchBody = [ordered]@{}
            if ($isUpdate) { foreach ($key in $appBody.Keys) { $patchBody[$key] = $appBody[$key] } }
            else           { $patchBody['@odata.type'] = '#microsoft.graph.win32LobApp' }
            $patchBody.committedContentVersion = "$cvId"
            Invoke-MgGraphRequest -Method PATCH -Uri "$graphBase/deviceAppManagement/mobileApps/$publishedAppId" `
                -Body ($patchBody | ConvertTo-Json -Depth 20) -ContentType 'application/json' | Out-Null

            # Last, once the app is complete: a dependency that cannot be set leaves a working
            # app that installs once its dependency is there, not a half-made one
            if ($dependencies) {
                try {
                    Set-AppDependency -TargetAppId $publishedAppId -Dependencies $dependencies
                    Write-Host ("  Depends on: " + (($dependencies | ForEach-Object { $_.Name }) -join ', '))
                }
                catch {
                    Write-Warning ("'$displayName' is published, but its dependency on $(($dependencies | ForEach-Object { $_.Name }) -join ', ') " +
                                   "could not be set: $($_.Exception.Message) Set it in the portal, or publish again with -Update.")
                }
            }

            Write-Host $(if ($isUpdate) {
                "  Done. '$displayName' now runs content version $cvId; assignments were left as they were."
            } else {
                "  Done. '$displayName' is published (no assignments yet)."
            }) -ForegroundColor Green

            [pscustomobject]@{
                Action         = if ($isUpdate) { 'Updated' } else { 'Created' }
                AppId          = $publishedAppId
                DisplayName    = $displayName
                Version        = $version
                ContentVersion = "$cvId"
                TenantId       = $tenant
                PortalUrl      = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$publishedAppId"
            }
        }
        catch {
            if ($isUpdate) {
                # The app is only switched over in the final PATCH, so a failure here leaves
                # it serving the previous content version — retrying is safe.
                Write-Warning "App '$displayName' ($publishedAppId) still runs its previous content version; nothing was changed over. Safe to retry."
            }
            elseif ($publishedAppId) {
                # Only send anyone hunting through the portal when there is really something there.
                Write-Warning "App '$displayName' ($publishedAppId) was created but content upload did not complete — delete it in the portal before retrying."
            }
            if (Test-GraphForbidden $_) { throw (Get-GraphForbiddenMessage -Action "change '$displayName'") }
            throw
        }
        finally {
            if (Test-Path -LiteralPath $tempPayload) { Remove-Item -LiteralPath $tempPayload -Force -ErrorAction SilentlyContinue }
        }
    }
}

# Run directly when invoked with -Path (or -ManifestPath alone, for an Intune Store app);
# dot-source the file to only load the function.
if ($PSBoundParameters.ContainsKey('Path') -or $PSBoundParameters.ContainsKey('ManifestPath')) {
    Publish-IntuneWinApp @PSBoundParameters
}
