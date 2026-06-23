<#
.SYNOPSIS
    Intune Proactive Remediations - DETECTION
    Verifies that Windows Recovery Environment (WinRE) is enabled and that it
    lives on a properly configured recovery partition on Windows 10/11.

.DESCRIPTION
    Flags a deviation (exit 1) if any of the following is true:
      - WinRE is disabled or has no valid partition location
      - The WinRE location does not point to a partition of type Recovery
      - WinRE lives on the system partition (C:) instead of a dedicated one
      - The recovery partition is smaller than $MinPartitionSizeMB
      - Free space in the partition is below $MinFreeSpaceMB (when measurable)
      - The volume health status is not Healthy (when measurable)

    Runs as SYSTEM in 64-bit PowerShell.

    Exit 0 = OK (compliant)
    Exit 1 = deviation (remediation will run)
#>

# ------------------------- Settings -------------------------
$MinPartitionSizeMB = 750                                       # Minimum total partition size
$MinFreeSpaceMB     = 250                                       # Minimum free space (per KB5034441)
$RecoveryGptType    = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'  # GPT type GUID for Recovery
$RecoveryMbrType    = 39                                        # 0x27 = Recovery (MBR)
# ------------------------------------------------------------

$issues = [System.Collections.Generic.List[string]]::new()

try {
    # 1. Read WinRE status. The GLOBALROOT path (harddiskX\partitionY) is
    #    language-independent, unlike the localized status text.
    $reagent = "$env:SystemRoot\System32\reagentc.exe"
    $info    = & $reagent /info 2>&1
    $text    = ($info | Out-String)

    $m = [regex]::Match($text, 'harddisk(?<disk>\d+)\\partition(?<part>\d+)')
    if (-not $m.Success) {
        Write-Output "Deviation: WinRE is disabled or has no valid partition location."
        exit 1
    }

    $diskNumber = [int]$m.Groups['disk'].Value
    $partNumber = [int]$m.Groups['part'].Value

    # 2. Look up partition and disk
    $part = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partNumber -ErrorAction Stop
    $disk = Get-Disk -Number $diskNumber -ErrorAction Stop

    # 3. Correct partition type?
    switch ($disk.PartitionStyle) {
        'GPT' {
            if ($part.GptType -ne $RecoveryGptType) {
                $issues.Add("Wrong partition type (GPT): $($part.GptType), expected Recovery.")
            }
        }
        'MBR' {
            if ($part.MbrType -ne $RecoveryMbrType) {
                $issues.Add("Wrong partition type (MBR): $($part.MbrType), expected 0x27.")
            }
        }
    }

    # 4. Not located on the system partition (C:)?
    if ($part.DriveLetter -eq 'C') {
        $issues.Add("WinRE is hosted on the system partition (C:) instead of a dedicated recovery partition.")
    }

    # 5. Size
    $sizeMB = [math]::Round($part.Size / 1MB)
    if ($sizeMB -lt $MinPartitionSizeMB) {
        $issues.Add("Recovery partition is too small: ${sizeMB} MB (required >= $MinPartitionSizeMB MB).")
    }

    # 6. Free space and health (when the volume is exposed - recovery
    #    volumes are often hidden and report no size)
    $vol = $part | Get-Volume -ErrorAction SilentlyContinue
    if ($vol -and $vol.Size -gt 0) {
        $freeMB = [math]::Round($vol.SizeRemaining / 1MB)
        if ($freeMB -lt $MinFreeSpaceMB) {
            $issues.Add("Not enough free space: ${freeMB} MB (required >= $MinFreeSpaceMB MB).")
        }
        if ($vol.HealthStatus -and $vol.HealthStatus -ne 'Healthy') {
            $issues.Add("Volume health status: $($vol.HealthStatus).")
        }
    }

    # 7. Result
    if ($issues.Count -gt 0) {
        Write-Output ("Deviation: " + ($issues -join ' | '))
        exit 1
    }

    Write-Output "OK: WinRE enabled. Disk $diskNumber/partition $partNumber, ${sizeMB} MB, type Recovery."
    exit 0
}
catch {
    Write-Output "Deviation (error during check): $($_.Exception.Message)"
    exit 1
}
