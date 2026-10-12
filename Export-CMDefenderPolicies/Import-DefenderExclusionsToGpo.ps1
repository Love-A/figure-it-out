#Requires -Version 5.1
<#
.SYNOPSIS
    Writes the exclusions from an Export-CMDefenderPolicies Exclusions.csv into a GPO.

.DESCRIPTION
    The Group Policy editor's Show... dialog does not take a multi-row paste, so long
    exclusion lists are slow to enter by hand. This script adds them with Set-GPRegistryValue:
    the same registry.pol entries the editor writes for Path, Extension and Process
    Exclusions (value name = the exclusion, REG_SZ "0"), plus the DWORD that switches each
    used setting to Enabled (Exclusions_Paths = 1 and so on).

    Additive and idempotent. Values already in the GPO are left alone and nothing is
    removed, so running it again after a new export only adds what is new. The GPO is never
    linked. Supports -WhatIf.

    The CSV's headers follow the export's -Language, so columns are read by position:
    Policy (1st), Exclusion (4th), Registry key (8th). Any delimiter the export wrote works.

.PARAMETER CsvPath
    Exclusions.csv written by Export-CMDefenderPolicies.ps1.

.PARAMETER GpoName
    GPO to write to.

.PARAMETER Policy
    Only take exclusions from ConfigMgr policies whose name matches one of these patterns
    (wildcards allowed). Default: all policies in the CSV.

.PARAMETER Create
    Create the GPO if it does not exist. It is created unlinked.

.PARAMETER Domain
    Domain of the GPO (FQDN). Default: the current user's domain.

.PARAMETER Server
    Domain controller to talk to. Default: the PDC emulator, as the GroupPolicy module chooses.

.EXAMPLE
    .\Import-DefenderExclusionsToGpo.ps1 -CsvPath .\DefenderPolicyExport-20261012-1405\Exclusions.csv -GpoName 'Defender - Exclusions - SQL' -Policy 'Servers - SQL*' -Create -WhatIf

    Shows what would be created and added, without touching anything.

.EXAMPLE
    .\Import-DefenderExclusionsToGpo.ps1 -CsvPath .\Exclusions.csv -GpoName 'Defender - Exclusions - Baseline' -Policy 'Default Client Antimalware Policy' -Create

.NOTES
    Version : 1.0.0
    Author  : Love A
    License : MIT
    Requires: the GroupPolicy module (RSAT: Group Policy Management Tools) and the right to
              edit the GPO (and to create GPOs, with -Create).
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive next-step hint after the summary objects.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$GpoName,

    [ValidateNotNullOrEmpty()]
    [string[]]$Policy = '*',

    [switch]$Create,

    [string]$Domain,

    [string]$Server
)

$ErrorActionPreference = 'Stop'
$ExclusionsKey = 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions'
$SettingNames = @{ Paths = 'Path Exclusions'; Extensions = 'Extension Exclusions'; Processes = 'Process Exclusions'; IpAddresses = 'Ip Address Exclusions' }

function Read-ExclusionCsv([string]$Path) {
    # Headers are localised, so read by position: 0 = Policy, 3 = Exclusion, 7 = Registry key.
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    if ($lines.Count -lt 2) { return @() }
    if ($lines[0] -notmatch '^"[^"]*"(.)') { throw "$Path does not look like a CSV written by Export-CMDefenderPolicies." }
    $delimiter = $Matches[1]

    foreach ($row in ($lines | ConvertFrom-Csv -Delimiter $delimiter)) {
        $values = @($row.PSObject.Properties | ForEach-Object { [string]$_.Value })
        if ($values.Count -lt 8 -or $values[7] -notlike "$ExclusionsKey\*") {
            throw "$Path is not an Exclusions.csv from Export-CMDefenderPolicies (column 8 should be a registry key under $ExclusionsKey)."
        }
        [pscustomobject]@{
            Policy = $values[0]
            Value  = $values[3]
            Key    = $values[7]
            Type   = Split-Path $values[7] -Leaf
        }
    }
}

