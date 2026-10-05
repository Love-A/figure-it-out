#Requires -Version 7.0

<#
.SYNOPSIS
    Validates Assigned Access configuration XML against Microsoft's official XSD and the
    documented rules the XSD can't express.

.DESCRIPTION
    Checks AssignedAccessConfiguration XML - the value of the Intune OMA-URI
    ./Vendor/MSFT/AssignedAccess/Configuration - in two passes:

      1. Schema: validated against Microsoft's published XSDs in .\schema (namespaces 2017,
         201810, 2020, 202010, 2021 and 2022). Schema warnings, such as an element in an
         unknown namespace, count as errors.
      2. Rules: documented constraints the XSD doesn't enforce. Every DefaultProfile and
         GlobalProfile must point at an existing Profile; at most one KioskModeApp profile;
         a KioskModeApp profile can't be assigned to a UserGroup (special groups such as the
         HoloLens Visitor are allowed); at least one assignment; at most one AutoLogonAccount;
         StartPins must be JSON with a pinnedList.

    Prints a readable summary per input and exits 1 when any input fails, so it can gate a
    pipeline. -PassThru also emits one result object per input. MinimumWindows is the lowest
    release per Microsoft's XSD reference for the newest namespace used - the sources don't
    always agree (Edge single-app kiosks are also documented on Windows 10), so treat it as a
    guide, not a guarantee.

    -SelfTestBundle runs the regression bundle exported from AssignedAccess-Generator.html#selftest
    and compares each case with its expected outcome. Run it after changing the generator.

.PARAMETER Path
    One or more XML files. Accepts pipeline input, e.g. from Get-ChildItem.

.PARAMETER Xml
    XML content as a string instead of a file.

