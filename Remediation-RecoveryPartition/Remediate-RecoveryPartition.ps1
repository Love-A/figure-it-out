<#
.SYNOPSIS
    Intune Proactive Remediations - REMEDIATION (resize)
    Rebuilds an undersized WinRE/recovery partition following Microsoft's
    KB5028997 procedure (the recommended fix for the KB5034441 issue).

.DESCRIPTION
    DESTRUCTIVE. The script deletes and recreates the recovery partition at a
    larger size by shrinking the OS partition (C:) immediately preceding it.

    SAFE BY DEFAULT:
      $AllowResize = $false  => NO changes are made. The script only logs what
      it WOULD do (dry-run). Set to $true only after pilot testing and with
      backup/recovery media in place.

    The script aborts WITHOUT changes if any of these safety checks fail:
      - A reboot is pending (staged partition/file jobs must complete first -
        the machine will reboot in its normal cycle and remediation will
        succeed on a later run). The triggering source is logged. If the only
        source is PendingFileRenameOperations (harmless to diskpart),
        $IgnorePendingFileRename = $true allows the run to continue.
      - WinRE is not enabled/located (use an enable-remediation instead)
      - The recovery partition is not the last partition on the disk
      - The partition immediately before recovery is not the OS partition (C:)
      - The OS volume is BitLocker-protected and $SuspendBitLocker = $false
      - The OS partition cannot be shrunk by the required amount
      - winre.wim is missing after /disable (we abort rather than leave the
        machine with no recovery image)

    Runs as SYSTEM in 64-bit PowerShell.

    Exit 0 = rebuilt OK, dry-run completed, or nothing to do
    Exit 1 = aborted (unsafe layout/conditions) or error
#>

# ------------------------- Settings -------------------------
$AllowResize             = $false  # MUST be $true to actually modify the disk
$SuspendBitLocker        = $true   # Suspend BitLocker on C: during the operation (-RebootCount 1) and resume after
$MinPartitionSizeMB      = 750     # Below this the partition is rebuilt (keep in sync with the detection script)
$TargetPartitionSizeMB   = 1024    # Grow the recovery partition to at least this size (~1 GB)
$TargetFreeMB            = 250     # Desired free space inside recovery after rebuild
$IgnorePendingFileRename = $true   # $true = allow resize even if the only pending-reboot source is PendingFileRenameOperations
$LogPath                 = "$env:ProgramData\IntuneRemediations\WinRE-Resize.log"
$RecoveryGuid            = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
# ------------------------------------------------------------

$reagent     = "$env:SystemRoot\System32\reagentc.exe"
$summary     = [System.Collections.Generic.List[string]]::new()
$blSuspended = $false        # Tracks whether we suspended BitLocker (so catch can resume)

function Write-Log {
    param([string]$Message)
    $line = ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    try {
        $dir = Split-Path $LogPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch { }
    $summary.Add($Message)
}

function Get-WinReLocation {
    $text = (& $reagent /info 2>&1 | Out-String)
    $m = [regex]::Match($text, 'harddisk(?<disk>\d+)\\partition(?<part>\d+)')
    if ($m.Success) {
        return [pscustomobject]@{
            Disk = [int]$m.Groups['disk'].Value
            Part = [int]$m.Groups['part'].Value
        }
    }
    return $null
}

function Get-FreeMB {
    param($Partition)
    $vol = $Partition | Get-Volume -ErrorAction SilentlyContinue
    if ($vol -and $vol.Size -gt 0) { return [int][math]::Round($vol.SizeRemaining / 1MB) }
    return -1   # Not measurable
}

function Get-PendingRebootSources {
    # Returns a list of sources indicating a pending reboot, so we can
    # distinguish the harmless one (PendingFileRename) from the serious ones.
    $sources = [System.Collections.Generic.List[string]]::new()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')   { $sources.Add('CBS') }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending') { $sources.Add('CBS-Packages') }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')  { $sources.Add('WindowsUpdate') }

    $sm   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $pfro = (Get-ItemProperty -Path $sm -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfro) { $sources.Add('PendingFileRename') }

    return $sources
}

function Resume-BL {
    # Resume BitLocker immediately if we suspended it. If that fails,
    # -RebootCount 1 is the safety net: protection turns back on automatically
    # at the next reboot.
    if ($script:blSuspended) {
        try {
            Resume-BitLocker -MountPoint 'C:' -ErrorAction Stop | Out-Null
            $script:blSuspended = $false
            Write-Log 'BitLocker resumed on C:.'
        } catch {
            Write-Log 'Could not resume BitLocker immediately - will resume automatically at next reboot (-RebootCount 1).'
        }
    }
}

