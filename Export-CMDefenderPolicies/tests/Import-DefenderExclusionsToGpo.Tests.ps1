#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

<#
    Pester suite for Import-DefenderExclusionsToGpo.ps1.

    Run it with:
        Invoke-Pester -Path .\Tests -Output Detailed

    No domain needed. The input is a real Exclusions.csv, written by running
    Export-CMDefenderPolicies.ps1 offline against Tests\Fixtures (in English with ';' and in
    Swedish with ','). The four GroupPolicy cmdlets the script calls are stubs, mocked per test.
    What these tests cannot show is how a real Group Policy editor displays the result.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:ImportScript = Join-Path $Root 'Import-DefenderExclusionsToGpo.ps1'
    $script:ExportScript = Join-Path $Root 'Export-CMDefenderPolicies.ps1'
    $script:Fixtures = Join-Path $PSScriptRoot 'Fixtures'
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "cmdefender-import-$([guid]::NewGuid().ToString('N'))"
    $script:ExclKey = 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions'
    $script:GpoId = [guid]'11111111-2222-3333-4444-555555555555'
    New-Item -ItemType Directory -Path $TestRoot | Out-Null

    foreach ($run in @(@{ Name = 'en'; Language = 'en'; Delimiter = ';' }, @{ Name = 'sv'; Language = 'sv'; Delimiter = ',' })) {
        & $ExportScript -XmlPath $Fixtures -OutputPath (Join-Path $TestRoot $run.Name) -AdmxPath (Join-Path $env:windir 'PolicyDefinitions') `
            -Language $run.Language -CsvDelimiter $run.Delimiter -WarningAction SilentlyContinue 6>$null | Out-Null
    }
    $script:CsvEn = Join-Path $TestRoot 'en\Exclusions.csv'
    $script:CsvSv = Join-Path $TestRoot 'sv\Exclusions.csv'
    $script:SettingsCsv = Join-Path $TestRoot 'en\AllSettings.csv'

    # A list long enough to need several Set-GPRegistryValue calls.
    $script:CsvBig = Join-Path $TestRoot 'big.csv'
    $lines = @('"Policy";"Order";"Type";"Exclusion";"Policies sharing it";"Deployed to";"GPO setting";"Registry key";"Value"')
    $lines += 1..250 | ForEach-Object { """Big"";""1"";""Path"";""D:\Data\Folder$_\"";""1"";""-"";""Path Exclusions"";""$ExclKey\Paths"";""0""" }
    Set-Content -LiteralPath $CsvBig -Value $lines -Encoding UTF8

    # Stand-ins for the GroupPolicy module, advanced so they take -ErrorAction like the real ones.
    function global:Get-GPO { [CmdletBinding()] param([string]$Name, $Guid, [string]$Domain, [string]$Server) }
    function global:New-GPO { [CmdletBinding()] param([string]$Name, [string]$Comment, [string]$Domain, [string]$Server) }
    function global:Get-GPRegistryValue { [CmdletBinding()] param($Guid, [string]$Name, [string]$Key, [string[]]$ValueName, [string]$Domain, [string]$Server) }
    function global:Set-GPRegistryValue { [CmdletBinding()] param($Guid, [string]$Name, [string]$Key, [string[]]$ValueName, [string]$Type, $Value, [string]$Domain, [string]$Server) }

    . $ImportScript -CsvPath 'unused' -GpoName 'unused'

    function Invoke-Import {
        param([hashtable]$Arguments)
        @(& $ImportScript @Arguments 6>$null)
    }
}

AfterAll {
    Remove-Item -Path 'function:Get-GPO', 'function:New-GPO', 'function:Get-GPRegistryValue', 'function:Set-GPRegistryValue' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Read-ExclusionCsv' {
    It 'reads an English export by position' {
        $rows = @(Read-ExclusionCsv $CsvEn)
        $rows.Count | Should -Be 17
        @($rows.Type | Sort-Object -Unique) | Should -Be @('Extensions', 'Paths', 'Processes')
        ($rows | Where-Object Value -eq 'sqlagent.exe').Key | Should -Be "$ExclKey\Processes"
    }

    It 'reads a Swedish export with another delimiter the same way' {
        $english = @(Read-ExclusionCsv $CsvEn | ForEach-Object { "$($_.Policy)|$($_.Key)|$($_.Value)" })
        $swedish = @(Read-ExclusionCsv $CsvSv | ForEach-Object { "$($_.Policy)|$($_.Key)|$($_.Value)" })
        Compare-Object $english $swedish | Should -BeNullOrEmpty
    }

    It 'refuses a CSV that is not an Exclusions.csv' {
        { Read-ExclusionCsv $SettingsCsv } | Should -Throw '*not an Exclusions.csv*'
    }
}

Describe 'Import into an existing GPO' {
    BeforeEach {
        Mock Get-GPO { [pscustomobject]@{ Id = $GpoId; DisplayName = $Name } }
        Mock New-GPO { }
        Mock Get-GPRegistryValue { throw 'The following key was not found' }
        Mock Set-GPRegistryValue { }
    }

    It 'adds every exclusion of the chosen policy and enables each setting' {
        $out = Invoke-Import @{ CsvPath = $CsvEn; GpoName = 'Test GPO'; Policy = 'Servers - SQL' }
        ($out | Where-Object Setting -eq 'Path Exclusions').Added | Should -Be 4
        ($out | Where-Object Setting -eq 'Extension Exclusions').Added | Should -Be 4
        ($out | Where-Object Setting -eq 'Process Exclusions').Added | Should -Be 2
        Should -Invoke Set-GPRegistryValue -Times 1 -Exactly -ParameterFilter { $Key -eq "$ExclKey\Paths" -and $Type -eq 'String' -and $ValueName.Count -eq 4 -and @($Value | Where-Object { $_ -ne '0' }).Count -eq 0 }
        Should -Invoke Set-GPRegistryValue -Times 1 -Exactly -ParameterFilter { $Key -eq $ExclKey -and $ValueName -eq 'Exclusions_Paths' -and $Type -eq 'DWord' -and $Value -eq 1 }
        Should -Invoke Set-GPRegistryValue -Times 1 -Exactly -ParameterFilter { $Key -eq $ExclKey -and $ValueName -eq 'Exclusions_Processes' }
        Should -Invoke New-GPO -Times 0
    }

    It 'leaves out values the GPO already has, case-insensitively' {
        Mock Get-GPRegistryValue -ParameterFilter { $Key -eq "$ExclKey\Paths" } { [pscustomobject]@{ ValueName = 'd:\sqldata\'; PolicyState = 'Set' } }
        $out = Invoke-Import @{ CsvPath = $CsvEn; GpoName = 'Test GPO'; Policy = 'Servers - SQL' }
        $paths = $out | Where-Object Setting -eq 'Path Exclusions'
        $paths.Added | Should -Be 3
        $paths.AlreadyPresent | Should -Be 1
        Should -Invoke Set-GPRegistryValue -Times 1 -Exactly -ParameterFilter { $Key -eq "$ExclKey\Paths" -and $ValueName -notcontains 'D:\SQLData\' -and $ValueName.Count -eq 3 }
    }

    It 'writes nothing with -WhatIf, but still reports what it would add' {
        $out = Invoke-Import @{ CsvPath = $CsvEn; GpoName = 'Test GPO'; Policy = 'Servers - SQL'; WhatIf = $true }
        ($out | Where-Object Setting -eq 'Path Exclusions').Added | Should -Be 4
        Should -Invoke Set-GPRegistryValue -Times 0
    }

    It 'merges every policy by default, one list per setting' {
        $out = Invoke-Import @{ CsvPath = $CsvEn; GpoName = 'Test GPO' }
        ($out | Where-Object Setting -eq 'Path Exclusions').Added | Should -Be 6
        Should -Invoke Set-GPRegistryValue -Times 3 -Exactly -ParameterFilter { $Type -eq 'String' }
    }

    It 'splits a long list into calls of at most 100 values' {
        $out = Invoke-Import @{ CsvPath = $CsvBig; GpoName = 'Test GPO' }
        $out.Added | Should -Be 250
        Should -Invoke Set-GPRegistryValue -Times 3 -Exactly -ParameterFilter { $Key -eq "$ExclKey\Paths" -and $ValueName.Count -le 100 }
    }

    It 'names the policies in the file when -Policy matches none' {
        { Invoke-Import @{ CsvPath = $CsvEn; GpoName = 'Test GPO'; Policy = 'Nope*' } } | Should -Throw '*Servers - SQL*'
    }
}

Describe 'A GPO that does not exist yet' {
    BeforeEach {
        Mock Get-GPO { throw [System.ArgumentException]::new('A GPO with the display name "Test GPO" could not be found.') }
        Mock New-GPO { [pscustomobject]@{ Id = $GpoId; DisplayName = $Name } }
        Mock Get-GPRegistryValue { throw 'The following key was not found' }
        Mock Set-GPRegistryValue { }
    }

    It 'is not created without -Create' {
        { Invoke-Import @{ CsvPath = $CsvEn; GpoName = 'Test GPO' } } | Should -Throw '*-Create*'
        Should -Invoke New-GPO -Times 0
    }

    It 'is created, unlinked, with -Create' {
        Invoke-Import @{ CsvPath = $CsvEn; GpoName = 'Test GPO'; Create = $true } | Out-Null
        Should -Invoke New-GPO -Times 1 -Exactly -ParameterFilter { $Name -eq 'Test GPO' }
        Should -Invoke Set-GPRegistryValue -Times 3 -Exactly -ParameterFilter { $Type -eq 'String' }
    }

    It 'is neither created nor written with -Create -WhatIf' {
        $out = Invoke-Import @{ CsvPath = $CsvEn; GpoName = 'Test GPO'; Create = $true; WhatIf = $true }
        ($out | Where-Object Setting -eq 'Path Exclusions').Added | Should -Be 6
        Should -Invoke New-GPO -Times 0
        Should -Invoke Set-GPRegistryValue -Times 0
    }

    It 'passes on errors other than "not found"' {
        Mock Get-GPO { throw [System.InvalidOperationException]::new('The server is not operational.') }
        { Invoke-Import @{ CsvPath = $CsvEn; GpoName = 'Test GPO'; Create = $true } } | Should -Throw '*not operational*'
        Should -Invoke New-GPO -Times 0
    }
}
