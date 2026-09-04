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
    2026-09-04 - 1.5 - Stop the run when sign-in fails instead of carrying on unauthenticated
                       and reporting an app that was never created; -SignIn picks how the
                       delegated prompt is shown (Browser for hosts with no console window);
                       one sentence instead of a pile of errors on Windows PowerShell 5.1,
                       and saved UTF-8 with BOM so 5.1 can read that far; the .intunewin and
                       app.json paths resolve through .ProviderPath so a UNC path stays a
                       plain filesystem path; a missing Microsoft.Graph.Authentication is
                       reported with the module path that was searched, since the usual
                       cause is an install that landed somewhere this process cannot see
    2026-09-03 - 1.4 - Idempotent publishing: -Update creates the app when missing and
                       otherwise adds a new content version to the existing app and
                       re-asserts its metadata; -AppId targets one app directly;
                       several apps sharing a name are reported instead of guessed at;
                       the result object carries Action and ContentVersion
    2026-09-03 - 1.3 - Refuse to create a second app with the same display name unless
                       -AllowDuplicateName is given (checked before anything is created)
    2026-07-06 - 1.2 - PSADT metadata: displayName/publisher/version auto-read from the
                       $adtSession block (AppVendor/AppName/AppVersion) for PSADT packages
    2026-07-06 - 1.1 - App-only auth via Entra app registration ('.secret' pattern: certificate
                       thumbprint or client secret), delegated sign-in kept as fallback
    2026-07-06 - 1.0 - Initial version (create win32LobApp, chunked content upload, commit)
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
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)]
        [Alias('IntuneWinFile', 'FullName')]
        [ValidateNotNullOrEmpty()]
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
            Write-Host "No app credentials found ('.secret' missing) - signing in as you (-SignIn $SignIn). Finish the prompt to continue." -ForegroundColor Yellow
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
        if (-not (Get-MgContext)) {
            throw ('Not connected to Microsoft Graph. Run "Connect-MgGraph -Scopes DeviceManagementApps.ReadWrite.All" ' +
                   'in this session, retry with -SignIn Browser, or set up app-only auth in ''.secret''.')
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        # --- helpers -------------------------------------------------------------

        function Get-FirstValue {
            foreach ($v in $args) { if ($null -ne $v -and "$v" -ne '') { return $v } }
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
                    Invoke-WebRequest -Method Put -Uri $uri -Body $body -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -UseBasicParsing | Out-Null
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
                Invoke-WebRequest -Method Put -Uri "$SasUri&comp=blocklist" -Body $blockList -UseBasicParsing | Out-Null
                Write-Progress -Activity 'Uploading content to Intune' -Completed
            }
            finally { $stream.Dispose() }
        }
    }

    process {
        # .ProviderPath, never .Path — see the note in Build-IntuneWinApp.ps1 on UNC paths
        $Path = (Resolve-Path -LiteralPath $Path).ProviderPath
        $meta = Get-IntuneWinMetadata -FilePath $Path

        # --- Locate and read manifest (app.json) ---
        $manifest    = $null
        $manifestDir = $null
        $candidates  = @()
        if ($ManifestPath)  { $candidates += $ManifestPath }
        if ($SourceFolder)  { $candidates += (Join-Path -Path $SourceFolder -ChildPath 'app.json') }
        $candidates += (Join-Path -Path (Split-Path -Path $Path -Parent) -ChildPath 'app.json')
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
            applicableArchitectures        = (Get-FirstValue $manifest.architecture 'x64')
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
        if ($version)                 { $appBody.displayVersion = "$version" }
        if ($manifest.owner)          { $appBody.owner = $manifest.owner }
        if ($manifest.notes)          { $appBody.notes = $manifest.notes }
        if ($manifest.informationUrl) { $appBody.informationUrl = $manifest.informationUrl }
        if ($manifest.icon) {
            $iconPath = $manifest.icon
            if ($manifestDir -and -not [IO.Path]::IsPathRooted($iconPath)) {
                $iconPath = Join-Path -Path $manifestDir -ChildPath $iconPath
            }
            if (Test-Path -LiteralPath $iconPath) {
                $mime = if ($iconPath -match '\.jpe?g$') { 'image/jpeg' } else { 'image/png' }
                $appBody.largeIcon = @{
                    '@odata.type' = '#microsoft.graph.mimeContent'
                    type          = $mime
                    value         = [Convert]::ToBase64String([IO.File]::ReadAllBytes($iconPath))
                }
            }
            else { Write-Warning "Icon not found, skipping: $iconPath" }
        }

        $tenant = (Get-MgContext).TenantId

        # --- Create or update? -----------------------------------------------------
        # app.json is the desired state. -Update makes running the same spec again
        # idempotent: create the app when it is missing, otherwise add a new content
        # version to the existing app and re-assert its metadata. Without -Update an
        # existing app is left alone and publishing stops, so nobody creates a
        # duplicate by re-running a publish.
        if ($Update -and $AllowDuplicateName) {
            throw '-Update and -AllowDuplicateName contradict each other: one replaces the app that is already there, the other creates a second one. Pick one.'
        }

        $targetApp = $null
        if ($AppId) {
            try { $targetApp = Invoke-MgGraphRequest -Method GET -Uri "$graphBase/deviceAppManagement/mobileApps/$AppId" }
            catch { throw "No app with id '$AppId' could be read in Intune: $($_.Exception.Message)" }
            if ("$($targetApp.'@odata.type')" -ne '#microsoft.graph.win32LobApp') {
                throw "App '$AppId' is $($targetApp.'@odata.type'), not a Win32 app — refusing to touch it."
            }
        }
        elseif (-not $AllowDuplicateName) {
            $nameFilter = "isof('microsoft.graph.win32LobApp') and displayName eq '$($displayName -replace "'", "''")'"
            $existingApps = @()
            try {
                $existingApps = @((Invoke-MgGraphRequest -Method GET -Uri (
                    "$graphBase/deviceAppManagement/mobileApps?`$filter=" + [Uri]::EscapeDataString($nameFilter))).value)
            }
            catch { Write-Warning "Could not check Intune for an existing app named '$displayName': $($_.Exception.Message)" }

            if ($existingApps.Count -gt 1) {
                $candidates = @($existingApps | ForEach-Object { "$($_.id) (v$($_.displayVersion))" }) -join ', '
                throw ("Intune has $($existingApps.Count) apps named '$displayName': $candidates. " +
                       'There is no way to tell which one this package belongs to — pass -AppId to name one, ' +
                       'or give this package a unique display name.')
            }
            if ($existingApps.Count -eq 1) {
                if (-not $Update) {
                    throw ("Intune already has an app named '$displayName' (v$($existingApps[0].displayVersion), id $($existingApps[0].id)). " +
                           'Publishing was stopped so you do not create a duplicate. Pass -Update to replace that app''s content with ' +
                           'this package, change the display name (for example add the version), or pass -AllowDuplicateName to create a second app.')
                }
                $targetApp = $existingApps[0]
            }
        }
        $isUpdate = [bool]$targetApp

        $processAction = if ($isUpdate) {
            "Update Win32 app $($targetApp.id) in tenant $tenant (v$($targetApp.displayVersion) -> v$version, new content version)"
        } else {
            "Create Win32 app in Intune tenant $tenant"
        }
        if (-not $PSCmdlet.ShouldProcess("$displayName ($([IO.Path]::GetFileName($Path)))", $processAction)) {
            return
        }

        # --- 1. Create the app, or take over the existing one ----------------------
        if ($isUpdate) {
            $appId = $targetApp.id
            Write-Host "Updating Win32 app '$displayName' ($appId) — uploading a new content version..."
        }
        else {
            Write-Host "Creating Win32 app '$displayName' in Intune..."
            $app = Invoke-MgGraphRequest -Method POST -Uri "$graphBase/deviceAppManagement/mobileApps" `
                       -Body ($appBody | ConvertTo-Json -Depth 20) -ContentType 'application/json' -ErrorAction Stop
            $appId = $app.id
            # No id means the POST reported an error instead of creating anything; going on
            # would upload content to a nonexistent app and blame the user for the leftovers.
            if ([string]::IsNullOrWhiteSpace($appId)) {
                throw "Intune returned no app id for '$displayName' — the app was not created."
            }
            Write-Host "  App created: $appId"
        }

        $tempPayload = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("IntunePackage_{0}.bin" -f [guid]::NewGuid())
        try {
            # --- 2. Content version + file entry ---
            $cv = Invoke-MgGraphRequest -Method POST -Uri "$graphBase/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions" `
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
            $contentFile = Invoke-MgGraphRequest -Method POST -Uri "$graphBase/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$cvId/files" `
                               -Body ($fileBody | ConvertTo-Json) -ContentType 'application/json'
            $fileUri = "$graphBase/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$($contentFile.id)"

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
            Invoke-MgGraphRequest -Method PATCH -Uri "$graphBase/deviceAppManagement/mobileApps/$appId" `
                -Body ($patchBody | ConvertTo-Json -Depth 20) -ContentType 'application/json' | Out-Null

            Write-Host $(if ($isUpdate) {
                "  Done. '$displayName' now runs content version $cvId; assignments were left as they were."
            } else {
                "  Done. '$displayName' is published (no assignments yet)."
            }) -ForegroundColor Green

            [pscustomobject]@{
                Action         = if ($isUpdate) { 'Updated' } else { 'Created' }
                AppId          = $appId
                DisplayName    = $displayName
                Version        = $version
                ContentVersion = "$cvId"
                TenantId       = $tenant
                PortalUrl      = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$appId"
            }
        }
        catch {
            if ($isUpdate) {
                # The app is only switched over in the final PATCH, so a failure here leaves
                # it serving the previous content version — retrying is safe.
                Write-Warning "App '$displayName' ($appId) still runs its previous content version; nothing was changed over. Safe to retry."
            }
            elseif ($appId) {
                # Only send anyone hunting through the portal when there is really something there.
                Write-Warning "App '$displayName' ($appId) was created but content upload did not complete — delete it in the portal before retrying."
            }
            throw
        }
        finally {
            if (Test-Path -LiteralPath $tempPayload) { Remove-Item -LiteralPath $tempPayload -Force -ErrorAction SilentlyContinue }
        }
    }
}

# Run directly when invoked with -Path; dot-source the file to only load the function.
if ($PSBoundParameters.ContainsKey('Path')) {
    Publish-IntuneWinApp @PSBoundParameters
}
