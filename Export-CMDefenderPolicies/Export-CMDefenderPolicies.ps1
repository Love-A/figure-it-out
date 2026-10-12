#Requires -Version 5.1
<#
.SYNOPSIS
    Exports every Microsoft Defender antimalware policy from Configuration Manager, with the
    exclusions laid out for porting to Group Policy.

.DESCRIPTION
    Reads all antimalware policies (Assets and Compliance > Endpoint Protection > Antimalware
    Policies), exports each one with Export-CMAntimalwarePolicy and turns the result into:

      Report.html       The readable deliverable. Overview of every policy, an exclusion
                        matrix (which exclusion lives in which policy) and, per policy, the
                        exclusions grouped per GPO setting plus every other setting
                        translated into the GPO setting it corresponds to.
      Exclusions.csv    One row per policy and exclusion, with GPO setting and registry key.
      AllSettings.csv   Every registry value every policy sets, mapped to its GPO setting.
      ConfigMgr-XML\    The untouched ConfigMgr exports. Re-importable with
                        Import-CMAntimalwarePolicy, so they double as a backup.

    WHY THE EXPORT AND NOT WMI
    SMS_AntimalwareSettings keeps the settings as lazy, embedded SMS_ClientAgentConfig
    objects, and Get-CMAntimalwarePolicy only surfaces exclusions for the default policy.
    The export is the format the client itself consumes: registry keys and values under
    SOFTWARE\Policies\Microsoft\Microsoft Antimalware. Defender's own ADMX uses the same
    value names under ...\Windows Defender, which is what makes an exact GPO mapping possible.

    GPO MAPPING
    Every value is looked up in WindowsDefender.admx/.adml - by default the domain's central
    store, falling back to C:\Windows\PolicyDefinitions - and translated into the setting
    path and state you pick in the Group Policy editor. Values without an ADMX counterpart
    (ConfigMgr/SCEP specific) are flagged in the report, never silently dropped.

    Read-only against ConfigMgr. Nothing in the site is changed.

.PARAMETER SiteCode
    Configuration Manager site code. Optional when exactly one ConfigMgr site drive already
    exists in the session - the script then uses that one.

.PARAMETER ProviderMachineName
    SMS Provider to connect to. Only needed when no site drive for -SiteCode exists yet.

.PARAMETER Name
    Only export policies whose name matches one of these patterns (wildcards allowed).
    Default: all policies.

.PARAMETER XmlPath
    Offline mode: build the report from already exported policy XML files - the console's
    right-click > Export, or the ConfigMgr-XML folder from an earlier run. Files or folders.
    No ConfigMgr connection is made, so order and deployments are unknown in this mode.

.PARAMETER OutputPath
    Folder for the result. Default: DefenderPolicyExport-<yyyyMMdd-HHmm> in the current
    file system location.

.PARAMETER AdmxPath
    Folder holding WindowsDefender.admx and <culture>\WindowsDefender.adml. Default: the
    domain central store when it has the file, otherwise C:\Windows\PolicyDefinitions.
    Point it at the central store you edit GPOs against to map against exactly what GPMC shows.

.PARAMETER Language
    Language of the report and CSV headers: 'en' (default) or 'sv'. GPO setting names and
    states (Enabled/Disabled) stay in English, as the Group Policy editor shows them.

.PARAMETER CsvDelimiter
    Field separator for the CSV files. Default: the list separator of the current culture,
    which is what Excel on the same machine expects (';' for most European cultures).

.EXAMPLE
    .\Export-CMDefenderPolicies.ps1

    Uses the ConfigMgr site drive already present in the session and exports every policy.

.EXAMPLE
    .\Export-CMDefenderPolicies.ps1 -SiteCode PS1 -ProviderMachineName cm01.contoso.com -Language sv

.EXAMPLE
    .\Export-CMDefenderPolicies.ps1 -Name 'Server*', 'SQL*' -OutputPath C:\Temp\Defender

.EXAMPLE
    .\Export-CMDefenderPolicies.ps1 -XmlPath C:\Temp\Defender\ConfigMgr-XML -OutputPath C:\Temp\Defender-v2

    Rebuilds the report offline from earlier exports, e.g. after updating the central store.

.NOTES
    Version : 1.0.0
    Author  : Love A
    License : MIT
    Requires: Configuration Manager console (ConfigurationManager module) for the site mode,
              and read access to antimalware policies and collections (Read-only Analyst
              is enough). Windows PowerShell 5.1, the ConfigurationManager module's home.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console progress and summary for an interactive report tool.')]
