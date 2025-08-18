<#
    .SYNOPSIS
        Removes older ConfigMgr package versions (e.g., created by Driver Automation Tool),
        keeping the most recent N versions per package name.

    .DESCRIPTION
        1) Connects to a specified ConfigMgr site/provider.
        2) Finds packages matching a wildcard pattern (e.g., "BIOS Update - *").
        3) Groups by Name and considers only names with 2+ items (i.e., multiple versions).
        4) Lets you pick names via Out-GridView (or runs headless with -NoGui / -IncludeName).
        5) Sorts by Version (robust parsing); keeps the newest N (default 1) and removes the rest,
           either from a single DP or from the environment entirely.

    .PARAMETER SiteCode
        ConfigMgr site code (e.g., "P01").

    .PARAMETER ProviderMachineName
        Hostname/FQDN of the ConfigMgr provider.

    .PARAMETER DistributionPointName
        DP to remove older versions from. Required unless using -RemoveFromEnvironment.

    .PARAMETER PackageName
        Wildcard-friendly Name pattern (e.g., "BIOS Update - *").

    .PARAMETER RemoveFromEnvironment
        Remove older packages from ConfigMgr entirely (Remove-CMPackage) instead of from a DP.

    .PARAMETER KeepLatest
        Number of most recent versions to keep per package name. Default: 1.

    .PARAMETER NoGui
        Skip Out-GridView and process non-interactively.

    .PARAMETER IncludeName
        Optional wildcard to narrow which Names are processed after grouping
        (useful with -NoGui). Example: -IncludeName "*Latitude*".

    .PARAMETER NoConfirm
        Suppress confirmation prompts (both this script and underlying CM cmdlets).
        -WhatIf still works.

    .EXAMPLE
        # Dry-run on a DP (recommended first):
        .\Remove-CMPackageOldVersions.ps1 -SiteCode P01 -ProviderMachineName CM01 -DistributionPointName DP01 -PackageName "BIOS Update - *" -WhatIf

    .EXAMPLE
        # Remove from environment, keep latest two per name (with explicit Confirm):
        .\Remove-CMPackageOldVersions.ps1 -SiteCode P01 -ProviderMachineName CM01 -PackageName "BIOS Update - *" -RemoveFromEnvironment -KeepLatest 2 -Confirm

    .EXAMPLE
        # Run without any confirmations (fast clean-up on a DP):
        .\Remove-CMPackageOldVersions.ps1 -SiteCode P01 -ProviderMachineName CM01 -DistributionPointName DP01 -PackageName "BIOS Update - *" -NoConfirm

    .NOTES
        FileName : Remove-CMPackageOldVersions.ps1
        Author   : Love A
        Created  : 2025-02-21

    .VERSION
        2025-08-18 - 2.2 - Final pass: consistent English help/comments; ConfirmImpact 'Low';
                           single confirmation via ShouldContinue; proper "Skipped" logging;
                           forced array for $toRemove; colon-safe interpolation; code style polish.
        2025-02-21 - 2.1 - Added -KeepLatest/-NoGui/-IncludeName; robust version parsing;
                           SupportsShouldProcess (-WhatIf/-Confirm); headless path;
                           location reset on exit; logging aligned to house standard.
        2025-02-21 - 2.0 - Initial version.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param (
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
    [string]$SiteCode,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
    [string]$ProviderMachineName,

    [Parameter()][ValidateNotNullOrEmpty()]
    [string]$DistributionPointName,

    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
    [string]$PackageName,

    [switch]$RemoveFromEnvironment,

    [ValidateRange(1, 50)]
    [int]$KeepLatest = 1,

    [switch]$NoGui,

    [string]$IncludeName,

    [switch]$NoConfirm
)

#region Logging (house standard)
if (-not $script:foldername) {
    $script:foldername = try { [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) } catch { 'Remove-CMPackageOldVersions' }
}

function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [string]$LogFile = "$PSScriptRoot\$foldername.log",

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    # Create timestamp
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Build log message
    $logMessage = "[$timestamp] [$Level] $Message"

    # Write to log file
    Add-Content -Path $LogFile -Value $logMessage

    # Also output to console
    Write-Output $logMessage
}
#endregion Logging

