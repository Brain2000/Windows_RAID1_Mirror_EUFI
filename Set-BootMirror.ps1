#Requires -Version 5.1
<#
.SYNOPSIS
    Mirrors the Windows boot volume (software RAID 1 on dynamic disks) on a UEFI
    server and makes the second disk bootable on its own.

.DESCRIPTION
    Replaces the manual diskpart / bcdboot / bcdedit procedure.

    PrepareTarget
        Wipes the target disk, then loops through the source disk's partitions
        in disk order and calls a function to recreate each one on the target:
          Recovery          New-TargetRecoveryPartition (same size, type, attributes)
          System (ESP)      New-TargetEspPartition      (same size, FAT32)
          Reserved (MSR)    New-TargetMsrPartition      (+1 MB if the source is dynamic,
                                                         because conversion takes 1 MB of it)
          Dynamic Reserved  nothing - Windows creates it when the target is converted
          Primary / Dynamic Data
                            nothing yet - these hold volumes and are added by the
                            Mirror phase with "add disk"
        Partitions that sit after the data area on the source (for example a
        Recovery partition at the end of the disk) are created at the same
        distance from the end of the target disk. They have to be created now,
        because diskpart cannot create ordinary partitions once the disk is
        dynamic, but the finished layout ends up in the same order as the source.

    Mirror
        Converts the disks to dynamic where needed, then mirrors the boot volume
        (C:) onto the target, followed by every other simple volume on the source
        disk (unless -BootVolumeOnly).

    SyncBoot  (safe to re-run at any time, e.g. after Windows updates)
        Runs bcdboot to write fresh boot files to the target disk's ESP, then
        uses bcdedit to replace that ESP's BCD with a copy of the active BCD,
        point its boot manager and memory diagnostic at the target's own ESP,
        and make it boot the target disk's copy of Windows by default. It then
        mirrors the \Recovery folder onto the target disk's Recovery partition
        (robocopy /E /PURGE, so additions, changes and deletions all carry over)
        and points that BCD's recovery entry there, so recovery works from the
        second disk on its own (unless -SkipWinRE). If bcdboot changes the
        firmware's Windows Boot Manager entry or boot order, the script puts
        them back.

    All (default) runs PrepareTarget, Mirror and SyncBoot in that order.

    Requirements and assumptions:
      - Elevated PowerShell on English-language Windows (diskpart and bcdedit
        output is parsed).
      - Booted in UEFI mode from the source disk.
      - When rebuilding after a disk failure, remove the Missing member from the
        C: mirror first (Disk Management > right-click C: > Remove Mirror).
      - Close Disk Management while the script runs.
      - Everything is logged to %SystemRoot%\Logs\BootMirror_<timestamp>.log.

.PARAMETER TargetDisk
    Disk number (as in diskpart "list disk") of the disk to mirror onto.
    The PrepareTarget phase ERASES this disk.

.PARAMETER SourceDisk
    Disk number holding the boot volume. Detected automatically if omitted.

.PARAMETER Phase
    All (default), PrepareTarget, Mirror or SyncBoot.

.PARAMETER BootMenuTimeout
    Boot menu timeout in seconds written to the target disk's BCD (default 1),
    so either copy of Windows can be picked when booting from that disk.

.PARAMETER OsEntryId
    BCD identifier to use as the target disk's default entry. Only needed when
    the script finds more than one candidate (for example stale "secondary
    plex" entries left over from an older mirror).

.PARAMETER BootVolumeOnly
    Mirror only the boot volume, not the other simple volumes on the source disk.

.PARAMETER SkipWinRE
    In SyncBoot, leave the target disk's WinRE entry pointing at the active WinRE
    instead of copying WinRE to the target disk's Recovery partition.

.PARAMETER DryRun
    Show what would be done without changing anything.

.PARAMETER Force
    Skip the typed confirmation before wiping the target disk, and the disk size
    and bus-type safety checks.

.EXAMPLE
    .\Set-BootMirror.ps1 -TargetDisk 1 -DryRun
    Preview the whole procedure for mirroring onto disk 1.

.EXAMPLE
    .\Set-BootMirror.ps1 -TargetDisk 1
    Recreate the partitions on disk 1, mirror the volumes onto it and make it bootable.

.EXAMPLE
    .\Set-BootMirror.ps1 -Phase SyncBoot -TargetDisk 1
    Refresh the second disk's boot files and BCD on an existing mirror.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$TargetDisk,

    [int]$SourceDisk = -1,

    [ValidateSet('All', 'PrepareTarget', 'Mirror', 'SyncBoot')]
    [string]$Phase = 'All',

    [ValidateRange(0, 999)]
    [int]$BootMenuTimeout = 1,

    [string]$OsEntryId,

    [switch]$BootVolumeOnly,

    [switch]$SkipWinRE,

    [switch]$DryRun,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$RecoveryPartitionType = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
$WindowsBootManagerId  = '{9dea862c-5cdd-4e70-acc1-f32b344d4795}'
$script:StopAfterPhase = $false

#region ---------- Output helpers ----------
function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}
function Write-Info([string]$Message)   { Write-Host "    $Message" }
function Write-Ok([string]$Message)     { Write-Host "    $Message" -ForegroundColor Green }
function Write-Warn([string]$Message)   { Write-Host "    WARNING: $Message" -ForegroundColor Yellow }
function Write-DryRun([string]$Message) { Write-Host "    [DryRun] $Message" -ForegroundColor DarkGray }
#endregion

#region ---------- Native command wrappers ----------
function Invoke-Native {
    # Runs a native command without PowerShell turning stderr output into terminating errors.
    param([string]$FilePath, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $output = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Output = @($output); ExitCode = $LASTEXITCODE }
}