.PARAMETER SelfTestBundle
    Path to selftest-bundle.json, downloaded from the generator's self-test page
    (AssignedAccess-Generator.html#selftest).

.PARAMETER SchemaPath
    Folder with the XSD files. Default: the schema folder next to this script.

.PARAMETER PassThru
    Also emit the result objects to the pipeline.

.EXAMPLE
    .\Test-AssignedAccessXml.ps1 -Path .\AssignedAccess-Lobby-kiosk.xml

.EXAMPLE
    Get-ChildItem .\*.xml | .\Test-AssignedAccessXml.ps1 -PassThru | Where-Object { -not $_.Valid }

.EXAMPLE
    .\Test-AssignedAccessXml.ps1 -SelfTestBundle "$HOME\Downloads\selftest-bundle.json"

.NOTES
    FileName   : Test-AssignedAccessXml.ps1
    Author     : Love A
    Created    : 2026-10-05
    Changelog
        - v1.0: initial implementation - XSD + rule validation, generator self-test bundle
#>

[CmdletBinding(DefaultParameterSetName = 'Path')]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path', ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('FullName')]
    [string[]]$Path,

    [Parameter(Mandatory, ParameterSetName = 'Xml')]
    [string]$Xml,

    [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
    [string]$SelfTestBundle,

    [string]$SchemaPath = (Join-Path $PSScriptRoot 'schema'),

    [switch]$PassThru
)

begin {
    $ErrorActionPreference = 'Stop'

    $Ns = [ordered]@{
        d       = 'http://schemas.microsoft.com/AssignedAccess/2017/config'
        rs5     = 'http://schemas.microsoft.com/AssignedAccess/201810/config'
        v3      = 'http://schemas.microsoft.com/AssignedAccess/2020/config'
        v202010 = 'http://schemas.microsoft.com/AssignedAccess/202010/config'
        v4      = 'http://schemas.microsoft.com/AssignedAccess/2021/config'
        v5      = 'http://schemas.microsoft.com/AssignedAccess/2022/config'
    }
    # Lowest Windows release per namespace, as headed on Microsoft's XSD reference page.
    $NsMinimum = [ordered]@{
        v5      = 'Windows 11 22H2'
        v4      = 'Windows 11 21H2'
        v3      = 'Windows 10 1909'
        v202010 = 'Windows 10 1909'
        rs5     = 'Windows 10 1809'
    }

    function Get-AssignedAccessSchemaSet {
        param([Parameter(Mandatory)][string]$Folder)
        $files = @(Get-ChildItem -LiteralPath $Folder -Filter '*.xsd' -File -ErrorAction SilentlyContinue)
        if (-not $files) { throw "No .xsd files found in '$Folder'." }
        $set = [System.Xml.Schema.XmlSchemaSet]::new()
        $set.XmlResolver = $null
        foreach ($file in $files) {
            $readerSettings = [System.Xml.XmlReaderSettings]::new()
            $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
            $readerSettings.XmlResolver = $null
            $reader = [System.Xml.XmlReader]::Create($file.FullName, $readerSettings)
            try { [void]$set.Add([System.Xml.Schema.XmlSchema]::Read($reader, $null)) }
            finally { $reader.Dispose() }
        }
        $set.Compile()
        $set
    }

    function Test-AssignedAccessContent {
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
            [Parameter(Mandatory)][string]$Source,
            [Parameter(Mandatory)][System.Xml.Schema.XmlSchemaSet]$SchemaSet
        )
        $schemaErrors = [System.Collections.Generic.List[string]]::new()
        $ruleErrors   = [System.Collections.Generic.List[string]]::new()
        $warnings     = [System.Collections.Generic.List[string]]::new()

        # --- Pass 1: schema ---------------------------------------------------------------
        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.ValidationType = [System.Xml.ValidationType]::Schema
        $settings.Schemas = $SchemaSet
        $settings.ValidationFlags = $settings.ValidationFlags -bor [System.Xml.Schema.XmlSchemaValidationFlags]::ReportValidationWarnings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $settings.add_ValidationEventHandler({
            param($validatingReader, $evt)
            $where = if ($evt.Exception.LineNumber) { "line $($evt.Exception.LineNumber), pos $($evt.Exception.LinePosition): " } else { '' }
            $prefix = if ($evt.Severity -eq [System.Xml.Schema.XmlSeverityType]::Warning) { 'warning: ' } else { '' }
            $schemaErrors.Add("$prefix$where$($evt.Message)")
        }.GetNewClosure())

        $doc = [System.Xml.XmlDocument]::new()
        $doc.XmlResolver = $null
        $loaded = $false
        $reader = $null
        try {
            $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Content.TrimStart([char]0xFEFF)), $settings)
            $doc.Load($reader)
            $loaded = $true
        } catch [System.Xml.XmlException] {
            $schemaErrors.Add("Not well-formed XML: $($_.Exception.Message)")
        } finally {
            if ($reader) { $reader.Dispose() }
        }

        # --- Pass 2: documented rules the XSD can't express --------------------------------
        $minimum = $null
        if ($loaded) {
            $nsm = [System.Xml.XmlNamespaceManager]::new($doc.NameTable)
            foreach ($key in $Ns.Keys) { $nsm.AddNamespace($key, $Ns[$key]) }
            $root = $doc.DocumentElement

            if ($root.LocalName -ne 'AssignedAccessConfiguration' -or $root.NamespaceURI -ne $Ns.d) {
                $ruleErrors.Add("Root element must be AssignedAccessConfiguration in namespace $($Ns.d).")
            } else {
                $isKiosk = @{}   # PROFILE-ID (upper) -> $true when the profile is a KioskModeApp profile
                foreach ($profileNode in $doc.SelectNodes('/d:AssignedAccessConfiguration/d:Profiles/d:Profile', $nsm)) {
                    $isKiosk[$profileNode.GetAttribute('Id').ToUpperInvariant()] = [bool]$profileNode.SelectSingleNode('d:KioskModeApp', $nsm)
                }
                $kioskCount = @($isKiosk.Values | Where-Object { $_ }).Count
                if ($kioskCount -gt 1) { $ruleErrors.Add("$kioskCount profiles use KioskModeApp; a configuration can contain only one.") }

                $referenced = @{}
                $configs = @($doc.SelectNodes('/d:AssignedAccessConfiguration/d:Configs/d:Config', $nsm))
                $global  = $doc.SelectSingleNode('/d:AssignedAccessConfiguration/d:Configs/v3:GlobalProfile', $nsm)
                if (-not $configs.Count -and -not $global) {
                    $ruleErrors.Add('No Config or GlobalProfile - the profiles are not assigned to anyone.')
                }

                $index = 0
                foreach ($config in $configs) {
                    $index++
                    $default = $config.SelectSingleNode('d:DefaultProfile', $nsm)
                    if (-not $default) { continue }   # the schema pass already reports it
                    $ref = $default.GetAttribute('Id')
                    $key = $ref.ToUpperInvariant()
                    $referenced[$key] = $true
                    if (-not $isKiosk.ContainsKey($key)) {
                        $ruleErrors.Add("Config #${index}: DefaultProfile $ref does not match any Profile Id.")
                    } elseif ($isKiosk[$key] -and $config.SelectSingleNode('d:UserGroup', $nsm)) {
                        # SpecialGroup is deliberately not included: Microsoft's HoloLens docs use Visitor for kiosks.
                        $ruleErrors.Add("Config #${index}: $ref is a KioskModeApp profile, which can't be assigned to a UserGroup - only to user accounts.")
                    }
                }

                if ($global) {
                    $globalId = $global.GetAttribute('Id')
                    $key = $globalId.ToUpperInvariant()
                    $referenced[$key] = $true
                    if (-not $isKiosk.ContainsKey($key)) {
                        $ruleErrors.Add("GlobalProfile $globalId does not match any Profile Id.")
                    } elseif ($isKiosk[$key]) {
                        $warnings.Add('GlobalProfile points at a KioskModeApp profile; Microsoft only documents global profiles with multi-app profiles, and KioskModeApp profiles as assignable to user accounts.')
                    }
                }

                $autoLogons = $doc.SelectNodes('/d:AssignedAccessConfiguration/d:Configs/d:Config/d:AutoLogonAccount', $nsm).Count
                if ($autoLogons -gt 1) { $ruleErrors.Add("$autoLogons AutoLogonAccount entries; only one is allowed.") }

                foreach ($id in $isKiosk.Keys) {
                    if (-not $referenced.ContainsKey($id)) { $warnings.Add("Profile $id is not assigned by any Config or GlobalProfile.") }
                }

                foreach ($pins in $doc.SelectNodes('//v5:StartPins', $nsm)) {
                    try {
                        $json = $pins.InnerText | ConvertFrom-Json -ErrorAction Stop
                        if ($null -eq $json -or $json.PSObject.Properties.Name -notcontains 'pinnedList') {
                            $ruleErrors.Add('StartPins JSON has no "pinnedList" array.')
                        }
                    } catch {
                        $ruleErrors.Add("StartPins is not valid JSON: $($_.Exception.Message)")
                    }
                }

                foreach ($group in $doc.SelectNodes('//d:UserGroup[@Type="AzureActiveDirectoryGroup"]', $nsm)) {
                    if ($group.GetAttribute('Name') -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                        $warnings.Add("Entra group '$($group.GetAttribute('Name'))' should be the group's object ID (a GUID).")
                    }
                }
            }

            foreach ($key in $NsMinimum.Keys) {
                $uri = $Ns[$key]
                if ($doc.SelectSingleNode("//*[namespace-uri()='$uri'] | //@*[namespace-uri()='$uri']")) { $minimum = $NsMinimum[$key]; break }
            }
            if (-not $minimum) {
                $minimum = if ($doc.SelectSingleNode('//d:KioskModeApp', $nsm)) { 'Windows 10 1803' } else { 'Windows 10 1709' }
            }
        }

        [pscustomobject]@{
            Source         = $Source
            Valid          = ($schemaErrors.Count -eq 0 -and $ruleErrors.Count -eq 0)
            SchemaErrors   = $schemaErrors.ToArray()
            RuleErrors     = $ruleErrors.ToArray()
            Warnings       = $warnings.ToArray()
            MinimumWindows = $minimum
        }
    }

    function Write-Result {
        param([Parameter(Mandatory)]$Result)
        if ($Result.Valid) {
            $min = if ($Result.MinimumWindows) { " - schema level $($Result.MinimumWindows)+ (per Microsoft's XSD reference)" } else { '' }
            Write-Host "[PASS] $($Result.Source)$min" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] $($Result.Source) - $($Result.SchemaErrors.Count) schema error(s), $($Result.RuleErrors.Count) rule error(s)" -ForegroundColor Red
        }
        foreach ($m in $Result.SchemaErrors) { Write-Host "       schema: $m" -ForegroundColor Red }
        foreach ($m in $Result.RuleErrors)   { Write-Host "       rule:   $m" -ForegroundColor Red }
        foreach ($m in $Result.Warnings)     { Write-Host "       warn:   $m" -ForegroundColor Yellow }
    }

    $schemaSet = Get-AssignedAccessSchemaSet -Folder $SchemaPath
    $failed = 0
}

