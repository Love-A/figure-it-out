# Logging.ps1 - module-internal logging
# Adapted from the Write-Log pattern in Start-OSDForm.ps1 (host-stream only, never the pipeline).

$script:TSLogFile = $null

function Set-TSLogFile {
    <#
    .SYNOPSIS
        Sets the file that Write-TSLog appends to. Falls back to %TEMP% if unwritable.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets a module-internal log-path variable; no external/system state change.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $script:TSLogFile = $Path
}

function Write-TSLog {
    <#
    .SYNOPSIS
        Writes a timestamped log line to the configured log file and the host stream.

    .DESCRIPTION
        Uses Write-Host so the success/pipeline stream is never polluted (important because
        these functions are called from runspaces whose output is data, not log noise).
        Logging never throws: a failed file write falls back to %TEMP%, then is swallowed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Intentional host-stream logging so the success/pipeline stream stays clean (repo Write-Log pattern; required for runspace callers).')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Logging must never throw; the final %TEMP% fallback intentionally swallows.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO',

        [switch]$NoConsole
    )

    if (-not $script:TSLogFile) {
        $script:TSLogFile = Join-Path $env:TEMP 'Sequence-Insight.log'
    }

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    try {
        Add-Content -LiteralPath $script:TSLogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        try {
            $script:TSLogFile = Join-Path $env:TEMP 'Sequence-Insight.log'
            Add-Content -LiteralPath $script:TSLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
    }

    if (-not $NoConsole) {
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'DEBUG' { Write-Host $line -ForegroundColor DarkGray }
            default { Write-Host $line }
        }
    }
}
