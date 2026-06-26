@{
    # PSScriptAnalyzer settings for Sequence Insight.
    # PSUseOutputTypeCorrectly is informational and noisy for a helper-heavy module; the rest are kept.
    IncludeDefaultRules = $true
    Severity            = @('Error', 'Warning', 'Information')
    ExcludeRules        = @(
        'PSUseOutputTypeCorrectly'
    )
}