function Invoke-Diskpart {
    param(
        [Parameter(Mandatory = $true)][string[]]$Commands,
        [switch]$ReadOnly,
        [switch]$IgnoreErrors
    )
    if ($DryRun -and -not $ReadOnly) {
        Write-DryRun 'diskpart would run:'
        foreach ($command in $Commands) { Write-DryRun "    $command" }
        return ''
    }
    $scriptFile = Join-Path $env:SystemRoot ('Temp\bootmirror_dp_{0}.txt' -f [guid]::NewGuid())
    Set-Content -Path $scriptFile -Value (($Commands + 'exit') -join "`r`n") -Encoding Ascii
    try {
        $result = Invoke-Native 'diskpart.exe' @('/s', $scriptFile)
    }
    finally {
        Remove-Item -Path $scriptFile -Force -ErrorAction SilentlyContinue
    }
    $text = $result.Output -join "`n"
    Write-Verbose "diskpart: $($Commands -join ' | ')`n$text"
    $failed = ($result.ExitCode -ne 0) -or
              ($text -match 'DiskPart has encountered an error|Virtual Disk Service error|not valid|There is no (disk|volume|partition) selected')
    if ($failed -and -not $IgnoreErrors) {
        throw "diskpart reported an error.`nCommands:`n  $($Commands -join "`n  ")`nOutput:`n$text"
    }
    return $text
}

function Invoke-Bcdedit {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$ReadOnly
    )
    if ($DryRun -and -not $ReadOnly) {
        Write-DryRun "bcdedit $($Arguments -join ' ')"
        return @()
    }
    $result = Invoke-Native 'bcdedit.exe' $Arguments
    if ($result.ExitCode -ne 0) {
        throw "bcdedit $($Arguments -join ' ') failed:`n$($result.Output -join "`n")"
    }
    return $result.Output
}
#endregion

#region ---------- diskpart output parsing ----------
function Get-Slice([string]$Line, [int]$Start, [int]$End) {
    if ($Start -ge $Line.Length) { return '' }
    $End = [Math]::Min($End, $Line.Length)
    return $Line.Substring($Start, $End - $Start).Trim()
}

function ConvertFrom-DiskpartTable {
    # Parses a fixed-width diskpart table (header line, dashed line, rows) into objects.
    param([string]$Text, [string]$Header)
    $lines = $Text -split "`r?`n"
    $rows = @()
    for ($i = 0; $i -lt $lines.Count - 1; $i++) {
        if (-not ($lines[$i].TrimStart().StartsWith($Header) -and $lines[$i + 1] -match '^\s*-')) { continue }
        $headerLine = $lines[$i]
        $starts = @([regex]::Matches($lines[$i + 1], '-+') | ForEach-Object { $_.Index })
        $names = @()
        for ($k = 0; $k -lt $starts.Count; $k++) {
            $end = $headerLine.Length
            if ($k -lt $starts.Count - 1) { $end = $starts[$k + 1] }
            $names += Get-Slice $headerLine $starts[$k] $end
        }
        for ($j = $i + 2; $j -lt $lines.Count; $j++) {
            $line = $lines[$j]
            if ($line.Trim() -eq '') { break }
            $row = [ordered]@{ Selected = $line.TrimStart().StartsWith('*') }
            for ($k = 0; $k -lt $starts.Count; $k++) {
                $end = $line.Length
                if ($k -lt $starts.Count - 1) { $end = $starts[$k + 1] }
                $row[$names[$k]] = Get-Slice $line $starts[$k] $end
            }
            $rows += [pscustomobject]$row
        }
        break
    }
    return $rows
}

function ConvertTo-MB([string]$Text) {
    if ($Text -notmatch '^([\d.]+)\s*(B|KB|MB|GB|TB)$') { return $null }
    $value = [double]$Matches[1]
    switch ($Matches[2]) {
        'B'  { return $value / 1MB }
        'KB' { return $value / 1KB }
        'MB' { return $value }
        'GB' { return $value * 1KB }
        'TB' { return $value * 1MB }
    }
}

function Get-DpDisks {
    $text = Invoke-Diskpart -ReadOnly -Commands 'list disk'
    foreach ($row in @(ConvertFrom-DiskpartTable -Text $text -Header 'Disk ###')) {
        $id = ($row.'Disk ###' -replace '^Disk\s*', '').Trim()
        $number = -1
        if ($id -match '^\d+$') { $number = [int]$id }
        [pscustomobject]@{
            Id      = $id
            Number  = $number
            Status  = $row.Status
            Dynamic = ($row.Dyn -eq '*')
            Gpt     = ($row.Gpt -eq '*')
        }
    }
}

function Get-DpPartitions([int]$Disk) {
    $text = Invoke-Diskpart -ReadOnly -Commands "select disk $Disk", 'list partition'
    foreach ($row in @(ConvertFrom-DiskpartTable -Text $text -Header 'Partition ###')) {
        [pscustomobject]@{
            Number = [int]($row.'Partition ###' -replace '\D', '')
            Type   = $row.Type
            SizeMB = [int][Math]::Round([double](ConvertTo-MB $row.Size))
        }
    }
}

function ConvertTo-VolumeObject($Rows) {
    foreach ($row in @($Rows)) {
        if (-not $row) { continue }
        [pscustomobject]@{
            Number = [int]($row.'Volume ###' -replace '\D', '')
            Letter = $row.Ltr
            Label  = $row.Label
            Fs     = $row.Fs
            Type   = $row.Type
            Status = $row.Status
            Info   = $row.Info
        }
    }
}

function Get-DpVolumes {
    $text = Invoke-Diskpart -ReadOnly -Commands 'list volume'
    ConvertTo-VolumeObject (ConvertFrom-DiskpartTable -Text $text -Header 'Volume ###')
}

function Get-DpDiskVolumes([int]$Disk) {
    $text = Invoke-Diskpart -ReadOnly -Commands "select disk $Disk", 'detail disk'
    ConvertTo-VolumeObject (ConvertFrom-DiskpartTable -Text $text -Header 'Volume ###')
}

