#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

<#
    Pester suite for Export-CMDefenderPolicies.ps1.

    Run it with:
        Invoke-Pester -Path .\Tests -Output Detailed

    Nothing here needs Configuration Manager. Unit tests dot-source the script, which defines
    its functions and stops before doing any work. End-to-end tests run it against the
    exports in Tests\Fixtures: offline mode as is, site mode with the three ConfigMgr cmdlets
    it calls replaced by stubs and a FileSystem drive standing in for the CMSite drive.

    The GPO mapping tests read the local C:\Windows\PolicyDefinitions\WindowsDefender.admx and
    are skipped where it is missing.
#>

BeforeDiscovery {
    $HasAdmx = Test-Path (Join-Path $env:windir 'PolicyDefinitions\WindowsDefender.admx')
}

BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Export-CMDefenderPolicies.ps1'
    $script:Fixtures = Join-Path $PSScriptRoot 'Fixtures'
    $script:LocalAdmx = Join-Path $env:windir 'PolicyDefinitions'
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "cmdefender-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TestRoot | Out-Null

    # Dot-sourcing defines the functions and the English text table, and runs nothing.
    . $script:ScriptPath

    function Invoke-Export {
        param([hashtable]$Arguments)
        $warnings = $null
        & $script:ScriptPath @Arguments -WarningVariable warnings -WarningAction SilentlyContinue 6>$null | Out-Null
        , @($warnings)
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Text tables' {
    It 'defines the same keys in every language' {
        $english = @($Strings.en.Keys | Sort-Object)
        $swedish = @($Strings.sv.Keys | Sort-Object)
        Compare-Object $english $swedish | Should -BeNullOrEmpty
    }

    It 'has as many CSV headers in every language' {
        $Strings.sv.CsvExclusions.Count | Should -Be $Strings.en.CsvExclusions.Count
        $Strings.sv.CsvSettings.Count | Should -Be $Strings.en.CsvSettings.Count
    }
}

Describe 'Esc' {
    It 'escapes markup and quotes but leaves non-ASCII text readable' {
        Esc 'a & <b> "c" ''d'' åäö ›' | Should -BeExactly 'a &amp; &lt;b&gt; &quot;c&quot; &#39;d&#39; åäö ›'
    }

    It 'turns $null into an empty string' {
        Esc $null | Should -BeExactly ''
    }
}