[CmdletBinding(DefaultParameterSetName = 'Site')]
param(
    [Parameter(ParameterSetName = 'Site')]
    [string]$SiteCode,

    [Parameter(ParameterSetName = 'Site')]
    [string]$ProviderMachineName,

    [Parameter(ParameterSetName = 'Site')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Name = '*',

    [Parameter(ParameterSetName = 'Offline', Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$XmlPath,

    [string]$OutputPath,

    [string]$AdmxPath,

    [ValidateSet('en', 'sv')]
    [string]$Language = 'en',

    [char]$CsvDelimiter = (Get-Culture).TextInfo.ListSeparator[0]
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'

#region Text

# Everything a reader sees. Console output stays English; GPO names come from the ADMX.
$Strings = @{
    en = @{
        TypePaths = 'Paths'; TypePath = 'Path'
        TypeExtensions = 'Extensions'; TypeExtension = 'Extension'
        TypeProcesses = 'Processes'; TypeProcess = 'Process'
        TypeIpAddresses = 'IP addresses'; TypeIpAddress = 'IP address'

        StateListRow = 'Enabled · list entry: {0} = {1}'
        StateNoMatch = 'Value {0} matches neither Enabled ({1}) nor Disabled ({2})'
        StateUnknownOption = 'value {0} (not an option in the ADMX)'
        StateOn = 'on'; StateOff = 'off'
        StateValue = 'value {0}'
        StateEmpty = 'Not configured (the value is empty in ConfigMgr)'

        NoteInactive = 'Inactive in the ConfigMgr policy (Disabled="true"), so clients never apply it. Do not port it.'
        NoteFromCM = 'Names ConfigMgr as an update source (AMDefinitionFallbackOrderFromCM). That source is gone without ConfigMgr, so remove it from the order in the GPO.'
        NoteNoAdmx = 'No counterpart in WindowsDefender.admx: ConfigMgr/SCEP specific. Skip it, or set it as a registry value through Group Policy Preferences if it is really needed.'

        DeployDefault = 'All clients (default policy)'
        DeployCountOnly = '{0} collection(s), names could not be read'
        DeployOffline = 'Unknown (offline mode)'
        DeployNone = 'Not deployed'
        OrderDefault = 'Default'

        CsvExclusions = @('Policy', 'Order', 'Type', 'Exclusion', 'Policies sharing it', 'Deployed to', 'GPO setting', 'Registry key', 'Value')
        CsvSettings = @('Policy', 'Order', 'Registry key (ConfigMgr)', 'Registry key (GPO)', 'Value name', 'Type', 'Value', 'GPO setting', 'Set to', 'Remark')

        Title = 'Defender policies'
        Heading = 'Defender policies in ConfigMgr'
        Meta = 'Basis for porting to Group Policy · {0} · exported {1} by {2}'
        SourceSite = 'Site {0} · {1}'
        SourceOffline = 'Offline mode, built from {0} XML files'
        BannerNoAdmx = 'WindowsDefender.admx could not be read from {0}. GPO names for other settings are missing; run again with <code>-AdmxPath</code>.'
        BannerFailed = 'The export failed for {0} polic(ies): {1}. They have no content below.'
        BannerOffline = 'Offline mode: order and deployments are not read from ConfigMgr and are therefore missing from the report.'

        TilePolicies = 'antimalware policies · {0}'
        TileNotDeployed = '{0} not deployed'
        TileOffline = 'offline mode'
        TileUnique = 'unique exclusions'
        TileCommon = 'in all {0} policies with exclusions – candidates for a shared baseline GPO'
        TileCommonNA = 'shared exclusions – needs at least two policies with exclusions to compare'
        TileMapped = 'other settings have a GPO counterpart in the ADMX'

        GuideTitle = 'Porting to Group Policy'
        GuideWhere = 'Exclusions live in <code>{0} › Microsoft Defender Antivirus › Exclusions</code>. Set <b>{1}</b>, <b>{2}</b> and <b>{3}</b> to <b>Enabled</b>, click <b>Show…</b> and add one row per exclusion with <b>Value name</b> = the exclusion and <b>Value</b> = <code>0</code>. Show… does not take a multi-row paste, so for long lists run <code>Import-DefenderExclusionsToGpo.ps1</code> against <code>Exclusions.csv</code> instead. The copy button on each list gives the values one per line.'
        GuideMerge = 'ConfigMgr merges the exclusions of every antimalware policy that targets a client (<a href="{0}">documented</a>). In WindowsDefender.admx the exclusion lists are declared <code>additive="true"</code>, which in the <a href="{1}">ADMX schema</a> means values are appended instead of replaced. Exclusions from several GPOs should therefore add up on the client the same way, so a baseline GPO plus role specific GPOs should work. Microsoft does not document that GPO-to-GPO case for Defender explicitly: confirm it with two test GPOs before you build on it.'
        GuideNotAdditive = 'In your version of WindowsDefender.admx the exclusion lists are <b>not</b> additive: the GPO with the highest precedence replaces the lists from other GPOs. Keep every exclusion that should apply to a client in one GPO.'
        GuideOther = 'Other settings do not merge. In ConfigMgr the policy with the lowest <i>Order</i> wins, in Group Policy the GPO with the highest precedence wins. Under <i>Other settings</i> on each policy you see exactly what every ConfigMgr value corresponds to in the Group Policy editor.'
        GuideNotDeployed = 'Policies tagged {0} affect no clients today. Decide whether they should be ported at all.'
        GuideFiles = 'The same data is in <code>Exclusions.csv</code> and <code>AllSettings.csv</code> for Excel or scripted import, and the original exports are in <code>ConfigMgr-XML</code>.'

        OverviewTitle = 'Policies'
        ColOrder = 'Order'; ColPolicy = 'Policy'; ColAppliesTo = 'Applies to'; ColOther = 'Other values'
        ChipExportFailed = 'Export failed'

        MatrixTitle = 'Exclusions by policy'
        MatrixNone = 'No policy contains any exclusions.'
        MatrixIntro = 'Every unique exclusion and the policies it appears in. Highlighted rows are in every policy that has exclusions. Policies without exclusions are not shown here.'
        FilterPlaceholder = 'Filter exclusions, e.g. sql or .ldf'
        FilterLabel = 'Filter exclusions'
        TypeLabel = 'Type'; AllTypes = 'All types'
        Showing = 'Showing {0} of {1}'
        ColType = 'Type'; ColExclusion = 'Exclusion'; ColCount = 'Count'
        ChipContextual = 'contextual'

        ChipOrder = 'Order {0}'
        ChipDefault = 'Default policy'
        FactAppliesTo = 'Applies to'; FactModified = 'Last modified'; FactSource = 'Source'
        ModifiedBy = '{0} by {1}'
        Members = ' · {0} devices'
        NoExclusions = 'The policy has no exclusions.'
        CopyOne = 'Copy 1 row'; CopyMany = 'Copy {0} rows'
        Copied = 'Copied ✓'; CopyFailed = 'Could not copy'
        OtherSummary = 'Other settings ({0} {1}{2})'
        ValueOne = 'value'; ValueMany = 'values'
        Unmapped = ' · {0} without a GPO counterpart'
        ColRegValue = 'Registry value'; ColValue = 'Value'; ColGpo = 'GPO setting'; ColSetTo = 'Set to'
        RootKey = '(root key)'
        ChipNoAdmx = 'No ADMX counterpart'
        ChipInactive = 'Inactive'
        Footer = 'Source: Export-CMAntimalwarePolicy · GPO mapping: {0} · {1}'
        AdmxMissing = 'missing'
    }
    sv = @{
        TypePaths = 'Sökvägar'; TypePath = 'Sökväg'
        TypeExtensions = 'Filändelser'; TypeExtension = 'Filändelse'
        TypeProcesses = 'Processer'; TypeProcess = 'Process'
        TypeIpAddresses = 'IP-adresser'; TypeIpAddress = 'IP-adress'

        StateListRow = 'Enabled · rad i listan: {0} = {1}'
        StateNoMatch = 'Värdet {0} matchar varken Enabled ({1}) eller Disabled ({2})'
        StateUnknownOption = 'värde {0} (finns inte som alternativ i ADMX:en)'
        StateOn = 'på'; StateOff = 'av'
        StateValue = 'värde {0}'
        StateEmpty = 'Not configured (värdet är tomt i ConfigMgr)'

        NoteInactive = 'Inaktiv i ConfigMgr-policyn (Disabled="true") och tillämpas inte på klienterna. Ska inte med till GPO.'
        NoteFromCM = 'Anger ConfigMgr som uppdateringskälla (AMDefinitionFallbackOrderFromCM). Den källan finns inte utan ConfigMgr, så ta bort den ur ordningen i GPO:n.'
        NoteNoAdmx = 'Har ingen motsvarighet i WindowsDefender.admx eftersom den är ConfigMgr/SCEP-specifik. Hoppa över den, eller sätt den som registervärde via GPP om den verkligen behövs.'

        DeployDefault = 'Alla klienter (standardpolicy)'
        DeployCountOnly = '{0} samling(ar), namnen kunde inte läsas'
        DeployOffline = 'Okänt (offline-läge)'
        DeployNone = 'Inte deployad'
        OrderDefault = 'Standard'

        CsvExclusions = @('Policy', 'Ordning', 'Typ', 'Exclusion', 'Finns i antal policyer', 'Deployad till', 'GPO-inställning', 'Registernyckel', 'Värde')
        CsvSettings = @('Policy', 'Ordning', 'Registernyckel (ConfigMgr)', 'Registernyckel (GPO)', 'Värdenamn', 'Typ', 'Värde', 'GPO-inställning', 'Ställ in till', 'Anmärkning')

        Title = 'Defender-policyer'
        Heading = 'Defender-policyer i ConfigMgr'
        Meta = 'Underlag för portning till GPO · {0} · exporterad {1} av {2}'
        SourceSite = 'Site {0} · {1}'
        SourceOffline = 'Offline-läge, byggd från {0} XML-filer'
        BannerNoAdmx = 'WindowsDefender.admx kunde inte läsas från {0}. GPO-namnen för övriga inställningar saknas; kör om med <code>-AdmxPath</code>.'
        BannerFailed = 'Exporten misslyckades för {0} policy(er): {1}. De saknar innehåll nedan.'
        BannerOffline = 'Offline-läge: ordning och deployments läses inte från ConfigMgr och saknas därför i rapporten.'

        TilePolicies = 'antimalware-policyer · {0}'
        TileNotDeployed = '{0} inte deployade'
        TileOffline = 'offline-läge'
        TileUnique = 'unika exclusions'
        TileCommon = 'finns i alla {0} policyer med exclusions – kandidater för en gemensam bas-GPO'
        TileCommonNA = 'gemensamma exclusions – kräver minst två policyer med exclusions att jämföra'
        TileMapped = 'övriga inställningar har en GPO-motsvarighet i ADMX:en'

        GuideTitle = 'Så portar du till GPO'
        GuideWhere = 'Exclusions ligger i <code>{0} › Microsoft Defender Antivirus › Exclusions</code>. Sätt <b>{1}</b>, <b>{2}</b> och <b>{3}</b> till <b>Enabled</b>, klicka <b>Show…</b> och lägg en rad per exclusion med <b>Value name</b> = exclusionen och <b>Value</b> = <code>0</code>. Show… tar inte emot inklistring av flera rader, så för långa listor kör du <code>Import-DefenderExclusionsToGpo.ps1</code> mot <code>Exclusions.csv</code> i stället. Kopieringsknappen vid varje lista ger värdena ett per rad.'
        GuideMerge = 'ConfigMgr slår ihop exclusions från alla antimalware-policyer som riktas mot en klient (<a href="{0}">dokumenterat</a>). I WindowsDefender.admx är exclusion-listorna deklarerade <code>additive="true"</code>, vilket i <a href="{1}">ADMX-schemat</a> betyder att värden läggs till i stället för att ersättas. Exclusions från flera GPO:er bör därför läggas ihop på klienten på samma sätt, och en bas-GPO plus rollspecifika GPO:er bör fungera. Microsoft dokumenterar inte just GPO-mot-GPO-fallet för Defender, så bekräfta det med två test-GPO:er innan ni bygger på det.'
        GuideNotAdditive = 'I din version av WindowsDefender.admx är exclusion-listorna <b>inte</b> additiva: GPO:n med högst precedens ersätter listan från övriga GPO:er. Samla därför alla exclusions som ska gälla en klient i en och samma GPO.'
        GuideOther = 'Övriga inställningar slås inte ihop. I ConfigMgr vinner policyn med lägst <i>Order</i>, i GPO vinner GPO:n med högst precedens. Under <i>Övriga inställningar</i> på varje policy står exakt vad varje ConfigMgr-värde motsvarar i GPO-editorn.'
        GuideNotDeployed = 'Policyer märkta {0} påverkar inga klienter i dag. Bestäm om de alls ska följa med.'
        GuideFiles = 'Samma värden finns i <code>Exclusions.csv</code> och <code>AllSettings.csv</code> för Excel eller skriptad import, och originalexporterna ligger i <code>ConfigMgr-XML</code>.'

        OverviewTitle = 'Policyer'
        ColOrder = 'Order'; ColPolicy = 'Policy'; ColAppliesTo = 'Gäller'; ColOther = 'Övriga värden'
        ChipExportFailed = 'Export misslyckades'

        MatrixTitle = 'Exclusions per policy'
        MatrixNone = 'Ingen policy innehåller några exclusions.'
        MatrixIntro = 'Varje unik exclusion och vilka policyer den finns i. Markerade rader finns i alla policyer som har exclusions. Policyer utan exclusions visas inte här.'
        FilterPlaceholder = 'Filtrera exclusions, t.ex. sql eller .ldf'
        FilterLabel = 'Filtrera exclusions'
        TypeLabel = 'Typ'; AllTypes = 'Alla typer'
        Showing = 'Visar {0} av {1}'
        ColType = 'Typ'; ColExclusion = 'Exclusion'; ColCount = 'Antal'
        ChipContextual = 'kontextuell'

        ChipOrder = 'Order {0}'
        ChipDefault = 'Standardpolicy'
        FactAppliesTo = 'Gäller'; FactModified = 'Senast ändrad'; FactSource = 'Källa'
        ModifiedBy = '{0} av {1}'
        Members = ' · {0} enheter'
        NoExclusions = 'Policyn innehåller inga exclusions.'
        CopyOne = 'Kopiera 1 rad'; CopyMany = 'Kopiera {0} rader'
        Copied = 'Kopierat ✓'; CopyFailed = 'Kunde inte kopiera'
        OtherSummary = 'Övriga inställningar ({0} {1}{2})'
        ValueOne = 'värde'; ValueMany = 'värden'
        Unmapped = ' · {0} utan GPO-motsvarighet'
        ColRegValue = 'Registervärde'; ColValue = 'Värde'; ColGpo = 'GPO-inställning'; ColSetTo = 'Ställ in till'
        RootKey = '(huvudnyckeln)'
        ChipNoAdmx = 'Ingen ADMX-motsvarighet'
        ChipInactive = 'Inaktiv'
        Footer = 'Källa: Export-CMAntimalwarePolicy · GPO-mappning: {0} · {1}'
        AdmxMissing = 'saknas'
    }
}
$T = $Strings[$Language]

#endregion

#region Constants

# Exclusion lists live in ...\Exclusions\<Type>. Gpo is the fallback name when no ADMX is found.
$ExclusionTypes = [ordered]@{
    Paths       = [pscustomobject]@{ Label = $T.TypePaths;       Singular = $T.TypePath;       Gpo = 'Path Exclusions' }
    Extensions  = [pscustomobject]@{ Label = $T.TypeExtensions;  Singular = $T.TypeExtension;  Gpo = 'Extension Exclusions' }
    Processes   = [pscustomobject]@{ Label = $T.TypeProcesses;   Singular = $T.TypeProcess;    Gpo = 'Process Exclusions' }
    IpAddresses = [pscustomobject]@{ Label = $T.TypeIpAddresses; Singular = $T.TypeIpAddress;  Gpo = 'Ip Address Exclusions' }
}
$GpoRoot = 'Computer Configuration › Policies › Administrative Templates › Windows Components'
$DocConfigMgrMerge = 'https://learn.microsoft.com/intune/configmgr/protect/deploy-use/endpoint-antimalware-policies#exclusion-settings'
$DocAdmxAdditive = 'https://learn.microsoft.com/previous-versions/windows/it-pro/windows-server-2008-r2-and-2008/cc754311(v=ws.10)'

# From the explain text of Threats_ThreatSeverityDefaultAction / Threats_ThreatIdDefaultAction.
$ThreatSeverity = @{ '1' = 'Low'; '2' = 'Medium'; '4' = 'High'; '5' = 'Severe' }
$ThreatAction   = @{ '2' = 'Quarantine'; '3' = 'Remove'; '6' = 'Ignore' }

#endregion

#region Helpers

function Esc([string]$Text) {
    # HTML-escape for element content and quoted attribute values alike. Only these five
    # matter there; the page is UTF-8, so å, ä, ö and › stay readable in the source.
    # (Not "H": that is a built-in alias for Get-History, and aliases win over functions.)
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;')
}

function Get-SafeFileName([string]$Text) {
    $invalid = [regex]::Escape(-join [System.IO.Path]::GetInvalidFileNameChars())
    ($Text -replace "[$invalid\[\]]", '_').Trim()
}

function Resolve-FileSystemPath([string]$Path) {
    # Relative paths resolve against the last file system location - never against the CMSite drive.
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location -PSProvider FileSystem).ProviderPath $Path))
}

function ConvertTo-DefenderKey([string]$Key) {
    # ConfigMgr writes the SCEP-era key. Defender's ADMX has the same layout under 'Windows Defender'.
    $relative = $Key.Trim() -replace '^(HKLM|HKEY_LOCAL_MACHINE)\\', ''
    $relative -replace '^(SOFTWARE\\Policies\\Microsoft\\)Microsoft Antimalware(?=\\|$)', '${1}Windows Defender'
}

function ConvertTo-CsvRow([string[]]$Columns, [object[]]$Values) {
    $row = [ordered]@{}
    for ($i = 0; $i -lt $Columns.Count; $i++) { $row[$Columns[$i]] = $Values[$i] }
    [pscustomobject]$row
}

function Write-CsvFile([object[]]$Rows, [string[]]$Columns, [string]$Path, [char]$Delimiter) {
    # UTF-8 with BOM, so Excel detects the encoding instead of guessing the ANSI code page.
    $lines = if ($Rows.Count) { @($Rows | ConvertTo-Csv -NoTypeInformation -Delimiter $Delimiter) }
             else { @(($Columns | ForEach-Object { '"' + $_ + '"' }) -join $Delimiter) }
    [System.IO.File]::WriteAllLines($Path, [string[]]$lines, (New-Object System.Text.UTF8Encoding $true))
}

#endregion

#region ADMX: registry value -> GPO setting

function Get-AdmxText([hashtable]$Strings, [string]$Reference) {
    if ($Reference -match '^\$\(string\.(.+)\)$') {
        $id = $Matches[1]
        if ($Strings.ContainsKey($id)) { return $Strings[$id] }
        return $id
    }
    $Reference
}

function Get-AdmxRegistryValue([System.Xml.XmlNode]$Node) {
    # <enabledValue>, <value>, <trueValue> ... wrap one <decimal value=".."/> or <string>..</string>.
    if (-not $Node) { return $null }
    $child = $Node.SelectSingleNode("*[local-name()='decimal' or local-name()='longDecimal' or local-name()='string' or local-name()='delete']")
    if (-not $child) { return $null }
    if ($child.LocalName -eq 'string') { return $child.InnerText }
    if ($child.LocalName -eq 'delete') { return '(delete)' }
    $child.GetAttribute('value')
}

function Get-DefenderAdmxIndex([string]$Folder) {
    $admxFile = Join-Path $Folder 'WindowsDefender.admx'
    $admlFile = @('en-US', (Get-UICulture).Name) |
        ForEach-Object { Join-Path $Folder "$_\WindowsDefender.adml" } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if (-not (Test-Path -LiteralPath $admxFile) -or -not $admlFile) { return $null }

    $admx = New-Object System.Xml.XmlDocument
    $admx.Load($admxFile)
    $adml = New-Object System.Xml.XmlDocument
    $adml.Load($admlFile)

    $strings = @{}
    foreach ($node in $adml.SelectNodes("//*[local-name()='stringTable']/*[local-name()='string']")) {
        $strings[$node.GetAttribute('id')] = $node.InnerText.Trim()
    }

    # Presentation labels, keyed "<presentation id>|<element id>".
    $labels = @{}
    foreach ($presentation in $adml.SelectNodes("//*[local-name()='presentationTable']/*[local-name()='presentation']")) {
        foreach ($control in $presentation.SelectNodes('*[@refId]')) {
            $labelNode = $control.SelectSingleNode("*[local-name()='label']")
            $text = if ($labelNode) { $labelNode.InnerText } else { $control.InnerText }
            $labels["$($presentation.GetAttribute('id'))|$($control.GetAttribute('refId'))"] = ($text.Trim() -replace '\s+', ' ').TrimEnd(':')
        }
    }

    $categories = @{}
    foreach ($category in $admx.SelectNodes("//*[local-name()='categories']/*[local-name()='category']")) {
        $parent = $category.SelectSingleNode("*[local-name()='parentCategory']")
        $categories[$category.GetAttribute('name')] = [pscustomobject]@{
            Display = Get-AdmxText $strings $category.GetAttribute('displayName')
            Parent  = if ($parent) { $parent.GetAttribute('ref') } else { $null }
        }
    }

    $values = @{}   # "<key>|<valueName>" -> what the value means in this policy
    $lists  = @{}   # "<key>" -> list policy owning every value in that key
    foreach ($policy in $admx.SelectNodes("//*[local-name()='policies']/*[local-name()='policy']")) {
        if ($policy.GetAttribute('class') -eq 'User') { continue }

        # Category chain below Windows Components, e.g. "Microsoft Defender Antivirus › Scan".
        $parts = New-Object System.Collections.Generic.List[string]
        $parentNode = $policy.SelectSingleNode("*[local-name()='parentCategory']")
        $ref = if ($parentNode) { $parentNode.GetAttribute('ref') } else { $null }
        for ($depth = 0; $ref -and $categories.ContainsKey($ref) -and $depth -lt 20; $depth++) {
            $parts.Insert(0, $categories[$ref].Display)
            $ref = $categories[$ref].Parent
        }
        $display = Get-AdmxText $strings $policy.GetAttribute('displayName')
        $parts.Add($display)
        $setting = [pscustomobject]@{ Name = $display; Path = $parts -join ' › ' }

        $policyKey = $policy.GetAttribute('key')
        $presentationId = $policy.GetAttribute('presentation') -replace '^\$\(presentation\.(.+)\)$', '$1'

        foreach ($element in $policy.SelectNodes("*[local-name()='elements']/*")) {
            $elementKey = if ($element.GetAttribute('key')) { $element.GetAttribute('key') } else { $policyKey }
            $label = $labels["$presentationId|$($element.GetAttribute('id'))"]
            if ($element.LocalName -eq 'list') {
                $lists[$elementKey.ToLowerInvariant()] = [pscustomobject]@{
                    Setting  = $setting
                    Additive = $element.GetAttribute('additive') -eq 'true'
                }
                continue
            }
            $valueName = $element.GetAttribute('valueName')
            if (-not $valueName) { continue }

            $items = foreach ($item in $element.SelectNodes("*[local-name()='item']")) {
                [pscustomobject]@{
                    Display = Get-AdmxText $strings $item.GetAttribute('displayName')
                    Value   = Get-AdmxRegistryValue $item.SelectSingleNode("*[local-name()='value']")
                }
            }
            $onValue  = Get-AdmxRegistryValue $element.SelectSingleNode("*[local-name()='trueValue']")
            $offValue = Get-AdmxRegistryValue $element.SelectSingleNode("*[local-name()='falseValue']")
            $values["$($elementKey.ToLowerInvariant())|$($valueName.ToLowerInvariant())"] = [pscustomobject]@{
                Setting  = $setting
                Kind     = $element.LocalName
                Label    = $label
                Items    = @($items)
                True     = if ($null -ne $onValue) { $onValue } else { '1' }
                False    = if ($null -ne $offValue) { $offValue } else { '0' }
                Enabled  = $null
                Disabled = $null
            }
        }

        # Policy-level value. An element writing the same value carries more meaning, so it wins.
        $policyValueName = $policy.GetAttribute('valueName')
        if ($policyValueName) {
            $lookup = "$($policyKey.ToLowerInvariant())|$($policyValueName.ToLowerInvariant())"
            if (-not $values.ContainsKey($lookup)) {
                $values[$lookup] = [pscustomobject]@{
                    Setting  = $setting
                    Kind     = 'policy'
                    Label    = $null
                    Items    = @()
                    True     = $null
                    False    = $null
                    Enabled  = Get-AdmxRegistryValue $policy.SelectSingleNode("*[local-name()='enabledValue']")
                    Disabled = Get-AdmxRegistryValue $policy.SelectSingleNode("*[local-name()='disabledValue']")
                }
            }
        }
    }

    [pscustomobject]@{
        Values   = $values
        Lists    = $lists
        Source   = $admxFile
        Language = Split-Path (Split-Path $admlFile -Parent) -Leaf
    }
}

function Resolve-GpoSetting($Index, [string]$DefenderKey, [string]$ValueName, [string]$Value) {
    if (-not $Index) { return $null }
    $key = $DefenderKey.ToLowerInvariant()

    if ($Index.Lists.ContainsKey($key)) {
        $shownName = $ValueName
        $shownValue = $Value
        if ($key -like '*\threats\threatseveritydefaultaction' -and $ThreatSeverity.ContainsKey($ValueName)) { $shownName = "$ValueName ($($ThreatSeverity[$ValueName]))" }
        if ($key -like '*\threats\threat*defaultaction' -and $ThreatAction.ContainsKey($Value)) { $shownValue = "$Value ($($ThreatAction[$Value]))" }
        return [pscustomobject]@{ Setting = $Index.Lists[$key].Setting; State = $T.StateListRow -f $shownName, $shownValue }
    }

    $entry = $Index.Values["$key|$($ValueName.ToLowerInvariant())"]
    if (-not $entry) { return $null }

    $prefix = if ($entry.Label) { "Enabled · $($entry.Label): " } else { 'Enabled · ' }
    $state = switch ($entry.Kind) {
        'policy' {
            # No explicit enabledValue/disabledValue: the editor writes 1 and 0.
            $on  = if ($null -ne $entry.Enabled)  { $entry.Enabled }  else { '1' }
            $off = if ($null -ne $entry.Disabled) { $entry.Disabled } else { '0' }
            if ($Value -eq $on) { 'Enabled' }
            elseif ($Value -eq $off) { 'Disabled' }
            else { $T.StateNoMatch -f $Value, $on, $off }
        }
        'enum' {
            $item = $entry.Items | Where-Object { $_.Value -eq $Value } | Select-Object -First 1
            if ($item) { $prefix + $item.Display } else { $prefix + ($T.StateUnknownOption -f $Value) }
        }
        'boolean' {
            if ($Value -eq $entry.True) { $prefix + $T.StateOn }
            elseif ($Value -eq $entry.False) { $prefix + $T.StateOff }
            else { $prefix + ($T.StateValue -f $Value) }
        }
        default {
            # ConfigMgr writes empty strings for lists it leaves empty, e.g. no definition file shares.
            if ($Value -eq '') { $T.StateEmpty } else { $prefix + $Value }
        }
    }
    [pscustomobject]@{ Setting = $entry.Setting; State = $state }
}

#endregion

#region ConfigMgr

function Connect-CMSiteDrive([string]$SiteCode, [string]$ProviderMachineName) {
    # Returns the name of the CMSite drive to work in. The module does not reliably mount one
    # on import, so use an existing drive when the choice is unambiguous, otherwise create it.
    if ($SiteCode) {
        if (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue) { return $SiteCode }
        if (-not $ProviderMachineName) { throw "No site drive '$SiteCode' in this session. Add -ProviderMachineName to connect to it." }
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName -Scope Global | Out-Null
        return $SiteCode
    }
    $drives = @()
    try { $drives = @(Get-PSDrive -PSProvider CMSite -ErrorAction Stop) } catch { $drives = @() }
    if ($drives.Count -eq 1) { return $drives[0].Name }
    if ($drives.Count -gt 1) { throw "Several ConfigMgr site drives exist ($(@($drives | ForEach-Object Name) -join ', ')). Choose one with -SiteCode." }
    throw 'No ConfigMgr site drive in this session. Pass -SiteCode and -ProviderMachineName.'
}

function Read-AntimalwarePolicyXml([string]$Path) {
    # <SecurityPolicy><PolicySection><LocalGroupPolicySettings><AddKey Name=".."><AddValue Name=".." Type="..">data
    $doc = New-Object System.Xml.XmlDocument
    $doc.Load($Path)
    $root = $doc.DocumentElement

    $entries = foreach ($value in $doc.SelectNodes("//*[local-name()='AddKey']/*[local-name()='AddValue']")) {
        # Disabled="true" on the value, its key or its section means the client never applies it.
        $disabled = $value.SelectSingleNode("ancestor-or-self::*[translate(@Disabled, 'TRUE', 'true') = 'true']")
        [pscustomobject]@{
            Key       = $value.ParentNode.GetAttribute('Name').Trim()
            ValueName = $value.GetAttribute('Name').Trim()
            Type      = $value.GetAttribute('Type')
            Value     = $value.InnerText.Trim()
            Active    = -not $disabled
        }
    }

    $other = @($doc.SelectNodes("//*[local-name()='LocalGroupPolicySettings']/*") |
        Where-Object { $_.LocalName -ne 'AddKey' } | ForEach-Object LocalName | Sort-Object -Unique)

    [pscustomobject]@{
        IsPolicy      = $root.LocalName -eq 'SecurityPolicy'
        Name          = $root.GetAttribute('Name')
        Description   = $root.GetAttribute('Description')
        ModifiedBy    = $root.GetAttribute('LastModifiedBy')
        Entries       = @($entries)
        OtherElements = $other
    }
}

function ConvertTo-PolicyModel($Parsed, $Index) {
    $byType = @{}
    $settings = foreach ($entry in $Parsed.Entries) {
        $defenderKey = ConvertTo-DefenderKey $entry.Key
        $exclusionType = $null
        if ($defenderKey -match '\\Exclusions\\([^\\]+)$') {
            $raw = $Matches[1]
            $exclusionType = @($ExclusionTypes.Keys | Where-Object { $_ -eq $raw })[0]
            if (-not $exclusionType) { $exclusionType = $raw }
            if ($entry.Active) {
                if (-not $byType.ContainsKey($exclusionType)) { $byType[$exclusionType] = New-Object System.Collections.Generic.List[string] }
                $byType[$exclusionType].Add($entry.ValueName)
            }
        }

        $gpo = Resolve-GpoSetting $Index $defenderKey $entry.ValueName $entry.Value
        $note = if (-not $entry.Active) { $T.NoteInactive }
                elseif ($entry.Value -match 'FromCM') { $T.NoteFromCM }
                elseif ($Index -and -not $gpo) { $T.NoteNoAdmx }

        [pscustomobject]@{
            Key           = $entry.Key
            DefenderKey   = $defenderKey
            ValueName     = $entry.ValueName
            Type          = $entry.Type
            Value         = $entry.Value
            Active        = $entry.Active
            ExclusionType = $exclusionType
            GpoSetting    = if ($gpo) { $gpo.Setting.Path } else { $null }
            GpoState      = if ($gpo) { $gpo.State } else { $null }
            Note          = $note
        }
    }

    # Known types in fixed order first, anything unexpected after. Defender compares
    # case-insensitively, and so does Sort-Object -Unique.
    $exclusions = [ordered]@{}
    $typeOrder = @($ExclusionTypes.Keys) + @($byType.Keys | Where-Object { -not $ExclusionTypes.Contains($_) } | Sort-Object)
    foreach ($type in $typeOrder) {
        if ($byType.ContainsKey($type)) { $exclusions[$type] = @($byType[$type] | Sort-Object -Unique) }
    }

    [pscustomobject]@{ Exclusions = $exclusions; Settings = @($settings) }
}

function ConvertTo-PolicyRecord {
    param(
        [string]$Name, $SettingsId, $Priority, [bool]$IsDefault, [string]$Description,
        $Modified, [string]$ModifiedBy, $AssignmentCount, $Deployments,
        [string]$XmlFile, [string]$ErrorMessage, $Parsed, $Index
    )
    $record = [pscustomobject]@{
        Name            = $Name
        SettingsId      = $SettingsId
        Priority        = $Priority
        IsDefault       = $IsDefault
        Description     = $Description
        Modified        = $Modified
        ModifiedBy      = $ModifiedBy
        AssignmentCount = $AssignmentCount
        Deployments     = $Deployments
        XmlFile         = $XmlFile
        Error           = $ErrorMessage
        Exclusions      = [ordered]@{}
        Settings        = @()
        OtherElements   = @()
    }
    if ($Parsed) {
        $model = ConvertTo-PolicyModel $Parsed $Index
        $record.Exclusions = $model.Exclusions
        $record.Settings = $model.Settings
        $record.OtherElements = $Parsed.OtherElements
        if (-not $record.Description) { $record.Description = $Parsed.Description }
        if (-not $record.ModifiedBy) { $record.ModifiedBy = $Parsed.ModifiedBy }
        if ($Parsed.OtherElements.Count) {
            Write-Warning "'$Name' contains elements this script does not interpret: $($Parsed.OtherElements -join ', '). See the raw XML."
        }
    }
    $record
}

function Get-ExclusionCount($Policy) {
    $count = 0
    foreach ($list in $Policy.Exclusions.Values) { $count += $list.Count }
    $count
}

function Test-NotDeployed($Policy) {
    -not $Policy.IsDefault -and $null -ne $Policy.Deployments -and $Policy.Deployments.Count -eq 0
}

function Get-DeploymentText($Policy) {
    if ($Policy.IsDefault) { return $T.DeployDefault }
    if ($null -eq $Policy.Deployments) {
        if ($null -ne $Policy.AssignmentCount) { return $T.DeployCountOnly -f $Policy.AssignmentCount }
        return $T.DeployOffline
    }
    if ($Policy.Deployments.Count -eq 0) { return $T.DeployNone }
    ($Policy.Deployments | ForEach-Object { "$($_.Name) ($($_.CollectionId))" }) -join '; '
}

function Get-OrderText($Policy) {
    if ($Policy.IsDefault) { return $T.OrderDefault }
    if ($null -ne $Policy.Priority) { return [string]$Policy.Priority }
    '–'
}

#endregion

# Dot-sourcing defines the functions above and stops here, which is how the Pester suite loads it:
#     . .\Export-CMDefenderPolicies.ps1
if ($MyInvocation.InvocationName -eq '.') { return }

#region Collect

$started = Get-Date
$OutputPath = if ($OutputPath) { Resolve-FileSystemPath $OutputPath }
              else { Resolve-FileSystemPath ('DefenderPolicyExport-{0:yyyyMMdd-HHmm}' -f $started) }
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

if (-not $AdmxPath) {
    $centralStore = if ($env:USERDNSDOMAIN) { "\\$env:USERDNSDOMAIN\SYSVOL\$env:USERDNSDOMAIN\Policies\PolicyDefinitions" }
    $AdmxPath = if ($centralStore -and (Test-Path -LiteralPath (Join-Path $centralStore 'WindowsDefender.admx'))) { $centralStore }
                else { Join-Path $env:windir 'PolicyDefinitions' }
}
$AdmxPath = Resolve-FileSystemPath $AdmxPath
$admx = $null
try { $admx = Get-DefenderAdmxIndex $AdmxPath }
catch { Write-Warning "Could not read WindowsDefender.admx under ${AdmxPath}: $($_.Exception.Message)" }
if ($admx) { Write-Host "GPO mapping from $($admx.Source) ($($admx.Language))" }
else { Write-Warning "WindowsDefender.admx/.adml not found under $AdmxPath - the report will lack GPO setting names." }

$policies = New-Object System.Collections.Generic.List[object]
$siteMode = $PSCmdlet.ParameterSetName -eq 'Site'

if ($siteMode) {
    $xmlFolder = Join-Path $OutputPath 'ConfigMgr-XML'
    New-Item -ItemType Directory -Path $xmlFolder -Force | Out-Null

    if (-not (Get-Command Get-CMAntimalwarePolicy -ErrorAction SilentlyContinue)) {
        if (-not $env:SMS_ADMIN_UI_PATH) {
            throw 'The ConfigurationManager module was not found. Run this on a machine with the Configuration Manager console installed, or use -XmlPath.'
        }
        Import-Module (Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1')
    }
    $SiteCode = Connect-CMSiteDrive $SiteCode $ProviderMachineName
    $ProviderMachineName = (Get-PSDrive -Name $SiteCode).Root

    Push-Location "$($SiteCode):\"
    try {
        $cmPolicies = @(Get-CMAntimalwarePolicy | Where-Object { $policyName = $_.Name; $Name.Where({ $policyName -like $_ }).Count })
        Write-Host "Found $($cmPolicies.Count) antimalware policies in site $SiteCode."

        # Deployments are client settings assignments; ClientSettingsID is the policy's SettingsID.
        $assignments = $null
        try { $assignments = @(Invoke-CMWmiQuery -Query 'SELECT * FROM SMS_ClientSettingsAssignment' -Option Fast) }
        catch { Write-Warning "Could not read deployments (SMS_ClientSettingsAssignment): $($_.Exception.Message)" }

        $collections = @{}
        if ($assignments) {
            $collectionIds = @($assignments | ForEach-Object { [string]$_.CollectionID } | Sort-Object -Unique)
            for ($i = 0; $i -lt $collectionIds.Count; $i += 50) {
                $chunk = $collectionIds[$i..([Math]::Min($i + 49, $collectionIds.Count - 1))]
                $where = ($chunk | ForEach-Object { "CollectionID = '$_'" }) -join ' OR '
                try {
                    foreach ($collection in (Invoke-CMWmiQuery -Query "SELECT * FROM SMS_Collection WHERE $where" -Option Fast)) {
                        $collections[[string]$collection.CollectionID] = $collection
                    }
                }
                catch { Write-Warning "Could not read collection member counts: $($_.Exception.Message)" }
            }
        }

        foreach ($cm in $cmPolicies) {
            $file = Join-Path $xmlFolder ('{0} ({1}).xml' -f (Get-SafeFileName $cm.Name), $cm.SettingsID)
            Write-Host "  Exporting '$($cm.Name)'"
            $parsed = $null
            $exportError = $null
            try {
                Export-CMAntimalwarePolicy -Id ([string]$cm.SettingsID) -Path $file -Force | Out-Null
                $parsed = Read-AntimalwarePolicyXml $file
                if (-not $parsed.IsPolicy) { throw "Unexpected root element in $file - not an antimalware policy export." }
            }
            catch {
                $exportError = $_.Exception.Message
                $parsed = $null
                Write-Warning "Export of '$($cm.Name)' failed: $exportError"
            }

            # Assigned inside the branches: an empty @() returned from an if-expression collapses to $null.
            if ($null -ne $assignments) {
                $deployments = @($assignments | Where-Object { [string]$_.ClientSettingsID -eq [string]$cm.SettingsID } | ForEach-Object {
                    $collection = $collections[[string]$_.CollectionID]
                    [pscustomobject]@{
                        CollectionId = [string]$_.CollectionID
                        Name         = [string]$_.CollectionName
                        Members      = if ($collection) { [int]$collection.MemberCount } else { $null }
                    }
                } | Sort-Object Name)
            }
            else { $deployments = $null }

            $policies.Add((ConvertTo-PolicyRecord -Name $cm.Name -SettingsId $cm.SettingsID -Priority $cm.Priority `
                -IsDefault ($cm.Priority -eq 10000 -or $cm.Name -eq 'Default Client Antimalware Policy') `
                -Description $cm.Description -Modified $cm.DateModified -ModifiedBy $cm.LastModifiedBy `
                -AssignmentCount $cm.AssignmentCount -Deployments $deployments -XmlFile $file `
                -ErrorMessage $exportError -Parsed $parsed -Index $admx))
        }
    }
    finally { Pop-Location }
}
else {
    $files = foreach ($item in $XmlPath) {
        $resolved = Resolve-FileSystemPath $item
        if (Test-Path -LiteralPath $resolved -PathType Container) {
            Get-ChildItem -LiteralPath $resolved -Filter *.xml -File | ForEach-Object FullName
        }
        elseif (Test-Path -LiteralPath $resolved) { $resolved }
        else { Write-Warning "Not found: $item" }
    }
    foreach ($file in @($files | Sort-Object -Unique)) {
        try { $parsed = Read-AntimalwarePolicyXml $file }
        catch { Write-Warning "Skipping ${file}: $($_.Exception.Message)"; continue }
        if (-not $parsed.IsPolicy) { Write-Warning "Skipping ${file}: not an antimalware policy export."; continue }
        $policyName = if ($parsed.Name) { $parsed.Name } else { [System.IO.Path]::GetFileNameWithoutExtension($file) }
        $policies.Add((ConvertTo-PolicyRecord -Name $policyName -IsDefault ($policyName -eq 'Default Client Antimalware Policy') `
            -XmlFile $file -Parsed $parsed -Index $admx))
    }
}

if ($policies.Count -eq 0) {
    Write-Warning 'No antimalware policies to report on.'
    return
}

# Order as the console does: lowest Order first, the default policy last.
$policies = @($policies | Sort-Object IsDefault, @{ Expression = { if ($null -ne $_.Priority) { [int]$_.Priority } else { [int]::MaxValue } } }, Name)

#endregion

#region Analyse

# Every unique exclusion across all policies, compared case-insensitively like Defender does.
$matrix = [ordered]@{}
for ($p = 0; $p -lt $policies.Count; $p++) {
    foreach ($type in $policies[$p].Exclusions.Keys) {
        foreach ($value in $policies[$p].Exclusions[$type]) {
            $key = "$type|$($value.ToLowerInvariant())"
            if (-not $matrix.Contains($key)) {
                $matrix[$key] = [pscustomobject]@{ Type = $type; Value = $value; Policies = New-Object System.Collections.Generic.List[int] }
            }
            $matrix[$key].Policies.Add($p)
        }
    }
}
$knownTypes = @($ExclusionTypes.Keys)
$matrixRows = @($matrix.Values | Sort-Object @{ Expression = { $index = $knownTypes.IndexOf($_.Type); if ($index -lt 0) { 99 } else { $index } } }, Value)

$typeInfo = [ordered]@{}
foreach ($type in $knownTypes + @($matrixRows | ForEach-Object Type)) {
    if ($typeInfo.Contains($type)) { continue }
    $base = if ($ExclusionTypes.Contains($type)) { $ExclusionTypes[$type] } else { [pscustomobject]@{ Label = $type; Singular = $type; Gpo = $type } }
    $listKey = "software\policies\microsoft\windows defender\exclusions\$($type.ToLowerInvariant())"
    $list = if ($admx -and $admx.Lists.ContainsKey($listKey)) { $admx.Lists[$listKey] } else { $null }
    $typeInfo[$type] = [pscustomobject]@{
        Label       = $base.Label
        Singular    = $base.Singular
        Gpo         = if ($list) { $list.Setting.Name } else { $base.Gpo }
        Additive    = if ($list) { $list.Additive } else { $null }
        RegistryKey = "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions\$type"
    }
}
$presentTypes = @($typeInfo.Keys | Where-Object { $type = $_; @($matrixRows | Where-Object Type -eq $type).Count })

$withExclusions = @(0..($policies.Count - 1) | Where-Object { (Get-ExclusionCount $policies[$_]) -gt 0 })
$commonRows = if ($withExclusions.Count -ge 2) { @($matrixRows | Where-Object { $_.Policies.Count -eq $withExclusions.Count }) } else { @() }
$notDeployed = @($policies | Where-Object { Test-NotDeployed $_ })
$failed = @($policies | Where-Object Error)
$otherSettings = @($policies | ForEach-Object { $_.Settings } | Where-Object { $_.Active -and -not $_.ExclusionType })
$mappedSettings = @($otherSettings | Where-Object GpoSetting)

#endregion

#region CSV

$exclusionRows = foreach ($policy in $policies) {
    $deployedTo = Get-DeploymentText $policy
    foreach ($type in $policy.Exclusions.Keys) {
        foreach ($value in $policy.Exclusions[$type]) {
            ConvertTo-CsvRow $T.CsvExclusions @(
                $policy.Name, (Get-OrderText $policy), $typeInfo[$type].Singular, $value,
                $matrix["$type|$($value.ToLowerInvariant())"].Policies.Count, $deployedTo,
                $typeInfo[$type].Gpo, $typeInfo[$type].RegistryKey, '0'
            )
        }
    }
}
Write-CsvFile @($exclusionRows) $T.CsvExclusions (Join-Path $OutputPath 'Exclusions.csv') $CsvDelimiter

$settingRows = foreach ($policy in $policies) {
    foreach ($setting in $policy.Settings) {
        ConvertTo-CsvRow $T.CsvSettings @(
            $policy.Name, (Get-OrderText $policy),
            "HKLM\$($setting.Key -replace '^(HKLM|HKEY_LOCAL_MACHINE)\\', '')", "HKLM\$($setting.DefenderKey)",
            $setting.ValueName, $setting.Type, $setting.Value,
            $setting.GpoSetting, $setting.GpoState, $setting.Note
        )
    }
}
Write-CsvFile @($settingRows) $T.CsvSettings (Join-Path $OutputPath 'AllSettings.csv') $CsvDelimiter

#endregion

#region HTML

$css = @'
:root {
  --bg: #f5f6f8; --panel: #ffffff; --text: #1b2230; --muted: #5b6474; --line: #e1e4ea;
  --accent: #0f62b8; --accent-soft: #e8f1fb; --warn: #8a4b00; --warn-soft: #fff3df;
  --ok: #0f7a3d; --ok-soft: #e5f4ea; --dot: #0f62b8;
  --mono: "Cascadia Mono", Consolas, ui-monospace, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #12151a; --panel: #1b1f27; --text: #e5e8ee; --muted: #9aa2b1; --line: #2b313c;
    --accent: #6aaeff; --accent-soft: #1b2c42; --warn: #f2b768; --warn-soft: #3a2b15;
    --ok: #63cf8f; --ok-soft: #16301f; --dot: #6aaeff;
  }
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 "Segoe UI", system-ui, sans-serif; }
main { max-width: 1240px; margin: 0 auto; padding: 28px 16px 72px; }
h1 { font-size: 27px; margin: 0 0 4px; letter-spacing: -.01em; }
h2 { font-size: 19px; margin: 0 0 12px; }
h3 { font-size: 14px; margin: 0; }
a { color: var(--accent); }
code, .mono { font-family: var(--mono); font-size: 13px; }
.meta, .muted { color: var(--muted); font-size: 13px; }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 12px; margin: 22px 0; }
.tile { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; }
.tile b { display: block; font-size: 30px; line-height: 1.15; font-variant-numeric: tabular-nums; }
.tile span { color: var(--muted); font-size: 13px; }
.card { background: var(--panel); border: 1px solid var(--line); border-radius: 14px; padding: 20px 22px; margin: 16px 0; }
.guide { background: var(--accent-soft); border-color: transparent; }
.guide ol { margin: 0; padding-left: 20px; }
.guide li { margin: 6px 0; }
.banner { background: var(--warn-soft); color: var(--warn); border-radius: 10px; padding: 10px 14px; margin: 12px 0; font-size: 14px; }
.scroll { overflow: auto; }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
th { font-size: 12px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
.chip { display: inline-block; font-size: 12px; line-height: 1; padding: 4px 8px; border-radius: 999px; background: var(--accent-soft); color: var(--accent); white-space: nowrap; vertical-align: 1px; }
.chip.warn { background: var(--warn-soft); color: var(--warn); }
.chip.ok { background: var(--ok-soft); color: var(--ok); }
.chip.plain { background: transparent; border: 1px solid var(--line); color: var(--muted); }
.controls { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 12px; }
.controls input, .controls select { font: inherit; color: var(--text); background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 7px 10px; }
.controls input { flex: 1 1 260px; min-width: 0; }
.matrix-wrap { max-height: 78vh; overflow: auto; border: 1px solid var(--line); border-radius: 10px; }
.matrix th { position: sticky; top: 0; background: var(--panel); z-index: 2; }
.matrix th.pol { vertical-align: bottom; text-transform: none; letter-spacing: 0; padding: 8px 4px; }
.matrix th.pol span { writing-mode: vertical-rl; transform: rotate(180deg); white-space: nowrap; max-height: 210px; overflow: hidden; text-overflow: ellipsis; display: inline-block; }
.matrix td.cell { text-align: center; width: 34px; padding: 7px 4px; }
.matrix td.cell i { display: inline-block; width: 9px; height: 9px; border-radius: 50%; background: var(--dot); }
.matrix td.val { word-break: break-all; min-width: 260px; }
.matrix tr.common td { background: var(--ok-soft); }
.phead { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-bottom: 6px; }
.phead h2 { margin: 0 8px 0 0; }
dl.facts { display: grid; grid-template-columns: max-content 1fr; gap: 4px 16px; margin: 12px 0 18px; font-size: 14px; }
dl.facts dt { color: var(--muted); }
dl.facts dd { margin: 0; }
.lists { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 14px; }
.list { border: 1px solid var(--line); border-radius: 10px; padding: 12px 14px; min-width: 0; }
.list header { display: flex; gap: 8px; align-items: center; justify-content: space-between; flex-wrap: wrap; }
.list .gpo { color: var(--muted); font-size: 12px; margin: 4px 0 8px; }
.list ul { list-style: none; margin: 0; padding: 0; }
.list li { font-family: var(--mono); font-size: 13px; padding: 3px 0; border-top: 1px dashed var(--line); word-break: break-all; }
.list li:first-child { border-top: 0; }
button.copy { font: inherit; font-size: 12px; color: var(--accent); background: transparent; border: 1px solid var(--accent); border-radius: 7px; padding: 3px 9px; cursor: pointer; }
button.copy:hover { background: var(--accent-soft); }
details { margin-top: 16px; }
summary { cursor: pointer; font-weight: 600; }
.settings { table-layout: fixed; min-width: 760px; }
.settings th:nth-child(1) { width: 24%; } .settings th:nth-child(2) { width: 16%; } .settings th:nth-child(3) { width: 32%; } .settings th:nth-child(4) { width: 28%; }
.settings td { font-size: 14px; overflow-wrap: anywhere; }
.settings tr.section td { background: var(--bg); font-weight: 600; font-size: 13px; color: var(--muted); }
.settings .path { color: var(--muted); font-size: 12px; }
footer { color: var(--muted); font-size: 12px; margin-top: 28px; }
@media print {
  body { background: #fff; }
  .controls, button.copy { display: none !important; }
  .card, .tile { break-inside: avoid; border-color: #ccc; }
  .matrix-wrap { max-height: none; overflow: visible; }
}
'@

$js = @'
(function () {
  var q = document.getElementById('q'), t = document.getElementById('t'), shown = document.getElementById('shown');
  var text = { copied: document.body.getAttribute('data-copied'), failed: document.body.getAttribute('data-copy-failed') };
  function apply() {
    var term = q.value.trim().toLowerCase(), type = t.value, n = 0;
    document.querySelectorAll('[data-x]').forEach(function (el) {
      var hit = (!type || el.getAttribute('data-type') === type) && (!term || el.getAttribute('data-x').indexOf(term) !== -1);
      el.hidden = !hit;
      if (hit && el.tagName === 'TR') { n++; }
    });
    if (shown) { shown.textContent = n; }
  }
  if (q && t) { q.addEventListener('input', apply); t.addEventListener('change', apply); }

  function fallbackCopy(value) {
    var ta = document.createElement('textarea'), ok = false;
    ta.value = value; ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.select();
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    return ok;
  }
  document.addEventListener('click', function (e) {
    var b = e.target.closest('button[data-copy]');
    if (!b || b.getAttribute('data-busy')) { return; }
    var value = b.getAttribute('data-copy'), label = b.textContent;
    function done(ok) {
      b.setAttribute('data-busy', '1');
      b.textContent = ok ? text.copied : text.failed;
      setTimeout(function () { b.textContent = label; b.removeAttribute('data-busy'); }, 1600);
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(value).then(function () { done(true); }, function () { done(fallbackCopy(value)); });
    } else { done(fallbackCopy(value)); }
  });
  window.addEventListener('beforeprint', function () {
    document.querySelectorAll('details').forEach(function (d) { d.open = true; });
  });
})();
'@

$html = New-Object System.Collections.Generic.List[string]
$sourceText = if ($siteMode) { $T.SourceSite -f $SiteCode, $ProviderMachineName } else { $T.SourceOffline -f $policies.Count }
$titleSite = if ($siteMode) { " – $SiteCode" } else { '' }
$notDeployedChip = "<span class=""chip warn"">$(Esc $T.DeployNone)</span>"

$html.Add("<!doctype html><html lang=""$Language""><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width, initial-scale=1"">")
$html.Add("<title>$(Esc ($T.Title + $titleSite))</title><style>$css</style></head>")
$html.Add("<body data-copied=""$(Esc $T.Copied)"" data-copy-failed=""$(Esc $T.CopyFailed)""><main>")
$html.Add("<header><h1>$(Esc $T.Heading)</h1>")
$html.Add("<div class=""meta"">$(Esc ($T.Meta -f $sourceText, $started.ToString('yyyy-MM-dd HH:mm'), "$env:USERDOMAIN\$env:USERNAME"))</div></header>")

if (-not $admx) { $html.Add("<div class=""banner"">$($T.BannerNoAdmx -f "<code>$(Esc $AdmxPath)</code>")</div>") }
if ($failed.Count) { $html.Add("<div class=""banner"">$(Esc ($T.BannerFailed -f $failed.Count, (($failed | ForEach-Object Name) -join ', ')))</div>") }
if (-not $siteMode) { $html.Add("<div class=""banner"">$(Esc $T.BannerOffline)</div>") }

# Tiles
$typeSummary = ($presentTypes | ForEach-Object { $type = $_; "$(@($matrixRows | Where-Object Type -eq $type).Count) $($typeInfo[$type].Label.ToLower())" }) -join ' · '
$policySub = if ($siteMode) { $T.TileNotDeployed -f $notDeployed.Count } else { $T.TileOffline }
$commonValue = if ($withExclusions.Count -ge 2) { $commonRows.Count } else { '–' }
$commonText = if ($withExclusions.Count -ge 2) { $T.TileCommon -f $withExclusions.Count } else { $T.TileCommonNA }
$uniqueText = if ($typeSummary) { "$($T.TileUnique) · $typeSummary" } else { $T.TileUnique }
$html.Add('<div class="tiles">')
$html.Add("<div class=""tile""><b>$($policies.Count)</b><span>$(Esc ($T.TilePolicies -f $policySub))</span></div>")
$html.Add("<div class=""tile""><b>$($matrixRows.Count)</b><span>$(Esc $uniqueText)</span></div>")
$html.Add("<div class=""tile""><b>$commonValue</b><span>$(Esc $commonText)</span></div>")
$html.Add("<div class=""tile""><b>$($mappedSettings.Count)/$($otherSettings.Count)</b><span>$(Esc $T.TileMapped)</span></div>")
$html.Add('</div>')

# Guide
$additive = if ($typeInfo.Contains('Paths')) { $typeInfo['Paths'].Additive } else { $null }
$mergeText = if ($additive -eq $false) { $T.GuideNotAdditive } else { $T.GuideMerge -f (Esc $DocConfigMgrMerge), (Esc $DocAdmxAdditive) }
$html.Add("<section class=""card guide""><h2>$(Esc $T.GuideTitle)</h2><ol>")
$html.Add("<li>$($T.GuideWhere -f (Esc $GpoRoot), (Esc $typeInfo['Paths'].Gpo), (Esc $typeInfo['Extensions'].Gpo), (Esc $typeInfo['Processes'].Gpo))</li>")
$html.Add("<li>$mergeText</li>")
$html.Add("<li>$($T.GuideOther)</li>")
if ($siteMode) { $html.Add("<li>$($T.GuideNotDeployed -f $notDeployedChip)</li>") }
$html.Add("<li>$($T.GuideFiles)</li>")
$html.Add('</ol></section>')

# Overview table
$html.Add("<section class=""card""><h2>$(Esc $T.OverviewTitle)</h2><div class=""scroll""><table><thead><tr><th>$(Esc $T.ColOrder)</th><th>$(Esc $T.ColPolicy)</th><th>$(Esc $T.ColAppliesTo)</th>")
foreach ($type in $presentTypes) { $html.Add("<th class=""num"">$(Esc $typeInfo[$type].Label)</th>") }
$html.Add("<th class=""num"">$(Esc $T.ColOther)</th></tr></thead><tbody>")
for ($p = 0; $p -lt $policies.Count; $p++) {
    $policy = $policies[$p]
    $deploymentHtml = if (Test-NotDeployed $policy) { $notDeployedChip } else { Esc (Get-DeploymentText $policy) }
    $failedChip = if ($policy.Error) { " <span class=""chip warn"">$(Esc $T.ChipExportFailed)</span>" } else { '' }
    $html.Add("<tr><td>$(Esc (Get-OrderText $policy))</td><td><a href=""#p$p"">$(Esc $policy.Name)</a>$failedChip</td><td>$deploymentHtml</td>")
    foreach ($type in $presentTypes) {
        $count = if ($policy.Exclusions.Contains($type)) { $policy.Exclusions[$type].Count } else { 0 }
        $html.Add("<td class=""num"">$(if ($count) { $count } else { '<span class="muted">–</span>' })</td>")
    }
    $html.Add("<td class=""num"">$(@($policy.Settings | Where-Object { $_.Active -and -not $_.ExclusionType }).Count)</td></tr>")
}
$html.Add('</tbody></table></div></section>')

# Matrix
$html.Add("<section class=""card""><h2>$(Esc $T.MatrixTitle)</h2>")
if ($matrixRows.Count -eq 0) {
    $html.Add("<p class=""muted"">$(Esc $T.MatrixNone)</p>")
}
else {
    $html.Add("<p class=""muted"">$(Esc $T.MatrixIntro)</p>")
    $html.Add("<div class=""controls""><input id=""q"" type=""search"" placeholder=""$(Esc $T.FilterPlaceholder)"" aria-label=""$(Esc $T.FilterLabel)""><select id=""t"" aria-label=""$(Esc $T.TypeLabel)""><option value="""">$(Esc $T.AllTypes)</option>")
    foreach ($type in $presentTypes) { $html.Add("<option value=""$(Esc $type)"">$(Esc $typeInfo[$type].Label)</option>") }
    $shownHtml = '<b id="shown">' + $matrixRows.Count + '</b>'
    $html.Add("</select><span class=""muted"">$($T.Showing -f $shownHtml, $matrixRows.Count)</span></div>")
    $html.Add("<div class=""matrix-wrap""><table class=""matrix""><thead><tr><th>$(Esc $T.ColType)</th><th>$(Esc $T.ColExclusion)</th>")
    foreach ($p in $withExclusions) { $html.Add("<th class=""pol"" title=""$(Esc $policies[$p].Name)""><span>$(Esc $policies[$p].Name)</span></th>") }
    $html.Add("<th class=""num"">$(Esc $T.ColCount)</th></tr></thead><tbody>")
    foreach ($row in $matrixRows) {
        $isCommon = $withExclusions.Count -ge 2 -and $row.Policies.Count -eq $withExclusions.Count
        $contextual = if ($row.Value -like '*\:{*') { " <span class=""chip"">$(Esc $T.ChipContextual)</span>" } else { '' }
        $html.Add("<tr$(if ($isCommon) { ' class="common"' }) data-type=""$(Esc $row.Type)"" data-x=""$(Esc $row.Value.ToLowerInvariant())""><td><span class=""chip plain"">$(Esc $typeInfo[$row.Type].Singular)</span></td><td class=""val mono"">$(Esc $row.Value)$contextual</td>")
        foreach ($p in $withExclusions) {
            $html.Add($(if ($row.Policies.Contains($p)) { "<td class=""cell"" title=""$(Esc $policies[$p].Name)""><i></i></td>" } else { '<td class="cell"></td>' }))
        }
        $html.Add("<td class=""num"">$($row.Policies.Count)</td></tr>")
    }
    $html.Add('</tbody></table></div>')
}
$html.Add('</section>')

# One card per policy
for ($p = 0; $p -lt $policies.Count; $p++) {
    $policy = $policies[$p]
    $html.Add("<section class=""card"" id=""p$p""><div class=""phead""><h2>$(Esc $policy.Name)</h2>")
    $html.Add("<span class=""chip"">$(Esc ($T.ChipOrder -f (Get-OrderText $policy)))</span>")
    if ($policy.IsDefault) { $html.Add("<span class=""chip plain"">$(Esc $T.ChipDefault)</span>") }
    if (Test-NotDeployed $policy) { $html.Add($notDeployedChip) }
    if ($policy.Error) { $html.Add("<span class=""chip warn"">$(Esc $T.ChipExportFailed)</span>") }
    $html.Add('</div>')
    if ($policy.Description) { $html.Add("<p>$(Esc $policy.Description)</p>") }
    if ($policy.Error) { $html.Add("<div class=""banner"">$(Esc $policy.Error)</div>") }

    $html.Add('<dl class="facts">')
    $html.Add("<dt>$(Esc $T.FactAppliesTo)</dt><dd>")
    if ($policy.Deployments -and $policy.Deployments.Count) {
        $html.Add(($policy.Deployments | ForEach-Object {
            $members = if ($null -ne $_.Members) { $T.Members -f $_.Members } else { '' }
            "$(Esc $_.Name) <span class=""muted"">($(Esc $_.CollectionId)$(Esc $members))</span>"
        }) -join '<br>')
    }
    else { $html.Add((Esc (Get-DeploymentText $policy))) }
    $html.Add('</dd>')
    if ($null -ne $policy.SettingsId) { $html.Add("<dt>SettingsID</dt><dd class=""mono"">$(Esc $policy.SettingsId)</dd>") }
    if ($policy.Modified -or $policy.ModifiedBy) {
        $modified = if ($policy.Modified) { ([datetime]$policy.Modified).ToString('yyyy-MM-dd HH:mm') } else { '' }
        $modifiedText = if ($modified -and $policy.ModifiedBy) { $T.ModifiedBy -f $modified, $policy.ModifiedBy } else { "$modified$($policy.ModifiedBy)" }
        $html.Add("<dt>$(Esc $T.FactModified)</dt><dd>$(Esc $modifiedText)</dd>")
    }
    if ($policy.XmlFile -and -not $policy.Error) { $html.Add("<dt>$(Esc $T.FactSource)</dt><dd class=""mono"">$(Esc (Split-Path $policy.XmlFile -Leaf))</dd>") }
    $html.Add('</dl>')

    if ($policy.Exclusions.Count) {
        $html.Add('<div class="lists">')
        foreach ($type in $policy.Exclusions.Keys) {
            $values = $policy.Exclusions[$type]
            $info = $typeInfo[$type]
            $copy = $values -join "`r`n"
            # Encoded CR LF: a literal one would be normalised to LF by the HTML parser.
            $copyAttribute = (Esc $copy).Replace("`r`n", '&#13;&#10;')
            $copyLabel = if ($values.Count -eq 1) { $T.CopyOne } else { $T.CopyMany -f $values.Count }
            $html.Add("<div class=""list""><header><h3>$(Esc $info.Label) <span class=""muted"">($($values.Count))</span></h3><button class=""copy"" type=""button"" data-copy=""$copyAttribute"">$(Esc $copyLabel)</button></header>")
            $html.Add("<div class=""gpo"">GPO: <b>$(Esc $info.Gpo)</b> · <span class=""mono"">$(Esc $info.RegistryKey)</span></div><ul>")
            foreach ($value in $values) {
                $html.Add("<li data-type=""$(Esc $type)"" data-x=""$(Esc $value.ToLowerInvariant())"">$(Esc $value)</li>")
            }
            $html.Add('</ul></div>')
        }
        $html.Add('</div>')
    }
    elseif (-not $policy.Error) {
        $html.Add("<p class=""muted"">$(Esc $T.NoExclusions)</p>")
    }

    $rest = @($policy.Settings | Where-Object { -not $_.ExclusionType })
    if ($rest.Count) {
        $unmapped = @($rest | Where-Object { $_.Active -and -not $_.GpoSetting }).Count
        $summaryNote = if ($admx -and $unmapped) { $T.Unmapped -f $unmapped } else { '' }
        $valueWord = if ($rest.Count -eq 1) { $T.ValueOne } else { $T.ValueMany }
        $html.Add("<details><summary>$(Esc ($T.OtherSummary -f $rest.Count, $valueWord, $summaryNote))</summary><div class=""scroll""><table class=""settings""><thead><tr><th>$(Esc $T.ColRegValue)</th><th>$(Esc $T.ColValue)</th><th>$(Esc $T.ColGpo)</th><th>$(Esc $T.ColSetTo)</th></tr></thead><tbody>")
        $base = 'SOFTWARE\Policies\Microsoft\Windows Defender'
        foreach ($group in ($rest | Group-Object { $_.DefenderKey })) {
            $section = $group.Name -replace "^$([regex]::Escape($base))\\?", ''
            if (-not $section) { $section = $T.RootKey }
            $html.Add("<tr class=""section""><td colspan=""4"">$(Esc $section)</td></tr>")
            foreach ($setting in $group.Group) {
                $gpoCell = if ($setting.GpoSetting) {
                    $parts = $setting.GpoSetting -split ' › '
                    "$(Esc $parts[-1])<div class=""path"">$(Esc (($parts[0..([Math]::Max(0, $parts.Count - 2))]) -join ' › '))</div>"
                }
                elseif ($admx) { "<span class=""chip warn"">$(Esc $T.ChipNoAdmx)</span>" }
                else { '<span class="muted">–</span>' }
                $stateCell = Esc $setting.GpoState
                if ($setting.Note) { $stateCell += "<div class=""path"">$(Esc $setting.Note)</div>" }
                if (-not $setting.Active) { $gpoCell = "<span class=""chip plain"">$(Esc $T.ChipInactive)</span> " + $gpoCell }
                $html.Add("<tr><td class=""mono"">$(Esc $setting.ValueName)</td><td class=""mono"">$(Esc $setting.Value)</td><td>$gpoCell</td><td>$stateCell</td></tr>")
            }
        }
        $html.Add('</tbody></table></div></details>')
    }
    $html.Add('</section>')
}

$admxText = if ($admx) { "$($admx.Source) ($($admx.Language))" } else { $T.AdmxMissing }
$html.Add("<footer>$(Esc ($T.Footer -f $admxText, "Export-CMDefenderPolicies.ps1 v$ScriptVersion"))</footer>")
$html.Add("</main><script>$js</script></body></html>")

$reportPath = Join-Path $OutputPath 'Report.html'
[System.IO.File]::WriteAllText($reportPath, ($html -join "`n"), (New-Object System.Text.UTF8Encoding $true))

#endregion

#region Summary

Write-Host ''
$policies | Format-Table -AutoSize -Property @(
    @{ Name = 'Order'; Expression = { Get-OrderText $_ } }
    @{ Name = 'Policy'; Expression = { $_.Name } }
    @{ Name = 'Exclusions'; Expression = { Get-ExclusionCount $_ } }
    @{ Name = 'Other values'; Expression = { @($_.Settings | Where-Object { $_.Active -and -not $_.ExclusionType }).Count } }
    @{ Name = 'Applies to'; Expression = { $text = Get-DeploymentText $_; if ($text.Length -gt 60) { $text.Substring(0, 57) + '...' } else { $text } } }
) | Out-String -Width 200 | Write-Host

Write-Host "$($matrixRows.Count) unique exclusions across $($policies.Count) policies."
if ($failed.Count) { Write-Warning "$($failed.Count) policy export(s) failed - see the report." }
Write-Host "Report : $reportPath"
Write-Host "CSV    : $(Join-Path $OutputPath 'Exclusions.csv')"
Write-Host "         $(Join-Path $OutputPath 'AllSettings.csv')"
if ($siteMode) { Write-Host "XML    : $xmlFolder" }

#endregion
