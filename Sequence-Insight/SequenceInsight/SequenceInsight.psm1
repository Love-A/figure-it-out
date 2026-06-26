# SequenceInsight.psm1 - module loader.
# Dot-sources Private (internal) then Public (exported) function files. Public function names are
# exported by the manifest (FunctionsToExport); this loader exports them too for direct import.

$ErrorActionPreference = 'Stop'

$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($private + $public)) {
    try {
        . $file.FullName
    } catch {
        throw "Failed to load $($file.FullName): $_"
    }
}

# Module-wide session context set by Connect-SequenceInsight.
$script:SequenceInsightContext = $null

Export-ModuleMember -Function $public.BaseName