function Get-BootVolume {
    $volumes = @(Get-DpVolumes)
    $volume = $volumes | Where-Object { $_.Info -match '\bBoot\b' } | Select-Object -First 1
    if (-not $volume) { $volume = $volumes | Where-Object { $_.Letter -eq 'C' } | Select-Object -First 1 }
    if (-not $volume) { throw 'Could not find the boot volume in diskpart "list volume".' }

    $text = Invoke-Diskpart -ReadOnly -Commands "select volume $($volume.Number)", 'detail volume'
    $disks = @()
    $missing = $false
    foreach ($row in @(ConvertFrom-DiskpartTable -Text $text -Header 'Disk ###')) {
        $id = ($row.'Disk ###' -replace '^Disk\s*', '').Trim()
        if ($id -match '^\d+$' -and $row.Status -notmatch 'Missing') { $disks += [int]$id }
        else { $missing = $true }
    }
    [pscustomobject]@{
        Number           = $volume.Number
        Letter           = $volume.Letter
        Type             = $volume.Type
        Status           = $volume.Status
        Disks            = $disks
        HasMissingMember = ($missing -or $volume.Status -match 'Failed')
    }
}
#endregion

#region ---------- BCD parsing ----------
function Get-BcdEntries {
    # Returns the entries of "bcdedit [/store X] /enum [Id] /v" as objects (raw GUIDs, no aliases).
    param([string]$Store, [string]$Id)
    $arguments = @()
    if ($Store) { $arguments += '/store', $Store }
    $arguments += '/enum'
    if ($Id) { $arguments += $Id }
    $arguments += '/v'
    $output = Invoke-Bcdedit -ReadOnly -Arguments $arguments

    $entries = @()
    $entry = $null
    $lastKey = $null
    foreach ($raw in $output) {
        $line = [string]$raw
        if ($line -match '^-{3,}\s*$') { continue }
        if ($line.Trim() -eq '') {
            if ($entry) { $entries += [pscustomobject]$entry; $entry = $null }
            continue
        }
        if (-not $entry) {
            $entry = [ordered]@{ Header = $line.Trim() }
            $lastKey = $null
            continue
        }
        if ($line -match '^(\S+)\s+(.*)$') {
            $lastKey = $Matches[1]
            $entry[$lastKey] = $Matches[2].Trim()
        }
        elseif ($lastKey -and $line -match '^\s+(\S.*)$') {
            $entry[$lastKey] = "$($entry[$lastKey]) $($Matches[1].Trim())"
        }
    }
    if ($entry) { $entries += [pscustomobject]$entry }
    return $entries
}
#endregion