#region Helpers
function Connect-CmEnvironment {
    <#
    .SYNOPSIS
        Connects to the specified ConfigMgr site/provider by creating a CMSite PSDrive and setting location.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$SiteCode,
        [Parameter(Mandatory)][string]$ProviderMachineName
    )

    if ((Get-Module ConfigurationManager) -eq $null) {
        Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" -ErrorAction Stop
    }

    if ((Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue) -eq $null) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName -ErrorAction Stop | Out-Null
    }

    Set-Location "$($SiteCode):\" -ErrorAction Stop
    Write-Log -Message "Connected to site ${SiteCode} (provider ${ProviderMachineName})" -Level INFO
}

function Get-ComparableVersion {
    <#
    .SYNOPSIS
        Returns a [Version] for robust sorting; falls back to 0.0 when parsing fails.
    #>
    param([string]$VersionString)

    $parsed = $null
    if ([Version]::TryParse($VersionString, [ref]$parsed)) { return $parsed }

    $digits = ($VersionString -replace '[^\d\.]', '')
    if ([string]::IsNullOrWhiteSpace($digits)) { return [Version]::new(0,0) }
    if ([Version]::TryParse($digits, [ref]$parsed)) { return $parsed }

    return [Version]::new(0,0)
}
#endregion Helpers