try {
    # 1. Get WinRE location
    $loc = Get-WinReLocation
    if (-not $loc) {
        Write-Log 'WinRE not enabled/located. Run enable-remediation instead. Aborting.'
        Write-Output ($summary -join ' | '); exit 1
    }
    $diskNumber = $loc.Disk
    $partNumber = $loc.Part

    $rec   = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partNumber -ErrorAction Stop
    $disk  = Get-Disk -Number $diskNumber -ErrorAction Stop
    $style = $disk.PartitionStyle    # GPT or MBR

    # 2. Pending reboot - log WHICH sources are triggering and decide whether
    #    they are blocking. PendingFileRename is harmless to diskpart;
    #    CBS/WindowsUpdate means half-finished servicing and always blocks.
    #    Staged partition jobs have no clean detector - so we block
    #    conservatively on everything except PFRO.
    $rebootSources = Get-PendingRebootSources
    if ($rebootSources.Count -gt 0) {
        Write-Log ('Pending reboot sources: ' + ($rebootSources -join ', '))
        $blocking = @($rebootSources | Where-Object { -not ($IgnorePendingFileRename -and $_ -eq 'PendingFileRename') })
        if ($blocking.Count -gt 0) {
            Write-Log ('Blocking pending reboot (' + ($blocking -join ', ') + '). Aborting - run again after reboot.')
            Write-Output ($summary -join ' | '); exit 1
        }
        Write-Log 'Only PendingFileRename and $IgnorePendingFileRename = $true - continuing.'
    }

    # 3. Measure current size and free space, then decide whether anything needs
    #    to change. This mirrors the detection script exactly: the partition is
    #    compliant when it is large enough AND either has enough free space or its
    #    free space cannot be measured (hidden recovery volume reports no size).
    $recMB  = [int][math]::Round($rec.Size / 1MB)
    $freeMB = Get-FreeMB -Partition $rec    # -1 when not measurable
    $sizeOk = ($recMB -ge $MinPartitionSizeMB)
    $freeOk = ($freeMB -lt 0) -or ($freeMB -ge $TargetFreeMB)
    if ($sizeOk -and $freeOk) {
        $freeText = if ($freeMB -lt 0) { 'free space not measurable' } else { "${freeMB} MB free" }
        Write-Log "Nothing to do: recovery partition is ${recMB} MB, $freeText (compliant)."
        Write-Output ($summary -join ' | '); exit 0
    }

    # 4. Layout safety checks
    $partsOnDisk = @(Get-Partition -DiskNumber $diskNumber | Sort-Object Offset)
    $lastPart    = $partsOnDisk | Select-Object -Last 1
    $recIsLast   = ($lastPart.PartitionNumber -eq $partNumber)

    $idx = -1
    for ($i = 0; $i -lt $partsOnDisk.Count; $i++) {
        if ($partsOnDisk[$i].PartitionNumber -eq $partNumber) { $idx = $i; break }
    }
    $prev = if ($idx -gt 0) { $partsOnDisk[$idx - 1] } else { $null }
    $osBeforeRec = ($prev -and $prev.DriveLetter -eq 'C')

    if (-not $recIsLast) {
        Write-Log 'Recovery partition is not the last partition on the disk. KB5028997 not supported. Aborting.'
        Write-Output ($summary -join ' | '); exit 1
    }
    if (-not $osBeforeRec) {
        Write-Log 'The partition immediately before recovery is not the OS partition (C:). Aborting.'
        Write-Output ($summary -join ' | '); exit 1
    }
    $osPart = $prev

    # 5. BitLocker on the OS volume - decide whether to suspend during the operation
    $bl = $null
    try { $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop } catch { }
    $blOn          = ($bl -and $bl.ProtectionStatus -eq 'On')
    $blWillSuspend = $false
    if ($blOn) {
        if ($SuspendBitLocker) {
            $blWillSuspend = $true
            Write-Log 'OS volume is BitLocker-protected. Planning to suspend protection during the operation (-RebootCount 1).'
        } else {
            Write-Log 'OS volume is BitLocker-protected and $SuspendBitLocker = $false. Aborting.'
            Write-Output ($summary -join ' | '); exit 1
        }
    }

    # 6. Calculate how much to shrink C: to reach both the size target and the
    #    free-space target. The recovery partition grows 1:1 with what we shrink
    #    from C:, so shrink = the largest of the two needs.
    $growForSize = $TargetPartitionSizeMB - $recMB
    if ($freeMB -lt 0) {
        # Free space is not measurable (hidden volume). We only reach this point
        # when the partition is below the minimum size, so grow toward the target.
        $shrinkMB = $growForSize
        Write-Log "Free space not measurable. Growing toward target size $TargetPartitionSizeMB MB."
    } else {
        $growForFree = ($TargetFreeMB - $freeMB) + 50
        $shrinkMB    = [int][math]::Max($growForSize, $growForFree)
    }
    if ($shrinkMB -le 0) {
        Write-Log "Recovery partition is already sufficient ($recMB MB, ${freeMB} MB free). Nothing to do."
        Write-Output ($summary -join ' | '); exit 0
    }

    $supported   = Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $osPart.PartitionNumber
    $shrinkBytes = [int64]$shrinkMB * 1MB
    if (($osPart.Size - $shrinkBytes) -lt $supported.SizeMin) {
        Write-Log "OS partition cannot be shrunk by $shrinkMB MB (not enough free space on C:). Aborting."
        Write-Output ($summary -join ' | '); exit 1
    }

    $blPlan   = if ($blWillSuspend) { ' Suspending BitLocker during the operation.' } else { '' }
    $freeText = if ($freeMB -lt 0) { 'free n/a' } else { "${freeMB} MB free" }
    $newPlan  = $recMB + $shrinkMB
    Write-Log "Plan: disk $diskNumber, OS=part $($osPart.PartitionNumber), recovery=part $partNumber ($style), currently ${recMB} MB / $freeText. Shrink C: by $shrinkMB MB -> recovery ~${newPlan} MB.$blPlan"

    # 7. Dry-run if resize is not enabled
    if (-not $AllowResize) {
        Write-Log 'DRY-RUN: $AllowResize = $false. No changes made.'
        Write-Output ($summary -join ' | '); exit 0
    }

    # 8. Live rebuild
    # 8a. Suspend BitLocker before we touch BCD/partitions. -RebootCount 1 means
    #     protection automatically resumes at the next reboot even if the script crashes.
    if ($blWillSuspend) {
        Suspend-BitLocker -MountPoint 'C:' -RebootCount 1 -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 1
        $blNow = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
        if (-not $blNow -or $blNow.ProtectionStatus -ne 'Off') {
            Write-Log 'Could not suspend BitLocker. Aborting without disk changes.'
            Write-Output ($summary -join ' | '); exit 1
        }
        $blSuspended = $true
        Write-Log 'BitLocker suspended on C: (-RebootCount 1).'
    }

    # 8b. Disable WinRE and verify the image is present before we delete anything
    & $reagent /disable | Out-Null
    Start-Sleep -Seconds 2
    $wim = "$env:SystemRoot\System32\Recovery\Winre.wim"
    if (-not (Test-Path $wim)) {
        Write-Log 'winre.wim is missing after /disable. Re-enabling and aborting (will not delete partition without an image).'
        & $reagent /enable | Out-Null
        Resume-BL
        Write-Output ($summary -join ' | '); exit 1
    }

    # 8c. diskpart: shrink OS, delete recovery, create larger, format, set type
    #     NOTE: set id must run AFTER format (format can reset the partition type).
    $dpLines = @(
        "select disk $diskNumber"
        "select partition $($osPart.PartitionNumber)"
        "shrink desired=$shrinkMB minimum=$shrinkMB"
        "select partition $partNumber"
        "delete partition override"
        "create partition primary"
        'format quick fs=ntfs label="Windows RE tools"'
    )
    if ($style -eq 'GPT') {
        $dpLines += "set id=$RecoveryGuid"
        $dpLines += "gpt attributes=0x8000000000000001"
    } else {
        $dpLines += "set id=27"
    }

    $dpFile = "$env:TEMP\winre_resize.txt"
    $dpLines | Set-Content -Path $dpFile -Encoding ASCII
    $dpOut = (& "$env:SystemRoot\System32\diskpart.exe" /s $dpFile 2>&1 | Out-String)
    Remove-Item $dpFile -Force -ErrorAction SilentlyContinue
    Write-Log ("diskpart finished. Excerpt: " + (($dpOut -split "`r?`n" | Where-Object { $_ -match '\S' }) -join '; '))

    # 8d. Re-enable WinRE
    & $reagent /enable | Out-Null
    Start-Sleep -Seconds 3

    # 8e. Verify result
    $newLoc = Get-WinReLocation
    if (-not $newLoc) {
        Write-Log 'ERROR: WinRE could not be enabled after rebuild. Manual review required.'
        Resume-BL
        Write-Output ($summary -join ' | '); exit 1
    }
    $newRec  = Get-Partition -DiskNumber $newLoc.Disk -PartitionNumber $newLoc.Part -ErrorAction Stop
    $newFree = Get-FreeMB -Partition $newRec
    $newSize = [int][math]::Round($newRec.Size / 1MB)

    # Verify the new partition is actually of recovery type (guard against
    # WinRE ending up on C: after the rebuild)
    $typeOk = $true
    if ($newLoc.Disk -eq $diskNumber) {
        $newDisk = Get-Disk -Number $newLoc.Disk
        if ($newDisk.PartitionStyle -eq 'GPT' -and $newRec.GptType -ne "{$RecoveryGuid}") { $typeOk = $false }
        if ($newDisk.PartitionStyle -eq 'MBR' -and $newRec.MbrType -ne 39) { $typeOk = $false }
    }
    if ($newRec.DriveLetter -eq 'C') { $typeOk = $false }

    if (-not $typeOk) {
        Write-Log "WARNING: new WinRE location looks wrong (disk $($newLoc.Disk)/part $($newLoc.Part), drive letter $($newRec.DriveLetter)). Manual review required."
        Resume-BL
        Write-Output ($summary -join ' | '); exit 1
    }

    Resume-BL
    Write-Log "DONE: new recovery partition ${newSize} MB, ${newFree} MB free, disk $($newLoc.Disk)/part $($newLoc.Part)."
    Write-Output ($summary -join ' | '); exit 0
}
catch {
    Write-Log "Error in resize remediation: $($_.Exception.Message)"
    try { & $reagent /enable | Out-Null } catch { }
    Resume-BL
    Write-Output ($summary -join ' | '); exit 1
}