#region ---------- Misc helpers ----------
function Get-FreeDriveLetter([string[]]$Exclude = @()) {
    $used = @((Get-PSDrive -PSProvider FileSystem).Name) + $Exclude
    foreach ($code in 90..68) {   # Z down to D
        $letter = [string][char]$code
        if ($used -notcontains $letter -and -not (Test-Path "$($letter):\")) { return $letter }
    }
    throw 'No free drive letter is available.'
}

function Get-VolumePathForLetter([string]$Letter) {
    $result = Invoke-Native 'mountvol.exe' @("$($Letter):", '/L')
    if ($result.ExitCode -ne 0) { return $null }
    $path = $result.Output | Where-Object { $_ -match '\\\\\?\\Volume\{' } | Select-Object -First 1
    if ($path) { return $path.Trim() }
    return $null
}
#endregion

#region ---------- More helpers ----------
function Format-Size([int64]$SizeMB) {
    if ($SizeMB -ge 10240) { return '{0:N0} GB' -f ($SizeMB / 1024) }
    return "$SizeMB MB"
}

function Get-DpPartitionOffset([int]$Disk, [int]$Partition) {
    $text = Invoke-Diskpart -ReadOnly -Commands "select disk $Disk", "select partition $Partition", 'detail partition'
    if ($text -match 'Offset in Bytes\s*:\s*(\d+)') { return [int64]$Matches[1] }
    throw "Could not read the offset of partition $Partition on disk $Disk."
}

function Remove-BcdFiles([string]$Folder) {
    # Deletes a BCD store and its transaction logs (BCD.LOG, BCD.LOG1, BCD.LOG2).
    if (-not (Test-Path -LiteralPath $Folder)) { return }
    Get-ChildItem -LiteralPath $Folder -Force |
        Where-Object { $_.Name -match '^BCD(\.LOG\d?)?$' } |
        ForEach-Object {
            $_.Attributes = 'Normal'
            Remove-Item -LiteralPath $_.FullName -Force
        }
}

function Get-FirmwareState {
    # Firmware boot order and where the firmware's "Windows Boot Manager" entry points.
    $entries = @(Get-BcdEntries -Id 'firmware')
    $fwManager = $entries | Where-Object { $_.Header -eq 'Firmware Boot Manager' } | Select-Object -First 1
    $bootManager = $entries | Where-Object { $_.identifier -eq $WindowsBootManagerId } | Select-Object -First 1
    $order = @()
    if ($fwManager -and $fwManager.displayorder) { $order = @(([string]$fwManager.displayorder) -split '\s+' | Where-Object { $_ }) }
    $device = $null
    if ($bootManager) { $device = $bootManager.device }
    [pscustomobject]@{ Order = $order; BootManagerDevice = $device }
}
#endregion

#region ---------- Source layout ----------
function Get-SourceLayout {
    # Source partitions in disk order, with exact offsets and whether each one sits after the data area.
    $parts = @(Get-DpPartitions $SourceDisk)
    foreach ($part in $parts) {
        $part | Add-Member -NotePropertyName OffsetBytes -NotePropertyValue (Get-DpPartitionOffset $SourceDisk $part.Number)
    }
    $dataParts = @($parts | Where-Object { $_.Type -in 'Dynamic Data', 'Primary' })
    $dataStart = $null
    if ($dataParts.Count -gt 0) { $dataStart = ($dataParts | Measure-Object -Property OffsetBytes -Minimum).Minimum }
    foreach ($part in $parts) {
        $after = ($null -ne $dataStart) -and ($part.OffsetBytes -gt $dataStart)
        $part | Add-Member -NotePropertyName AfterData -NotePropertyValue $after
    }
    return @($parts | Sort-Object OffsetBytes)
}
#endregion

#region ---------- Partition creation (one function per partition type) ----------
function Get-OffsetClause($SourcePart) {
    # Partitions after the data area go at the same distance from the end of the
    # target disk as on the source (aligned down to 1 MB). Others go in the next free space.
    if (-not $SourcePart.AfterData) { return '' }
    if (-not $sourceInfo -or -not $targetInfo) {
        throw "Get-Disk could not read both disks, so partition $($SourcePart.Number) cannot be placed at the end of disk $TargetDisk."
    }
    $distanceFromEnd = [int64]$sourceInfo.Size - [int64]$SourcePart.OffsetBytes
    $targetOffset = [int64]$targetInfo.Size - $distanceFromEnd
    $offsetKB = [int64]([Math]::Floor($targetOffset / 1MB) * 1024)
    return " offset=$offsetKB"
}

function Get-PlacementText($SourcePart) {
    if ($SourcePart.AfterData) { return 'at the end of the disk' }
    return 'in the next free space'
}

function New-TargetRecoveryPartition($SourcePart) {
    Write-Info "Recovery partition, $($SourcePart.SizeMB) MB, $(Get-PlacementText $SourcePart)"
    Invoke-Diskpart -Commands "select disk $TargetDisk",
        "create partition primary size=$($SourcePart.SizeMB)$(Get-OffsetClause $SourcePart)",
        'format quick fs=ntfs label="Recovery"',
        "set id=$RecoveryPartitionType",
        'gpt attributes=0x8000000000000001' | Out-Null
}

function New-TargetEspPartition($SourcePart) {
    Write-Info "EFI System partition, $($SourcePart.SizeMB) MB, $(Get-PlacementText $SourcePart)"
    Invoke-Diskpart -Commands "select disk $TargetDisk",
        "create partition efi size=$($SourcePart.SizeMB)$(Get-OffsetClause $SourcePart)",
        'format quick fs=fat32 label="System"' | Out-Null
}

function New-TargetMsrPartition($SourcePart, [bool]$SourceIsDynamic) {
    $size = $SourcePart.SizeMB
    $note = ''
    if ($SourceIsDynamic) {
        $size += 1
        $note = " (source shows $($SourcePart.SizeMB) MB; +1 MB because converting to dynamic takes 1 MB of it)"
    }
    Write-Info "Reserved (MSR) partition, $size MB$note, $(Get-PlacementText $SourcePart)"
    Invoke-Diskpart -Commands "select disk $TargetDisk",
        "create partition msr size=$size$(Get-OffsetClause $SourcePart)" | Out-Null
}
#endregion

#region ---------- Phase: PrepareTarget ----------
function Invoke-PrepareTarget {
    Write-Step "Phase PrepareTarget: recreating disk $SourceDisk's partitions on disk $TargetDisk"

    if ($bootVolume.Disks -contains $TargetDisk) {
        throw "Disk $TargetDisk already holds a copy of the boot volume. Refusing to wipe it."
    }
    if ($targetInfo) {
        if ($targetInfo.IsBoot -or $targetInfo.IsSystem) { throw "Disk $TargetDisk is a boot or system disk. Refusing to wipe it." }
        if ($targetInfo.IsClustered) { throw "Disk $TargetDisk is a cluster disk. Refusing to wipe it." }
        if (-not $Force -and ('iSCSI', 'Fibre Channel', 'FibreChannel') -contains [string]$targetInfo.BusType) {
            throw "Disk $TargetDisk is on a $($targetInfo.BusType) bus, which suggests shared storage. Use -Force if this really is the right disk."
        }
        if ($sourceInfo) {
            if ($targetInfo.LogicalSectorSize -ne $sourceInfo.LogicalSectorSize) {
                throw "Sector size mismatch: disk $SourceDisk uses $($sourceInfo.LogicalSectorSize)-byte sectors, disk $TargetDisk uses $($targetInfo.LogicalSectorSize)-byte sectors."
            }
            if ($targetInfo.Size -lt $sourceInfo.Size -and -not $Force) {
                throw ("Disk $TargetDisk ({0:N1} GB) is smaller than disk $SourceDisk ({1:N1} GB). Use -Force to try anyway." -f ($targetInfo.Size / 1GB), ($sourceInfo.Size / 1GB))
            }
        }
    }
    else {
        Write-Warn "Get-Disk could not read disk $TargetDisk, so the size and bus checks were skipped."
    }

    $layout = @(Get-SourceLayout)
    $sourceIsDynamic = @($layout | Where-Object { $_.Type -like 'Dynamic*' }).Count -gt 0
    if (-not ($layout | Where-Object { $_.Type -eq 'System' })) { throw "No EFI System partition found on disk $SourceDisk." }
    if (-not ($layout | Where-Object { $_.Type -eq 'Reserved' })) {
        throw "No Reserved (MSR) partition found on disk $SourceDisk. Create one on the source disk before converting it to dynamic."
    }

    Write-Info "Source disk $SourceDisk layout ($(if ($sourceIsDynamic) { 'dynamic' } else { 'basic' })):"
    foreach ($part in $layout) {
        Write-Info ('  Partition {0}: {1}, {2}, offset {3:N0} bytes' -f $part.Number, $part.Type, (Format-Size $part.SizeMB), $part.OffsetBytes)
    }

    $description = "status $($targetDp.Status)"
    if ($targetInfo) {
        $description = '{0}, serial {1}, {2:N1} GB, {3}' -f $targetInfo.FriendlyName, $targetInfo.SerialNumber, ($targetInfo.Size / 1GB), $targetInfo.BusType
    }
    Write-Info "Target disk $TargetDisk : $description"
    $existing = @(Get-DpPartitions $TargetDisk)
    if ($existing.Count -gt 0) { Write-Warn "Disk $TargetDisk has $($existing.Count) partition(s). ALL of them will be erased." }

    if (-not $DryRun -and -not $Force) {
        $answer = Read-Host "Type ERASE $TargetDisk to wipe disk $TargetDisk and continue"
        if ($answer -cne "ERASE $TargetDisk") { throw 'Cancelled by user.' }
    }

    Invoke-Diskpart -IgnoreErrors -Commands "select disk $TargetDisk", 'online disk noerr', 'attributes disk clear readonly noerr' | Out-Null
    Invoke-Diskpart -Commands "select disk $TargetDisk", 'clean', 'convert gpt' | Out-Null

    # "convert gpt" may create an MSR on its own; remove anything it created.
    if ($DryRun) {
        Write-DryRun 'would delete any partitions created automatically by "convert gpt".'
    }
    else {
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            $auto = @(Get-DpPartitions $TargetDisk)
            if ($auto.Count -eq 0) { break }
            Invoke-Diskpart -Commands "select disk $TargetDisk", "select partition $($auto[0].Number)", 'delete partition override' | Out-Null
        }
        if (@(Get-DpPartitions $TargetDisk).Count -gt 0) { throw "Could not remove the partitions Windows created on disk $TargetDisk." }
    }

    Write-Info 'Creating partitions in source order:'
    foreach ($part in $layout) {
        switch ($part.Type) {
            'Recovery'         { New-TargetRecoveryPartition $part }
            'System'           { New-TargetEspPartition $part }
            'Reserved'         { New-TargetMsrPartition $part $sourceIsDynamic }
            'Dynamic Reserved' { Write-Info "Dynamic Reserved, $($part.SizeMB) MB: created by Windows when the disk is converted to dynamic" }
            'Dynamic Data'     { Write-Info "Dynamic Data, $(Format-Size $part.SizeMB): holds volumes, added by the Mirror phase" }
            'Primary'          { Write-Info "Primary, $(Format-Size $part.SizeMB): holds a volume, added by the Mirror phase" }
            default            { Write-Warn "Partition $($part.Number) has type '$($part.Type)', which this script does not recreate." }
        }
    }

    if (-not $DryRun) {
        Write-Ok "Disk $TargetDisk now has:"
        foreach ($part in @(Get-DpPartitions $TargetDisk)) {
            Write-Info ('  Partition {0}: {1}, {2}' -f $part.Number, $part.Type, (Format-Size $part.SizeMB))
        }
    }
}
#endregion

#region ---------- Phase: Mirror ----------
function ConvertTo-DynamicDisk([int]$Disk) {
    # Returns $true if Windows needs a restart before the conversion is complete.
    $info = Get-DpDisks | Where-Object { $_.Number -eq $Disk } | Select-Object -First 1
    if ($info -and $info.Dynamic) {
        Write-Info "Disk $Disk is already dynamic."
        return $false
    }
    Write-Info "Converting disk $Disk to dynamic..."
    $output = Invoke-Diskpart -Commands "select disk $Disk", 'convert dynamic'
    return ($output -match 'restart|reboot')
}

function Add-TargetMirror($Volume) {
    $name = "volume $($Volume.Number) ($(@($Volume.Letter, $Volume.Label, $Volume.Fs) -ne '' -join ' '))"
    Write-Info "Adding disk $TargetDisk as a mirror of $name..."
    Invoke-Diskpart -Commands "select volume $($Volume.Number)", "add disk=$TargetDisk" | Out-Null
}

function Invoke-Mirror {
    Write-Step "Phase Mirror: mirroring the volumes onto disk $TargetDisk"

    $volume = Get-BootVolume
    if ($volume.HasMissingMember) {
        throw 'The boot volume still lists a Missing or failed mirror member. In Disk Management, right-click C: > Remove Mirror > select the Missing disk, then run this phase again.'
    }
    if (-not $DryRun -and @(Get-DpPartitions $TargetDisk | Where-Object { $_.Type -eq 'System' }).Count -ne 1) {
        throw "Disk $TargetDisk has no EFI System partition. Run -Phase PrepareTarget first."
    }

    foreach ($disk in @($SourceDisk, $TargetDisk)) {
        if (ConvertTo-DynamicDisk $disk) {
            Write-Warn "Windows needs a restart to finish converting disk $disk. Restart, then run this script again with -Phase Mirror, followed by -Phase SyncBoot."
            $script:StopAfterPhase = $true
            return
        }
    }

    # Boot volume first, then the other volumes on the source disk in order.
    if ($volume.Disks -contains $TargetDisk) {
        Write-Ok "The boot volume is already mirrored onto disk $TargetDisk."
    }
    else {
        $bootVolumeObject = [pscustomobject]@{ Number = $volume.Number; Letter = $volume.Letter; Label = ''; Fs = 'boot volume' }
        Add-TargetMirror $bootVolumeObject
    }

    foreach ($other in @(Get-DpDiskVolumes $SourceDisk | Sort-Object Number)) {
        if ($other.Number -eq $volume.Number) { continue }
        if ($other.Status -match 'Failed') {
            Write-Warn "Volume $($other.Number) shows '$($other.Status)'. Remove its Missing mirror member in Disk Management, then run -Phase Mirror again."
        }
        elseif ($other.Type -eq 'Simple') {
            if ($BootVolumeOnly) { Write-Info "Skipping volume $($other.Number) (-BootVolumeOnly)." }
            else { Add-TargetMirror $other }
        }
    }
    if (-not $DryRun) { Write-Ok 'Mirrors created. Resynchronization runs in the background.' }
}
#endregion

#region ---------- Phase: SyncBoot ----------
function Invoke-TargetBcdboot([string]$TargetLetter, [string]$ActiveLetter) {
    # Writes fresh boot files to the target ESP with bcdboot, then undoes any change
    # bcdboot made to the firmware's Windows Boot Manager entry or boot order.
    $bootDir = "$($TargetLetter):\EFI\Microsoft\Boot"
    Remove-BcdFiles $bootDir   # start clean; stale BCD logs caused the node 2 problem

    $before = Get-FirmwareState
    $result = Invoke-Native 'bcdboot.exe' @($env:SystemRoot, '/s', "$($TargetLetter):", '/f', 'UEFI', '/addlast')
    if ($result.ExitCode -ne 0) { throw "bcdboot failed:`n$($result.Output -join "`n")" }
    Write-Ok "bcdboot: $(($result.Output | Where-Object { $_ }) -join ' ')"

    $fallback = "$($TargetLetter):\EFI\Boot\bootx64.efi"
    if (-not (Test-Path -LiteralPath $fallback)) {
        New-Item -ItemType Directory -Path (Split-Path $fallback) -Force | Out-Null
        Copy-Item -LiteralPath "$bootDir\bootmgfw.efi" -Destination $fallback -Force
        Write-Info 'Added the \EFI\Boot\bootx64.efi fallback loader.'
    }

    $after = Get-FirmwareState
    if ($before.BootManagerDevice -and $after.BootManagerDevice -ne $before.BootManagerDevice) {
        Write-Warn "bcdboot moved the firmware's Windows Boot Manager entry from $($before.BootManagerDevice) to $($after.BootManagerDevice). Putting it back."
        Invoke-Bcdedit -Arguments '/set', '{bootmgr}', 'device', "partition=$($ActiveLetter):" | Out-Null
    }
    if ($before.Order.Count -gt 0 -and $after.Order.Count -gt 0 -and $after.Order[0] -ne $before.Order[0]) {
        $restored = @($before.Order) + @($after.Order | Where-Object { $before.Order -notcontains $_ })
        Write-Warn 'bcdboot changed the first entry in the firmware boot order. Restoring the original order.'
        Invoke-Bcdedit -Arguments (@('/set', '{fwbootmgr}', 'displayorder') + $restored) | Out-Null
    }
    $added = @($after.Order | Where-Object { $before.Order -notcontains $_ })
    if ($added.Count -gt 0) { Write-Info "bcdboot added firmware boot entry $($added -join ', ') at the end of the boot order." }
}

function Repair-TargetBcd([string]$TargetLetter, $TargetEntry) {
    # Replaces the target ESP's BCD with a copy of the active BCD (which has both
    # Windows entries and WinRE), then fixes it up for the target disk.
    $bootDir = "$($TargetLetter):\EFI\Microsoft\Boot"
    $store = "$bootDir\BCD"
    $tempBcd = Join-Path $env:SystemRoot ('Temp\bootmirror_bcd_{0}' -f [guid]::NewGuid())
    try {
        Invoke-Bcdedit -Arguments '/export', $tempBcd | Out-Null
        Remove-BcdFiles $bootDir
        Copy-Item -LiteralPath $tempBcd -Destination $store -Force
    }
    finally {
        Remove-Item -Path "$tempBcd*" -Force -ErrorAction SilentlyContinue
    }

    Invoke-Bcdedit -Arguments '/store', $store, '/set', '{bootmgr}', 'device', "partition=$($TargetLetter):" | Out-Null
    Invoke-Bcdedit -Arguments '/store', $store, '/set', '{memdiag}', 'device', "partition=$($TargetLetter):" | Out-Null
    Invoke-Bcdedit -Arguments '/store', $store, '/default', $TargetEntry.identifier | Out-Null
    Invoke-Bcdedit -Arguments '/store', $store, '/timeout', "$BootMenuTimeout" | Out-Null

    $bootManager = @(Get-BcdEntries -Store $store) | Where-Object { $_.Header -eq 'Windows Boot Manager' } | Select-Object -First 1
    if (-not $bootManager) { throw 'Verification failed: could not read the boot manager entry from the copied BCD.' }
    if ($bootManager.default -ne $TargetEntry.identifier) {
        throw "Verification failed: the copied BCD's default is $($bootManager.default), expected $($TargetEntry.identifier)."
    }
    Write-Ok "Disk $TargetDisk's BCD: boot manager device $($bootManager.device), default $($bootManager.default), timeout $($bootManager.timeout)."
}

function Get-WinReLocation {
    # Where Windows RE lives now, from "reagentc /info". Returns $null if WinRE is not enabled.
    $info = Invoke-Native 'reagentc.exe' @('/info')
    $text = $info.Output -join "`n"
    if ($text -notmatch 'Windows RE status:\s*Enabled') { return $null }
    if ($text -match 'Windows RE location:\s*\\\\\?\\GLOBALROOT\\device\\harddisk(\d+)\\partition(\d+)(\\\S*)') {
        return [pscustomobject]@{ Disk = [int]$Matches[1]; Partition = [int]$Matches[2]; Folder = $Matches[3] }
    }
    return $null
}

function Mount-PartitionLetter([int]$Disk, [int]$Partition, [string[]]$Exclude = @()) {
    $letter = Get-FreeDriveLetter -Exclude $Exclude
    Invoke-Diskpart -Commands "select disk $Disk", "select partition $Partition", "assign letter=$letter" | Out-Null
    return $letter
}

function Sync-TargetWinRE([string]$Store, $TargetEntry, [string[]]$LettersInUse) {
    # Copies WinRE to the target disk's Recovery partition and points the recovery
    # entry in the target's BCD there. A Recovery partition is an ordinary partition,
    # so bcdedit records it correctly as being on the target disk.
    $winReId = $TargetEntry.recoverysequence
    if (-not $winReId) { Write-Info 'This Windows entry has no WinRE linked to it; skipping WinRE.'; return }
    $location = Get-WinReLocation
    if (-not $location) { Write-Warn 'WinRE is not enabled (see reagentc /info); skipping WinRE.'; return }

    $targetRecovery = @(Get-DpPartitions $TargetDisk | Where-Object { $_.Type -eq 'Recovery' }) | Select-Object -First 1
    if (-not $targetRecovery) {
        Write-Warn "Disk $TargetDisk has no Recovery partition, so its BCD keeps using WinRE on disk $($location.Disk)."
        return
    }

    $entry = @(Get-BcdEntries -Store $Store -Id $winReId)[0]
    if (-not $entry -or [string]$entry.device -notmatch '^ramdisk=\[[^\]]*\](?<path>[^,]+),(?<options>\{[^}]+\})$') {
        Write-Warn "Could not read WinRE entry $winReId in the target BCD; skipping WinRE."
        return
    }
    $wimPath = $Matches['path']
    $optionsId = $Matches['options']

    $sourceLetter = $null
    $targetLetter = $null
    try {
        $targetLetter = Mount-PartitionLetter $TargetDisk $targetRecovery.Number $LettersInUse

        # Mirror the top-level folder that holds WinRE (normally \Recovery), not the whole
        # partition, so /PURGE can only ever touch that folder.
        $topFolder = '\' + ($location.Folder.Trim('\') -split '\\')[0]
        if (Test-Path -LiteralPath "$env:SystemDrive$($location.Folder)\Winre.wim") {
            # WinRE lives on C: (reagentc does this on some servers).
            $sourceFolder = "$env:SystemDrive$topFolder"
        }
        else {
            $sourceLetter = Mount-PartitionLetter $location.Disk $location.Partition (@($LettersInUse) + @($targetLetter))
            $sourceFolder = "$($sourceLetter):$topFolder"
        }
        $targetFolder = "$($targetLetter):$topFolder"
        $what = $sourceFolder
        if ($sourceLetter) { $what = "$topFolder on disk $($location.Disk) partition $($location.Partition)" }

        # /E /PURGE = exact mirror of that folder: copies new and changed files and deletes files
        # that no longer exist on the source. /B gets past the restrictive permissions on WinRE.
        $copy = Invoke-Native 'robocopy.exe' @($sourceFolder, $targetFolder, '/E', '/PURGE', '/B', '/R:1', '/W:1',
                                               '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
        if ($copy.ExitCode -ge 8) {
            throw "Copying $what failed (robocopy exit code $($copy.ExitCode)):`n$($copy.Output -join "`n")"
        }
        Write-Info "Mirrored $what to disk $TargetDisk's Recovery partition (partition $($targetRecovery.Number))."

        $ramdisk = "ramdisk=[$($targetLetter):]$wimPath,$optionsId"
        Invoke-Bcdedit -Arguments '/store', $Store, '/set', $winReId, 'device', $ramdisk | Out-Null
        Invoke-Bcdedit -Arguments '/store', $Store, '/set', $winReId, 'osdevice', $ramdisk | Out-Null
        Invoke-Bcdedit -Arguments '/store', $Store, '/set', $optionsId, 'ramdisksdidevice', "partition=$($targetLetter):" | Out-Null

        $check = @(Get-BcdEntries -Store $Store -Id $winReId)[0]
        if (-not ([string]$check.device).StartsWith("ramdisk=[$($targetLetter):]")) {
            throw "Verification failed: the target BCD's WinRE device is $($check.device)."
        }
        Write-Ok "Disk $TargetDisk's BCD now uses the WinRE on its own Recovery partition."
    }
    finally {
        if ($targetLetter) { Invoke-Native 'mountvol.exe' @("$($targetLetter):", '/D') | Out-Null }
        if ($sourceLetter) { Invoke-Native 'mountvol.exe' @("$($sourceLetter):", '/D') | Out-Null }
    }
}

function Invoke-SyncBoot {
    Write-Step "Phase SyncBoot: making disk $TargetDisk bootable on its own"

    $volume = Get-BootVolume
    if (-not $DryRun -and $volume.Disks -notcontains $TargetDisk) {
        throw "The boot volume is not mirrored onto disk $TargetDisk (it is on disk(s) $($volume.Disks -join ', '))."
    }

    # Which Windows entry should the target disk start by default? The one that is not running now.
    $current = @(Get-BcdEntries -Id '{current}')[0]
    $osEntries = @(Get-BcdEntries | Where-Object { $_.Header -eq 'Windows Boot Loader' -and $_.winpe -ne 'Yes' })
    $targetEntry = $null
    if ($OsEntryId) {
        $targetEntry = $osEntries | Where-Object { $_.identifier -eq $OsEntryId } | Select-Object -First 1
        if (-not $targetEntry) { throw "BCD entry $OsEntryId was not found in the active BCD." }
    }
    else {
        $candidates = @($osEntries | Where-Object { $_.identifier -ne $current.identifier })
        if ($candidates.Count -eq 1) {
            $targetEntry = $candidates[0]
        }
        elseif ($candidates.Count -eq 0) {
            if (-not $DryRun) {
                throw 'The active BCD has only one Windows entry, so there is no "secondary plex" entry to use. If you just added the mirror, wait a minute and run -Phase SyncBoot again.'
            }
            Write-DryRun 'no second Windows entry in the BCD yet (expected until the mirror exists).'
        }
        else {
            $list = ($candidates | ForEach-Object { "  $($_.identifier)  $($_.description)" }) -join "`n"
            throw "More than one candidate entry was found. Run again with -OsEntryId set to the right one:`n$list"
        }
    }
    if ($targetEntry) { Write-Info "Disk $TargetDisk will boot by default: $($targetEntry.identifier) ($($targetEntry.description))" }

    $targetEsp = @(Get-DpPartitions $TargetDisk | Where-Object { $_.Type -eq 'System' })
    if ($DryRun) {
        $defaultText = '<secondary plex entry>'
        if ($targetEntry) { $defaultText = $targetEntry.identifier }
        Write-DryRun "would mount disk $TargetDisk's ESP and the active ESP, then run:"
        Write-DryRun "    bcdboot $env:SystemRoot /s <target ESP> /f UEFI /addlast   (firmware entries checked and restored afterwards)"
        Write-DryRun '    bcdedit /export, copy the BCD to the target ESP, then on that copy:'
        Write-DryRun "    set {bootmgr} and {memdiag} device = target ESP, /default $defaultText, /timeout $BootMenuTimeout"
        if (-not $SkipWinRE) { Write-DryRun "    mirror \Recovery to disk $TargetDisk's Recovery partition (robocopy /E /PURGE) and point the copied BCD's WinRE entry there" }
        return
    }
    if ($targetEsp.Count -ne 1) { throw "Expected one EFI System partition on disk $TargetDisk, found $($targetEsp.Count)." }

    $targetLetter = Get-FreeDriveLetter
    $activeLetter = Get-FreeDriveLetter -Exclude $targetLetter
    $targetMounted = $false
    $activeMounted = $false
    try {
        Invoke-Diskpart -Commands "select disk $TargetDisk", "select partition $($targetEsp[0].Number)", "assign letter=$targetLetter" | Out-Null
        $targetMounted = $true

        $mount = Invoke-Native 'mountvol.exe' @("$($activeLetter):", '/S')
        if ($mount.ExitCode -ne 0) {
            throw "mountvol could not mount the active ESP: $($mount.Output -join ' '). If the ESP already has a drive letter, remove it and run again."
        }
        $activeMounted = $true

        $targetPath = Get-VolumePathForLetter $targetLetter
        $activePath = Get-VolumePathForLetter $activeLetter
        if (-not $targetPath -or -not $activePath) { throw 'Could not resolve the volume names of the two ESPs.' }
        if ($targetPath -eq $activePath) {
            throw "Disk $TargetDisk's ESP is the one this system booted from. Run SyncBoot against the other disk instead."
        }
        Write-Info "Active ESP mounted at $($activeLetter):, target ESP at $($targetLetter):"

        Invoke-TargetBcdboot -TargetLetter $targetLetter -ActiveLetter $activeLetter
        Repair-TargetBcd -TargetLetter $targetLetter -TargetEntry $targetEntry
        if ($SkipWinRE) {
            Write-Info 'Skipping WinRE (-SkipWinRE): the target BCD keeps using the active WinRE.'
        }
        else {
            Sync-TargetWinRE -Store "$($targetLetter):\EFI\Microsoft\Boot\BCD" -TargetEntry $targetEntry -LettersInUse @($targetLetter, $activeLetter)
        }
    }
    finally {
        if ($activeMounted) { Invoke-Native 'mountvol.exe' @("$($activeLetter):", '/D') | Out-Null }
        if ($targetMounted) { Invoke-Native 'mountvol.exe' @("$($targetLetter):", '/D') | Out-Null }
    }
}
#endregion

#region ---------- Main ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run this script from an elevated PowerShell prompt.' -ForegroundColor Red
    exit 1
}

$logFile = Join-Path $env:SystemRoot ('Logs\BootMirror_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
Start-Transcript -Path $logFile | Out-Null
$exitCode = 0
try {
    Write-Step "Pre-flight checks (phase: $Phase$(if ($DryRun) { ', DRY RUN - nothing will be changed' }))"

    try {
        $currentEntry = @(Get-BcdEntries -Id '{current}')[0]
    }
    catch {
        throw "Windows cannot open its boot configuration (BCD). Fix that first; 'bcdedit /enum' must work.`n$($_.Exception.Message)"
    }
    if ($currentEntry.path -notmatch '\.efi$') { throw 'This system is not booted in UEFI mode (winload.efi is not in use).' }

    $bootVolume = Get-BootVolume
    Write-Info ("Boot volume: volume {0} ({1}:), {2}, {3}, on disk(s) {4}" -f $bootVolume.Number, $bootVolume.Letter, $bootVolume.Type, $bootVolume.Status, ($bootVolume.Disks -join ', '))

    if ($SourceDisk -lt 0) {
        $sourceCandidates = @($bootVolume.Disks | Where-Object { $_ -ne $TargetDisk })
        if ($sourceCandidates.Count -ne 1) {
            throw "Could not work out the source disk (the boot volume is on disk(s) $($bootVolume.Disks -join ', ')). Specify -SourceDisk."
        }
        $SourceDisk = $sourceCandidates[0]
    }
    if ($SourceDisk -eq $TargetDisk) { throw 'SourceDisk and TargetDisk must be different disks.' }
    if ($bootVolume.Disks -notcontains $SourceDisk) { throw "Disk $SourceDisk does not hold the boot volume." }

    $targetDp = Get-DpDisks | Where-Object { $_.Number -eq $TargetDisk } | Select-Object -First 1
    if (-not $targetDp) { throw "Disk $TargetDisk was not found in diskpart 'list disk'." }
    $sourceInfo = Get-Disk -Number $SourceDisk -ErrorAction SilentlyContinue
    $targetInfo = Get-Disk -Number $TargetDisk -ErrorAction SilentlyContinue
    Write-Info "Source disk: $SourceDisk    Target disk: $TargetDisk"

    if ($Phase -in 'All', 'PrepareTarget') { Invoke-PrepareTarget }
    if (-not $script:StopAfterPhase -and $Phase -in 'All', 'Mirror') { Invoke-Mirror }
    if (-not $script:StopAfterPhase -and $Phase -in 'All', 'SyncBoot') {
        if ($Phase -eq 'All' -and -not $DryRun) { Start-Sleep -Seconds 10 }   # let Windows add the secondary plex entry
        Invoke-SyncBoot
    }

    if (-not $DryRun -and -not $script:StopAfterPhase) {
        Write-Step 'Status'
        $finalVolume = Get-BootVolume
        Write-Info ("Boot volume {0}: is a {1} on disk(s) {2}, status: {3}" -f $finalVolume.Letter, $finalVolume.Type, ($finalVolume.Disks -join ', '), $finalVolume.Status)
        if ($finalVolume.Status -match 'Rebuild|Resync') {
            Write-Warn 'The mirror is still resynchronizing. Do not test-boot from the second disk until the status is Healthy.'
        }
        Write-Info 'To test: in a maintenance window, press F11 at POST and boot the second disk (often listed as "UEFI OS").'
        Write-Info 'Re-run with -Phase SyncBoot after Windows updates that change the boot files, or after changing BCD settings.'
    }
    Write-Host ''
    Write-Ok "Finished. Log: $logFile"
}
catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log: $logFile"
    $exitCode = 1
}
finally {
    Stop-Transcript | Out-Null
}
exit $exitCode
#endregion