#region Core
function Invoke-CMPackageVersionCleanup {
    <#
    .SYNOPSIS
        Finds package names that have multiple versions and removes all but the latest N
        either from a DP or from the environment.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param (
        [Parameter(Mandatory)][string]$SiteCode,
        [Parameter(Mandatory)][string]$ProviderMachineName,
        [Parameter(Mandatory)][string]$PackageName,
        [string]$DistributionPointName,
        [switch]$RemoveFromEnvironment,
        [int]$KeepLatest,
        [switch]$NoGui,
        [string]$IncludeName,
        [switch]$NoConfirm
    )

    if (-not $RemoveFromEnvironment -and -not $DistributionPointName) {
        Write-Log -Message "DistributionPointName is required unless -RemoveFromEnvironment is specified." -Level ERROR
        return
    }

    Connect-CmEnvironment -SiteCode $SiteCode -ProviderMachineName $ProviderMachineName

    Write-Log -Message "Querying Get-CMPackage -Name '${PackageName}'..." -Level INFO
    $allPackages = Get-CMPackage -Name $PackageName -Fast -ErrorAction Stop |
                   Select-Object PackageID, Name, Version

    if (-not $allPackages) {
        Write-Log -Message "No packages found for pattern '${PackageName}'." -Level WARN
        return
    }

    $groups = $allPackages | Group-Object Name
    $multi  = $groups | Where-Object { $_.Count -gt 1 }
    if (-not $multi) {
        Write-Log -Message "No package names with multiple versions found." -Level WARN
        return
    }

    $display = foreach ($g in $multi) {
        [pscustomobject]@{
            Name  = $g.Name
            Count = $g.Count
            Group = $g.Group
        }
    }

    if ($IncludeName) {
        $display = $display | Where-Object { $_.Name -like $IncludeName }
        if (-not $display) {
            Write-Log -Message "Filter '${IncludeName}' matched no names." -Level WARN
            return
        }
    }

    # Select names interactively if possible; otherwise process all
    $selected = $null
    if (-not $NoGui -and (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
        Write-Log -Message "Showing Out-GridView for multi-select..." -Level INFO
        $selected = $display | Out-GridView -Title "Select Package Names (2+ versions)" -OutputMode Multiple
    } else {
        Write-Log -Message "Running headless selection (NoGui or OGV missing). Processing all listed names." -Level INFO
        $selected = $display
    }

    if (-not $selected) {
        Write-Log -Message "No names selected. Exiting." -Level INFO
        return
    }

    foreach ($item in $selected) {
        $name   = $item.Name
        $group  = $item.Group

        # Sort by robust version; tie-break by PackageID for deterministic order
        $sorted = $group | Sort-Object @{ Expression = { Get-ComparableVersion $_.Version } }, PackageID

        $toKeep   = [Math]::Min($KeepLatest, $sorted.Count)
        $toRemove = @()
        if ($sorted.Count -gt $toKeep) {
            # Force array to ensure consistent .Count semantics
            $toRemove = @($sorted | Select-Object -SkipLast $toKeep)
        }

        Write-Log -Message "Name: [${name}] - found $($sorted.Count) version(s). Keeping ${toKeep}, removing $($toRemove.Count)." -Level INFO

        foreach ($old in $toRemove) {
            $pkgId = $old.PackageID
            $ver   = $old.Version

            $action = if ($RemoveFromEnvironment) { "remove from environment" } else { "remove DP content on '${DistributionPointName}'" }
            $target = "PackageId ${pkgId} (Name ""${name}"", Version ${ver})"

            # Respect -WhatIf (no prompts in WhatIf mode)
            if (-not $PSCmdlet.ShouldProcess($target, $action)) {
                Write-Log -Message "User cancelled (PowerShell confirmation) for ${target}." -Level INFO
                continue
            }
            if ($WhatIfPreference) {
                Write-Log -Message "WHATIF: Would ${action} for ${target}." -Level INFO
                continue
            }

            # Our own single confirmation (with Name + Version + Id), unless -NoConfirm
            if (-not $NoConfirm) {
                $msg     = "This will ${action} for:`n${target}`n`nDo you want to continue?"
                $caption = "Confirm removal"
                if (-not $PSCmdlet.ShouldContinue($msg, $caption)) {
                    Write-Log -Message "User cancelled removal for ${target}." -Level INFO
                    continue
                }
            }

            # Suppress underlying cmdlets' prompts during the actual call
            $oldConfirmPref = $ConfirmPreference
            $oldDefaults    = $PSDefaultParameterValues
            try {
                $ConfirmPreference = 'None'
                $PSDefaultParameterValues = @{}
                $PSDefaultParameterValues['*:Confirm'] = $false

                if ($RemoveFromEnvironment) {
                    try {
                        Remove-CMPackage -PackageId $pkgId -ErrorAction Stop -Confirm:$false
                        # Verify only after an actual attempt
                        $verify = Get-CMPackage -Id $pkgId -Fast -ErrorAction SilentlyContinue
                        if ($null -eq $verify) {
                            Write-Log -Message "Removed ${target}." -Level INFO
                        } else {
                            Write-Log -Message "Removal completed but package still present (check dependencies/replication): ${target}." -Level WARN
                        }
                    } catch {
                        Write-Log -Message "FAILED to remove ${target}: $($_.Exception.Message)" -Level ERROR
                    }
                } else {
                    try {
                        Remove-CMContentDistribution -PackageId $pkgId -DistributionPointName $DistributionPointName -Force -ErrorAction Stop -Confirm:$false
                        Write-Log -Message "Removed DP content for ${target}." -Level INFO
                    } catch {
                        Write-Log -Message "FAILED to remove DP content for ${target}: $($_.Exception.Message)" -Level ERROR
                    }
                }
            }
            finally {
                $ConfirmPreference = $oldConfirmPref
                $PSDefaultParameterValues = $oldDefaults
            }
        }
    }
}
#endregion Core

# Main entry point
try {
    if (-not $RemoveFromEnvironment -and -not $DistributionPointName) {
        Write-Log -Message "DistributionPointName is required unless -RemoveFromEnvironment is specified." -Level ERROR
        return
    }

    Invoke-CMPackageVersionCleanup -SiteCode $SiteCode -ProviderMachineName $ProviderMachineName `
        -PackageName $PackageName -DistributionPointName $DistributionPointName `
        -RemoveFromEnvironment:$RemoveFromEnvironment -KeepLatest $KeepLatest `
        -NoGui:$NoGui -IncludeName $IncludeName -NoConfirm:$NoConfirm
}
finally {
    try {
        $targetDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
        Set-Location -Path "${targetDrive}\" -ErrorAction Stop
        Write-Log -Message "Returned to ${targetDrive}\" -Level INFO
    }
    catch {
        Write-Log -Message "Failed to change back to system drive: $($_.Exception.Message)" -Level WARN
    }
}