process {
    switch ($PSCmdlet.ParameterSetName) {
        'Path' {
            foreach ($item in $Path) {
                # Literal first, so a name with [brackets] isn't read as a wildcard pattern.
                $files = if (Test-Path -LiteralPath $item -PathType Leaf) { @(Resolve-Path -LiteralPath $item) }
                         else { @(Resolve-Path -Path $item -ErrorAction SilentlyContinue) }
                if (-not $files) { Write-Host "[FAIL] $item - file not found" -ForegroundColor Red; $failed++; continue }
                foreach ($file in $files) {
                    $result = Test-AssignedAccessContent -Content ([System.IO.File]::ReadAllText($file.ProviderPath)) -Source (Split-Path $file.ProviderPath -Leaf) -SchemaSet $schemaSet
                    Write-Result $result
                    if (-not $result.Valid) { $failed++ }
                    if ($PassThru) { $result }
                }
            }
        }
        'Xml' {
            $result = Test-AssignedAccessContent -Content $Xml -Source '<string>' -SchemaSet $schemaSet
            Write-Result $result
            if (-not $result.Valid) { $failed++ }
            if ($PassThru) { $result }
        }
        'SelfTest' {
            $bundle = Get-Content -LiteralPath $SelfTestBundle -Raw -Encoding utf8 | ConvertFrom-Json
            if (-not $bundle.cases) { throw "'$SelfTestBundle' contains no cases - is it a generator self-test bundle?" }
            Write-Host "Generator self-test bundle: $($bundle.cases.Count) cases (generator $($bundle.generator), created $($bundle.created))" -ForegroundColor Cyan
            foreach ($case in $bundle.cases) {
                $result = Test-AssignedAccessContent -Content $case.xml -Source $case.name -SchemaSet $schemaSet
                $schemaValid = ($result.SchemaErrors.Count -eq 0)
                $hasRuleErrors = ($result.RuleErrors.Count -gt 0)
                $problems = @()
                if ($schemaValid -ne [bool]$case.expect.schemaValid) { $problems += "schema valid=$schemaValid, expected $([bool]$case.expect.schemaValid)" }
                if ($hasRuleErrors -ne [bool]$case.expect.ruleErrors) { $problems += "rule errors=$hasRuleErrors, expected $([bool]$case.expect.ruleErrors)" }
                if (-not $case.js.pass) { $problems += "generator-side check failed: $($case.js.detail)" }
                if ($problems) {
                    $failed++
                    Write-Host "[FAIL] $($case.name) - $($problems -join '; ')" -ForegroundColor Red
                    foreach ($m in $result.SchemaErrors + $result.RuleErrors) { Write-Host "       $m" -ForegroundColor DarkGray }
                } else {
                    Write-Host "[PASS] $($case.name)" -ForegroundColor Green
                }
                if ($PassThru) { $result | Add-Member -NotePropertyName Expected -NotePropertyValue $case.expect -PassThru }
            }
        }
    }
}

end {
    if ($failed) {
        Write-Host "$failed input(s) failed." -ForegroundColor Red
        exit 1
    }
}