Describe 'Policy XML' {
    It 'maps the ConfigMgr key to the Defender policy key' {
        ConvertTo-DefenderKey 'SOFTWARE\Policies\Microsoft\Microsoft Antimalware\Exclusions\Paths' |
            Should -Be 'SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions\Paths'
        ConvertTo-DefenderKey 'HKLM\SOFTWARE\Policies\Microsoft\Microsoft Antimalware' |
            Should -Be 'SOFTWARE\Policies\Microsoft\Windows Defender'
    }

    It 'leaves keys outside the antimalware branch alone' {
        ConvertTo-DefenderKey 'SOFTWARE\Policies\Microsoft\Microsoft AntimalwareX\Scan' |
            Should -Be 'SOFTWARE\Policies\Microsoft\Microsoft AntimalwareX\Scan'
    }

    It 'reads name, values and the Disabled flag of a single value' {
        $parsed = Read-AntimalwarePolicyXml (Join-Path $Fixtures 'Servers - SQL (16777300).xml')
        $parsed.IsPolicy | Should -BeTrue
        $parsed.Name | Should -Be 'Servers - SQL'
        ($parsed.Entries | Where-Object ValueName -eq 'C:\Old\Removed\').Active | Should -BeFalse
        ($parsed.Entries | Where-Object ValueName -eq 'D:\SQLData\').Active | Should -BeTrue
    }

    It 'treats every value in a disabled section as inactive' {
        $parsed = Read-AntimalwarePolicyXml (Join-Path $Fixtures 'Scheduled scan only (16777302).xml')
        $parsed.Entries.Count | Should -BeGreaterThan 0
        @($parsed.Entries | Where-Object Active).Count | Should -Be 0
    }

    It 'recognises a file that is not a policy export' {
        (Read-AntimalwarePolicyXml (Join-Path $Fixtures 'not-a-policy.xml')).IsPolicy | Should -BeFalse
    }

    It 'groups exclusions by type, drops inactive ones and de-duplicates case-insensitively' {
        $parsed = Read-AntimalwarePolicyXml (Join-Path $Fixtures 'Servers - SQL (16777300).xml')
        $model = ConvertTo-PolicyModel $parsed $null
        @($model.Exclusions.Keys) | Should -Be @('Paths', 'Extensions', 'Processes')
        $model.Exclusions['Paths'] | Should -Not -Contain 'C:\Old\Removed\'
        $model.Exclusions['Extensions'].Count | Should -Be 4    # .mdf and .MDF are one exclusion
    }
}

Describe 'GPO mapping' -Skip:(-not $HasAdmx) {
    BeforeAll {
        $script:Index = Get-DefenderAdmxIndex $LocalAdmx
        $script:Base = 'SOFTWARE\Policies\Microsoft\Windows Defender'
    }

    It 'finds the exclusion lists and reads them as additive' {
        $list = $Index.Lists["$($Base.ToLowerInvariant())\exclusions\paths"]
        $list.Setting.Name | Should -Be 'Path Exclusions'
        $list.Additive | Should -BeTrue
    }

    It 'takes polarity from the ADMX: <ValueName> = <Value> is <Expected>' -ForEach @(
        @{ Key = 'Real-Time Protection'; ValueName = 'DisableRealtimeMonitoring'; Value = '0'; Expected = 'Disabled' }
        @{ Key = 'Real-Time Protection'; ValueName = 'DisableBehaviorMonitoring'; Value = '0'; Expected = 'Enabled' }
        @{ Key = 'Scan'; ValueName = 'DisableArchiveScanning'; Value = '0'; Expected = 'Enabled' }
    ) {
        (Resolve-GpoSetting $Index "$Base\$Key" $ValueName $Value).State | Should -Be $Expected
    }

    It 'matches registry keys case-insensitively (ConfigMgr writes "Real-time protection")' {
        (Resolve-GpoSetting $Index "$Base\Real-time protection" 'DisableRealtimeMonitoring' '1').State | Should -Be 'Enabled'
    }

    It 'names the drop-down option' {
        (Resolve-GpoSetting $Index "$Base\Scan" 'ScanParameters' '2').State | Should -BeLike '*Full*'
    }

    It 'decodes threat severity and action' {
        (Resolve-GpoSetting $Index "$Base\Threats\ThreatSeverityDefaultAction" '5' '3').State |
            Should -BeLike '*5 (Severe) = 3 (Remove)*'
    }

    It 'returns nothing for a ConfigMgr-only value' {
        Resolve-GpoSetting $Index "$Base\Signature Updates" 'AuGracePeriod' '4320' | Should -BeNullOrEmpty
    }

    It 'treats an empty text value as Not configured' {
        (Resolve-GpoSetting $Index "$Base\Signature Updates" 'DefinitionUpdateFileSharesSources' '').State |
            Should -BeLike 'Not configured*'
    }
}

Describe 'Connect-CMSiteDrive' {
    It 'uses the only site drive in the session' {
        Mock Get-PSDrive { [pscustomobject]@{ Name = 'PS1' } } -ParameterFilter { $PSProvider -eq 'CMSite' }
        Connect-CMSiteDrive '' '' | Should -Be 'PS1'
    }

    It 'refuses to guess between several site drives' {
        Mock Get-PSDrive { [pscustomobject]@{ Name = 'PS1' }; [pscustomobject]@{ Name = 'PS2' } } -ParameterFilter { $PSProvider -eq 'CMSite' }
        { Connect-CMSiteDrive '' '' } | Should -Throw '*-SiteCode*'
    }

    It 'asks for the site when there is no drive' {
        Mock Get-PSDrive { } -ParameterFilter { $PSProvider -eq 'CMSite' }
        { Connect-CMSiteDrive '' '' } | Should -Throw '*-SiteCode and -ProviderMachineName*'
    }

    It 'asks for the provider when the named site has no drive yet' {
        Mock Get-PSDrive { } -ParameterFilter { $Name -eq 'ZZ9' }
        { Connect-CMSiteDrive 'ZZ9' '' } | Should -Throw '*-ProviderMachineName*'
    }
}

Describe 'Offline run' {
    BeforeAll {
        $script:Out = Join-Path $TestRoot 'offline-en'
        $script:Warnings = Invoke-Export @{ XmlPath = $Fixtures; OutputPath = $Out; AdmxPath = $LocalAdmx; CsvDelimiter = ';' }
        $script:Html = Get-Content (Join-Path $Out 'Report.html') -Raw -Encoding UTF8
        $script:Exclusions = @(Import-Csv (Join-Path $Out 'Exclusions.csv') -Delimiter ';' -Encoding UTF8)
        $script:Settings = @(Import-Csv (Join-Path $Out 'AllSettings.csv') -Delimiter ';' -Encoding UTF8)
    }

    It 'writes the report and both CSV files' {
        foreach ($file in 'Report.html', 'Exclusions.csv', 'AllSettings.csv') {
            Join-Path $Out $file | Should -Exist
        }
    }

    It 'skips a file that is not a policy export, with a warning' {
        $Warnings -join "`n" | Should -BeLike '*not-a-policy.xml*'
    }

    It 'has one CSV row per policy and active exclusion' {
        $Exclusions.Count | Should -Be 17
        @($Exclusions | Where-Object Exclusion -eq 'C:\Old\Removed\').Count | Should -Be 0
    }

    It 'counts unique exclusions across policies case-insensitively' {
        ([regex]::Matches($Html, '<tr[^>]* data-x=')).Count | Should -Be 12
        ($Exclusions | Where-Object { $_.Exclusion -eq '%windir%\Security\Database\*.edb' } | Select-Object -First 1).'Policies sharing it' | Should -Be 3
    }

    It 'sorts the default policy last' {
        $Exclusions[-1].Policy | Should -Be 'Default Client Antimalware Policy'
    }

    It 'HTML-encodes policy names' {
        # Contains(), not -like: [VDI] would be a wildcard character class.
        $Html.Contains('Workstations &amp; [VDI] &lt;test&gt;') | Should -BeTrue
        $Html.Contains('<test>') | Should -BeFalse
    }

    It 'writes the report in English with an encoded CRLF in the copy data' {
        $Html | Should -BeLike '*<html lang="en">*'
        $Html | Should -BeLike '*data-copy="*&#13;&#10;*'
    }

    It 'keeps CSV columns aligned when a value has no GPO counterpart' -Skip:(-not $HasAdmx) {
        $row = $Settings | Where-Object 'Value name' -eq 'AuGracePeriod'
        $row.'GPO setting' | Should -BeNullOrEmpty
        $row.Remark | Should -Be $Strings.en.NoteNoAdmx
    }

    It 'flags ConfigMgr as an update source' {
        ($Settings | Where-Object 'Value name' -eq 'FallbackOrder').Remark | Should -Be $Strings.en.NoteFromCM
    }
}

Describe 'Offline run in Swedish with a comma delimiter' {
    BeforeAll {
        $script:Out = Join-Path $TestRoot 'offline-sv'
        Invoke-Export @{ XmlPath = $Fixtures; OutputPath = $Out; AdmxPath = $LocalAdmx; Language = 'sv'; CsvDelimiter = ',' } | Out-Null
        $script:Html = Get-Content (Join-Path $Out 'Report.html') -Raw -Encoding UTF8
    }

    It 'writes the report in Swedish' {
        $Html | Should -BeLike '*<html lang="sv">*'
        $Html | Should -BeLike "*$($Strings.sv.GuideTitle)*"
    }

    It 'uses Swedish CSV headers and the requested delimiter' {
        $header = (Get-Content (Join-Path $Out 'Exclusions.csv') -Encoding UTF8 -TotalCount 1)
        $header | Should -Be (($Strings.sv.CsvExclusions | ForEach-Object { '"' + $_ + '"' }) -join ',')
    }
}

Describe 'Site mode with stubbed ConfigMgr cmdlets' {
    BeforeAll {
        $global:CMFixtures = $Fixtures
        $global:CMQueries = New-Object System.Collections.Generic.List[string]
        New-PSDrive -Name TS1 -PSProvider FileSystem -Root $TestRoot -Scope Global | Out-Null

        function global:Get-CMAntimalwarePolicy {
            [pscustomobject]@{ Name = 'Default Client Antimalware Policy'; SettingsID = [uint32]16777216; Priority = [uint32]10000; Description = 'Default'; DateModified = [datetime]'2024-05-01 10:00'; LastModifiedBy = 'CONTOSO\cmadmin'; AssignmentCount = [uint32]0 }
            [pscustomobject]@{ Name = 'Servers - SQL'; SettingsID = [uint32]16777300; Priority = [uint32]1; Description = 'SQL Server'; DateModified = [datetime]'2025-02-03 08:30'; LastModifiedBy = 'CONTOSO\bob'; AssignmentCount = [uint32]2 }
            [pscustomobject]@{ Name = 'Workstations & [VDI] <test>'; SettingsID = [uint32]16777301; Priority = [uint32]2; Description = ''; DateModified = [datetime]'2023-11-20 14:12'; LastModifiedBy = 'CONTOSO\alice'; AssignmentCount = [uint32]1 }
            [pscustomobject]@{ Name = 'Scheduled scan only'; SettingsID = [uint32]16777302; Priority = [uint32]3; Description = ''; DateModified = [datetime]'2022-01-01 00:00'; LastModifiedBy = 'CONTOSO\alice'; AssignmentCount = [uint32]0 }
            [pscustomobject]@{ Name = 'Broken policy'; SettingsID = [uint32]16777303; Priority = [uint32]4; Description = ''; DateModified = [datetime]'2022-01-01 00:00'; LastModifiedBy = 'CONTOSO\alice'; AssignmentCount = [uint32]0 }
        }

        function global:Export-CMAntimalwarePolicy {
            param([string]$Id, [string]$Path, [switch]$Force)
            if ((Get-Location).Drive.Name -ne 'TS1') { throw 'Export called outside the site drive' }
            if (-not [System.IO.Path]::IsPathRooted($Path)) { throw "Relative export path: $Path" }
            $map = @{
                '16777216' = 'Default Client Antimalware Policy (16777216).xml'
                '16777300' = 'Servers - SQL (16777300).xml'
                '16777301' = 'Workstations (16777301).xml'
                '16777302' = 'Scheduled scan only (16777302).xml'
            }
            if (-not $map.ContainsKey($Id)) { throw "Simulated failure: policy $Id could not be exported" }
            Copy-Item -LiteralPath (Join-Path $global:CMFixtures $map[$Id]) -Destination $Path
        }

        function global:Invoke-CMWmiQuery {
            param([string]$Query, $Option)
            $global:CMQueries.Add($Query)
            if ($Query -like '*SMS_ClientSettingsAssignment*') {
                [pscustomobject]@{ ClientSettingsID = [uint32]16777300; CollectionID = 'PS100123'; CollectionName = 'SRV - SQL Prod' }
                [pscustomobject]@{ ClientSettingsID = [uint32]16777300; CollectionID = 'PS100124'; CollectionName = 'SRV - SQL Test' }
                [pscustomobject]@{ ClientSettingsID = [uint32]16777301; CollectionID = 'PS100200'; CollectionName = 'WS - All VDI' }
                [pscustomobject]@{ ClientSettingsID = [uint32]1; CollectionID = 'SMS00001'; CollectionName = 'All Systems' }
            }
            elseif ($Query -like '*FROM SMS_Collection WHERE*') {
                $counts = @{ PS100123 = 14; PS100124 = 3; PS100200 = 412; SMS00001 = 5000 }
                foreach ($id in $counts.Keys) {
                    if ($Query -like "*CollectionID = '$id'*") { [pscustomobject]@{ CollectionID = $id; MemberCount = [uint32]$counts[$id] } }
                }
            }
        }

        $script:Out = Join-Path $TestRoot 'site'
        Push-Location $TestRoot
        try {
            $script:Warnings = Invoke-Export @{ SiteCode = 'TS1'; OutputPath = $Out; AdmxPath = $LocalAdmx; CsvDelimiter = ';' }
            $script:LocationAfter = (Get-Location).Path
        }
        finally { Pop-Location }
        $script:Html = Get-Content (Join-Path $Out 'Report.html') -Raw -Encoding UTF8
        $script:Exclusions = @(Import-Csv (Join-Path $Out 'Exclusions.csv') -Delimiter ';' -Encoding UTF8)
    }

    AfterAll {
        Remove-Item -Path 'function:Get-CMAntimalwarePolicy', 'function:Export-CMAntimalwarePolicy', 'function:Invoke-CMWmiQuery' -ErrorAction SilentlyContinue
        Remove-PSDrive -Name TS1 -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name CMFixtures, CMQueries -Scope Global -ErrorAction SilentlyContinue
    }

    It 'exports every policy from the site drive to an absolute path' {
        @(Get-ChildItem (Join-Path $Out 'ConfigMgr-XML') -Filter *.xml).Count | Should -Be 4
    }

    It 'reports a failed export without stopping the run' {
        $Warnings -join "`n" | Should -BeLike "*Export of 'Broken policy' failed*"
        $Html | Should -BeLike "*$($Strings.en.ChipExportFailed)*"
    }

    It 'returns to the original location' {
        $LocationAfter | Should -Be $TestRoot
    }

    It 'reads deployments and member counts' {
        ($Exclusions | Where-Object Policy -eq 'Servers - SQL' | Select-Object -First 1).'Deployed to' |
            Should -Be 'SRV - SQL Prod (PS100123); SRV - SQL Test (PS100124)'
        $Html | Should -BeLike '*PS100123 · 14 devices*'
    }

    It 'ignores client settings assignments that belong to no antimalware policy' {
        $Html | Should -Not -BeLike '*All Systems*'
    }

    It 'tags policies without deployments' {
        ($Exclusions | Where-Object Policy -eq 'Default Client Antimalware Policy' | Select-Object -First 1).'Deployed to' |
            Should -Be $Strings.en.DeployDefault
        ([regex]::Matches($Html, [regex]::Escape($Strings.en.DeployNone))).Count | Should -BeGreaterThan 1
    }

    It 'queries member counts only for the assigned collections' {
        $CMQueries[1] | Should -BeLike "*CollectionID = 'PS100123' OR *"
    }
}
