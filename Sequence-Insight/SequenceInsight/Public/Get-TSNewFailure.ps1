function Get-TSNewFailure {
    <#
    .SYNOPSIS
        Detects runs that have newly transitioned to failed since the last refresh (drives alerts).

    .DESCRIPTION
        Compares the current failed runs against a set of previously-seen failed-run keys and returns
        the newly-failed runs plus the complete current failed-key set (so the caller can update its
        baseline for the next comparison). Pure - no notification side effects here.

    .PARAMETER PreviousFailedKeys
        Failed-run keys seen on the previous refresh (empty on first run).

    .PARAMETER Current
        The current run objects.

    .OUTPUTS
        [pscustomobject] with NewFailures (array of runs) and AllFailedKeys (array of strings).
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$PreviousFailedKeys = @(),
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Current
    )

    $prev = @{}
    foreach ($k in $PreviousFailedKeys) { $prev[$k] = $true }

    $allKeys = New-Object System.Collections.Generic.List[string]
    $new     = New-Object System.Collections.Generic.List[object]

    foreach ($run in ($Current | Where-Object { $_.Status -eq 'Error' })) {
        $key = '{0}|{1}|{2}' -f $run.Computer, $run.TaskSequence, $run.StartedUtc
        $allKeys.Add($key)
        if (-not $prev.ContainsKey($key)) { $new.Add($run) }
    }

    # Use .ToArray() rather than @() - wrapping a List[object] of PSCustomObjects in @() throws
    # "Argument types do not match" on PowerShell 7.5.
    return [pscustomobject]@{
        NewFailures   = $new.ToArray()
        AllFailedKeys = $allKeys.ToArray()
    }
}