function Get-ExistingValueName($GpoId, [string]$Key, [hashtable]$GpParams) {
    # Get-GPRegistryValue throws when the key holds nothing yet.
    try {
        @(Get-GPRegistryValue -Guid $GpoId -Key $Key @GpParams -ErrorAction Stop |
            Where-Object { $_.ValueName -and $_.PolicyState -ne 'Delete' } | ForEach-Object ValueName)
    }
    catch { @() }
}

# Dot-sourcing defines the functions above and stops here (Pester).
if ($MyInvocation.InvocationName -eq '.') { return }

if (-not (Get-Command Set-GPRegistryValue -ErrorAction SilentlyContinue)) {
    Import-Module GroupPolicy -ErrorAction Stop
}
$gpParams = @{}
if ($Domain) { $gpParams.Domain = $Domain }
if ($Server) { $gpParams.Server = $Server }

$entries = @(Read-ExclusionCsv (Resolve-Path -LiteralPath $CsvPath).ProviderPath)
$selected = @($entries | Where-Object { $policyName = $_.Policy; $Policy.Where({ $policyName -like $_ }).Count })
if (-not $selected) {
    $available = ($entries.Policy | Sort-Object -Unique) -join "', '"
    throw "No exclusions in $CsvPath match -Policy '$($Policy -join "', '")'. Policies in the file: '$available'."
}

$gpo = $null
try { $gpo = Get-GPO -Name $GpoName @gpParams -ErrorAction Stop }
catch {
    # "Not found" is an ArgumentException (GpoWithNameNotFound); anything else, e.g. no DC, is real.
    if (-not ($_.Exception -is [System.ArgumentException] -or $_.FullyQualifiedErrorId -like 'GpoWithNameNotFound*')) { throw }
}
if (-not $gpo) {
    if (-not $Create) { throw "GPO '$GpoName' was not found. Add -Create to create it (it is created unlinked)." }
    if ($PSCmdlet.ShouldProcess($GpoName, 'Create GPO (unlinked)')) {
        $gpo = New-GPO -Name $GpoName -Comment "Defender exclusions imported from $(Split-Path $CsvPath -Leaf) by Import-DefenderExclusionsToGpo.ps1" @gpParams
    }
}

foreach ($group in ($selected | Group-Object Key | Sort-Object Name)) {
    $key = $group.Name
    $type = $group.Group[0].Type
    $setting = if ($SettingNames.ContainsKey($type)) { $SettingNames[$type] } else { $type }

    # Defender compares exclusions case-insensitively; so does this.
    $existing = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($gpo) { foreach ($name in (Get-ExistingValueName $gpo.Id $key $gpParams)) { [void]$existing.Add($name) } }
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $new = New-Object System.Collections.Generic.List[string]
    foreach ($value in $group.Group.Value) {
        if ($wanted.Add($value) -and -not $existing.Contains($value)) { $new.Add($value) }
    }

    if ($new.Count -and $PSCmdlet.ShouldProcess("$GpoName : $setting", "Add $($new.Count) exclusion(s): $($new -join '; ')")) {
        # Switch the policy to Enabled - the editor writes this DWORD next to the list.
        Set-GPRegistryValue -Guid $gpo.Id -Key $ExclusionsKey -ValueName "Exclusions_$type" -Type DWord -Value 1 @gpParams | Out-Null
        # One call per 100 values: each call bumps the GPO version and rewrites registry.pol.
        for ($i = 0; $i -lt $new.Count; $i += 100) {
            $chunk = [string[]]$new.GetRange($i, [Math]::Min(100, $new.Count - $i))
            Set-GPRegistryValue -Guid $gpo.Id -Key $key -ValueName $chunk -Type String -Value ([string[]](@('0') * $chunk.Count)) @gpParams | Out-Null
        }
    }

    [pscustomobject]@{
        Gpo            = $GpoName
        Setting        = $setting
        Added          = $new.Count
        AlreadyPresent = $wanted.Count - $new.Count
        Key            = $key
    }
}

if (-not $WhatIfPreference) {
    Write-Host "Done. '$GpoName' is not linked: check Path/Extension/Process Exclusions in GPMC, then link it to a pilot OU."
}
