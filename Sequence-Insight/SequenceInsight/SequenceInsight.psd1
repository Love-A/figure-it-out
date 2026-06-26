@{
    RootModule        = 'SequenceInsight.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b3f2c9a4-7d51-4e62-9c3a-2f8e1d6b40a7'
    Author            = 'Love Arvidsson'
    CompanyName       = 'Community'
    Copyright         = 'Copyright (c) 2026 Love Arvidsson. Licensed under the MIT License.'
    Description       = 'Sequence Insight - data layer for a modern, dependency-free ConfigMgr task-sequence monitor: AdminService + SQL providers, normalization, and standalone HTML/CSV/JSON reporting. An independent homage to the SMSAgentSoftware ConfigMgr Task Sequence Monitor (1.6); not affiliated or endorsed.'

    # WPF and System.Data.SqlClient are available on Windows PowerShell 5.1; the module is also 7-compatible.
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Connect-SequenceInsight'
        'Get-TSList'
        'Get-TSExecution'
        'Get-TSStepOutput'
        'Get-TSRun'
        'Get-TSStatusFeed'
        'Get-TSStepBaseline'
        'Get-TSAnalytics'
        'Add-TSLiveInfo'
        'Get-TSNewFailure'
        'Export-TSReport'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('ConfigMgr', 'SCCM', 'MEMCM', 'TaskSequence', 'OSD', 'Monitoring', 'AdminService')
            LicenseUri = 'https://opensource.org/licenses/MIT'
            # Inspired by (homage to) SMSAgentSoftware's ConfigMgr Task Sequence Monitor; not affiliated.
            ReleaseNotes = '1.0.0 - Sequence Insight: a modern, dependency-free homage to the ConfigMgr Task Sequence Monitor. AdminService + SQL hybrid data layer, MDT removed, dependency-free WPF UI, dark mode, fleet analytics, live %-complete, CSV/JSON/HTML export.'
        }
    }
}
